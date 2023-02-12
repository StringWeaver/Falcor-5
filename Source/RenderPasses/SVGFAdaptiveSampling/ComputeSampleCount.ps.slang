cbuffer PerImageCB
{
	Texture2D gPrevNoiseLevel;
	Texture2D gMotion;
    float gThreshold2spp;
    float gThreshold3spp;
    bool gUseAdaptiveSampling;
    uint gFixedSpp;
}
struct FullScreenPassVsOut
{
    float2 texC : TEXCOORD;
#ifndef _VIEWPORT_MASK
    float4 posH : SV_POSITION;
#else
    float4 posH : POSITION;
#endif
};
struct PS_OUT
{
    uint outSampleCount : SV_TARGET0;
};
int2 getTextureDims(Texture2D tex, uint mip)
{
    uint w, h;
    tex.GetDimensions(w, h);
    return int2(w, h);
}
bool isReprjValid(int2 coord)
{
    const int2 imageDim = getTextureDims(gPrevNoiseLevel, 0);
	// check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1,1)) || any(coord > imageDim - int2(1,1))) 
		return false;
	return true;
}
PS_OUT main(FullScreenPassVsOut vsOut){
	const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;
    const float2 imageDim = float2(getTextureDims(gPrevNoiseLevel, 0));
    const float2 motion = gMotion[ipos].xy;
    const float2 posPrev = posH.xy + motion.xy * imageDim;
    const int2 iposPrev = int2(posPrev);
    PS_OUT psOut;
    if(!gUseAdaptiveSampling){
        psOut.outSampleCount = gFixedSpp;
    }
    else if (isReprjValid(iposPrev)) {
        //psOut.outSampleCount = uint(lerp(1.0, 3.0, smoothstep(t1, t2, gPrevNoiseLevel[iposPrev].r)));
        float noiseLevel = gPrevNoiseLevel[iposPrev].r;
        if(noiseLevel<gThreshold2spp){
            psOut.outSampleCount = 1;
        }else if(noiseLevel<gThreshold3spp){
            psOut.outSampleCount = 2;
        }else{
            psOut.outSampleCount = 3;
        }
    } else {
        psOut.outSampleCount = 2;
	}
	return psOut;
}
