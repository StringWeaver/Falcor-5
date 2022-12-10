/***************************************************************************
 # Copyright (c) 2015-22, NVIDIA CORPORATION. All rights reserved.
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
#include "SVGFIndividualPass.h"

/*
TODO:
- clean up shaders
- clean up UI: tooltips, etc.
- handle skybox pixels
- enum for fbo channel indices
*/

const RenderPass::Info SVGFIndividualPass::kInfo { "SVGFIndividualPass", "SVGF denoising pass for individual path type components." };

namespace
{
    // Shader source files
    const char kPackLinearZAndNormalShader[] = "RenderPasses/SVGFIndividualPass/SVGFPackLinearZAndNormal.ps.slang";
    const char kReprojectShader[]            = "RenderPasses/SVGFIndividualPass/SVGFReproject.ps.slang";
    const char kAtrousShader[]               = "RenderPasses/SVGFIndividualPass/SVGFAtrous.ps.slang";
    const char kFinalModulateShader[]        = "RenderPasses/SVGFIndividualPass/SVGFFinalModulate.ps.slang";

    // Names of valid entries in the parameter dictionary.
    const char kEnabled[] = "Enabled";
    const char kIterations[] = "Iterations";
    const char kFeedbackTap[] = "FeedbackTap";
    const char kVarianceEpsilon[] = "VarianceEpsilon";
    const char kCoefficientOfVariationEpsilon[] = "CoefficientOfVariationEpsilon";
    const char kPhiXY[] = "PhiXY";
    const char kPhiColor[] = "PhiColor";
    const char kPhiNormal[] = "PhiNormal";
    const char kMaxHistoryLength[] = "MaxHistoryLength";

    // Input buffer names
    const char kInputBufferDiffuseReflectance[] = "DiffuseReflectance";
    const char kInputBufferIllumination[] = "Illumination";
    const char kInputBufferWorldPosition[] = "WorldPosition";
    const char kInputBufferWorldNormal[] = "WorldNormal";
    const char kInputBufferPosNormalFwidth[] = "PositionNormalFwidth";
    const char kInputBufferLinearZ[] = "LinearZ";
    const char kInputBufferMotionVector[] = "MotionVec";

    // Internal buffer names
    const char kInternalBuffersLinearZAndNormal0[] = "Linear Z and Packed Normal 0";
    const char kInternalBuffersLinearZAndNormal1[] = "Linear Z and Packed Normal 1";
    const char kInternalBufferPreviousLighting[] = "Previous Lighting";
    const char kInternalBufferHistoryLength0[] = "HistoryLength 0";
    const char kInternalBufferHistoryLength1[] = "HistroyLength 1";
    const char kInternalBufferAtrousResult0[] = "Atrous Result 0";
    const char kInternalBufferAtrousResult1[] = "Atrous Result 1";

    // Output buffer name
    const char kOutputBufferFilteredImage[] = "Filtered image";
    const char kOutputBufferCoefficientOfVariation[] = "Coefficient of Variation";
    const char  kOutputBufferDebugView1[] = "Debug View 1";
    const char  kOutputBufferDebugView2[] = "Debug View 2";
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(SVGFIndividualPass::kInfo, SVGFIndividualPass::create);
}

SVGFIndividualPass::SharedPtr SVGFIndividualPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    return SharedPtr(new SVGFIndividualPass(dict));
}

