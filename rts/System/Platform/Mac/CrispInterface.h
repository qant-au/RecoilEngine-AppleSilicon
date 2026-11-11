/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef MAC_CRISP_INTERFACE_H
#define MAC_CRISP_INTERFACE_H

// MacCrispInterface (macOS, off by default; takes effect only with
// MacRenderScale below 1): the 3D world renders at MacRenderScale as before,
// but the interface and its text are drawn at the window's full resolution.
//
// The engine keeps working at the MacRenderScale size (its window, view,
// mouse and every screen-space shader are unchanged). Only the GL default
// framebuffer (the pbuffer) is full size. While the world draws, binds of
// framebuffer 0 go to an engine-size scene framebuffer; the world is then
// stretched into the pbuffer (plain linear filtering) and the interface pass
// draws on top, its viewport and scissor scaled to the full-size buffer.
// Reads of the default framebuffer during the interface pass are taken from
// an engine-size copy, so screen copies keep the sizes the engine expects.
// Fonts rasterise at twice their size so text stays sharp.
//
// Design after smallketchup82's ZkMacOS "Retina text and UI" mode
// (https://github.com/smallketchup82/ZkMacOS), written again for this tree.
namespace MacCrisp {
	// latched once at context creation
	void Configure(bool enabled);
	bool Enabled();

	// engine (MacRenderScale) size and default-framebuffer (full) size
	void SetSizes(int engineW, int engineH, int surfaceW, int surfaceH);

	// gladLoadGLLoader hook: returns a wrapper for the calls this mode
	// intercepts (and remembers the real entry point), otherwise real
	void* WrapProc(const char* name, void* real);

	// Game::Draw: the world pass (up to and including screen effects)
	void BeginWorld();
	void EndWorld();
	// screens that do not set their own viewport each frame (the lobby)
	void BeginInterface();

	// glyph raster scale for CFontTexture (1 when off)
	int FontRasterScale();

	// the present path: raw access to the full-size default framebuffer
	struct Bypass {
		Bypass();
		~Bypass();
	};
}

#endif // MAC_CRISP_INTERFACE_H
