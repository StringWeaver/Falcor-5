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
#include "SSGAFPass.h"

/*
TODO:
- clean up shaders
- clean up UI: tooltips, etc.
- handle skybox pixels
- enum for fbo channel indices
*/

const RenderPass::Info SSGAFPass::kInfo { "SSGAFPass", "SSGAF denoising pass for individual path type components." };

namespace {
// Shader source files
const char kReprojectShader[] = "RenderPasses/SSGAFPass/Reproject.ps.slang";
const char kSpatialShader[] = "RenderPasses/SSGAFPass/Spatial.ps.slang";
const char kSpatialComputeShader[] = "RenderPasses/SSGAFPass/Spatial.cs.slang";
const char kNoiseLevelShader[] = "RenderPasses/SSGAFPass/NoiseLevel.ps.slang";

// Names of valid entries in the parameter dictionary.
const char kEnabled[] = "Enabled";
const char kUseComputeShader[] = "UseComputeShader";
const char kIterations[] = "Iterations";
const char kFeedbackIteration[] = "FeedbackIteration";
const char kReprojectIteration[] = "ReprojectIteration";
const char kVarianceEpsilon[] = "VarianceEpsilon";
const char kPhiXY[] = "PhiXY";
const char kPhiDepth[] = "PhiDepth";
const char kPhiColor[] = "PhiColor";
const char kIgnorePhiColorSampleCountThreshold[] = "IgnorePhiColorSampleCountThreshold";
const char kPhiNormal[] = "PhiNormal";
const char kMaxHistoryLengthInMs[] = "MaxHistoryLengthInMs";

// Input buffer names
const char kInputBufferIllumination[] = "Illumination";
const char kInputBufferSpp[] = "PathTracerSampleCount";
const char kInputBufferNoiseLevel[] = "NoiseLevel";
const char kInputNormalRoughnessMaterialID[] = "normWRoughnessMaterialID";
const char kInputBufferPathLength[] = "PathLength";
const char kInputBufferMotionVector[] = "MotionVec";

// Internal buffer names
const char kInternalBuffersPreviousPathLength[] = "Previous Path Length";
const char kInternalBufferPreviousLighting[] = "Previous Lighting";
const char kInternalBufferPrevFrameValidSpp[] = "Previous Valid Spp";
const char kInternalBufferValidSpp0[] = "Valid Spp 0";
const char kInternalBufferValidSpp1[] = "Valid Spp 1";
const char kInternalBufferHistoryLength0[] = "HistoryLength 0";
const char kInternalBufferHistoryLength1[] = "HistoryLength 1";

// Output buffer name
const char kOutputBufferFilteredImage[] = "Filtered image";
const char kOutputBufferDebugView0[] = "Debug View 0";
}

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(SSGAFPass::kInfo, SSGAFPass::create);
}

SSGAFPass::SharedPtr SSGAFPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    return SharedPtr(new SSGAFPass(dict));
}

SSGAFPass::SSGAFPass(const Dictionary& dict)
    : RenderPass(kInfo)
{
    for (const auto& [key, value] : dict) {
        if (key == kEnabled)
            mFilterEnabled = value;
        else if (key == kIterations)
            mFilterIterations = value;
        else if (key == kFeedbackIteration)
            mFeedbackIteration = value;
        else if (key == kReprojectIteration)
            mReprojectIteration = value;
        else if (key == kPhiXY)
            mPhiXY = value;
        else if (key == kPhiDepth)
            mPhiDepth = value;
        else if (key == kPhiColor)
            mPhiColor = value;
        else if (key == kIgnorePhiColorSampleCountThreshold)
            mIgnorePhiColorSampleCountThreshold = value;
        else if (key == kPhiNormal)
            mPhiNormal = value;
        else if (key == kMaxHistoryLengthInMs)
            mMaxHistoryLengthInMs = value;
        else
            logWarning("Unknown field '{}' in SSGAFPass dictionary.", key);
    }
    
    auto groupSize = "512";
    auto spatialRadius = "32";
    mpReprojection = FullScreenPass::create(kReprojectShader);
    auto spatialShaderDefineList = Program::DefineList();
    spatialShaderDefineList["SPATIAL_RADIUS"] = spatialRadius;
    mpSpatial = FullScreenPass::create(kSpatialShader,spatialShaderDefineList);
    auto spatialHorizontalDefineList = Program::DefineList();
    spatialHorizontalDefineList["SPATIAL_RADIUS"] = spatialRadius;
    spatialHorizontalDefineList["GROUPSIZE"] = groupSize;
    spatialHorizontalDefineList["GROUPSIZE_X"] = groupSize;
    spatialHorizontalDefineList["GROUPSIZE_Y"] = "1";
    auto spatialVerticalDefineList = Program::DefineList();
    spatialVerticalDefineList["SPATIAL_RADIUS"] = spatialRadius;
    spatialVerticalDefineList["GROUPSIZE"] = groupSize;
    spatialVerticalDefineList["GROUPSIZE_X"] = "1";
    spatialVerticalDefineList["GROUPSIZE_Y"] = groupSize;
    mpSpatialHorizontal = ComputePass::create(kSpatialComputeShader, "main", spatialHorizontalDefineList, false);
    mpSpatialVertical = ComputePass::create(kSpatialComputeShader, "main", spatialVerticalDefineList, false);
    mpSpatialHorizontal->setVars(nullptr);
    mpSpatialVertical->setVars(nullptr);
    mpNoiseLevel = FullScreenPass::create(kNoiseLevelShader);
    FALCOR_ASSERT(mpReprojection && mpSpatial && mpSpatialHorizontal && mpSpatialVertical && mpNoiseLevel);
}

