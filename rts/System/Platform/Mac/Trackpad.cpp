/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "Trackpad.h"

#include <cstring>
#include <type_traits>

#include <objc/message.h>
#include <objc/runtime.h>

#include <SDL_events.h>
#include <SDL_keyboard.h>
#include <SDL_timer.h>
#include <SDL_video.h>

namespace MacTrackpad {

// AppKit constants (the engine does not include AppKit headers here)
static constexpr unsigned long NSEventTypeScrollWheel = 22;
static constexpr unsigned long NSEventTypeMagnify = 30;
static constexpr unsigned long NSEventPhaseBegan = 1 << 0;
static constexpr unsigned long NSEventPhaseEnded = 1 << 3;
static constexpr unsigned long NSEventPhaseCancelled = 1 << 4;
static constexpr unsigned long NSEventModifierFlagOption = 1 << 19;

static bool enabled = false;
static Uint32 gestureType = Uint32(-1);
static bool scrolling = false;
static bool pinching = false;
static bool scrollTilts = false;

template<typename R = id, typename... Args>
static R Send(id obj, const char* sel, Args... args)
{
	return reinterpret_cast<R (*)(id, SEL, Args...)>(objc_msgSend)(obj, sel_registerName(sel), args...);
}

static void Push(Action action, float x, float y, bool begin, bool end, bool momentum, bool natural)
{
	static_assert(std::is_trivially_copyable_v<Gesture> && sizeof(Gesture) <= sizeof(SDL_Event));

	SDL_Window* window = SDL_GetMouseFocus();
	const Gesture gesture = {gestureType, SDL_GetTicks(), (window != nullptr) ? SDL_GetWindowID(window) : 0, action, x, y, begin, end, momentum, natural};

	SDL_Event event = {};
	std::memcpy(&event, &gesture, sizeof(gesture));
	SDL_PushEvent(&event);
}

void SetEnabled(bool value)
{
	if (value && gestureType == Uint32(-1))
		gestureType = SDL_RegisterEvents(1);

	enabled = value && (gestureType != Uint32(-1));

	if (!enabled)
		scrolling = pinching = false;
}

bool HandleNativeEvent(id event)
{
	if (!enabled || SDL_GetMouseFocus() == nullptr)
		return false;

	const unsigned long type = Send<unsigned long>(event, "type");

	if (type == NSEventTypeMagnify) {
		const unsigned long phase = Send<unsigned long>(event, "phase");
		const bool end = (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0;
		Push(Action::Pinch, 0.0f, end ? 0.0f : float(Send<double>(event, "magnification")), !pinching || (phase & NSEventPhaseBegan) != 0, end, false, false);
		pinching = !end;
		return true;
	}

	if (type != NSEventTypeScrollWheel)
		return false;

	// a notched mouse wheel has no precise deltas: leave it to SDL (zoom as before)
	if (!Send<signed char>(event, "hasPreciseScrollingDeltas"))
		return false;

	const unsigned long phase = Send<unsigned long>(event, "phase");
	const unsigned long momentum = Send<unsigned long>(event, "momentumPhase");

	// a phase of zero with no momentum is a device that sends no gesture phases
	// (some mice with precise wheels): leave those to SDL as well
	if (phase == 0 && momentum == 0)
		return false;

	const bool begin = !scrolling || (phase & NSEventPhaseBegan) != 0;
	const bool end = ((phase | momentum) & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0;

	// Option at the start of a sequence makes the whole sequence a tilt
	if (begin)
		scrollTilts = (Send<unsigned long>(event, "modifierFlags") & NSEventModifierFlagOption) != 0;

	// scrollingDelta follows the natural-scrolling setting; report the fingers' own direction
	float dx = float(Send<double>(event, "scrollingDeltaX"));
	float dy = float(Send<double>(event, "scrollingDeltaY"));

	const bool natural = Send<signed char>(event, "isDirectionInvertedFromDevice");
	if (!natural) {
		dx = -dx;
		dy = -dy;
	}

	// AppKit's y grows upward: report screen coordinates (y down)
	Push(scrollTilts ? Action::Tilt : Action::Pan, dx, -dy, begin, end, momentum != 0, natural);

	// the momentum tail belongs to the same sequence (its first event follows
	// phase=Ended), so the sequence ends when the momentum does; a new
	// phase=Began starts the next one either way
	scrolling = !(end && momentum != 0);
	return true;
}

bool GetGesture(const SDL_Event& event, Gesture& gesture)
{
	if (gestureType == Uint32(-1) || event.type != gestureType)
		return false;

	std::memcpy(&gesture, &event, sizeof(gesture));
	return true;
}

}
