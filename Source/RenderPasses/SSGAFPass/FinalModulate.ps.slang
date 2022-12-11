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
    Texture2D   gDiffuseReflectance;
    Texture2D   gIllumination;
    Texture2D   gHistoryLength;
    Texture2D   gLinearZAndNormal;
    float gMaxHistoryLength;
    
};
struct PS_OUT{
    float3 outColor: SV_TARGET0;
    float outValidSampleCount : SV_TARGET1;
    float4 outDbgView1 : SV_TARGET2;
    float outDbgView2 : SV_TARGET3;
}
PS_OUT main(FullScreenPassVsOut vsOut) 
{
    PS_OUT psOut;
    const int2 ipos = int2(vsOut.posH.xy);
    float4 illumination = gIllumination[ipos];
    const float2 zCenter = gLinearZAndNormal[ipos].xy;
    const float3 nCenter = oct_to_ndir_snorm(gLinearZAndNormal[ipos].zw);
    psOut.outColor = gIllumination[ipos].rgb / gIllumination[ipos].a;
    psOut.outValidSampleCount = gIllumination[ipos].a / 50000.f;
    psOut.outDbgView1 = float4(nCenter,0.f);
    psOut.outDbgView2 = gHistoryLength[ipos].x/64.f;
    return psOut;
}
