/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

// smmalloc.h leaks `#define INLINE inline` -- a very generic token that
// collides with unrelated code (e.g. simdjson's layout_mode::INLINE
// enumerator) whenever both end up in the same translation unit. Include
// smmalloc only through this wrapper so the macro is dropped immediately and
// never escapes into engine code.

// smmalloc.h also uses <type_traits> and <cstdlib> without including them,
// which only compiles where another header happens to bring them in.
#include <cstdlib>
#include <type_traits>

#include "smmalloc/smmalloc.h"

#ifdef INLINE
#undef INLINE
#endif
