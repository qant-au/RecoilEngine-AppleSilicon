/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "CrispInterface.h"

#if defined(__APPLE__) && !defined(HEADLESS)

#include <cmath>
#include <cstring>

#include <glad/glad.h>

#include "Rendering/GlobalRendering.h"
#include "System/Log/ILog.h"

// See CrispInterface.h. Inside this file the intercepted calls go through the
// real entry points kept below, never through the glad names (which point at
// the wrappers once glad has loaded).
namespace MacCrisp {

namespace {
	PFNGLBINDFRAMEBUFFERPROC    bindFramebuffer = nullptr;
	PFNGLBINDFRAMEBUFFERPROC    bindFramebufferEXT = nullptr;
	PFNGLGETINTEGERVPROC        getIntegerv = nullptr;
	PFNGLVIEWPORTPROC           viewport = nullptr;
	PFNGLSCISSORPROC            scissor = nullptr;
	PFNGLBLITFRAMEBUFFERPROC    blitFramebuffer = nullptr;
	PFNGLBLITFRAMEBUFFERPROC    blitFramebufferEXT = nullptr;
	PFNGLCOPYTEXSUBIMAGE2DPROC  copyTexSubImage2D = nullptr;
	PFNGLCOPYTEXIMAGE2DPROC     copyTexImage2D = nullptr;
	PFNGLREADPIXELSPROC         readPixels = nullptr;

	bool enabled = false;
	bool inWorld = false;
	int  bypass = 0;

	int engW = 1, engH = 1;     // what the engine renders at (MacRenderScale)
	int surfW = 1, surfH = 1;   // the default framebuffer (window pixels)
	float sx = 1.0f, sy = 1.0f; // surface / engine

	// engine-size targets: the world pass, and copies of the default
	// framebuffer read during the interface pass
	struct Target {
		GLuint fbo = 0, color = 0, depth = 0;
		int w = 0, h = 0;
	};
	Target scene;
	Target readCopy;
	bool depthBlitOK = true;

	PFNGLBINDFRAMEBUFFERPROC Bind() { return (bindFramebuffer != nullptr) ? bindFramebuffer : bindFramebufferEXT; }
	PFNGLBLITFRAMEBUFFERPROC Blit() { return (blitFramebuffer != nullptr) ? blitFramebuffer : blitFramebufferEXT; }

	GLint Binding(GLenum which)
	{
		GLint fbo = 0;
		getIntegerv(which, &fbo);
		return fbo;
	}

	// true when calls on this binding address the full-size default
	// framebuffer in engine coordinates, so they need scaling
	bool Scaled(GLenum which)
	{
		if (!enabled || inWorld || bypass > 0 || getIntegerv == nullptr)
			return false;
		return Binding(which) == 0;
	}

	GLint ScaleX(GLint v) { return GLint(std::lround(v * sx)); }
	GLint ScaleY(GLint v) { return GLint(std::lround(v * sy)); }

	void Destroy(Target& t)
	{
		if (t.fbo != 0) glDeleteFramebuffers(1, &t.fbo);
		if (t.color != 0) glDeleteRenderbuffers(1, &t.color);
		if (t.depth != 0) glDeleteRenderbuffers(1, &t.depth);
		t = Target();
	}