SVGFIndividualPass::SVGFIndividualPass(const Dictionary& dict)
    : RenderPass(kInfo)
{
    for (const auto& [key, value] : dict)
    {
        if (key == kEnabled) mFilterEnabled = value;
        else if (key == kIterations) mFilterIterations = value;
        else if (key == kFeedbackTap) mFeedbackTap = value;
        else if (key == kVarianceEpsilon) mVarainceEpsilon = value;
        else if (key == kCoefficientOfVariationEpsilon) mMomentEpsilon = value;
        else if (key == kPhiXY) mPhiXY = value;
        else if (key == kPhiColor) mPhiColor = value;
        else if (key == kPhiNormal) mPhiNormal = value;
        else if (key == kMaxHistoryLength) mMaxHistoryLength = value;
        else logWarning("Unknown field '{}' in SVGFIndividualPass dictionary.", key);
    }

    mpPackLinearZAndNormal = FullScreenPass::create(kPackLinearZAndNormalShader);
    mpReprojection = FullScreenPass::create(kReprojectShader);
    mpAtrous = FullScreenPass::create(kAtrousShader);
    mpFinalModulate = FullScreenPass::create(kFinalModulateShader);
    FALCOR_ASSERT(mpPackLinearZAndNormal && mpReprojection && mpAtrous && mpFinalModulate);
}

Dictionary SVGFIndividualPass::getScriptingDictionary()
{
    Dictionary dict;
    dict[kEnabled] = mFilterEnabled;
    dict[kIterations] = mFilterIterations;
    dict[kFeedbackTap] = mFeedbackTap;
    dict[kVarianceEpsilon] = mVarainceEpsilon;
    dict[kCoefficientOfVariationEpsilon] = mMomentEpsilon;
    dict[kPhiXY] = mPhiXY;
    dict[kPhiColor] = mPhiColor;
    dict[kPhiNormal] = mPhiNormal;
    dict[kMaxHistoryLength] = mMaxHistoryLength;
    return dict;
}

/*
Reproject:
  - takes: motion, color, prevLighting, prevMoments, linearZ, prevLinearZ, historyLen
    returns: illumination, moments, historyLength
Variance/filter moments:
  - takes: illumination, moments, history length, normal+depth
  - returns: filtered illumination+variance (to ping pong fbo)
a-trous:
  - takes: albedo, filtered illumination+variance, normal+depth, history length
  - returns: final color
*/

RenderPassReflection SVGFIndividualPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    reflector.addInput(kInputBufferDiffuseReflectance, "DiffuseReflectance");
    reflector.addInput(kInputBufferIllumination, "Radiance");
    reflector.addInput(kInputBufferWorldPosition, "World Position");
    reflector.addInput(kInputBufferWorldNormal, "World Normal");
    reflector.addInput(kInputBufferPosNormalFwidth, "PositionNormalFwidth");
    reflector.addInput(kInputBufferLinearZ, "LinearZ");
    reflector.addInput(kInputBufferMotionVector, "Motion vectors");

    reflector.addInternal(kInternalBuffersLinearZAndNormal0, "Previous Linear Z and Packed Normal")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBuffersLinearZAndNormal1, "Previous Linear Z and Packed Normal")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousLighting, "Previous Filtered Lighting")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferAtrousResult0, kInternalBufferAtrousResult0)
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferAtrousResult1, kInternalBufferAtrousResult1)
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferHistoryLength0, kInternalBufferHistoryLength0)
        .format(ResourceFormat::R16Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferHistoryLength1, kInternalBufferHistoryLength1)
        .format(ResourceFormat::R16Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);

    reflector.addOutput(kOutputBufferFilteredImage, "Filtered image").format(ResourceFormat::RGBA32Float);
    reflector.addOutput(kOutputBufferCoefficientOfVariation, "Coefficient of Variation").format(ResourceFormat::R16Float).bindFlags(Resource::BindFlags::RenderTarget);
    reflector.addOutput(kOutputBufferDebugView1, kOutputBufferDebugView1).format(ResourceFormat::RGBA16Float).bindFlags(Resource::BindFlags::RenderTarget);
    reflector.addOutput(kOutputBufferDebugView2, kOutputBufferDebugView2).format(ResourceFormat::R16Float).bindFlags(Resource::BindFlags::RenderTarget);

    return reflector;
}

void SVGFIndividualPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    uint2 dim = compileData.defaultTexDims;
    {
        Fbo::Desc desc;
        desc.setSampleCount(0);
        mpReprojFbo = Fbo::create2D(dim.x, dim.y, desc);
    }

    {
        // Screen-size FBOs with no buffer
        Fbo::Desc desc;
        mpLinearZAndNormalFbo = Fbo::create2D(dim.x, dim.y, desc);
        mpAtrousFbo = Fbo::create2D(dim.x, dim.y, desc);
        mpFinalFbo = Fbo::create2D(dim.x, dim.y, desc);
    }

    mBuffersNeedClear = true;
}

void SVGFIndividualPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    Texture::SharedPtr pDiffuseReflectanceTexture = renderData[kInputBufferDiffuseReflectance]->asTexture();
    Texture::SharedPtr pIlluminationTexture = renderData[kInputBufferIllumination]->asTexture();
    Texture::SharedPtr pWorldPositionTexture = renderData[kInputBufferWorldPosition]->asTexture();
    Texture::SharedPtr pWorldNormalTexture = renderData[kInputBufferWorldNormal]->asTexture();
    Texture::SharedPtr pPosNormalFwidthTexture = renderData[kInputBufferPosNormalFwidth]->asTexture();
    Texture::SharedPtr pLinearZTexture = renderData[kInputBufferLinearZ]->asTexture();
    Texture::SharedPtr pMotionVectorTexture = renderData[kInputBufferMotionVector]->asTexture();
    Texture::SharedPtr pPrevFrameIllumTexture = renderData[kInternalBufferPreviousLighting]->asTexture();
    Texture::SharedPtr pPrevIterIllumTexture = renderData[kInternalBufferAtrousResult0]->asTexture();
    Texture::SharedPtr pCurrIterIllumTexture = renderData[kInternalBufferAtrousResult1]->asTexture();
    Texture::SharedPtr pPrevHistoryLengthTexture;
    Texture::SharedPtr pHistoryLengthTexture;
    Texture::SharedPtr pPrevFrameLinearZAndNormalTexture;
    Texture::SharedPtr pLinearZAndNormalTexture;
    if (!mPrevFrameTextureIndex) {
        pPrevFrameLinearZAndNormalTexture = renderData[kInternalBuffersLinearZAndNormal0]->asTexture();
        pLinearZAndNormalTexture = renderData[kInternalBuffersLinearZAndNormal1]->asTexture();
        pPrevHistoryLengthTexture = renderData[kInternalBufferHistoryLength0]->asTexture();
        pHistoryLengthTexture = renderData[kInternalBufferHistoryLength1]->asTexture();
    }
    else {
        pPrevFrameLinearZAndNormalTexture = renderData[kInternalBuffersLinearZAndNormal1]->asTexture();
        pLinearZAndNormalTexture = renderData[kInternalBuffersLinearZAndNormal0]->asTexture();
        pPrevHistoryLengthTexture = renderData[kInternalBufferHistoryLength1]->asTexture();
        pHistoryLengthTexture = renderData[kInternalBufferHistoryLength0]->asTexture();
    }


    Texture::SharedPtr pOutputColorTexture = renderData[kOutputBufferFilteredImage]->asTexture();
    Texture::SharedPtr pOutputCoefficientOfVariationTexture = renderData[kOutputBufferCoefficientOfVariation]->asTexture();
    Texture::SharedPtr pOutputDebugView1Texture = renderData[kOutputBufferDebugView1]->asTexture();
    Texture::SharedPtr pOutputDebugView2Texture = renderData[kOutputBufferDebugView2]->asTexture();


    if (mBuffersNeedClear)
    {
        clearBuffers(pRenderContext, renderData);
        mBuffersNeedClear = false;
    }

    if (mFilterEnabled)
    {
        // Grab linear z and its derivative and also pack the normal into
        // the last two channels of the mpLinearZAndNormalFbo.
        {
            auto perImageCB = mpPackLinearZAndNormal["PerImageCB"];
            perImageCB["gLinearZ"] = pLinearZTexture;
            perImageCB["gNormal"] = pWorldNormalTexture;
            mpLinearZAndNormalFbo->attachColorTarget(pLinearZAndNormalTexture, 0);
            mpPackLinearZAndNormal->execute(pRenderContext, mpLinearZAndNormalFbo);
        }


        

        // Filter illumination from pPrevIterIllumTexture, storing the result
        // in pCurrIterIllumTexture.  Along the way (or at the end, depending on
        // the value of mFeedbackTap), save the filtered illumination for
        // next time into mpFilteredPastFbo.
        {
            auto perImageCB = mpAtrous["PerImageCB"];
            perImageCB["gLinearZAndNormal"] = pLinearZAndNormalTexture;
            perImageCB["gPhiXY"] = mPhiXY;
            perImageCB["gPhiColor"] = mPhiColor;
            perImageCB["gPhiNormal"] = mPhiNormal;
            perImageCB["gPhiDepth"] = mPhiDepth;
            perImageCB["epsVariance"] = mVarainceEpsilon;
            perImageCB["epsMoment"] = mMomentEpsilon;

            bool isPrevIterIllumTextureWritten = false;
            for (int i = -1; i < mFilterIterations; i++)
            {  
                // Spatial Accumulation
                if (i >= 0) {
                    perImageCB["gIllumination"] = isPrevIterIllumTextureWritten ? pPrevIterIllumTexture : pIlluminationTexture;
                    perImageCB["gStepSize"] = int(pow(3, i));
                    perImageCB["gIteration"] = i;
                    perImageCB["gSetSpp"] = !isPrevIterIllumTextureWritten;
                    mpAtrousFbo->attachColorTarget(pCurrIterIllumTexture, 0);
                    mpAtrous->execute(pRenderContext, mpAtrousFbo);
                    isPrevIterIllumTextureWritten = true;
                    std::swap(pCurrIterIllumTexture, pPrevIterIllumTexture);
                }

                // store the filtered color for the feedback path
                // get illumination and lerp in
                // reprojected filtered illumination from the previous frame.
                // Stores the result as well as initial moments and an updated
                // per-pixel history length in mpReprojFbo.
                if (i == std::min(mFeedbackTap, mFilterIterations - 1))
                {
                    auto reprojPerImageCB = mpReprojection["PerImageCB"];

                    // Setup textures for our reprojection shader pass
                    reprojPerImageCB["gMotion"] = pMotionVectorTexture;
                    reprojPerImageCB["gIllumination"] = isPrevIterIllumTextureWritten ? pPrevIterIllumTexture : pIlluminationTexture;
                    reprojPerImageCB["gDiffuseReflectance"] = pDiffuseReflectanceTexture;
                    reprojPerImageCB["gPositionNormalFwidth"] = pPosNormalFwidthTexture;
                    reprojPerImageCB["gPrevIllum"] = pPrevFrameIllumTexture;
                    reprojPerImageCB["gPrevHistoryLength"] = pPrevHistoryLengthTexture;
                    reprojPerImageCB["gLinearZAndNormal"] = pLinearZAndNormalTexture;
                    reprojPerImageCB["gPrevLinearZAndNormal"] = pPrevFrameLinearZAndNormalTexture;
                    reprojPerImageCB["gSetSpp"] = !isPrevIterIllumTextureWritten;

                    // Setup variables for our reprojection pass
                    reprojPerImageCB["gMaxHistoryLength"] = mMaxHistoryLength;

                    mpReprojFbo->attachColorTarget(pCurrIterIllumTexture, 0);
                    mpReprojFbo->attachColorTarget(pHistoryLengthTexture, 1);
                    mpReprojection->execute(pRenderContext, mpReprojFbo);
                    isPrevIterIllumTextureWritten = true;
                    pRenderContext->blit(pCurrIterIllumTexture->getSRV(), pPrevFrameIllumTexture->getRTV());
                    std::swap(pCurrIterIllumTexture, pPrevIterIllumTexture);
                }
            }

            
        }

        // Compute albedo * filtered illumination and add emission back in.
        auto perImageCB = mpFinalModulate["PerImageCB"];
        perImageCB["gDiffuseReflectance"] = pDiffuseReflectanceTexture;
        perImageCB["gIllumination"] = pPrevIterIllumTexture;
        perImageCB["gHistoryLength"] = pHistoryLengthTexture;
        perImageCB["gMaxHistoryLength"] = mMaxHistoryLength;
        perImageCB["gLinearZAndNormal"] = pPrevFrameLinearZAndNormalTexture;
        mpFinalFbo->attachColorTarget(pOutputColorTexture, 0);
        mpFinalFbo->attachColorTarget(pOutputCoefficientOfVariationTexture, 1);
        mpFinalFbo->attachColorTarget(pOutputDebugView1Texture, 2);
        mpFinalFbo->attachColorTarget(pOutputDebugView2Texture, 3);
        mpFinalModulate->execute(pRenderContext, mpFinalFbo);


        // Swap resources so we're ready for next frame.
        mPrevFrameTextureIndex = !mPrevFrameTextureIndex;
    }
    else
    {
        pRenderContext->blit(pIlluminationTexture->getSRV(), pOutputColorTexture->getRTV());
    }
}



