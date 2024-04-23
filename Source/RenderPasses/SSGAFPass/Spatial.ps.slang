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

cbuffer PerImageCB
{
    Texture2D<float4> gIllumination;
    Texture2D<uint> gInputSpp;
    Texture2D<float> gValidSpp;
    Texture2D<float2> gPathLength;
    Texture2D<float4> gNormalRoughnessMaterialID;

    int2 gPattern;
    float gPhiXY;
    float gPhiColor;
    float gPhiNormal;
    float gPhiDepth;
    float gIgnorePhiColorSampleCountThreshold;
    int gIteration;
    bool gClearSpp;
};
struct PS_OUT
{
    float4 OutIllumination : SV_TARGET0;
    float OutValidSpp : SV_TARGET1;
};
PS_OUT main(FullScreenPassVsOut vsOut) {
    PS_OUT psOut;
    const int2 ipos = int2(vsOut.posH.xy);
    // constant samplers to prevent the compiler from generating code which
    // fetches the sampler descriptor from memory for each texture access

    const float zCenter = gPathLength[ipos].x;
    if (zCenter <= 0)
    {
        // not a valid depth => must be envmap => do not filter
        psOut.OutIllumination = float4(0.0);
        psOut.OutValidSpp = 0.0f;
        return psOut;
    }
    const int2 screenSize = getTextureDims(gIllumination, 0);
    float4 illuminationCenter = gIllumination[ipos];
    const float illuminationLuminanceCenter = luminance(illuminationCenter.rgb);
    const float sppCenter = gClearSpp ? float(gInputSpp[ipos]) : gValidSpp[ipos];
    const float3 nCenter = oct_to_ndir_unorm(gNormalRoughnessMaterialID[ipos].xy);
    float varianceCenter = max(0,illuminationCenter.a - illuminationLuminanceCenter*illuminationLuminanceCenter);

    // explicitly store/accumulate center pixel with weight 1 to prevent issues
    // with the edge-stopping functions
    float sumWIllumination =1.0;
    float sumSpp = sppCenter;
    float4 sumIllumination =  illuminationCenter;
    int2 dxdy = gPattern;
    for (int step = 1; step <= SPATIAL_RADIUS; step++)
    {
        for (int i = 0; i < 2 ; i++)
        {
            const int2 p = ipos + dxdy;
            if (isInsideScreen(p,screenSize)) // skip center pixel, it is already accumulated
            {
                const float4 illuminationP = gIllumination[p];
                const float illuminationLuminanceP = luminance(illuminationP.rgb);
                const float zP = gPathLength[p].x;
                const float3 nP = oct_to_ndir_unorm(gNormalRoughnessMaterialID[p].xy);
                float sppP = gClearSpp ? float(gInputSpp[p]) : gValidSpp[p];
                // compute the edge-stopping functions
                float phiLIllumination;
                if (sppCenter >= gIgnorePhiColorSampleCountThreshold && sppP>= gIgnorePhiColorSampleCountThreshold) {
                    const float epsVariance  = 1e-10;
                    phiLIllumination = gPhiColor * sqrt(varianceCenter+epsVariance);
                } else {
                    phiLIllumination = 10000.0f;
                }
                float wIllumination = computeWeight(step, 0, gPhiXY, zCenter, zP, gPhiDepth, nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
                //const float wIllumination = computeWeightBspline(step, gPhiXY, zCenter, zP, gPhiDepth, nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
                sumWIllumination += wIllumination;
                sumIllumination += wIllumination * illuminationP;
                sumSpp += wIllumination * sppP;
            }
            dxdy = -dxdy;
        }
        dxdy += gPattern;
    }

    psOut.OutIllumination = sumIllumination / sumWIllumination;
    psOut.OutValidSpp = sumSpp;
    return psOut;
}
