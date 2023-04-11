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
import SSGAFCommon;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers; //temporary for showing normal

cbuffer PerImageCB
{
    Texture2D<float4> gIllumination;
    Texture2D<float> gValidSpp;
    Texture2D gHistoryLength;
    Texture2D gPathLength;
    Texture2D gNormalRoughnessMaterialID;
    float gDbgViewScaleFactor;
    
};
struct PS_OUT{
    float4 outRadiance : SV_TARGET0;
    float outDbgView : SV_TARGET1;
}
float tDistributionInverseCDF975(float degreeOfFreedom) {
    float a = 1041959638471.35;
    float b = 1.65075475862341;
    float c = 2.17792652658284E-07;
    float d = 1.96;
    return (a - d) / (1 + pow(degreeOfFreedom / c, b)) + d;
}
PS_OUT main(FullScreenPassVsOut vsOut) 
{
    PS_OUT psOut;
    const int2 ipos = int2(vsOut.posH.xy);
    const float zCenter = gPathLength[ipos].x;
    const float3 nCenter = oct_to_ndir_unorm(gNormalRoughnessMaterialID[ipos].xy);
    float o1stMoment = luminance(gIllumination[ipos].rgb);
    float variance = gIllumination[ipos].a - o1stMoment * o1stMoment;
    float validSpp = gValidSpp[ipos];
    float noiseLevel = tDistributionInverseCDF975(validSpp) * sqrt(variance / validSpp);
    psOut.outRadiance =  float4(gIllumination[ipos].rgb, noiseLevel);
    psOut.outDbgView = noiseLevel * gDbgViewScaleFactor;
    return psOut;
}
