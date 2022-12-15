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
import SSGAFCommon;
import RenderPasses.Shared.Denoising.NRDConstants;

// Workaround for isnan() not working in slang.
bool isNaN(float f)
{
    uint u = asuint(f) & ~0x80000000u; // clear out the sign bit
    return (u > 0x7F800000);           // greater than Inf is NaN
}

cbuffer PerImageCB
{
    Texture2D   gMotion;
    Texture2D   gIllumination;
    Texture2D   gReflectance;
    Texture2D gPrevIllum;
    Texture2D gLinearZ;
    Texture2D gPrevLinearZ;
    Texture2D gNormalRoughnessMaterialID;
    Texture2D   gPrevHistoryLength;

    float gMaxHistoryLength;
    float gPhiDepth;
};

bool isReprjValid(int2 iposPrev,int2 ipos)
{
    const int2 imageDim = getTextureDims(gIllumination, 0);

    // check whether reprojected pixel is inside of the screen
    if (any(iposPrev < int2(0, 0)) || any(iposPrev >= imageDim)) return false;

    float Z = gLinearZ[ipos].x;
    float prevZ = gPrevLinearZ[iposPrev].x;
    // check if deviation of depths is acceptable
    if (abs(prevZ - Z) >  gPhiDepth*  3.0) return false;

    return true;
}

bool loadPrevData(float2 posH, out float4 prevIllum, out float historyLength)
{
    const int2 ipos = posH;
    const float2 imageDim = float2(getTextureDims(gIllumination, 0));

    const float2 motion = gMotion[ipos].xy;

     const float2 posPrev = posH.xy + motion.xy * imageDim;
     const int2 iposPrev = int2(posPrev);

    
    if (isReprjValid(iposPrev,ipos)) {
        prevIllum = gPrevIllum[iposPrev];
        historyLength = gPrevHistoryLength[iposPrev].x;
        return true;
    } else {
        prevIllum = float4(0, 0, 0, 0);
        historyLength = 0.0f;
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
    PS_OUT psOut;
    float4 illumination = gIllumination[ipos];
    float historyLength;
    // Workaround path tracer bugs. TODO: remove this when we can.
    if (isNaN(illumination.x) || isNaN(illumination.y) || isNaN(illumination.z))
    {
        psOut.OutIllumination = float4(0, 0, 0, 0);
        psOut.OutHistoryLength = 0.f;
        return psOut;
    }

    
    float4 prevIllumination;
    bool success = loadPrevData(posH.xy, prevIllumination, historyLength);
    const float eps = 1e-6;
    if (historyLength >  gMaxHistoryLength - eps) { // historyLength >=  gMaxHistoryLength
        prevIllumination.a *= (gMaxHistoryLength - 1.f) / historyLength;
        historyLength = gMaxHistoryLength - 1.f;
    }


    // variance *= computeVarianceScale(16, 16, alpha);
    
    // temporal integration of illumination
    float weightHistory = historyLength;
    float weightCurrent = 1.f;
    float sumWeight = weightHistory + weightCurrent;
    psOut.OutIllumination =  float4((weightHistory * prevIllumination.rgb + weightCurrent * illumination.rgb) / sumWeight, prevIllumination.a + illumination.a) ;
    psOut.OutHistoryLength = historyLength + 1.f;
    return psOut;
}
