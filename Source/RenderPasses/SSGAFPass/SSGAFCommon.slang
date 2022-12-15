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
int2 getTextureDims(Texture2D tex, uint mip)
{
    uint w, h;
    tex.GetDimensions(w, h);
    return int2(w,h);
}

float computeWeight(
    int xx, int yy, float phiXY,
    float depthCenter, float depthP, float phiDepth,
    float3 normalCenter, float3 normalP, float phiNormal,
    float luminanceIllumCenter, float luminanceIllumP, float phiIllum)
{
    const float weightXY = float(xx * xx + yy * yy) /( 2 * phiXY * phiXY);
    const float weightNormal  = pow(saturate(dot(normalCenter, normalP)), phiNormal);
    const float weightZ = (depthCenter - depthP) / phiDepth;
    const float weightLillum = (luminanceIllumCenter - luminanceIllumP) / (0.5* (luminanceIllumCenter + luminanceIllumP + 1e-5) * phiIllum);
    const float weightIllum   = exp(- weightXY - 0.5 * weightZ * weightZ - 0.5 * weightLillum * weightLillum ) * weightNormal;

    return weightIllum;
}

float computeWeightBspline(
    int i, float phiXY,
    float depthCenter, float depthP, float phiDepth,
    float3 normalCenter, float3 normalP, float phiNormal,
    float luminanceIllumCenter, float luminanceIllumP, float phiIllum)
{
    const float kernelWeights[3] = { 1.0, 2.0 / 3.0, 1.0 / 6.0 };
    const float weightXY = kernelWeights[i];
    const float weightNormal = pow(saturate(dot(normalCenter, normalP)), phiNormal);
    const float weightZ = (depthCenter - depthP) / phiDepth;
    const float weightLillum = (luminanceIllumCenter - luminanceIllumP) / (0.5 * (luminanceIllumCenter + luminanceIllumP + 1e-5) * phiIllum);
    const float weightIllum = weightXY * exp( - 0.5 * weightZ * weightZ - 0.5 * weightLillum * weightLillum) * weightNormal;

    return weightIllum;
}
float3 demodulate(float3 c, float3 albedo)
{
    return c / max(albedo, float3(0.001, 0.001, 0.001));
}

struct FullScreenPassVsOut
{
    float2 texC       : TEXCOORD;
#ifndef _VIEWPORT_MASK
    float4 posH       : SV_POSITION;
#else
    float4 posH       : POSITION;
#endif
};
