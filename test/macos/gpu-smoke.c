/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
/*
 * GPU smoke test for the macOS driver stack (Mesa zink -> KosmicKrisp -> Metal),
 * with no window: a surfaceless EGL desktop-GL 4.6 compatibility context renders
 * into an FBO and the pixels are read back.
 *
 *  1. renderer string must be zink on KosmicKrisp (never llvmpipe/softpipe)
 *  2. a clear colour reads back exactly
 *  3. two draws with DIFFERENT vertex layouts back to back (vec2/stride 8, then
 *     vec3/stride 12) both land: the bug class patches/mesa 0008 and upstream
 *     6abefa5177e address (a vertex-layout-only change must rebuild the pipeline)
 *  4. a draw after an unbind/rebind of the vertex buffer still lands
 *
 * Prints GPU_SMOKE_OK and exits 0 on success. Built and run by scripts/gpu-smoke.sh.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned int GLenum, GLuint, GLbitfield; typedef int GLint, GLsizei; typedef float GLfloat;
typedef unsigned char GLubyte; typedef char GLchar; typedef long GLsizeiptr; typedef unsigned char GLboolean;
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_FRAMEBUFFER 0x8D40
#define GL_RENDERBUFFER 0x8D41
#define GL_RGBA8 0x8058
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401
#define GL_FLOAT 0x1406
#define GL_FALSE 0
#define GL_TRIANGLES 0x0004
#define GL_ARRAY_BUFFER 0x8892
#define GL_STATIC_DRAW 0x88E4
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82

#define FNS(X) \
 X(const GLubyte*, glGetString, (GLenum)) X(void, glGenFramebuffers, (GLsizei, GLuint*)) \
 X(void, glBindFramebuffer, (GLenum, GLuint)) X(void, glGenRenderbuffers, (GLsizei, GLuint*)) \
 X(void, glBindRenderbuffer, (GLenum, GLuint)) X(void, glRenderbufferStorage, (GLenum, GLenum, GLsizei, GLsizei)) \
 X(void, glFramebufferRenderbuffer, (GLenum, GLenum, GLenum, GLuint)) X(GLenum, glCheckFramebufferStatus, (GLenum)) \
 X(void, glViewport, (GLint, GLint, GLsizei, GLsizei)) X(void, glClearColor, (GLfloat, GLfloat, GLfloat, GLfloat)) \
 X(void, glClear, (GLbitfield)) X(void, glReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*)) \
 X(GLuint, glCreateShader, (GLenum)) X(void, glShaderSource, (GLuint, GLsizei, const GLchar* const*, const GLint*)) \
 X(void, glCompileShader, (GLuint)) X(void, glGetShaderiv, (GLuint, GLenum, GLint*)) \
 X(void, glGetShaderInfoLog, (GLuint, GLsizei, GLsizei*, GLchar*)) X(GLuint, glCreateProgram, (void)) \
 X(void, glAttachShader, (GLuint, GLuint)) X(void, glLinkProgram, (GLuint)) X(void, glGetProgramiv, (GLuint, GLenum, GLint*)) \
 X(void, glUseProgram, (GLuint)) X(GLint, glGetUniformLocation, (GLuint, const GLchar*)) \
 X(void, glUniform4f, (GLint, GLfloat, GLfloat, GLfloat, GLfloat)) X(void, glGenVertexArrays, (GLsizei, GLuint*)) \
 X(void, glBindVertexArray, (GLuint)) X(void, glGenBuffers, (GLsizei, GLuint*)) X(void, glBindBuffer, (GLenum, GLuint)) \
 X(void, glBufferData, (GLenum, GLsizeiptr, const void*, GLenum)) \
 X(void, glVertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void*)) \
 X(void, glEnableVertexAttribArray, (GLuint)) X(void, glDrawArrays, (GLenum, GLint, GLsizei)) X(void, glFinish, (void)) \
 X(GLenum, glGetError, (void))
#define DECL(r, n, a) static r (*n) a;
FNS(DECL)
#define LOAD(r, n, a) n = (r (*) a)eglGetProcAddress(#n); if (!n) { printf("FAIL: missing %s\n", #n); return 1; }

#define W 64
#define H 64
static int fails = 0;
static void expect(const char *what, int x, int y, int r, int g, int b) {
	unsigned char px[4] = {0};
	glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	int ok = abs(px[0] - r) <= 2 && abs(px[1] - g) <= 2 && abs(px[2] - b) <= 2;
	printf("  %s %-38s at (%2d,%2d): got %3d,%3d,%3d want %3d,%3d,%3d\n", ok ? "ok  " : "FAIL", what, x, y, px[0], px[1], px[2], r, g, b);
	if (!ok) fails++;
}

static GLuint shader(GLenum type, const char *src) {
	GLuint s = glCreateShader(type); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
	GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof log, NULL, log); printf("FAIL: shader: %s\n", log); exit(1); }
	return s;
}

int main(void) {
	/* Same EGL setup as the engine (rts/System/Platform/Mac/MacPresentBackend.mm):
	 * default display (Mesa's surfaceless platform), RGBA8/D24S8 pbuffer-capable
	 * GL config, a pbuffer, and a 4.6 compatibility context (the engine's first try). */
	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint maj, min;
	if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &maj, &min)) { printf("FAIL: eglInitialize (0x%x)\n", eglGetError()); return 1; }
	if (!eglBindAPI(EGL_OPENGL_API)) { printf("FAIL: eglBindAPI\n"); return 1; }
	const EGLint cfgAttr[] = { EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
	EGLConfig cfg; EGLint n = 0;
	if (!eglChooseConfig(dpy, cfgAttr, &cfg, 1, &n) || n < 1) { printf("FAIL: no GL config (0x%x)\n", eglGetError()); return 1; }
	const EGLint ctxAttr[] = { EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 6,
		EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttr);
	const EGLint pbAttr[] = { EGL_WIDTH, W, EGL_HEIGHT, H, EGL_NONE };
	EGLSurface sfc = eglCreatePbufferSurface(dpy, cfg, pbAttr);  /* as the engine does */
	if (ctx == EGL_NO_CONTEXT) { printf("FAIL: eglCreateContext (0x%x)\n", eglGetError()); return 1; }
	if (sfc == EGL_NO_SURFACE) { printf("FAIL: eglCreatePbufferSurface (0x%x)\n", eglGetError()); return 1; }
	if (!eglMakeCurrent(dpy, sfc, sfc, ctx)) { printf("FAIL: eglMakeCurrent (0x%x)\n", eglGetError()); return 1; }
	FNS(LOAD)

	const char *renderer = (const char *)glGetString(GL_RENDERER), *version = (const char *)glGetString(GL_VERSION);
	printf("GL_RENDERER: %s\nGL_VERSION:  %s\n", renderer, version);
	if (!renderer || !strstr(renderer, "zink") || !strstr(renderer, "KOSMICKRISP")) { printf("FAIL: not zink on KosmicKrisp\n"); fails++; }
	if (!version || strncmp(version, "4.6", 3) != 0 || !strstr(version, "Compatibility")) { printf("FAIL: not GL 4.6 Compatibility\n"); fails++; }

	GLuint fbo, rb;
	glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { printf("FAIL: FBO incomplete\n"); return 1; }
	glViewport(0, 0, W, H);

	glClearColor(64 / 255.0f, 128 / 255.0f, 191 / 255.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();
	expect("clear colour", 32, 32, 64, 128, 191);

	const char *vs = "#version 330\nlayout(location=0) in vec3 p; void main(){ gl_Position = vec4(p.xy, 0.0, 1.0); }\n";
	const char *fs = "#version 330\nuniform vec4 c; out vec4 o; void main(){ o = c; }\n";
	GLuint prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER, vs)); glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs));
	glLinkProgram(prog); GLint linked = 0; glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	if (!linked) { printf("FAIL: link\n"); return 1; }
	glUseProgram(prog);
	GLint uc = glGetUniformLocation(prog, "c");
	GLuint vao; glGenVertexArrays(1, &vao); glBindVertexArray(vao);

	/* left half: vec2 positions, stride 8 */
	const float left[] = { -1, -1,  0, -1,  -1, 1,   0, -1,  0, 1,  -1, 1 };
	/* right half: vec3 positions, stride 12 (layout change only) */
	const float right[] = { 0, -1, 0,  1, -1, 0,  0, 1, 0,   1, -1, 0,  1, 1, 0,  0, 1, 0 };
	GLuint vb[2]; glGenBuffers(2, vb);
	glBindBuffer(GL_ARRAY_BUFFER, vb[0]); glBufferData(GL_ARRAY_BUFFER, sizeof left, left, GL_STATIC_DRAW);
	glBindBuffer(GL_ARRAY_BUFFER, vb[1]); glBufferData(GL_ARRAY_BUFFER, sizeof right, right, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);

	glBindBuffer(GL_ARRAY_BUFFER, vb[0]); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, 0);
	glUniform4f(uc, 1, 0, 0, 1); glDrawArrays(GL_TRIANGLES, 0, 6);
	glBindBuffer(GL_ARRAY_BUFFER, vb[1]); glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, 0);
	glUniform4f(uc, 0, 1, 0, 1); glDrawArrays(GL_TRIANGLES, 0, 6);
	glFinish();
	expect("draw A (vec2, stride 8)", 16, 32, 255, 0, 0);
	expect("draw B (vec3, stride 12) after layout change", 48, 32, 0, 255, 0);

	/* unbind, then rebind and draw again: the queued rebind must survive */
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glBindBuffer(GL_ARRAY_BUFFER, vb[0]); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, 0);
	glUniform4f(uc, 0, 0, 1, 1); glDrawArrays(GL_TRIANGLES, 0, 6);
	glFinish();
	expect("draw C (rebind after unbind)", 16, 32, 0, 0, 255);
	expect("draw B untouched", 48, 32, 0, 255, 0);

	GLenum err = glGetError();
	if (err) { printf("FAIL: GL error 0x%x\n", err); fails++; }
	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	if (fails) { printf("GPU_SMOKE_FAIL (%d)\n", fails); return 1; }
	printf("GPU_SMOKE_OK\n");
	return 0;
}