	bool Ensure(Target& t, const char* what)
	{
		if (t.fbo != 0 && t.w == engW && t.h == engH)
			return true;

		const GLint read = Binding(GL_READ_FRAMEBUFFER_BINDING);
		const GLint draw = Binding(GL_DRAW_FRAMEBUFFER_BINDING);
		GLint rbo = 0;
		getIntegerv(GL_RENDERBUFFER_BINDING, &rbo);

		Destroy(t);
		glGenFramebuffers(1, &t.fbo);
		Bind()(GL_FRAMEBUFFER, t.fbo);
		glGenRenderbuffers(1, &t.color);
		glBindRenderbuffer(GL_RENDERBUFFER, t.color);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, engW, engH);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, t.color);
		// the default framebuffer is D24S8 (EGL config), which a depth blit must match
		glGenRenderbuffers(1, &t.depth);
		glBindRenderbuffer(GL_RENDERBUFFER, t.depth);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, engW, engH);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, t.depth);
		const bool valid = (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);

		Bind()(GL_READ_FRAMEBUFFER, read);
		Bind()(GL_DRAW_FRAMEBUFFER, draw);
		glBindRenderbuffer(GL_RENDERBUFFER, rbo);

		if (!valid) {
			Destroy(t);
			LOG_L(L_ERROR, "[MacCrisp] could not create the %s framebuffer (%dx%d)", what, engW, engH);
			return false;
		}
		t.w = engW;
		t.h = engH;
		return true;
	}

	// copy between the engine-size and full-size buffers: colour smoothly,
	// depth and stencil as they are (a scaled depth blit must be NEAREST)
	void Copy(int srcW, int srcH, int dstW, int dstH)
	{
		Blit()(0, 0, srcW, srcH, 0, 0, dstW, dstH, GL_COLOR_BUFFER_BIT, GL_LINEAR);
		if (!depthBlitOK)
			return;
		while (glGetError() != GL_NO_ERROR) {}
		Blit()(0, 0, srcW, srcH, 0, 0, dstW, dstH, GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT, GL_NEAREST);
		if (glGetError() != GL_NO_ERROR) {
			depthBlitOK = false;
			LOG_L(L_WARNING, "[MacCrisp] depth/stencil copy refused by the driver; copying colour only");
		}
	}

	// ---- wrappers ---------------------------------------------------------

	void APIENTRY BindFramebufferW(GLenum target, GLuint fbo)
	{
		if (fbo == 0 && enabled && inWorld && bypass == 0 && scene.fbo != 0)
			fbo = scene.fbo;
		bindFramebuffer(target, fbo);
	}
	void APIENTRY BindFramebufferEXTW(GLenum target, GLuint fbo)
	{
		if (fbo == 0 && enabled && inWorld && bypass == 0 && scene.fbo != 0)
			fbo = scene.fbo;
		bindFramebufferEXT(target, fbo);
	}

	void APIENTRY GetIntegervW(GLenum name, GLint* values)
	{
		getIntegerv(name, values);
		if (!enabled || bypass > 0 || values == nullptr)
			return;

		if (inWorld) {
			// the scene framebuffer stands in for the default one: report it as 0,
			// so code that saves and restores the binding restores the scene
			if ((name == GL_DRAW_FRAMEBUFFER_BINDING || name == GL_READ_FRAMEBUFFER_BINDING) && scene.fbo != 0 && GLuint(values[0]) == scene.fbo)
				values[0] = 0;
			return;
		}
		if ((name == GL_VIEWPORT || name == GL_SCISSOR_BOX) && Binding(GL_DRAW_FRAMEBUFFER_BINDING) == 0) {
			values[0] = GLint(std::lround(values[0] / sx)); values[1] = GLint(std::lround(values[1] / sy));
			values[2] = GLint(std::lround(values[2] / sx)); values[3] = GLint(std::lround(values[3] / sy));
		}
	}

	void APIENTRY ViewportW(GLint x, GLint y, GLsizei w, GLsizei h)
	{
		if (Scaled(GL_DRAW_FRAMEBUFFER_BINDING)) {
			viewport(ScaleX(x), ScaleY(y), ScaleX(w), ScaleY(h));
			return;
		}
		viewport(x, y, w, h);
	}

	void APIENTRY ScissorW(GLint x, GLint y, GLsizei w, GLsizei h)
	{
		if (Scaled(GL_DRAW_FRAMEBUFFER_BINDING)) {
			scissor(ScaleX(x), ScaleY(y), ScaleX(w), ScaleY(h));
			return;
		}
		scissor(x, y, w, h);
	}

	void BlitScaled(PFNGLBLITFRAMEBUFFERPROC real, GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0, GLint dx1, GLint dy1, GLbitfield mask, GLenum filter)
	{
		if (Scaled(GL_READ_FRAMEBUFFER_BINDING)) {
			sx0 = ScaleX(sx0); sx1 = ScaleX(sx1);
			sy0 = ScaleY(sy0); sy1 = ScaleY(sy1);
		}
		if (Scaled(GL_DRAW_FRAMEBUFFER_BINDING)) {
			dx0 = ScaleX(dx0); dx1 = ScaleX(dx1);
			dy0 = ScaleY(dy0); dy1 = ScaleY(dy1);
		}
		real(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
	}
	void APIENTRY BlitFramebufferW(GLint a, GLint b, GLint c, GLint d, GLint e, GLint f, GLint g, GLint h, GLbitfield m, GLenum fl)
	{
		BlitScaled(blitFramebuffer, a, b, c, d, e, f, g, h, m, fl);
	}
	void APIENTRY BlitFramebufferEXTW(GLint a, GLint b, GLint c, GLint d, GLint e, GLint f, GLint g, GLint h, GLbitfield m, GLenum fl)
	{
		BlitScaled(blitFramebufferEXT, a, b, c, d, e, f, g, h, m, fl);
	}

	// a read of the default framebuffer during the interface pass is taken
	// from an engine-size copy of it, so its coordinates and sizes stay the
	// engine's (screen copies into view-size textures, screenshots)
	template<typename F>
	void ReadEngineSize(F&& read)
	{
		if (!Scaled(GL_READ_FRAMEBUFFER_BINDING) || !Ensure(readCopy, "read copy")) {
			read();
			return;
		}
		const GLint draw = Binding(GL_DRAW_FRAMEBUFFER_BINDING);
		const bool clipped = glIsEnabled(GL_SCISSOR_TEST);
		if (clipped) glDisable(GL_SCISSOR_TEST);
		Bind()(GL_DRAW_FRAMEBUFFER, readCopy.fbo);
		Copy(surfW, surfH, engW, engH);
		Bind()(GL_READ_FRAMEBUFFER, readCopy.fbo);
		Bind()(GL_DRAW_FRAMEBUFFER, draw);
		if (clipped) glEnable(GL_SCISSOR_TEST);
		read();
		Bind()(GL_READ_FRAMEBUFFER, 0);
	}

	void APIENTRY CopyTexSubImage2DW(GLenum target, GLint level, GLint xoff, GLint yoff, GLint x, GLint y, GLsizei w, GLsizei h)
	{
		ReadEngineSize([&]() { copyTexSubImage2D(target, level, xoff, yoff, x, y, w, h); });
	}
	void APIENTRY CopyTexImage2DW(GLenum target, GLint level, GLenum format, GLint x, GLint y, GLsizei w, GLsizei h, GLint border)
	{
		ReadEngineSize([&]() { copyTexImage2D(target, level, format, x, y, w, h, border); });
	}
	void APIENTRY ReadPixelsW(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type, void* pixels)
	{
		ReadEngineSize([&]() { readPixels(x, y, w, h, format, type, pixels); });
	}
}

