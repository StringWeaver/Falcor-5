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
#include "PathTracerWithSVGF.h"

const RenderPass::Info PathTracerWithSVGF::kInfo { "PathTracerWithSVGF", "This pass use SVGF to guide samping of Pathtracer." };
namespace {
    // SVGF Input buffer names
    const char kInputBufferDiffuseReflectance[] = "DiffuseReflectance";
    const char kInputBufferSpecularReflectance[] = "SpecularReflectance";
    const char kInputBufferColor[] = "Color";
    const char kInputBufferEmission[] = "Emission";
    const char kInputBufferWorldPosition[] = "WorldPosition";
    const char kInputBufferWorldNormal[] = "WorldNormal";
    const char kInputBufferPosNormalFwidth[] = "PositionNormalFwidth";
    const char kInputBufferLinearZ[] = "LinearZ";
    const char kInputBufferMotionVector[] = "MotionVec";
    // PathTracer Input buffer names
    const std::string kInputVBuffer = "vbuffer";
    const std::string kOutputColor = "color";

}
// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(PathTracerWithSVGF::kInfo, PathTracerWithSVGF::create);
}

PathTracerWithSVGF::SharedPtr PathTracerWithSVGF::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new PathTracerWithSVGF());
    pPass->mpPathTracerPass = PathTracer::create(pRenderContext, dict);
    pPass->mpSVGFPass = SVGFPass::create(pRenderContext,dict);
    return pPass;
}
void PathTracerWithSVGF::compile(RenderContext* pRenderContext, const CompileData& compileData) {
    mpRenderGraph = RenderGraph::create("PathTracerWithSVGF Pass");
    mpRenderGraph->addPass(mpPathTracerPass, "PathTracer");
    mpRenderGraph->addPass(mpSVGFPass, "SVGFPass");
    mpRenderGraph->addEdge("PathTracer.color", "SVGFPass.Color");
    mpRenderGraph->markOutput("SVGFPass.Filtered image");
    mpRenderGraph->setScene(mpScene);
}

Dictionary PathTracerWithSVGF::getScriptingDictionary()
{
    auto pathtracerPassDict = mpPathTracerPass->getScriptingDictionary().toPython();
    auto svgfPassDict = mpSVGFPass->getScriptingDictionary().toPython();
    auto dict = pathtracerPassDict + svgfPassDict;
    return Dictionary(dict);
}

RenderPassReflection PathTracerWithSVGF::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    //reflector.addOutput("dst");
    reflector.addInput(kInputVBuffer, "VBuffer");
    reflector.addInput(kInputBufferDiffuseReflectance, "DiffuseReflectance");
    reflector.addInput(kInputBufferSpecularReflectance, "SpecularReflectance");
    reflector.addInput(kInputBufferEmission, "Emission");
    reflector.addInput(kInputBufferWorldPosition, "World Position");
    reflector.addInput(kInputBufferWorldNormal, "World Normal");
    reflector.addInput(kInputBufferPosNormalFwidth, "PositionNormalFwidth");
    reflector.addInput(kInputBufferLinearZ, "LinearZ");
    reflector.addInput(kInputBufferMotionVector, "Motion vectors");
    reflector.addOutput(kOutputColor, "color").format(ResourceFormat::RGBA32Float);
    return reflector;
}
void PathTracerWithSVGF::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) {
    mpScene = pScene;
    mpPathTracerPass->setScene(pRenderContext, pScene);
    mpSVGFPass->setScene(pRenderContext, pScene);
}
void PathTracerWithSVGF::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // renderData holds the requested resources
    // auto& pTexture = renderData["src"]->asTexture();
    if (!mpScene) return;
    auto pVBuffer = renderData[kInputVBuffer]->asTexture();
    auto pDiffuseReflectance = renderData[kInputBufferDiffuseReflectance]->asTexture();
    auto pSpecularReflectance = renderData[kInputBufferSpecularReflectance]->asTexture();
    auto pEmission = renderData[kInputBufferEmission]->asTexture();
    auto pWorldPosition = renderData[kInputBufferWorldPosition]->asTexture();
    auto pWorldNormal = renderData[kInputBufferWorldNormal]->asTexture();
    auto pPosNormalFwidth = renderData[kInputBufferPosNormalFwidth]->asTexture();
    auto pLinearZ = renderData[kInputBufferLinearZ]->asTexture();
    auto pMotionVector = renderData[kInputBufferMotionVector]->asTexture();
    mpRenderGraph->setInput("PathTracer.vbuffer", pVBuffer);
    mpRenderGraph->setInput("SVGFPass.DiffuseReflectance", pDiffuseReflectance);
    mpRenderGraph->setInput("SVGFPass.SpecularReflectance", pSpecularReflectance);
    mpRenderGraph->setInput("SVGFPass.Emission", pEmission);
    mpRenderGraph->setInput("SVGFPass.WorldPosition", pWorldPosition);
    mpRenderGraph->setInput("SVGFPass.WorldNormal", pWorldNormal);
    mpRenderGraph->setInput("SVGFPass.PositionNormalFwidth", pPosNormalFwidth);
    mpRenderGraph->setInput("SVGFPass.LinearZ", pLinearZ);
    mpRenderGraph->setInput("SVGFPass.MotionVec", pMotionVector);
    mpRenderGraph->execute(pRenderContext);
    auto pSVGFOutColor = mpRenderGraph->getOutput("SVGFPass.Filtered image")->asTexture();
    auto pOutColor = renderData[kOutputColor]->asTexture();
    pRenderContext->copyResource(pOutColor.get(), pSVGFOutColor.get());
}

void PathTracerWithSVGF::renderUI(Gui::Widgets& widget)
{
    mpPathTracerPass->renderUI(widget);
    mpSVGFPass->renderUI(widget);
}
