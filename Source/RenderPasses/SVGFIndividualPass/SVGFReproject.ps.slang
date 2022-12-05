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
    Texture2D   gIllumination;
    Texture2D   gDiffuseReflectance;
    Texture2D   gPrevIllum;
    Texture2D   gLinearZAndNormal;
    Texture2D   gPrevLinearZAndNormal;
    Texture2D   gPrevHistoryLength;

    float       gMaxHistoryLength;
};

float3 demodulate(float3 c, float3 albedo)
{
    return c / max(albedo, float3(0.001, 0.001, 0.001));
}

bool isReprjValid(int2 coord, float Z, float Zprev, float fwidthZ, float3 normal, float3 normalPrev, float fwidthNormal)
{
    const int2 imageDim = getTextureDims(gIllumination, 0);

    // check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1,1)) || any(coord > imageDim - int2(1,1))) return false;

    // check if deviation of depths is acceptable
    if (abs(Zprev - Z) / (fwidthZ + 1e-2f) > 10.f) return false;

    // check normals for compatibility
    if (distance(normal, normalPrev) / (fwidthNormal + 1e-2) > 16.0) return false;

    return true;
}

bool loadPrevData(float2 posH, out float4 prevIllum, out float historyLength)
{
    const int2 ipos = posH;
    const float2 imageDim = float2(getTextureDims(gIllumination, 0));

    const float2 motion = gMotion[ipos].xy;
    const float normalFwidth = gPositionNormalFwidth[ipos].y;

     const float2 posPrev = posH.xy + motion.xy * imageDim;
     const int2 iposPrev = int2(posPrev);

    float2 ZAndFwidthZ = gLinearZAndNormal[ipos].xy;
    float3 normal = oct_to_ndir_snorm(gLinearZAndNormal[ipos].zw);


    float2 prevZAndFwidthZ = gPrevLinearZAndNormal[iposPrev].xy;
    float3 normalPrev = oct_to_ndir_snorm(gPrevLinearZAndNormal[iposPrev].zw);
    if (isReprjValid(iposPrev, ZAndFwidthZ.x, prevZAndFwidthZ.x, ZAndFwidthZ.y, normal, normalPrev, normalFwidth)) {
        prevIllum = gPrevIllum[iposPrev];
        historyLength = gPrevHistoryLength[iposPrev].x + 1.0f;
        return true;
    } else {
        prevIllum = float4(0, 0, 0, 0);
        historyLength = 1.0f;
        return false;
    }
}

// not used currently
float computeVarianceScale(float numSamples, float loopLength, float alpha)
{
    const float aa = (1.0 - alpha) * (1.0 - alpha);
    return (1.0 - pow(aa, min(loopLength, numSamples))) / (1.0 - aa);
}

struct PS_OUT
{
    float4 OutIllumination : SV_TARGET0;
    float OutHistoryLength       : SV_TARGET1;
};

PS_OUT main(FullScreenPassVsOut vsOut)
{
    const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;

    float3 illumination = gIllumination[ipos].rgb;
    // Workaround path tracer bugs. TODO: remove this when we can.
    if (isNaN(illumination.x) || isNaN(illumination.y) || isNaN(illumination.z))
    {
        illumination = float3(0, 0, 0);
    }

    float historyLength;
    float4 prevIllumination;
    bool success = loadPrevData(posH.xy, prevIllumination, historyLength);
    historyLength = min(gMaxHistoryLength,historyLength);
    // Alpha is the weight of current frame
    const float alpha        =  1.0 / historyLength;

    // variance *= computeVarianceScale(16, 16, alpha);
    const float illuminationLuminance = luminance(illumination);
    const float secondMoment = illuminationLuminance * illuminationLuminance;
    PS_OUT psOut;
    // temporal integration of illumination
    // 2nd moment is propagated through the alpha channel
    psOut.OutIllumination = lerp(prevIllumination,   float4(illumination, secondMoment), alpha);
    psOut.OutHistoryLength = historyLength;
    return psOut;
}