Dictionary SSGAFPass::getScriptingDictionary()
{
    Dictionary dict;
    dict[kEnabled] = mFilterEnabled;
    dict[kIterations] = mFilterIterations;
    dict[kFeedbackIteration] = mFeedbackIteration;
    dict[kReprojectIteration] = mReprojectIteration;
    dict[kPhiXY] = mPhiXY;
    dict[kPhiDepth] = mPhiDepth;
    dict[kPhiColor] = mPhiColor;
    dict[kIgnorePhiColorSampleCountThreshold] = mIgnorePhiColorSampleCountThreshold;
    dict[kPhiNormal] = mPhiNormal;
    dict[kMaxHistoryLengthInMs] = mMaxHistoryLengthInMs;
    return dict;
}


RenderPassReflection SSGAFPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    reflector.addInput(kInputBufferIllumination, "Radiance");
    reflector.addInput(kInputBufferSpp , "SampleCount");
    reflector.addInput(kInputBufferNoiseLevel, "Noise Level");
    reflector.addInput(kInputNormalRoughnessMaterialID, "World normal, roughness, and material ID");
    reflector.addInput(kInputBufferPathLength, "PathLength");
    reflector.addInput(kInputBufferMotionVector, "Motion vectors");

    reflector.addInternal(kInternalBuffersPreviousPathLength, "Previous Linear Z")
        .format(ResourceFormat::R32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousLighting, "Previous Filtered Lighting")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess);
    reflector.addInternal(kInternalBufferPrevFrameValidSpp, kInternalBufferPrevFrameValidSpp)
        .format(ResourceFormat::R32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferValidSpp0, kInternalBufferValidSpp0)
        .format(ResourceFormat::R32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess);
    reflector.addInternal(kInternalBufferValidSpp1, kInternalBufferValidSpp1)
        .format(ResourceFormat::R32Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess);
    reflector.addInternal(kInternalBufferHistoryLength0, kInternalBufferHistoryLength0)
        .format(ResourceFormat::R16Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferHistoryLength1, kInternalBufferHistoryLength1)
        .format(ResourceFormat::R16Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);

    reflector.addOutput(kOutputBufferFilteredImage, "Filtered image").format(ResourceFormat::RGBA32Float);
    reflector.addOutput(kOutputBufferDebugView0, kOutputBufferDebugView0).format(ResourceFormat::R16Float).bindFlags(Resource::BindFlags::RenderTarget);

    return reflector;
}

void SSGAFPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
    {
        Fbo::Desc desc;
        desc.setSampleCount(0);
        mpReprojFbo = Fbo::create2D(mFrameDim.x, mFrameDim.y, desc);
        mpSpatialFbo = Fbo::create2D(mFrameDim.x, mFrameDim.y, desc);
        mpNoiseLevelFbo = Fbo::create2D(mFrameDim.x, mFrameDim.y, desc);
    }

    mBuffersNeedClear = true;
}

void SSGAFPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    Texture::SharedPtr pIlluminationTexture = renderData[kInputBufferIllumination]->asTexture();
    Texture::SharedPtr pInputSppTexture = renderData[kInputBufferSpp]->asTexture();
    Texture::SharedPtr pInputNoiseLevelTexture = renderData[kInputBufferNoiseLevel]->asTexture();
    Texture::SharedPtr pNormalRoughnessMaterialIDTexture = renderData[kInputNormalRoughnessMaterialID]->asTexture();
    Texture::SharedPtr pPathLengthTexture = renderData[kInputBufferPathLength]->asTexture();
    Texture::SharedPtr pMotionVectorTexture = renderData[kInputBufferMotionVector]->asTexture();
    Texture::SharedPtr pPrevFrameIllumTexture = renderData[kInternalBufferPreviousLighting]->asTexture();
    Texture::SharedPtr pPrevFrameValidSppTexture = renderData[kInternalBufferPrevFrameValidSpp]->asTexture();
    Texture::SharedPtr pPrevFramePathLengthTexture = renderData[kInternalBuffersPreviousPathLength]->asTexture();
    Texture::SharedPtr pPrevHistoryLengthTexture;
    Texture::SharedPtr pHistoryLengthTexture;
    if (!mPrevFrameTextureIndex) {
        pPrevHistoryLengthTexture = renderData[kInternalBufferHistoryLength0]->asTexture();
        pHistoryLengthTexture = renderData[kInternalBufferHistoryLength1]->asTexture();

    } else {
        pPrevHistoryLengthTexture = renderData[kInternalBufferHistoryLength1]->asTexture();
        pHistoryLengthTexture = renderData[kInternalBufferHistoryLength0]->asTexture();
    }

    Texture::SharedPtr pOutputColorTexture = renderData[kOutputBufferFilteredImage]->asTexture();
    Texture::SharedPtr pOutputDebugView0Texture = renderData[kOutputBufferDebugView0]->asTexture();

    Texture::SharedPtr pPrevIterIllumTexture = pIlluminationTexture;
    Texture::SharedPtr pCurrIterIllumTexture = pOutputColorTexture;
    Texture::SharedPtr pPrevIterValidSppTexture = renderData[kInternalBufferValidSpp0]->asTexture();
    Texture::SharedPtr pCurrIterValidSppTexture = renderData[kInternalBufferValidSpp1]->asTexture();

    if (mBuffersNeedClear) {
        clearBuffers(pRenderContext, renderData);
        mBuffersNeedClear = false;
    }

    if (mFilterEnabled) {
        // Filter illumination from pPrevIterIllumTexture, storing the result
        // in pCurrIterIllumTexture.  Along the way (or at the end, depending on
        // the value of mFeedbackIteration), save the filtered illumination for
        // next time into mpFilteredPastFbo.

        

        bool clearSpp = true;
        // const std::array<const int2, 4> patternSequence = { int2(0,1), int2(1,1), int2(0,1), int2(-1,1) };
        // mPatternSequenceIndex = (mPatternSequenceIndex + 1) % patternSequence.size();
        // loop 0 is only for temporal filter in case you want to temporal accumutaion ahead of spatial filter
        for (int i = 0; i <= mFilterIterations; i++) {
            bool isLastIteration = (i == mFilterIterations);
            bool isReprojectIter = (i == mReprojectIteration);
            bool isFeedbackIter = (i == mFeedbackIteration);

            // Spatial Accumulation
            if (i >= 1) {
                for (int j = 0; j < 2; j++) {
                    auto pSpatialComputePass = j == 0 ? mpSpatialVertical : mpSpatialHorizontal;
                    ShaderVar spatialPassCB = mUseComputeShader ? pSpatialComputePass["PerImageCB"] : mpSpatial["PerImageCB"];
                    spatialPassCB["gPattern"] = (j==0 ? int2(0, 1) : int2(1, 0)) << i - 1;
                    spatialPassCB["gPhiXY"] = mPhiXY;
                    spatialPassCB["gPhiColor"] = mPhiColor;
                    spatialPassCB["gPhiNormal"] = mPhiNormal;
                    spatialPassCB["gPhiDepth"] = mPhiDepth;
                    spatialPassCB["gIgnorePhiColorSampleCountThreshold"] = mIgnorePhiColorSampleCountThreshold;
                    bool isLastPass = isLastIteration && !isReprojectIter && j == 1;
                    spatialPassCB["gIteration"] = i -1 ;
                    spatialPassCB["gClearSpp"] = clearSpp;
                    
                    clearSpp = false;
                    if(mUseComputeShader){
                        pSpatialComputePass["gPathLength"] = pPathLengthTexture;
                        pSpatialComputePass["gNormalRoughnessMaterialID"] = pNormalRoughnessMaterialIDTexture;
                        pSpatialComputePass["gIllumination"] = pPrevIterIllumTexture;
                        pSpatialComputePass["gValidSpp"] = pPrevIterValidSppTexture;
                        pSpatialComputePass["gInputSpp"] = pInputSppTexture;
                        pSpatialComputePass["gOutIllumination"] = pCurrIterIllumTexture;
                        pSpatialComputePass["gOutValidSpp"] = pCurrIterValidSppTexture;
                        pSpatialComputePass->execute(pRenderContext, mFrameDim.x, mFrameDim.y);
                    }else{
                        spatialPassCB["gPathLength"] = pPathLengthTexture;
                        spatialPassCB["gNormalRoughnessMaterialID"] = pNormalRoughnessMaterialIDTexture;
                        spatialPassCB["gIllumination"] = pPrevIterIllumTexture;
                        spatialPassCB["gValidSpp"] = pPrevIterValidSppTexture;
                        spatialPassCB["gInputSpp"] = pInputSppTexture;
                        mpSpatialFbo->attachColorTarget(pCurrIterIllumTexture, 0);
                        mpSpatialFbo->attachColorTarget(pCurrIterValidSppTexture, 1);
                        mpSpatial->execute(pRenderContext, mpSpatialFbo);
                    }
                    
                    std::swap(pCurrIterIllumTexture, pPrevIterIllumTexture);
                    std::swap(pCurrIterValidSppTexture, pPrevIterValidSppTexture);
                }
            }

            // store the filtered color for the feedback path
            // get illumination and lerp in
            // reprojected filtered illumination from the previous frame.
            // Stores the result as well as initial moments and an updated
            // per-pixel history length in mpReprojFbo.
            if (isReprojectIter) {
                auto reprojPassVars = mpReprojection["PerImageCB"];
                // Setup textures for our reprojection shader pass
                reprojPassVars["gMotion"] = pMotionVectorTexture;
                reprojPassVars["gIllumination"] = pPrevIterIllumTexture;
                reprojPassVars["gValidSpp"] = pPrevIterValidSppTexture;
                reprojPassVars["gInputSpp"] = pInputSppTexture;
                reprojPassVars["gInputNoiseLevel"] = pInputNoiseLevelTexture;
                reprojPassVars["gPrevIllum"] = pPrevFrameIllumTexture;
                reprojPassVars["gPrevHistoryLength"] = pPrevHistoryLengthTexture;
                reprojPassVars["gPrevFrameValidSpp"] = pPrevFrameValidSppTexture;
                reprojPassVars["gNormalRoughnessMaterialID"] = pNormalRoughnessMaterialIDTexture;
                reprojPassVars["gPathLength"] = pPathLengthTexture;
                reprojPassVars["gPrevPathLength"] = pPrevFramePathLengthTexture;
                // Setup variables for our reprojection pass
                if (mUseFixedFrameTime) {
                    reprojPassVars["gMaxHistoryLength"] = mMaxHistoryLengthInMs / mFixedFrameTime;
                }
                else {
                    reprojPassVars["gMaxHistoryLength"] = mMaxHistoryLengthInMs / float(gpFramework->getFrameRate().getAverageFrameTime());                   
                }
                reprojPassVars["gPhiDepth"] = mPhiDepth;
                reprojPassVars["gClearSpp"] = clearSpp;
                reprojPassVars["gUseAdaptiveHistoryLength"] = mUseAdaptiveHistoryLength;
                reprojPassVars["gMaxHistoryLengthStrength"] = mAdaptiveHistoryLengthStrength;
                clearSpp = false;
                mpReprojFbo->attachColorTarget(pCurrIterIllumTexture, 0);
                mpReprojFbo->attachColorTarget(pCurrIterValidSppTexture, 1);
                mpReprojFbo->attachColorTarget(pHistoryLengthTexture, 2);
                mpReprojection->execute(pRenderContext, mpReprojFbo);
                std::swap(pCurrIterIllumTexture, pPrevIterIllumTexture);
                std::swap(pCurrIterValidSppTexture, pPrevIterValidSppTexture);
            }
            if (isFeedbackIter) {
                pRenderContext->blit(pPrevIterIllumTexture->getSRV(), pPrevFrameIllumTexture->getRTV());
                pRenderContext->blit(pPrevIterValidSppTexture->getSRV(), pPrevFrameValidSppTexture->getRTV());
            }
        }

        // Compute albedo * filtered illumination and add emission back in.
        auto noiseLevelPassVars = mpNoiseLevel["PerImageCB"];
        noiseLevelPassVars["gIllumination"] = pOutputColorTexture;
        noiseLevelPassVars["gValidSpp"] = pPrevIterValidSppTexture;
        noiseLevelPassVars["gHistoryLength"] = pHistoryLengthTexture;
        noiseLevelPassVars["gPathLength"] = pPathLengthTexture;
        noiseLevelPassVars["gNormalRoughnessMaterialID"] = pNormalRoughnessMaterialIDTexture;
        noiseLevelPassVars["gDbgViewScaleFactor"] = mDbgViewScaleFactor;
        mpNoiseLevelFbo->attachColorTarget(pOutputColorTexture, 0);
        mpNoiseLevelFbo->attachColorTarget(pOutputDebugView0Texture, 1);
        mpNoiseLevel->execute(pRenderContext, mpNoiseLevelFbo);

        if (pPrevIterIllumTexture != pOutputColorTexture) {
            pRenderContext->blit(pPrevIterIllumTexture->getSRV(), pOutputColorTexture->getRTV());
        }

        // Swap resources so we're ready for next frame.
        mPrevFrameTextureIndex = !mPrevFrameTextureIndex;
        pRenderContext->blit(pPathLengthTexture->getSRV(), pPrevFramePathLengthTexture->getRTV());
    } else {
        pRenderContext->blit(pIlluminationTexture->getSRV(), pOutputColorTexture->getRTV());
    }
}

