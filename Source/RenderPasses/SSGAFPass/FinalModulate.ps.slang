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
    Texture2D gHistoryLength;
    Texture2D gLinearZ;
    Texture2D gNormalRoughnessMaterialID;
    float gMaxHistoryLength;
    float gDbgViewScaleFactor;
    
};
struct PS_OUT{
    float outDbgView0 : SV_TARGET0;
    float outDbgView1 : SV_TARGET1;
    float4 outDbgView2 : SV_TARGET2;
}
PS_OUT main(FullScreenPassVsOut vsOut) 
{
    PS_OUT psOut;
    const int2 ipos = int2(vsOut.posH.xy);
    const float zCenter = gLinearZ[ipos].x;
    const float3 nCenter = oct_to_ndir_unorm(gNormalRoughnessMaterialID[ipos].xy);
    psOut.outDbgView0 = gIllumination[ipos].a * gDbgViewScaleFactor;
    psOut.outDbgView1 = gHistoryLength[ipos].x * gDbgViewScaleFactor;
    psOut.outDbgView2 = float4(nCenter, 0.f) * gDbgViewScaleFactor;
    return psOut;
}
