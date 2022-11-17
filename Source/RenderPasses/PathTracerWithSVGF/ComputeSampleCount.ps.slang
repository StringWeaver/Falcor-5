cbuffer PerImageCB
{
	Texture2D gPrevVariance;
	Texture2D gMotion;
	bool gIsFirstFrame;
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
    const int2 imageDim = getTextureDims(gPrevVariance, 0);
	// check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1,1)) || any(coord > imageDim - int2(1,1))) 
		return false;
	return true;
}
PS_OUT main(FullScreenPassVsOut vsOut){
	const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;
    const float2 imageDim = float2(getTextureDims(gPrevVariance, 0));
    const float2 motion = gMotion[ipos].xy;
    const float2 posPrev = posH.xy + motion.xy * imageDim;
    const int2 iposPrev = int2(posPrev);
    PS_OUT psOut;
    if (gIsFirstFrame && isReprjValid(iposPrev)) {
        const float t1 = 0.0;
        const float t2 = 3.0;
        psOut.outSampleCount = uint(lerp(1.0, 3.0, smoothstep(t1, t2, gPrevVariance[iposPrev].r)));
    } else {
        psOut.outSampleCount = 2;
	}
	return psOut;
}