void SSGAFPass::clearBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    pRenderContext->clearFbo(mpSpatialFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpReprojFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);

    pRenderContext->clearTexture(renderData[kInternalBuffersPreviousPathLength]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferPreviousLighting]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferHistoryLength0]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferHistoryLength1]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferValidSpp0]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferValidSpp1]->asTexture().get());
    pRenderContext->clearTexture(renderData[kInternalBufferPrevFrameValidSpp]->asTexture().get());
    pRenderContext->clearTexture(renderData[kOutputBufferDebugView0]->asTexture().get());
}

// Extracts linear z and its derivative from the linear Z texture and packs
// the normal from the world normal texture and packes them into the FBO.
// (It's slightly wasteful to copy linear z here, but having this all
// together in a single buffer is a small simplification, since we make a
// copy of it to refer to in the next frame.)

void SSGAFPass::renderUI(Gui::Widgets& widget)
{
    int dirty = 0;
    dirty |= (int)widget.checkbox("Enable", mFilterEnabled);
    dirty |= (int)widget.checkbox("Use compute shader for spatial filtering", mUseComputeShader);
    dirty |= (int)widget.checkbox("Use Adaptive History Length", mUseAdaptiveHistoryLength);
    dirty |= (int)widget.var("Adaptive History Length Strength", mAdaptiveHistoryLengthStrength, 0.0f, 100000.0f, 0.01f);

    widget.text("");
    widget.text("Number of filter iterations.  Which");
    widget.text("    iteration feeds into future frames?");
    dirty |= (int)widget.var("Iterations", mFilterIterations, 0, 10, 1);
    dirty |= (int)widget.var("Reproject Iteration", mReprojectIteration, -1, mFilterIterations, 1);
    dirty |= (int)widget.var("Feedback Iteration", mFeedbackIteration, 0, mFilterIterations, 1);

    
    widget.text("");
    widget.text("Contol edge stopping on bilateral fitler");
    dirty |= (int)widget.var("For XY", mPhiXY, 0.5f, 1000.0f, 0.01f);
    dirty |= (int)widget.var("For Color", mPhiColor, 0.01f, 10000.0f, 0.01f);
    dirty |= (int)widget.var("Threshold sample count for PhiColor to take effect", mIgnorePhiColorSampleCountThreshold, 1.f, 1000.0f, 1.f);
    dirty |= (int)widget.var("For Normal", mPhiNormal, 0.001f, 1000.0f, 0.2f);
    dirty |= (int)widget.var("For Depth", mPhiDepth, 0.001f, 100.0f);

    widget.text("");
    widget.text("How much history should be used?");
    widget.text("    (MaxHistoryLength;  0 = no reuse)");
    dirty |= (int)widget.var("Max HistoryLength (ms)", mMaxHistoryLengthInMs, 0.0f, 32000.0f, 1.0f);
    dirty |= (int)widget.checkbox("Use a user specified frame time", mUseFixedFrameTime);
    dirty |= (int)widget.var("frame time", mFixedFrameTime, 1.f, 1000.0f);


    widget.text("");
    widget.text("Control Debug View");
    dirty |= (int)widget.var("Scale Factor", mDbgViewScaleFactor, 0.f, 32.0f);

    if (dirty)
        mBuffersNeedClear = true;
}
