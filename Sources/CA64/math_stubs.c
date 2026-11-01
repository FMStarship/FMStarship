#include <math.h>
#include <stdint.h>
#include <string.h>
#include "internal.h"

// Deterministic libm calls run natively: their answers do not depend on the game.
typedef double (*d1)(double); typedef float (*f1)(float); typedef double (*d2)(double, double); typedef float (*f2)(float, float);

static const d1 one_d[] = {acos, asin, atan, cos, exp, exp2, log, log10, sin, tan};
static const f1 one_f[] = {acosf, asinf, cosf, expf, logf, sinf};
static const d2 two_d[] = {atan2, pow, fmod};
static const f2 two_f[] = {atan2f, powf, fmodf};

void a64_run_math(a64 *c, int stub) {
    int index = stub - A64_STUB_MATH_BASE;
    int group = index >> 8, which = index & 255;
    double a, b; float x, y;
    uint32_t u;
    memcpy(&a, &c->v[0].lo, 8); memcpy(&b, &c->v[1].lo, 8);
    u = (uint32_t)c->v[0].lo; memcpy(&x, &u, 4);
    u = (uint32_t)c->v[1].lo; memcpy(&y, &u, 4);
    uint64_t out = 0;
    switch (group) {
    case 0: { double r = one_d[which](a); memcpy(&out, &r, 8); break; }
    case 1: { float r = one_f[which](x); memcpy(&u, &r, 4); out = u; break; }
    case 2: { double r = two_d[which](a, b); memcpy(&out, &r, 8); break; }
    default: { float r = two_f[which](x, y); memcpy(&u, &r, 4); out = u; break; }
    }
    c->v[0].lo = out;
    c->v[0].hi = 0;
}
