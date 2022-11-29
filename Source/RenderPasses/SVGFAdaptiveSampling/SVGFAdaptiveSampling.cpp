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
#include "SVGFAdaptiveSampling.h"

const RenderPass::Info SVGFAdaptiveSampling::kInfo { "SVGFAdaptiveSampling", "This pass use SVGF to guide samping of Pathtracer." };
namespace {

    const char kSampleCountShader[] = "RenderPasses/SVGFAdaptiveSampling/ComputeSampleCount.ps.slang";
    // Scripting options.
    const std::string kUseAdaptiveSampling = "useAdaptiveSampling";
    const std::string kFixedSpp = "FixedSpp";
    const std::string k2SppThreshold = "2SppThreshold";
    const std::string k3SppThreshold = "3SppThreshold";
    // Subpass dictionary names
    const std::string kPathTracerPassDict = "PathTracerPassDict";
    const std::string kSVGFPassDict = "SVGFPassDict";
    // SVGF Input buffer names
    const char kInputBufferLinearZ[] = "LinearZ";
    const char kInputBufferMotionVector[] = "MotionVec";
    // PathTracer Input buffer names
    const std::string kInputVBuffer = "vbuffer";
    //Internal buffer names
    const char kInternalBufferPreviousVariance[] = "PreviousVariance";
    const char kInternalBufferSampleCount[] = "SampleCount";

}
// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(SVGFAdaptiveSampling::kInfo, SVGFAdaptiveSampling::create);
}

SVGFAdaptiveSampling::SharedPtr SVGFAdaptiveSampling::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new SVGFAdaptiveSampling());
    Dictionary PathTracerPassDict;
    Dictionary SVGFPassDict;
    for (const auto& [key, value] : dict)
    {
        for (const auto& [key, value] : dict)
        {
            if (key == kUseAdaptiveSampling) pPass->mUseAdaptiveSampling = value;
            else if (key == kFixedSpp) pPass->mFixedSpp = value;
            else if (key == k2SppThreshold) pPass->mThreshold2spp = value;
            else if (key == k3SppThreshold) pPass->mThreshold3spp = value;
            else logWarning("Unknown field '{}' in SVGFAdaptiveSampling dictionary.", key);
        }
    }
    pPass->mpSampleCountPass = FullScreenPass::create(kSampleCountShader);
    FALCOR_ASSERT( pPass->mpSampleCountPass);
    return pPass;
}
void SVGFAdaptiveSampling::compile(RenderContext* pRenderContext, const CompileData& compileData) {

    uint2 dim = compileData.defaultTexDims;
    Fbo::Desc desc;
    desc.setSampleCount(0);
    mpFbo = Fbo::create2D(dim.x, dim.y, desc);

    
}

Dictionary SVGFAdaptiveSampling::getScriptingDictionary()
{
    Dictionary dict;
    dict[kUseAdaptiveSampling] = mUseAdaptiveSampling;
    dict[k2SppThreshold] = mThreshold2spp;
    dict[k3SppThreshold] = mThreshold3spp;
    dict[kFixedSpp] = mFixedSpp;
    return dict;
}

RenderPassReflection SVGFAdaptiveSampling::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    //reflector.addOutput("dst");
    
    reflector.addInput(kInputBufferMotionVector, "Motion vectors");
    reflector.addOutput(kInternalBufferPreviousVariance, "Previous Variance")
        .format(ResourceFormat::R16Float)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    reflector.addOutput(kInternalBufferSampleCount, "Sample Count")
        .format(ResourceFormat::R8Uint)
        .bindFlags(Resource::BindFlags::RenderTarget | Resource::BindFlags::ShaderResource);
    return reflector;
}
void SVGFAdaptiveSampling::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) {
    mpScene = pScene;
}
void SVGFAdaptiveSampling::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // renderData holds the requested resources
    // auto& pTexture = renderData["src"]->asTexture();
    if (!mpScene) return;

    auto pLinearZ = renderData[kInputBufferLinearZ]->asTexture();
    auto pMotionVector = renderData[kInputBufferMotionVector]->asTexture();
    auto pPreviousVariance = renderData[kInternalBufferPreviousVariance]->asTexture();
    auto pSampleCount = renderData[kInternalBufferSampleCount]->asTexture();

    FALCOR_ASSERT(mpFbo);
    mpFbo->attachColorTarget(pSampleCount, 0); //set sampleCount as render target
    FALCOR_ASSERT(mpFbo->getWidth() == pSampleCount->getWidth() && mpFbo->getHeight() == pSampleCount->getHeight());
    FALCOR_ASSERT(mpFbo->getWidth() == pPreviousVariance->getWidth() && mpFbo->getHeight() == pPreviousVariance->getHeight());
    auto perImageCB = mpSampleCountPass["PerImageCB"];
    perImageCB["gPrevVariance"] = pPreviousVariance;
    perImageCB["gMotion"] = pMotionVector;
    perImageCB["gThreshold2spp"] = mThreshold2spp;
    perImageCB["gThreshold3spp"] = mThreshold3spp;
    perImageCB["gUseAdaptiveSampling"] = mUseAdaptiveSampling;
    perImageCB["gFixedSpp"] = mFixedSpp;
    mpSampleCountPass->execute(pRenderContext, mpFbo);
}

void SVGFAdaptiveSampling::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Enable Adaptive Sampling", mUseAdaptiveSampling);
    if (mUseAdaptiveSampling) {
        widget.text("Contol Adaptive Sampling Threshold");
        widget.var("2spp threshold", mThreshold2spp, 0.0f, 0.1f, 0.01f);
        widget.var("3spp threshold", mThreshold3spp, 0.1f, 1.0f, 0.01f);
    }
    else {
        widget.var("Fixed spp", mFixedSpp, uint32_t(1), uint32_t(5));
    }
    
    
    
}
