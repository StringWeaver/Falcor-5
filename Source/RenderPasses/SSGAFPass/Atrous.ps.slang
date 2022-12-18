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
    Texture2D gIllumination;
    Texture2D gReflectance;
    Texture2D gLinearZ;
    Texture2D gNormalRoughnessMaterialID;

    int2 gPattern;
    float gPhiXY;
    float gPhiColor;
    float gPhiNormal;
    float gPhiDepth;
    float gIgnorePhiColorSampleCountThreshold;
    int gIteration;
};

float4 main(FullScreenPassVsOut vsOut)
    : SV_TARGET0
{
    const int2 ipos = int2(vsOut.posH.xy);
    const int2 screenSize = getTextureDims(gIllumination, 0);
    float4 illuminationCenter = gIllumination.Load(int3(ipos, 0));
    // float validSampleCountCenter = gHistoryLength[ipos].x;
    const float illuminationLuminanceCenter = luminance(illuminationCenter.rgb);

    // constant samplers to prevent the compiler from generating code which
    // fetches the sampler descriptor from memory for each texture access

    const float zCenter = gLinearZ[ipos].x;
    if (zCenter < 0)
    {
        // not a valid depth => must be envmap => do not filter
        return illuminationCenter;
    }
    const float3 nCenter = oct_to_ndir_unorm(gNormalRoughnessMaterialID[ipos].xy);


    // explicitly store/accumulate center pixel with weight 1 to prevent issues
    // with the edge-stopping functions
    float sumWIllumination = 1.0;
    float3 sumIllumination = illuminationCenter.rgb;
    float sumSpp, sum2ndMoment;
    unpackSppAndMoment(illuminationCenter.a, sumSpp, sum2ndMoment);
    float sppCenter = sumSpp;
    int2 dxdy = gPattern;
    for (int step = 1; step <= 32; step++)
    {
        for (int i = 0; i < 2 ; i++)
        {
            const int2 p = ipos +  dxdy;
            const bool inside = all(p >= int2(0, 0)) && all(p < screenSize);
            if (inside) // skip center pixel, it is already accumulated
            {
                const float4 illuminationP = gIllumination.Load(int3(p, 0));
                const float illuminationLuminanceP = luminance(illuminationP.rgb);
                const float zP = gLinearZ[p].x;
                const float3 nP = oct_to_ndir_unorm(gNormalRoughnessMaterialID[p].xy);
                float sppP, o2ndMomentP;
                unpackSppAndMoment(illuminationP.a, sppP, o2ndMomentP);
                // compute the edge-stopping functions
                float phiLIllumination;
                if (sppCenter < gIgnorePhiColorSampleCountThreshold || sppP < gIgnorePhiColorSampleCountThreshold) {
                    phiLIllumination = 1e5;
                } else {
                    phiLIllumination = gPhiColor;
                }
                const float wIllumination= computeWeight(step, 0, gPhiXY,zCenter, zP, gPhiDepth,nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
                //const float wIllumination = computeWeightBspline(step, gPhiXY, zCenter, zP, gPhiDepth, nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
                sumWIllumination += wIllumination;
                sumIllumination += wIllumination * illuminationP.rgb;
                sumSpp += wIllumination * sppP;
                sum2ndMoment += wIllumination * o2ndMomentP;
            }
            dxdy = -dxdy;
        }
        dxdy += gPattern;
    }
    sum2ndMoment /= sumWIllumination;
    float packedSppAndMoment = packSppAndMoment(sumSpp, sum2ndMoment);

    return float4(sumIllumination.rgb / sumWIllumination, packedSppAndMoment);

    
}
