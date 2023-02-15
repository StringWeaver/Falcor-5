import Scene.ShadingData;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;
import SSGAFCommon;
import RenderPasses.Shared.Denoising.NRDConstants;

cbuffer PerImageCB
{
    int2 gPattern;
    float gPhiXY;
    float gPhiColor;
    float gPhiNormal;
    float gPhiDepth;
    float gIgnorePhiColorSampleCountThreshold;
    int gIteration;
    bool gIsFirstPass;
};
Texture2D<float4> gIllumination;
Texture2D<uint> gInputSpp;
Texture2D<float> gValidSpp;
Texture2D<float2> gPathLength;
Texture2D<float4> gNormalRoughnessMaterialID;
RWTexture2D<float4> gOutIllumination;
RWTexture2D<float> gOutValidSpp;

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const int2 ipos = int2(dispatchThreadId.xy);
    // constant samplers to prevent the compiler from generating code which
    // fetches the sampler descriptor from memory for each texture access

    const float zCenter = gPathLength[ipos].x;
    if (zCenter <= 0)
    {
        // not a valid depth => must be envmap => do not filter
        gOutIllumination[ipos] = float4(0.0);
        gOutValidSpp[ipos] = 0.0f;
        return;
    }
    const int2 screenSize = getTextureDims(gIllumination, 0);
    float4 illuminationCenter = gIllumination[ipos];
    // float validSampleCountCenter = gHistoryLength[ipos].x;
    const float illuminationLuminanceCenter = luminance(illuminationCenter.rgb);
    const float sppCenter = gIsFirstPass ? float(gInputSpp[ipos]) : gValidSpp[ipos];
    const float3 nCenter = oct_to_ndir_unorm(gNormalRoughnessMaterialID[ipos].xy);

    // explicitly store/accumulate center pixel with weight 1 to prevent issues
    // with the edge-stopping functions
    float sumWIllumination = sppCenter;
    float4 sumIllumination = sppCenter * illuminationCenter;
    int2 dxdy = gPattern;
    for (int step = 1; step <= 32; step++)
    {
        for (int i = 0; i < 2; i++)
        {
            const int2 p = ipos + dxdy;
            const bool inside = all(p >= int2(0, 0)) && all(p < screenSize);
            if (inside) // skip center pixel, it is already accumulated
            {
                const float4 illuminationP = gIllumination[p];
                const float illuminationLuminanceP = luminance(illuminationP.rgb);
                const float zP = gPathLength[p].x;
                const float3 nP = oct_to_ndir_unorm(gNormalRoughnessMaterialID[p].xy);
                float sppP = gIsFirstPass ? float(gInputSpp[ipos]) : gValidSpp[p];
                // compute the edge-stopping functions
                float phiLIllumination;
                if (sppCenter >= gIgnorePhiColorSampleCountThreshold && sppP >= gIgnorePhiColorSampleCountThreshold) {
                    phiLIllumination = gPhiColor;
                } else {
                    phiLIllumination = 20.0f;
                }
                const float wIllumination = sppP * computeWeight(step, 0, gPhiXY, zCenter, zP, gPhiDepth, nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
                // const float wIllumination = computeWeightBspline(step, gPhiXY, zCenter, zP, gPhiDepth, nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
                sumWIllumination += wIllumination;
                sumIllumination += wIllumination * illuminationP;
            }
            dxdy = -dxdy;
        }
        dxdy += gPattern;
    }

    gOutIllumination[ipos] = sumIllumination / sumWIllumination;
    gOutValidSpp[ipos] = sumWIllumination;
}