void SVGFIndividualPass::clearBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    pRenderContext->clearFbo(mpLinearZAndNormalFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpAtrousFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpReprojFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);

    pRenderContext->clearTexture(renderData[kInternalBuffersLinearZAndNormal0]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBuffersLinearZAndNormal1]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferPreviousLighting]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferHistoryLength0]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferHistoryLength1]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferAtrousResult0]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferAtrousResult1]->asTexture().get());
    pRenderContext->clearTexture(renderData[kOutputBufferCoefficientOfVariation]->asTexture().get());
    
}

// Extracts linear z and its derivative from the linear Z texture and packs
// the normal from the world normal texture and packes them into the FBO.
// (It's slightly wasteful to copy linear z here, but having this all
// together in a single buffer is a small simplification, since we make a
// copy of it to refer to in the next frame.)


void SVGFIndividualPass::renderUI(Gui::Widgets& widget)
{
    int dirty = 0;
    dirty |= (int)widget.checkbox("Enable SVGF", mFilterEnabled);

    widget.text("");
    widget.text("Number of filter iterations.  Which");
    widget.text("    iteration feeds into future frames?");
    dirty |= (int)widget.var("Iterations", mFilterIterations, 0, 10, 1);
    dirty |= (int)widget.var("Feedback Iteration Index", mFeedbackTap, -1, mFilterIterations - 1, 1);

    widget.text("");
    widget.text("Contol edge stopping on bilateral fitler");
    dirty |= (int)widget.var("For XY", mPhiXY, 0.5f, 1000.0f, 0.01f);
    dirty |= (int)widget.var("For Color", mPhiColor, 0.01f, 10000.0f, 0.01f);
    dirty |= (int)widget.var("For Normal", mPhiNormal, 0.001f, 1000.0f, 0.2f);
    dirty |= (int)widget.var("For Depth", mPhiDepth, 0.001f, 30.0f);

    widget.text("Control epsilons");
    dirty |= (int)widget.var("Eps Variance", mVarainceEpsilon, 1e-10f, 1.0f, 0.000000001f);
    dirty |= (int)widget.var("Eps Moment(for compute Coefficient of Variation)", mMomentEpsilon, 1e-10f, 1.0f, 0.000000001f);
    
    widget.text("");
    widget.text("How much history should be used?");
    widget.text("    (MaxHistoryLength;  1 = no reuse)");
    dirty |= (int)widget.var("Max HistoryLength", mMaxHistoryLength, 1.0f, 32.0f, 1.0f);

    

    if (dirty) mBuffersNeedClear = true;
}
