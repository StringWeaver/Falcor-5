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
    bool gClearSpp;
};
Texture2D<float4> gIllumination;
Texture2D<uint> gInputSpp;
Texture2D<float> gValidSpp;
Texture2D<float2> gPathLength;
Texture2D<float4> gNormalRoughnessMaterialID;
RWTexture2D<float4> gOutIllumination;
RWTexture2D<float> gOutValidSpp;

groupshared float4 gIlluminationCache[GROUPSIZE + 2 * SPATIAL_RADIUS];
groupshared float2 gNormalCache[GROUPSIZE + 2 * SPATIAL_RADIUS];
groupshared float gPathLengthCache[GROUPSIZE + 2 * SPATIAL_RADIUS];
groupshared float gValidSppCache[GROUPSIZE + 2 * SPATIAL_RADIUS];
groupshared float gInitialSppCache[GROUPSIZE + 2 * SPATIAL_RADIUS];
int getCacheIndex(int thid) {
    return thid + SPATIAL_RADIUS; //right shift
}

[numthreads(GROUPSIZE_X, GROUPSIZE_Y, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID, uint3 groupThreadID: SV_GroupThreadID)
{
    int thid = max(groupThreadID.x, groupThreadID.y);
    int cacheIndex = getCacheIndex(thid);
    const int2 ipos = int2(dispatchThreadId.xy);
    // constant samplers to prevent the compiler from generating code which
    // fetches the sampler descriptor from memory for each texture access
    const int2 screenSize = getTextureDims(gIllumination, 0);
    const float zCenter = gPathLength[ipos].x;
    float4 illuminationCenter = gIllumination[ipos];
    const float illuminationLuminanceCenter = luminance(illuminationCenter.rgb);
    const float initialSpp = float(gInputSpp[ipos]);
    const float sppCenter = gClearSpp ? initialSpp : gValidSpp[ipos];
    const float2 packedNCenter = gNormalRoughnessMaterialID[ipos].xy;
    const float3 nCenter = oct_to_ndir_unorm(packedNCenter);

    gPathLengthCache[cacheIndex] = zCenter;
    gIlluminationCache[cacheIndex] = illuminationCenter;
    gInitialSppCache[cacheIndex] = initialSpp;
    gValidSppCache[cacheIndex] = sppCenter;
    gNormalCache[cacheIndex] = packedNCenter;

    const int left = thid - SPATIAL_RADIUS;
    const int leftCacheIndex = getCacheIndex(left);
    if (left < 0 && isInsideScreen(ipos - SPATIAL_RADIUS * gPattern,screenSize)) {
        gPathLengthCache[leftCacheIndex] = gPathLength[ipos - SPATIAL_RADIUS * gPattern].x;
        gIlluminationCache[leftCacheIndex] = gIllumination[ipos - SPATIAL_RADIUS * gPattern];
        float initalSpp = float(gInputSpp[ipos - SPATIAL_RADIUS * gPattern]);
        gInitialSppCache[leftCacheIndex] = initalSpp;
        gValidSppCache[leftCacheIndex] = gClearSpp ? initalSpp : gValidSpp[ipos - SPATIAL_RADIUS * gPattern];
        gNormalCache[leftCacheIndex] = gNormalRoughnessMaterialID[ipos - SPATIAL_RADIUS * gPattern].xy;
    }

    const int right = thid + SPATIAL_RADIUS;
    const int rightCacheIndex = getCacheIndex(right);
    if (right >= GROUPSIZE && isInsideScreen(ipos + SPATIAL_RADIUS * gPattern, screenSize)) {
        gPathLengthCache[rightCacheIndex] = gPathLength[ipos + SPATIAL_RADIUS * gPattern].x;
        gIlluminationCache[rightCacheIndex] = gIllumination[ipos + SPATIAL_RADIUS * gPattern];
        const float initialSpp = float(gInputSpp[ipos + SPATIAL_RADIUS * gPattern]);
        gInitialSppCache[rightCacheIndex] = initialSpp;
        gValidSppCache[rightCacheIndex] = gClearSpp ? initialSpp : gValidSpp[ipos + SPATIAL_RADIUS * gPattern];
        gNormalCache[rightCacheIndex] = gNormalRoughnessMaterialID[ipos + SPATIAL_RADIUS * gPattern].xy;
    }

    // explicitly store/accumulate center pixel with weight 1 to prevent issues
    // with the edge-stopping functions
    float sumWIllumination = sppCenter;
    float4 sumIllumination = sppCenter * illuminationCenter;
    int2 dxdy = gPattern;
    GroupMemoryBarrierWithGroupSync();
    for (int step = 1; step <= SPATIAL_RADIUS; step++)
    {
        for (int i = 0; i < 2; i++)
        {
            const int2 p = ipos + dxdy;
            if (isInsideScreen(p,screenSize)) // skip center pixel, it is already accumulated
            {
                int cacheIndexP = getCacheIndex(i == 0 ? thid + step : thid - step);
                const float4 illuminationP = gIlluminationCache[cacheIndexP] ;
                const float illuminationLuminanceP = luminance(illuminationP.rgb);
                const float zP = gPathLengthCache[cacheIndexP];
                const float3 nP = oct_to_ndir_unorm(gNormalCache[cacheIndexP]);
                float sppP;
                sppP = gValidSppCache[cacheIndexP];

                // compute the edge-stopping functions
                float phiLIllumination;
                if (sppCenter >= gIgnorePhiColorSampleCountThreshold && sppP >= gIgnorePhiColorSampleCountThreshold) {
                    phiLIllumination = gPhiColor;
                } else {
                    phiLIllumination = 200.0f;
                }
                float wIllumination = sppP * computeWeight(step, 0, gPhiXY, zCenter, zP, gPhiDepth, nCenter, nP, gPhiNormal, illuminationLuminanceCenter, illuminationLuminanceP, phiLIllumination);
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
