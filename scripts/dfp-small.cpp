// Per-function bit-exactness probe for streflop Double transcendentals.
// Names WHICH double function diverges between builds (root-cause narrowing).
#include <cstdio>
#include <cstdint>
#include <cstring>
#include "streflop_cond.h"

static uint64_t h;
static void reset() { h = 1469598103934665603ULL; }
// A NaN made by an invalid operation carries the platform's sign bit (set on
// x86, clear on arm64), so every NaN is hashed as one fixed pattern: the line
// then says "NaN at this input" the same way on both.
static void tapd(double v) { uint64_t b; memcpy(&b, &v, 8); if (v != v) b = 0x7ff8000000000000ULL; h ^= b; h *= 1099511628211ULL; }

// one hash line over n+1 evenly spaced inputs in [lo, hi]
template <typename F> static void sweep(const char* name, double lo, double hi, int n, F f) {
    reset();
    for (int i = 0; i <= n; i++) f(lo + (hi - lo) * (double)i / (double)n);
    printf("%s %016llx\n", name, (unsigned long long)h);
}

int main() {
    using streflop::Double;

    reset();
    for (int i = -80; i <= 80; i++)
        for (int j = -80; j <= 80; j++) {
            if (i == 0 && j == 0) continue;
            tapd(streflop::atan2(Double(i * 0.0037), Double(j * 0.0041)));
        }
    printf("atan2  %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::sin(Double(x))); }
    printf("sin    %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::cos(Double(x))); }
    printf("cos    %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::tan(Double(x))); }
    printf("tan    %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::floor(Double(x*1.7))); }
    printf("floor  %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::fmod(Double(x), Double(0.7853981633974483))); }
    printf("fmod   %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 1; i <= 40000; i++) { double x = 20.0*(double)i/40000.0; tapd(streflop::sqrt(Double(x))); tapd(streflop::log(Double(x))); }
    printf("sqrtlog %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 20000; i++) { double x = -1.0 + 2.0*(double)i/20000.0; tapd(streflop::asin(Double(x))); tapd(streflop::acos(Double(x))); }
    printf("asinacos %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 20000; i++) { double x = -20.0 + 40.0*(double)i/20000.0; tapd(streflop::exp(Double(x))); tapd(streflop::atan(Double(x))); }
    printf("expatan %016llx\n", (unsigned long long)h);

    // The rest of the double functions the library exports, one line per group,
    // so a difference names the function. Appended: the lines above keep their
    // values.
    // Known and the same on the fleet: expm1(x) and cosh(x) return NaN for |x|
    // below 2^-54, zero included, because -fsingle-precision-constant turns the
    // library's "huge = 1.0e+300" into a float infinity. The engine calls neither
    // on doubles.
    sweep("pow", 0.097, 19.4, 200, [](double x) {
        for (int j = -100; j <= 100; j++) tapd(streflop::pow(Double(x), Double(j * 0.043)));
    });
    sweep("log2log10", 0.0005, 20.0, 40000, [](double x) { tapd(streflop::log2(Double(x))); tapd(streflop::log10(Double(x))); });
    sweep("exp2expm1", -20.0, 20.0, 20000, [](double x) { tapd(streflop::exp2(Double(x))); tapd(streflop::expm1(Double(x))); });
    sweep("log1p", -0.9999, 20.0, 40000, [](double x) { tapd(streflop::log1p(Double(x))); });
    sweep("sinhcosh", -20.0, 20.0, 20000, [](double x) { tapd(streflop::sinh(Double(x))); tapd(streflop::cosh(Double(x))); });
    sweep("tanh", -20.0, 20.0, 40000, [](double x) { tapd(streflop::tanh(Double(x))); });
    sweep("asinhatanh", -0.9999, 0.9999, 20000, [](double x) { tapd(streflop::asinh(Double(x * 20.0))); tapd(streflop::atanh(Double(x))); });
    sweep("acosh", 1.0, 40.0, 40000, [](double x) { tapd(streflop::acosh(Double(x))); });
    sweep("cbrthypot", -20.0, 20.0, 20000, [](double x) { tapd(streflop::cbrt(Double(x))); tapd(streflop::hypot(Double(x), Double(0.7 * x + 1.3))); });
    sweep("erf", -6.0, 6.0, 40000, [](double x) { tapd(streflop::erf(Double(x))); });
    sweep("rounding", -10.0, 10.0, 40000, [](double x) {
        tapd(streflop::ceil(Double(x * 1.7))); tapd(streflop::trunc(Double(x * 1.7)));
        tapd(streflop::round(Double(x * 1.7))); tapd(streflop::rint(Double(x * 1.7)));
    });
    sweep("remainder", -10.0, 10.0, 40000, [](double x) { tapd(streflop::remainder(Double(x), Double(0.7853981633974483))); });
    // (the Bessel functions j0, j1, jn, y0, y1, yn are declared but do not link in
    // this library, so nothing in the engine can call them)
    return 0;
}
