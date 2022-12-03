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
import SVGFCommon;

cbuffer PerImageCB
{
    Texture2D   gAlbedo;
    Texture2D   gEmission;
    Texture2D   gIllumination;
    Texture2D   gMoments;
    Texture2D   gHistoryLength;
    float       gAlpha;
};
struct PS_OUT{
    float4 outColor: SV_TARGET0;
    float outCoefficientOfVariation : SV_TARGET1;
    float outDbgView1 : SV_TARGET2;
    float outDbgView2 : SV_TARGET3;
}
inline float luminance(float3 rgb)
{
    return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

PS_OUT main(FullScreenPassVsOut vsOut) : SV_TARGET0
{
    PS_OUT psOut;
    const int2 ipos = int2(vsOut.posH.xy);
    psOut.outColor = gAlbedo[ipos] * gIllumination[ipos] + gEmission[ipos];
    psOut.outCoefficientOfVariation = 50.f * gIllumination[ipos].a / (1e-5 + gMoments[ipos].r);
    psOut.outDbgView1 = gHistoryLength[ipos].r * gAlpha;
    psOut.outDbgView2 = gMoments[ipos].r;
    return psOut;
}
