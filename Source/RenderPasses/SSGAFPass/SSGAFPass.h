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
#pragma once
#include "Falcor.h"
using namespace Falcor;

class SSGAFPass : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<SSGAFPass>;

    static const Info kInfo;

    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    virtual void renderUI(Gui::Widgets& widget) override;

private:
    SSGAFPass(const Dictionary& dict);

    bool init(const Dictionary& dict);
    void clearBuffers(RenderContext* pRenderContext, const RenderData& renderData);

    bool mBuffersNeedClear = false;

    // SSGAF parameters
    bool    mFilterEnabled       = true;
    int32_t mFilterIterations    = 1;
    int32_t mFeedbackIteration = 1;
    int32_t mReprojectIteration = 1;
    int32_t mPatternSequenceIndex = 0;
    float   mPhiXY = 20.0f;
    float   mPhiColor            = 1.0f;
    float   mIgnorePhiColorSampleCountThreshold = 25.f;
    float   mPhiNormal           = 128.0f;
    float   mPhiDepth            = 1.f;
    float   mMaxHistoryLength    = 32.0f;
    float   mDbgViewScaleFactor = 0.01f;
    bool    mPrevFrameTextureIndex  = 0;
    bool    mUseComputeShader = true;
    uint2 mFrameDim = uint2(1280,720);

    // SSGAF passes
    FullScreenPass::SharedPtr mpReprojection;
    FullScreenPass::SharedPtr mpFilterMoments;
    FullScreenPass::SharedPtr mpSpatial;
    ComputePass::SharedPtr mpSpatialHorizontal;
    ComputePass::SharedPtr mpSpatialVertical;
    FullScreenPass::SharedPtr mpNoiseLevel;

    // Intermediate framebuffers
    Fbo::SharedPtr mpSpatialFbo;
    Fbo::SharedPtr mpReprojFbo;
    Fbo::SharedPtr mpFilteredIlluminationFbo;
    Fbo::SharedPtr mpNoiseLevelFbo;
};
