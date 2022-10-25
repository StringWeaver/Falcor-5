cbuffer PerImageCB
{
	Texture2D gPrevVariance;
	Texture2D gLinearZ;
	Texture2D   gPositionNormalFwidth;
	Texture2D   gMotion;
	bool gIsFirstFrame;
}

bool isReprjValid(int2 coord, float Z, float Zprev, float fwidthZ)
{
    const int2 imageDim = getTextureDims(gPrevVariance, 0);

	// check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1,1)) || any(coord > imageDim - int2(1,1))) 
		return false;
    // check if deviation of depths is acceptable
    if (abs(Zprev - Z) / (fwidthZ + 1e-2f) > 10.f)
		return false;
	return true;
}
PS_OUT main(FullScreenPassVsOut vsOut){
	const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;
    const float2 imageDim = float2(getTextureDims(gVariance, 0));
    const float2 motion = gMotion[ipos].xy;
	PS_OUT psOut;
	return psOut;
}