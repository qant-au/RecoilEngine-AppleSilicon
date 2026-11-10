/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include <cmath>
#include <numeric>
#include "System/SpringMath.h"
#include "System/Misc/SpringTime.h"
#include "Sim/Units/Scripts/CobInstance.h"

#include <catch_amalgamated.hpp>

// COB scripts encode angles as TA units where a full turn is COBSCALE (65536),
// so any angle past a half turn exceeds the range of a signed short and is meant
// to wrap around (it is a circular 16-bit angle). Truncating the scaled value to
// int first is well defined for the bounded angles the sim feeds in, and the
// following int->short narrowing performs that modular wrap deterministically.
// Converting straight from float to short would be undefined behaviour once the
// value leaves short's range, and produced different results on arm64 vs x86,
// desyncing multiplayer.
static inline short RadAngleToCobShort(float radAngle)
{
	return static_cast<short>(static_cast<int>(radAngle * RAD2TAANG));
}

InitSpringTime ist;

TEST_CASE("ClampRad")
{
	// Test 0 (should return 0)
	CHECK(ClampRad(0.0f) == 0.0f);

	// Test math::TWOPI (should return 0 because TWOPI wraps to 0)
	CHECK(ClampRad(math::TWOPI) == 0.0f);

	// Test std::nextafterf(math::TWOPI, -inf) (should return value just under TWOPI)
	CHECK(ClampRad(std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity())) == std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity()));

	// Test math::PI (should return PI because PI is in [0, TWOPI))
	CHECK(ClampRad(math::PI) == math::PI);

	// Test negative value -math::PI (should return PI because -PI + TWOPI = PI)
	CHECK(ClampRad(-math::PI) == math::PI);

	// Test negative value -math::TWOPI (should return 0)
	CHECK(ClampRad(-math::TWOPI) == 0.0f);

	// Test std::nextafterf(-math::TWOPI, +inf) (should return small positive value)
	{
		const float input = std::nextafterf(-math::TWOPI, +std::numeric_limits<float>::infinity());
		CHECK(ClampRad(input) == input + math::TWOPI);
	}

	// Test with -0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRad(-0.0f)));

	// Test with +0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRad(0.0f)));

	// Test TAANG2RAD conversion to short for [0, 2pi)
	CHECK(RadAngleToCobShort(ClampRad(0.0f)) == short(0));
	CHECK(RadAngleToCobShort(ClampRad(+std::nextafterf(math::TWOPI, -std::numeric_limits<float>::infinity()))) == short(-1));
	CHECK(RadAngleToCobShort(ClampRad(+std::nextafterf(       0.0f, +std::numeric_limits<float>::infinity()))) == short( 0));
	CHECK(RadAngleToCobShort(ClampRad(+std::nextafterf(TAANG2RAD  , +std::numeric_limits<float>::infinity()))) == short(+1));
}

TEST_CASE("ClampRadPi")
{
	// Test math::PI (should return -math::PI because PI is not in [-PI, PI))
	CHECK(ClampRadPi(math::PI) == -math::PI);

	// Test std::nextafterf(math::PI, +inf) (should return -math::PI)
	CHECK(ClampRadPi(std::nextafterf(math::PI, +std::numeric_limits<float>::infinity())) == std::nextafterf(-math::PI, +std::numeric_limits<float>::infinity()));

	// Test std::nextafterf(math::PI, -inf) (should return math::PI because it's the largest value < PI)
	CHECK(ClampRadPi(std::nextafterf(math::PI, -std::numeric_limits<float>::infinity())) == std::nextafterf(+math::PI, -std::numeric_limits<float>::infinity()));

	// Test -math::PI (should return -math::PI because -PI is in [-PI, PI))
	CHECK(ClampRadPi(-math::PI) == -math::PI);

	// Test std::nextafterf(-math::PI, +inf) (should return -math::PI)
	CHECK(ClampRadPi(std::nextafterf(-math::PI, +std::numeric_limits<float>::infinity())) == std::nextafterf(-math::PI, +std::numeric_limits<float>::infinity()));

	// Test std::nextafterf(-math::PI, -inf) (should return math::PI because it wraps around)
	CHECK(ClampRadPi(std::nextafterf(-math::PI, -std::numeric_limits<float>::infinity())) == std::nextafterf(+math::PI, -std::numeric_limits<float>::infinity()));

	// Test with -0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRadPi(-0.0f)));

	// Test with +0.0f and verify the result is not negative zero (signbit returns false)
	CHECK_FALSE(std::signbit(ClampRadPi(0.0f)));

	// Test TAANG2RAD conversion to short for [-pi, pi)
	CHECK(RadAngleToCobShort(ClampRadPi(-(math::PI))) == short(-32768));
	CHECK(RadAngleToCobShort(ClampRadPi(+std::nextafterf(math::PI, -std::numeric_limits<float>::infinity()))) == short(32767));
	CHECK(RadAngleToCobShort(ClampRadPi((math::PI))) == short(-32768));
}

TEST_CASE("FloatToHeadingWrapped")
{
	// in range of short: the plain conversion, truncating toward zero
	CHECK(FloatToHeadingWrapped(0.0f) == 0);
	CHECK(FloatToHeadingWrapped(1234.9f) == 1234);
	CHECK(FloatToHeadingWrapped(-1234.9f) == -1234);
	CHECK(FloatToHeadingWrapped(32767.0f) == 32767);
	CHECK(FloatToHeadingWrapped(-32768.0f) == -32768);

	// in range of int: the low 16 bits, so headings wrap
	CHECK(FloatToHeadingWrapped(32768.0f) == -32768);
	CHECK(FloatToHeadingWrapped(65536.0f) == 0);
	CHECK(FloatToHeadingWrapped(65537.0f) == 1);
	CHECK(FloatToHeadingWrapped(-65537.0f) == -1);
	CHECK(FloatToHeadingWrapped(2147483520.0f) == -128); // largest float below 2^31

	// outside int, and NaN: what x86 computes (INT_MIN, low 16 bits 0), on every platform
	CHECK(FloatToHeadingWrapped(2147483648.0f) == 0);
	CHECK(FloatToHeadingWrapped(3.0e9f) == 0);
	CHECK(FloatToHeadingWrapped(-3.0e9f) == 0);
	CHECK(FloatToHeadingWrapped(-2147483648.0f) == 0);
	CHECK(FloatToHeadingWrapped(std::numeric_limits<float>::infinity()) == 0);
	CHECK(FloatToHeadingWrapped(-std::numeric_limits<float>::infinity()) == 0);
	CHECK(FloatToHeadingWrapped(std::numeric_limits<float>::quiet_NaN()) == 0);
}