void Configure(bool value)
{
	enabled = value;
	if (enabled)
		LOG("[MacCrisp] interface and text at full resolution, world at MacRenderScale (MacCrispInterface)");
}

bool Enabled() { return enabled; }

void SetSizes(int engineW, int engineH, int surfaceW, int surfaceH)
{
	if (engineW <= 0 || engineH <= 0 || surfaceW <= 0 || surfaceH <= 0)
		return;
	if (engineW == engW && engineH == engH && surfaceW == surfW && surfaceH == surfH)
		return;
	engW = engineW; engH = engineH;
	surfW = surfaceW; surfH = surfaceH;
	sx = float(surfW) / float(engW);
	sy = float(surfH) / float(engH);
	if (enabled)
		LOG("[MacCrisp] world %dx%d, interface %dx%d (x%.3f)", engW, engH, surfW, surfH, sx);
}

void* WrapProc(const char* name, void* real)
{
	if (!enabled || real == nullptr || name == nullptr)
		return real;
	#define WRAP(glName, pointer, wrapper) \
		if (std::strcmp(name, glName) == 0) { pointer = reinterpret_cast<decltype(pointer)>(real); return reinterpret_cast<void*>(&wrapper); }
	WRAP("glBindFramebuffer", bindFramebuffer, BindFramebufferW);
	WRAP("glBindFramebufferEXT", bindFramebufferEXT, BindFramebufferEXTW);
	WRAP("glGetIntegerv", getIntegerv, GetIntegervW);
	WRAP("glViewport", viewport, ViewportW);
	WRAP("glScissor", scissor, ScissorW);
	WRAP("glBlitFramebuffer", blitFramebuffer, BlitFramebufferW);
	WRAP("glBlitFramebufferEXT", blitFramebufferEXT, BlitFramebufferEXTW);
	WRAP("glCopyTexSubImage2D", copyTexSubImage2D, CopyTexSubImage2DW);
	WRAP("glCopyTexImage2D", copyTexImage2D, CopyTexImage2DW);
	WRAP("glReadPixels", readPixels, ReadPixelsW);
	#undef WRAP
	return real;
}

void BeginWorld()
{
	if (!enabled || Bind() == nullptr || Blit() == nullptr || getIntegerv == nullptr)
		return;
	if (!Ensure(scene, "scene"))
		return;
	inWorld = true;
	Bind()(GL_FRAMEBUFFER, scene.fbo);
}

void EndWorld()
{
	if (!enabled || !inWorld)
		return;
	inWorld = false;

	// stretch the world into the full-size default framebuffer, then the
	// interface draws on top of it at full resolution
	const bool clipped = glIsEnabled(GL_SCISSOR_TEST);
	if (clipped) glDisable(GL_SCISSOR_TEST);
	Bind()(GL_READ_FRAMEBUFFER, scene.fbo);
	Bind()(GL_DRAW_FRAMEBUFFER, 0);
	Copy(scene.w, scene.h, surfW, surfH);
	Bind()(GL_FRAMEBUFFER, 0);
	if (clipped) glEnable(GL_SCISSOR_TEST);

	BeginInterface();
}

void BeginInterface()
{
	if (!enabled || inWorld || viewport == nullptr)
		return;
	ViewportW(globalRendering->viewPosX, globalRendering->viewPosY, globalRendering->viewSizeX, globalRendering->viewSizeY);
}

int FontRasterScale() { return enabled ? 2 : 1; }

Bypass::Bypass() { ++bypass; }
Bypass::~Bypass() { --bypass; }

} // namespace MacCrisp

#endif // __APPLE__ && !HEADLESS
