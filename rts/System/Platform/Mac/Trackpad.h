/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef MAC_TRACKPAD_H
#define MAC_TRACKPAD_H

#include <SDL_events.h>
#include <objc/objc.h>

// Trackpad camera gestures on macOS (MacTrackpadEnabled, off by default):
// two-finger scroll pans the map, pinch zooms, Option + two-finger scroll
// tilts. SDL2 reports neither pinches nor scroll phases, so the AppKit events
// are read where MacKeyboard's sendEvent: hook sees them and passed on as a
// private SDL event. Design after smallketchup82's ZkMacOS trackpad support
// (https://github.com/smallketchup82/ZkMacOS), written again for this tree.
namespace MacTrackpad {
	enum class Action { Pan, Pinch, Tilt };

	struct Gesture {
		Uint32 type;
		Uint32 timestamp;
		Uint32 windowID;
		Action action;
		float x;         // Pan, Tilt: finger movement in points (x right, y down); Pinch: magnification
		float y;
		bool begin;
		bool end;
		bool momentum;   // the inertial tail after the fingers lift
		bool natural;    // the user scrolls naturally (content follows the fingers)
	};

	void SetEnabled(bool enabled);
	// AppKit event from the sendEvent: hook; true when it was taken as a gesture
	bool HandleNativeEvent(id event);
	// the gesture carried by an SDL event, if it is one of ours
	bool GetGesture(const SDL_Event& event, Gesture& gesture);
}

#endif // MAC_TRACKPAD_H
