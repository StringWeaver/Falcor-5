/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
import Scene.ShadingData;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;
import SVGFCommon;

// Workaround for isnan() not working in slang.
bool isNaN(float f)
{
    uint u = asuint(f) & ~0x80000000u; // clear out the sign bit
    return (u > 0x7F800000);           // greater than Inf is NaN
}

cbuffer PerImageCB
{
    Texture2D   gMotion;
    Texture2D   gPositionNormalFwidth;
    Texture2D   gColor;
    Texture2D   gDiffuseReflectance;
    Texture2D   gSpecularReflectance;
    Texture2D   gEmission;
    Texture2D   gPrevIllum;
    Texture2D   gPrevMoments;
    Texture2D   gLinearZAndNormal;
    Texture2D   gPrevLinearZAndNormal;
    Texture2D   gPrevHistoryLength;

    float       gAlpha;
    float       gMomentsAlpha;
};

float3 demodulate(float3 c, float3 albedo)
{
    return c / max(albedo, float3(0.001, 0.001, 0.001));
}

bool isReprjValid(int2 coord, float Z, float Zprev, float fwidthZ, float3 normal, float3 normalPrev, float fwidthNormal)
{
    const int2 imageDim = getTextureDims(gColor, 0);

    // check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1,1)) || any(coord > imageDim - int2(1,1))) return false;

    // check if deviation of depths is acceptable
    if (abs(Zprev - Z) / (fwidthZ + 1e-2f) > 10.f) return false;

    // check normals for compatibility
    if (distance(normal, normalPrev) / (fwidthNormal + 1e-2) > 16.0) return false;

    return true;
}

bool loadPrevData(float2 posH, out float4 prevIllum, out float2 prevMoments, out float historyLength)
{
    const int2 ipos = posH;
    const float2 imageDim = float2(getTextureDims(gColor, 0));

    const float2 motion = gMotion[ipos].xy;
    const float normalFwidth = gPositionNormalFwidth[ipos].y;

     const float2 posPrev = posH.xy + motion.xy * imageDim;
     const int2 iposPrev = int2(posPrev);

    float2 depth = gLinearZAndNormal[ipos].xy;
    float3 normal = oct_to_ndir_snorm(gLinearZAndNormal[ipos].zw);

    prevIllum   = float4(0,0,0,0);
    prevMoments = float2(0, 0);
    historyLength = 0.0;

    bool v[4];
    
    const float2 offset[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };

    // check for all 4 taps of the bilinear filter for validity
    bool valid = false;
    float sumw = 0;
    for (int tapIdx = 0; tapIdx < 4; tapIdx++)
    {
        float2 tapPos = posPrev + offset[tapIdx];
        int2 tapIpos = tapPos;
        float2 tapCenter = tapIpos + float2(0.5, 0.5);
        float tapWeight = (1.0 - abs(posPrev.x - tapCenter.x)) * (1.0 - abs(posPrev.y - tapCenter.y));
        float2 depthPrev = gPrevLinearZAndNormal[tapIpos].xy;
        float3 normalPrev = oct_to_ndir_snorm(gPrevLinearZAndNormal[tapIpos].zw);

        if (isReprjValid(tapIpos, depth.x, depthPrev.x, depth.y, normal, normalPrev, normalFwidth)) {
            prevIllum += tapWeight * gPrevIllum[tapIpos];
            prevMoments += tapWeight * gPrevMoments[tapIpos].xy;
            historyLength += gPrevHistoryLength[tapIpos].x;
            sumw += tapWeight;
        };
    }
    valid = (sumw >= 0.01);
    prevIllum = valid ? prevIllum / sumw : float4(0, 0, 0, 0);
    prevMoments = valid ? prevMoments / sumw : float2(0, 0);
    historyLength = valid ? historyLength / sumw : 0.0;


    if (!valid) // perform cross-bilateral filter in the hope to find some suitable samples somewhere
    {
        float nValid = 0.0;

        // this code performs a binary descision for each tap of the cross-bilateral filter
        const int radius = 1;
        for (int yy = -radius; yy <= radius; yy++)
        {
            for (int xx = -radius; xx <= radius; xx++)
            {
                const int2 p = iposPrev + int2(xx, yy);
                const float2 depthFilter = gPrevLinearZAndNormal[p].xy;
                const float3 normalFilter = oct_to_ndir_snorm(gPrevLinearZAndNormal[p].zw);

                if (isReprjValid(iposPrev, depth.x, depthFilter.x, depth.y, normal, normalFilter, normalFwidth))
                {
                    prevIllum += gPrevIllum[p];
                    prevMoments += gPrevMoments[p].xy;
                    historyLength += gPrevHistoryLength[p].x;
                    nValid += 1.0;
                }
            }
        }
        if (nValid > 0)
        {
            valid = true;
            prevIllum   /= nValid;
            prevMoments /= nValid;
            historyLength /= valid;
        }
    }


    return valid;
}

// not used currently
float computeVarianceScale(float numSamples, float loopLength, float alpha)
{
    const float aa = (1.0 - alpha) * (1.0 - alpha);
    return (1.0 - pow(aa, min(loopLength, numSamples))) / (1.0 - aa);
}

struct PS_OUT
{
    float4 OutIllumination  : SV_TARGET0;
    float2 OutMoments       : SV_TARGET1;
    float  OutHistoryLength : SV_TARGET2;
};

PS_OUT main(FullScreenPassVsOut vsOut)
{
    const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;

    float3 illumination = demodulate(gColor[ipos].rgb - gEmission[ipos].rgb, gDiffuseReflectance[ipos].rgb + gSpecularReflectance[ipos].rgb);
    // Workaround path tracer bugs. TODO: remove this when we can.
    if (isNaN(illumination.x) || isNaN(illumination.y) || isNaN(illumination.z))
    {
        illumination = float3(0, 0, 0);
    }

    float historyLength;
    float4 prevIllumination;
    float2 prevMoments;
    bool success = loadPrevData(posH.xy, prevIllumination, prevMoments, historyLength);
    historyLength = min(32.0f, success ? historyLength + 1.0f : 1.0f);

    // this adjusts the alpha for the case where insufficient history is available.
    // It boosts the temporal accumulation to give the samples equal weights in
    // the beginning.
    // Alpha is the weight of current frame
    const float alpha        = success ? max(gAlpha,        1.0 / historyLength) : 1.0;
    const float alphaMoments = success ? max(gMomentsAlpha, 1.0 / historyLength) : 1.0;

    // compute first two moments of luminance
    float2 moments;
    moments.r = luminance(illumination);
    moments.g = moments.r * moments.r;

    float2 pm = moments;

    // temporal integration of the moments
    moments = lerp(prevMoments, moments, alphaMoments);

    float variance = max(0.f, moments.g - moments.r * moments.r);

    //variance *= computeVarianceScale(16, 16, alpha);

    PS_OUT psOut;
    // temporal integration of illumination
    psOut.OutIllumination = lerp(prevIllumination,   float4(illumination,   0), alpha);
    // variance is propagated through the alpha channel
    psOut.OutIllumination.a = variance;
    psOut.OutMoments = moments;
    psOut.OutHistoryLength = historyLength;

    return psOut;
}
