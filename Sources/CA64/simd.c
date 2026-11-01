#include "internal.h"

#include <math.h>

#define BIT(v, n) (((v) >> (n)) & 1)
#define BF(v, hi, lo) (((uint64_t)(v) >> (lo)) & ((1ull << ((hi) - (lo) + 1)) - 1))

static inline float F(uint64_t v) { float f; uint32_t u = (uint32_t)v; memcpy(&f, &u, 4); return f; }
static inline uint64_t Fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline double D(uint64_t v) { double d; memcpy(&d, &v, 8); return d; }
static inline uint64_t Db(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static inline int64_t sext64(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }

static void scalar(a64 *c, unsigned rd, uint64_t value) { c->v[rd].lo = value; c->v[rd].hi = 0; }

static inline void get_bytes(const vreg *r, uint8_t out[16]) { memcpy(out, &r->lo, 8); memcpy(out + 8, &r->hi, 8); }
static inline void put_bytes(vreg *r, const uint8_t in[16]) { memcpy(&r->lo, in, 8); memcpy(&r->hi, in + 8, 8); }

// Lanes are range-checked: decoding bytes that aren't code can ask for one that doesn't exist.
static inline uint64_t lane(const vreg *r, int index, int bytes) {
    if (bytes > 8 || index < 0 || (index + 1) * bytes > 16) return 0;
    uint8_t b[16];
    get_bytes(r, b);
    uint64_t v = 0;
    memcpy(&v, b + index * bytes, (size_t)bytes);
    return v;
}

static inline void set_lane(vreg *r, int index, int bytes, uint64_t value) {
    if (bytes > 8 || index < 0 || (index + 1) * bytes > 16) return;
    uint8_t b[16];
    get_bytes(r, b);
    memcpy(b + index * bytes, &value, (size_t)bytes);
    put_bytes(r, b);
}

static double round_mode(double v, int mode) {  // 0 nearest even, 1 +inf, 2 -inf, 3 zero, 4 nearest away
    switch (mode) {
    case 0: return nearbyint(v);
    case 1: return ceil(v);
    case 2: return floor(v);
    case 3: return trunc(v);
    default: return round(v);
    }
}

static uint64_t to_int(double v, int is64, int is_signed, int mode) {
    if (isnan(v)) return 0;
    double r = round_mode(v, mode);
    if (is_signed) {
        if (is64) {
            if (r >= 9223372036854775807.0) return (uint64_t)INT64_MAX;
            if (r <= -9223372036854775808.0) return (uint64_t)INT64_MIN;
            return (uint64_t)(int64_t)r;
        }
        if (r >= 2147483647.0) return (uint32_t)INT32_MAX;
        if (r <= -2147483648.0) return (uint32_t)INT32_MIN;
        return (uint32_t)(int32_t)r;
    }
    if (r <= 0) return 0;
    if (is64) return r >= 18446744073709551615.0 ? UINT64_MAX : (uint64_t)r;
    return r >= 4294967295.0 ? UINT32_MAX : (uint32_t)r;
}

static void compare(a64 *c, double a, double b) {
    if (isnan(a) || isnan(b)) { c->n = 0; c->z = 0; c->c = 1; c->v_flag = 1; }
    else if (a == b) { c->n = 0; c->z = 1; c->c = 1; c->v_flag = 0; }
    else if (a < b) { c->n = 1; c->z = 0; c->c = 0; c->v_flag = 0; }
    else { c->n = 0; c->z = 0; c->c = 1; c->v_flag = 0; }
}

static int cond(const a64 *c, unsigned cc) {
    int r;
    switch (cc >> 1) {
    case 0: r = c->z; break;
    case 1: r = c->c; break;
    case 2: r = c->n; break;
    case 3: r = c->v_flag; break;
    case 4: r = c->c && !c->z; break;
    case 5: r = c->n == c->v_flag; break;
    case 6: r = c->n == c->v_flag && !c->z; break;
    default: return 1;
    }
    return (cc & 1) ? !r : r;
}

static uint64_t fp_expand(unsigned imm8, int is_double) {
    unsigned sign = imm8 >> 7, b6 = (imm8 >> 6) & 1, rest = imm8 & 0x3f;
    if (is_double) {
        uint64_t exp = ((uint64_t)(b6 ^ 1) << 10) | (b6 ? 0x3fcull : 0) ;
        exp |= ((uint64_t)(rest >> 4));
        return ((uint64_t)sign << 63) | (exp << 52) | ((uint64_t)(rest & 15) << 48);
    }
    uint32_t exp = ((uint32_t)(b6 ^ 1) << 7) | (b6 ? 0x7cu : 0);
    exp |= rest >> 4;
    return ((uint32_t)sign << 31) | (exp << 23) | ((uint32_t)(rest & 15) << 19);
}

static int fp_data(a64 *c, uint32_t i) {
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16), type = BF(i, 23, 22);
    int dbl = type == 1;
    if (type > 1 && !(BF(i, 21, 10) == 0 && 0)) {
        if (type != 3 || BF(i, 15, 10) != 0) return 0;
    }
#define SRC(r) (dbl ? D(c->v[r].lo) : (double)F(c->v[r].lo))
#define OUT(rd_, value) scalar(c, rd_, dbl ? Db(value) : Fb((float)(value)))
    if (BIT(i, 24)) {  // FMADD and friends
        unsigned ra = BF(i, 14, 10), o1 = BIT(i, 21), o0 = BIT(i, 15);
        double a = SRC(ra), n = SRC(rn), m = SRC(rm), r;
        if (!o1 && !o0) r = dbl ? fma(n, m, a) : (double)fmaf((float)n, (float)m, (float)a);
        else if (!o1) r = dbl ? fma(-n, m, a) : (double)fmaf((float)-n, (float)m, (float)a);
        else if (!o0) r = dbl ? fma(-n, m, -a) : (double)fmaf((float)-n, (float)m, (float)-a);
        else r = dbl ? fma(n, m, -a) : (double)fmaf((float)n, (float)m, (float)-a);
        OUT(rd, r);
        return 1;
    }
    if (!BIT(i, 21)) {  // fixed-point conversions
        unsigned rmode = BF(i, 20, 19), opcode = BF(i, 18, 16);
        int is64 = BIT(i, 31), fbits = 64 - (int)BF(i, 15, 10);
        if (rmode == 0 && (opcode == 2 || opcode == 3)) {
            uint64_t raw = reg(c, rn);
            double value = opcode == 2 ? (is64 ? (double)(int64_t)raw : (double)(int32_t)raw)
                                       : (is64 ? (double)raw : (double)(uint32_t)raw);
            OUT(rd, ldexp(value, -fbits));
            return 1;
        }
        if (rmode == 3 && opcode <= 1) {
            set(c, rd, to_int(ldexp(SRC(rn), fbits), is64, opcode == 0, 3));
            return 1;
        }
        return 0;
    }
    unsigned sub = BF(i, 11, 10);
    if (sub == 2) {  // two source
        unsigned opcode = BF(i, 15, 12);
        double a = SRC(rn), b = SRC(rm), r;
        switch (opcode) {
        case 0: r = a * b; break;
        case 1: r = a / b; break;
        case 2: r = a + b; break;
        case 3: r = a - b; break;
        case 4: r = isnan(a) || isnan(b) ? NAN : (a > b ? a : b); break;
        case 5: r = isnan(a) || isnan(b) ? NAN : (a < b ? a : b); break;
        case 6: r = isnan(a) ? b : isnan(b) ? a : (a > b ? a : b); break;
        case 7: r = isnan(a) ? b : isnan(b) ? a : (a < b ? a : b); break;
        case 8: r = -(a * b); break;
        default: return 0;
        }
        OUT(rd, r);
        return 1;
    }
    if (sub == 1) {  // FCCMP
        if (cond(c, BF(i, 15, 12))) compare(c, SRC(rn), SRC(rm));
        else {
            unsigned nzcv = i & 15;
            c->n = BIT(nzcv, 3); c->z = BIT(nzcv, 2); c->c = BIT(nzcv, 1); c->v_flag = BIT(nzcv, 0);
        }
        return 1;
    }
    if (sub == 3) {  // FCSEL
        scalar(c, rd, cond(c, BF(i, 15, 12)) ? c->v[rn].lo : c->v[rm].lo);
        if (!dbl) c->v[rd].lo = (uint32_t)c->v[rd].lo;
        return 1;
    }
    if (BF(i, 15, 10) == 0) {  // conversions between FP and integer
        int is64 = BIT(i, 31);
        unsigned rmode = BF(i, 20, 19), opcode = BF(i, 18, 16);
        if (opcode == 6 || opcode == 7) {  // FMOV
            if (opcode == 7) {
                if (rmode == 1) { c->v[rd].hi = reg(c, rn); return 1; }
                scalar(c, rd, is64 ? reg(c, rn) : (uint32_t)reg(c, rn));
            } else {
                uint64_t raw = rmode == 1 ? c->v[rn].hi : (is64 ? c->v[rn].lo : (uint32_t)c->v[rn].lo);
                set(c, rd, raw);
            }
            return 1;
        }
        if (opcode == 2 || opcode == 3) {  // SCVTF, UCVTF
            uint64_t raw = reg(c, rn);
            double value;
            if (opcode == 2) value = is64 ? (double)(int64_t)raw : (double)(int32_t)raw;
            else value = is64 ? (double)raw : (double)(uint32_t)raw;
            if (dbl) scalar(c, rd, Db(value));
            else if (opcode == 2 && is64) scalar(c, rd, Fb((float)(int64_t)raw));
            else if (opcode == 3 && is64) scalar(c, rd, Fb((float)raw));
            else scalar(c, rd, Fb((float)value));
            return 1;
        }
        if (opcode <= 1 || opcode == 4 || opcode == 5) {
            int is_signed = !(opcode & 1);
            int mode = opcode >= 4 ? 4 : (rmode == 0 ? 0 : rmode);
            set(c, rd, to_int(SRC(rn), is64, is_signed, mode));
            return 1;
        }
        return 0;
    }
    if (BF(i, 14, 10) == 0x10) {  // one source
        unsigned opcode = BF(i, 20, 15);
        double a = SRC(rn);
        switch (opcode) {
        case 0: scalar(c, rd, dbl ? c->v[rn].lo : (uint32_t)c->v[rn].lo); return 1;
        case 1: scalar(c, rd, dbl ? c->v[rn].lo & ~(1ull << 63) : (uint32_t)c->v[rn].lo & 0x7fffffffu); return 1;
        case 2: scalar(c, rd, dbl ? c->v[rn].lo ^ (1ull << 63) : (uint32_t)c->v[rn].lo ^ 0x80000000u); return 1;
        case 3: OUT(rd, dbl ? sqrt(a) : (double)sqrtf((float)a)); return 1;
        case 4: if (dbl) scalar(c, rd, Fb((float)a)); else return 0; return 1;
        case 5: if (!dbl) scalar(c, rd, Db(a)); else return 0; return 1;
        case 8: OUT(rd, nearbyint(a)); return 1;
        case 9: OUT(rd, ceil(a)); return 1;
        case 10: OUT(rd, floor(a)); return 1;
        case 11: OUT(rd, trunc(a)); return 1;
        case 12: OUT(rd, round(a)); return 1;
        case 14: case 15: OUT(rd, nearbyint(a)); return 1;
        default: return 0;
        }
    }
    if (BF(i, 13, 10) == 8) {  // FCMP
        compare(c, SRC(rn), BIT(i, 3) ? 0.0 : SRC(rm));
        return 1;
    }
    if (BF(i, 12, 10) == 4 && BF(i, 9, 5) == 0) {  // FMOV immediate
        scalar(c, rd, fp_expand((unsigned)BF(i, 20, 13), dbl));
        return 1;
    }
    return 0;
}

static uint64_t expand_imm(unsigned op, unsigned cmode, unsigned imm8) {
    uint64_t v = imm8, r = 0;
    switch (cmode >> 1) {
    case 0: r = v * 0x0000000100000001ull; break;
    case 1: r = (v << 8) * 0x0000000100000001ull; break;
    case 2: r = (v << 16) * 0x0000000100000001ull; break;
    case 3: r = (v << 24) * 0x0000000100000001ull; break;
    case 4: r = v * 0x0001000100010001ull; break;
    case 5: r = (v << 8) * 0x0001000100010001ull; break;
    case 6:
        r = (cmode & 1 ? (v << 16) | 0xffff : (v << 8) | 0xff) * 0x0000000100000001ull;
        break;
    default:
        if (!(cmode & 1)) {
            if (!op) r = v * 0x0101010101010101ull;
            else for (int b = 0; b < 8; b++) if (BIT(v, b)) r |= 0xffull << (8 * b);
        } else if (!op) {
            r = fp_expand(imm8, 0) * 0x0000000100000001ull;
        } else {
            r = fp_expand(imm8, 1);
        }
        break;
    }
    return r;
}

static int simd_modified_immediate(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), op = BIT(i, 29), cmode = BF(i, 15, 12), rd = i & 31;
    unsigned imm8 = ((unsigned)BF(i, 18, 16) << 5) | (unsigned)BF(i, 9, 5);
    uint64_t imm = expand_imm(op, cmode, imm8);
    vreg *d = &c->v[rd];
    uint64_t lo = d->lo, hi = d->hi;
    int is_logical = (cmode & 1) && cmode < 12;
    if (is_logical) {
        if (!op) { lo |= imm; hi |= imm; }
        else { lo &= ~imm; hi &= ~imm; }
    } else {
        int invert = op && cmode != 14 && cmode != 15;
        lo = invert ? ~imm : imm;
        hi = lo;
    }
    d->lo = lo;
    d->hi = q ? hi : 0;
    return 1;
}

static int simd_copy(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), op = BIT(i, 29), imm5 = BF(i, 20, 16), imm4 = BF(i, 14, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5);
    if (imm5 == 0) return 0;
    int size = __builtin_ctz(imm5), bytes = 1 << size;
    int index = (int)(imm5 >> (size + 1));
    if (op) {  // INS element
        set_lane(&c->v[rd], index, bytes, lane(&c->v[rn], (int)(imm4 >> size), bytes));
        return 1;
    }
    switch (imm4) {
    case 0: {  // DUP element
        uint64_t v = lane(&c->v[rn], index, bytes);
        vreg out = {0, 0};
        for (int l = 0; l < (q ? 16 : 8) / bytes; l++) set_lane(&out, l, bytes, v);
        c->v[rd] = out;
        return 1;
    }
    case 1: {  // DUP general
        uint64_t v = reg(c, rn);
        vreg out = {0, 0};
        for (int l = 0; l < (q ? 16 : 8) / bytes; l++) set_lane(&out, l, bytes, v);
        c->v[rd] = out;
        return 1;
    }
    case 3: set_lane(&c->v[rd], index, bytes, reg(c, rn)); return 1;  // INS general
    case 5: {  // SMOV
        uint64_t v = (uint64_t)sext64(lane(&c->v[rn], index, bytes), bytes * 8);
        set(c, rd, q ? v : (uint32_t)v);
        return 1;
    }
    case 7: set(c, rd, lane(&c->v[rn], index, bytes)); return 1;  // UMOV
    default: return 0;
    }
}

static int simd_three_same(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 15, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    vreg a = c->v[rn], b = c->v[rm], out = {0, 0};
    int total = q ? 16 : 8;

    if (opcode == 3) {  // logical
        uint64_t lo, hi, dl = c->v[rd].lo, dh = c->v[rd].hi;
        switch ((u << 2) | size) {
        case 0: lo = a.lo & b.lo; hi = a.hi & b.hi; break;
        case 1: lo = a.lo & ~b.lo; hi = a.hi & ~b.hi; break;
        case 2: lo = a.lo | b.lo; hi = a.hi | b.hi; break;
        case 3: lo = a.lo | ~b.lo; hi = a.hi | ~b.hi; break;
        case 4: lo = a.lo ^ b.lo; hi = a.hi ^ b.hi; break;
        case 5: lo = (dl & a.lo) | (~dl & b.lo); hi = (dh & a.hi) | (~dh & b.hi); break;
        case 6: lo = (dl & ~b.lo) | (a.lo & b.lo); hi = (dh & ~b.hi) | (a.hi & b.hi); break;
        default: lo = (dl & b.lo) | (a.lo & ~b.lo); hi = (dh & b.hi) | (a.hi & ~b.hi); break;
        }
        c->v[rd].lo = lo;
        c->v[rd].hi = q ? hi : 0;
        return 1;
    }
    if (opcode >= 0x18) {  // floating point
        int dbl = size & 1, top = (int)(size >> 1), bytes = dbl ? 8 : 4;
        unsigned key = (u << 5) | ((unsigned)top << 4) | (opcode & 15);
        for (int l = 0; l < total / bytes; l++) {
            double x = dbl ? D(lane(&a, l, 8)) : (double)F(lane(&a, l, 4));
            double y = dbl ? D(lane(&b, l, 8)) : (double)F(lane(&b, l, 4));
            double r = 0, d = dbl ? D(lane(&c->v[rd], l, 8)) : (double)F(lane(&c->v[rd], l, 4));
            int is_mask = 0, truth = 0;
            switch (key) {
            case 0x0a: r = x + y; break;                      // FADD
            case 0x1a: r = x - y; break;                      // FSUB
            case 0x2b: r = x * y; break;                      // FMUL
            case 0x2f: r = x / y; break;                      // FDIV
            case 0x0e: r = isnan(x) || isnan(y) ? NAN : (x > y ? x : y); break;  // FMAX
            case 0x1e: r = isnan(x) || isnan(y) ? NAN : (x < y ? x : y); break;  // FMIN
            case 0x08: r = isnan(x) ? y : isnan(y) ? x : (x > y ? x : y); break; // FMAXNM
            case 0x18: r = isnan(x) ? y : isnan(y) ? x : (x < y ? x : y); break; // FMINNM
            case 0x09: r = d + x * y; break;                  // FMLA
            case 0x19: r = d - x * y; break;                  // FMLS
            case 0x0c: is_mask = 1; truth = x == y; break;    // FCMEQ
            case 0x2c: is_mask = 1; truth = x >= y; break;    // FCMGE
            case 0x3c: is_mask = 1; truth = x > y; break;     // FCMGT
            case 0x3a: r = fabs(x - y); break;                // FABD
            default: return 0;
            }
            if (is_mask) set_lane(&out, l, bytes, truth ? ~0ull : 0);
            else set_lane(&out, l, bytes, dbl ? Db(r) : Fb((float)r));
        }
        c->v[rd] = out;
        return 1;
    }
    if (opcode == 0x17 && !u) {  // ADDP
        int bytes = 1 << size;
        int lanes = total / bytes;
        for (int l = 0; l < lanes / 2; l++) {
            set_lane(&out, l, bytes, lane(&a, 2 * l, bytes) + lane(&a, 2 * l + 1, bytes));
            set_lane(&out, l + lanes / 2, bytes, lane(&b, 2 * l, bytes) + lane(&b, 2 * l + 1, bytes));
        }
        c->v[rd] = out;
        return 1;
    }
    if (opcode == 8) {  // SSHL, USHL
        int bytes = 1 << size, bits = bytes * 8;
        for (int l = 0; l < total / bytes; l++) {
            uint64_t x = lane(&a, l, bytes);
            int shift = (int8_t)lane(&b, l, bytes);
            uint64_t r;
            if (shift >= 0) r = shift >= bits ? 0 : x << shift;
            else if (u) r = -shift >= bits ? 0 : x >> -shift;
            else r = (uint64_t)(sext64(x, bits) >> (-shift >= bits ? bits - 1 : -shift));
            set_lane(&out, l, bytes, r);
        }
        c->v[rd] = out;
        return 1;
    }
    int bytes = 1 << size, bits = bytes * 8;
    for (int l = 0; l < total / bytes; l++) {
        uint64_t x = lane(&a, l, bytes), y = lane(&b, l, bytes), r;
        int64_t sx = sext64(x, bits), sy = sext64(y, bits);
        switch ((u << 5) | opcode) {
        case 0x10: r = x + y; break;
        case 0x30: r = x - y; break;
        case 0x11: r = (x & y) ? ~0ull : 0; break;   // CMTST
        case 0x31: r = x == y ? ~0ull : 0; break;    // CMEQ
        case 0x06: r = sx > sy ? ~0ull : 0; break;   // CMGT
        case 0x07: r = sx >= sy ? ~0ull : 0; break;  // CMGE
        case 0x26: r = x > y ? ~0ull : 0; break;     // CMHI
        case 0x27: r = x >= y ? ~0ull : 0; break;    // CMHS
        case 0x0c: r = sx > sy ? x : y; break;
        case 0x0d: r = sx < sy ? x : y; break;
        case 0x2c: r = x > y ? x : y; break;
        case 0x2d: r = x < y ? x : y; break;
        case 0x13: r = x * y; break;
        default: return 0;
        }
        set_lane(&out, l, bytes, r);
    }
    c->v[rd] = out;
    return 1;
}

static int simd_two_misc(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 16, 12);
    unsigned rd = i & 31, rn = BF(i, 9, 5);
    vreg a = c->v[rn], out = {0, 0};
    int total = q ? 16 : 8;

    if (opcode == 0x12 && !u) {  // XTN, XTN2
        int bytes = 1 << size;
        out = q ? c->v[rd] : out;
        for (int l = 0; l < 8 / bytes; l++) set_lane(&out, l + (q ? 8 / bytes : 0), bytes, lane(&a, l, bytes * 2));
        c->v[rd] = out;
        return 1;
    }
    if (opcode >= 0x18 || opcode == 0x0f || opcode == 0x0d) {
        int dbl = size & 1, bytes = dbl ? 8 : 4;
        if (opcode >= 0x18 || (size >> 1)) {
            for (int l = 0; l < total / bytes; l++) {
                uint64_t raw = lane(&a, l, bytes);
                double x = dbl ? D(raw) : (double)F(raw);
                uint64_t r;
                unsigned key = (u << 6) | ((size >> 1) << 5) | opcode;
                switch (key) {
                case 0x0f | 0x20: r = dbl ? raw & ~(1ull << 63) : raw & 0x7fffffffu; break;   // FABS
                case 0x4f | 0x20: r = dbl ? raw ^ (1ull << 63) : raw ^ 0x80000000u; break;    // FNEG
                case 0x5f | 0x20: { double s = sqrt(x); r = dbl ? Db(s) : Fb((float)s); break; }
                case 0x1d: { double s = dbl ? (double)(int64_t)raw : (double)(int32_t)raw; r = dbl ? Db(s) : Fb((float)s); break; }
                case 0x5d: { double s = dbl ? (double)raw : (double)(uint32_t)raw; r = dbl ? Db(s) : Fb((float)s); break; }
                case 0x3b: r = to_int(x, dbl, 1, 3); break;
                case 0x7b: r = to_int(x, dbl, 0, 3); break;
                default: return 0;
                }
                set_lane(&out, l, bytes, r);
            }
            c->v[rd] = out;
            return 1;
        }
        return 0;
    }
    int bytes = 1 << size, bits = bytes * 8;
    if (opcode == 5 && !u && size == 0) {  // CNT
        for (int l = 0; l < total; l++) set_lane(&out, l, 1, (uint64_t)__builtin_popcount((unsigned)lane(&a, l, 1)));
        c->v[rd] = out;
        return 1;
    }
    if (opcode == 5 && u) {  // NOT, RBIT
        if (size == 0) {
            c->v[rd].lo = ~a.lo;
            c->v[rd].hi = q ? ~a.hi : 0;
            return 1;
        }
        return 0;
    }
    if (opcode <= 1) {  // REV64, REV32, REV16
        int group = opcode == 0 && !u ? 8 : (opcode == 0 ? 4 : 2);
        for (int g = 0; g < total / group; g++)
            for (int l = 0; l < group / bytes; l++)
                set_lane(&out, g * group / bytes + l, bytes, lane(&a, g * group / bytes + group / bytes - 1 - l, bytes));
        c->v[rd] = out;
        return 1;
    }
    for (int l = 0; l < total / bytes; l++) {
        uint64_t x = lane(&a, l, bytes), r;
        int64_t sx = sext64(x, bits);
        switch ((u << 5) | opcode) {
        case 0x08: r = sx > 0 ? ~0ull : 0; break;
        case 0x09: r = sx == 0 ? ~0ull : 0; break;
        case 0x0a: r = sx < 0 ? ~0ull : 0; break;
        case 0x28: r = sx >= 0 ? ~0ull : 0; break;
        case 0x29: r = sx <= 0 ? ~0ull : 0; break;
        case 0x0b: r = sx < 0 ? (uint64_t)-sx : x; break;
        case 0x2b: r = (uint64_t)-sx; break;
        default: return 0;
        }
        set_lane(&out, l, bytes, r);
    }
    c->v[rd] = out;
    return 1;
}

static int simd_across(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 16, 12);
    unsigned rd = i & 31, rn = BF(i, 9, 5);
    int total = q ? 16 : 8, bytes = 1 << size, bits = bytes * 8;
    vreg a = c->v[rn];
    uint64_t r = lane(&a, 0, bytes);
    int64_t sum = u ? (int64_t)r : sext64(r, bits);
    for (int l = 1; l < total / bytes; l++) {
        uint64_t x = lane(&a, l, bytes);
        switch ((u << 5) | opcode) {
        case 0x1b: case 0x3b: r += x; break;                                              // ADDV
        case 0x0a: r = sext64(x, bits) > sext64(r, bits) ? x : r; break;                  // SMAXV
        case 0x1a: r = sext64(x, bits) < sext64(r, bits) ? x : r; break;                  // SMINV
        case 0x2a: r = x > r ? x : r; break;                                              // UMAXV
        case 0x3a: r = x < r ? x : r; break;                                              // UMINV
        case 0x03: sum += sext64(x, bits); break;                                         // SADDLV
        case 0x23: sum += (int64_t)x; break;                                              // UADDLV
        default: return 0;
        }
    }
    if (opcode == 3) scalar(c, rd, (uint64_t)sum);
    else scalar(c, rd, r & (bits == 64 ? ~0ull : (1ull << bits) - 1));
    return 1;
}

static int simd_shift_imm(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), u = BIT(i, 29), immh = BF(i, 22, 19), immb = BF(i, 18, 16), opcode = BF(i, 15, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5);
    if (!immh) return simd_modified_immediate(c, i);
    int size = 31 - __builtin_clz(immh), bytes = 1 << size, bits = bytes * 8;
    unsigned imm = (immh << 3) | immb;
    int shr = 2 * bits - (int)imm, shl = (int)imm - bits;
    vreg a = c->v[rn], out = {0, 0};
    int total = q ? 16 : 8;
    switch (opcode) {
    case 0: case 2: {  // SSHR, USHR, SSRA, USRA
        for (int l = 0; l < total / bytes; l++) {
            uint64_t x = lane(&a, l, bytes);
            uint64_t r = u ? (shr >= 64 ? 0 : x >> shr)
                           : (uint64_t)(sext64(x, bits) >> (shr >= 64 ? 63 : shr));
            if (opcode == 2) r += lane(&c->v[rd], l, bytes);
            set_lane(&out, l, bytes, r);
        }
        break;
    }
    case 10:  // SHL
        if (u) return 0;
        for (int l = 0; l < total / bytes; l++) set_lane(&out, l, bytes, lane(&a, l, bytes) << shl);
        break;
    case 20: {  // SSHLL, USHLL
        int half = bits / 2 * 0 + bits;
        (void)half;
        for (int l = 0; l < 8 / bytes; l++) {
            uint64_t x = lane(&a, l + (q ? 8 / bytes : 0), bytes);
            uint64_t wide = u ? x : (uint64_t)sext64(x, bits);
            set_lane(&out, l, bytes * 2, wide << shl);
        }
        break;
    }
    case 16: {  // SHRN
        out = q ? c->v[rd] : out;
        for (int l = 0; l < 8 / bytes; l++) {
            int wide_shift = 2 * bits - (int)imm;
            set_lane(&out, l + (q ? 8 / bytes : 0), bytes, lane(&a, l, bytes * 2) >> wide_shift);
        }
        break;
    }
    default:
        return 0;
    }
    c->v[rd] = out;
    return 1;
}

static int simd_permute(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), size = BF(i, 23, 22), opcode = BF(i, 14, 12);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    int total = q ? 16 : 8, bytes = 1 << size, lanes = total / bytes;
    vreg a = c->v[rn], b = c->v[rm], out = {0, 0};
    switch (opcode) {
    case 1: case 5:  // UZP1, UZP2
        for (int l = 0; l < lanes / 2; l++) {
            int part = opcode == 5;
            set_lane(&out, l, bytes, lane(&a, 2 * l + part, bytes));
            set_lane(&out, l + lanes / 2, bytes, lane(&b, 2 * l + part, bytes));
        }
        break;
    case 2: case 6:  // TRN1, TRN2
        for (int l = 0; l < lanes / 2; l++) {
            int part = opcode == 6;
            set_lane(&out, 2 * l, bytes, lane(&a, 2 * l + part, bytes));
            set_lane(&out, 2 * l + 1, bytes, lane(&b, 2 * l + part, bytes));
        }
        break;
    case 3: case 7:  // ZIP1, ZIP2
        for (int l = 0; l < lanes / 2; l++) {
            int base = opcode == 7 ? lanes / 2 : 0;
            set_lane(&out, 2 * l, bytes, lane(&a, base + l, bytes));
            set_lane(&out, 2 * l + 1, bytes, lane(&b, base + l, bytes));
        }
        break;
    default:
        return 0;
    }
    c->v[rd] = out;
    return 1;
}

static int simd_ext(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), imm4 = BF(i, 14, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    uint8_t a[16], b[16], in[32], out[16] = {0};
    int total = q ? 16 : 8;
    if (imm4 + total > 32) return 0;
    get_bytes(&c->v[rn], a);
    get_bytes(&c->v[rm], b);
    memcpy(in, a, (size_t)total);
    memcpy(in + total, b, (size_t)total);
    memcpy(out, in + imm4, (size_t)total);
    put_bytes(&c->v[rd], out);
    return 1;
}

static int simd_three_different(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 15, 12);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    int bytes = 1 << size, bits = bytes * 8, lanes = 8 / bytes, skip = q ? lanes : 0;
    vreg a = c->v[rn], b = c->v[rm], d = c->v[rd], out = {0, 0};
    for (int l = 0; l < lanes; l++) {
        uint64_t y = lane(&b, l + skip, bytes);
        uint64_t wy = u ? y : (uint64_t)sext64(y, bits);
        int wide_first = opcode == 1 || opcode == 3;
        uint64_t x = wide_first ? lane(&a, l, bytes * 2) : lane(&a, l + skip, bytes);
        uint64_t wx = wide_first ? x : (u ? x : (uint64_t)sext64(x, bits));
        uint64_t r;
        switch (opcode) {
        case 0: case 1: r = wx + wy; break;                        // ADDL, ADDW
        case 2: case 3: r = wx - wy; break;                        // SUBL, SUBW
        case 8: r = lane(&d, l, bytes * 2) + wx * wy; break;       // MLAL
        case 10: r = lane(&d, l, bytes * 2) - wx * wy; break;      // MLSL
        case 12: r = wx * wy; break;                               // MULL
        default: return 0;
        }
        set_lane(&out, l, bytes * 2, r);
    }
    c->v[rd] = out;
    return 1;
}

static int simd_scalar_fp_three(a64 *c, uint32_t i) {
    unsigned u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 15, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    int dbl = size & 1, top = (int)(size >> 1);
    double x = dbl ? D(c->v[rn].lo) : (double)F(c->v[rn].lo);
    double y = dbl ? D(c->v[rm].lo) : (double)F(c->v[rm].lo);
    uint64_t mask = dbl ? ~0ull : 0xffffffffull;
    switch ((u << 6) | ((unsigned)top << 5) | opcode) {
    case 0x7a: {  // FABD
        double r = fabs(x - y);
        scalar(c, rd, dbl ? Db(r) : Fb((float)r));
        return 1;
    }
    case 0x1c: scalar(c, rd, x == y ? mask : 0); return 1;  // FCMEQ
    case 0x5c: scalar(c, rd, x >= y ? mask : 0); return 1;  // FCMGE
    case 0x7c: scalar(c, rd, x > y ? mask : 0); return 1;   // FCMGT
    default: return 0;
    }
}

static int simd_scalar_pairs_etc(a64 *c, uint32_t i) {
    unsigned u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 15, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    if (BIT(i, 21) && BIT(i, 10) && opcode >= 0x18) return simd_scalar_fp_three(c, i);
    if (BF(i, 28, 24) == 0x1e && BIT(i, 21) && BIT(i, 10)) {  // scalar three-same, 64-bit integer forms
        uint64_t a = c->v[rn].lo, b = c->v[rm].lo, r;
        if (size != 3) return 0;
        switch ((u << 5) | opcode) {
        case 0x10: r = a + b; break;
        case 0x30: r = a - b; break;
        case 0x31: r = a == b ? ~0ull : 0; break;
        default: return 0;
        }
        scalar(c, rd, r);
        return 1;
    }
    return 0;
}

static int simd_scalar_shift(a64 *c, uint32_t i) {
    unsigned u = BIT(i, 29), immh = BF(i, 22, 19), immb = BF(i, 18, 16), opcode = BF(i, 15, 11);
    unsigned rd = i & 31, rn = BF(i, 9, 5);
    if (!(immh & 8)) return 0;
    unsigned imm = (immh << 3) | immb;
    int shr = 128 - (int)imm, shl = (int)imm - 64;
    uint64_t a = c->v[rn].lo;
    if (opcode == 0) scalar(c, rd, u ? (shr == 64 ? 0 : a >> shr) : (uint64_t)((int64_t)a >> (shr == 64 ? 63 : shr)));
    else if (opcode == 10 && !u) scalar(c, rd, a << shl);
    else return 0;
    return 1;
}

static int simd_scalar_misc(a64 *c, uint32_t i) {
    unsigned u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 16, 12), rd = i & 31, rn = BF(i, 9, 5);
    int dbl = size & 1, top = (int)(size >> 1);
    uint64_t raw = dbl ? c->v[rn].lo : (uint32_t)c->v[rn].lo;
    double x = dbl ? D(raw) : (double)F(raw);
    if (opcode == 0x1d && !top) {  // SCVTF, UCVTF
        double v = dbl ? (u ? (double)raw : (double)(int64_t)raw) : (u ? (double)(uint32_t)raw : (double)(int32_t)raw);
        scalar(c, rd, dbl ? Db(v) : Fb((float)v));
        return 1;
    }
    int mode;
    switch ((top << 5) | opcode) {
    case 0x1a: mode = 0; break;  // FCVTN
    case 0x1b: mode = 2; break;  // FCVTM
    case 0x1c: mode = 4; break;  // FCVTA
    case 0x3a: mode = 1; break;  // FCVTP
    case 0x3b: mode = 3; break;  // FCVTZ
    default: return 0;
    }
    scalar(c, rd, to_int(x, dbl, !u, mode));
    return 1;
}

static int simd_scalar_pairwise(a64 *c, uint32_t i) {
    unsigned u = BIT(i, 29), size = BF(i, 23, 22), opcode = BF(i, 16, 12), rd = i & 31, rn = BF(i, 9, 5);
    if (!u && opcode == 0x1b && size == 3) {  // ADDP
        scalar(c, rd, c->v[rn].lo + c->v[rn].hi);
        return 1;
    }
    if (u && opcode == 0x0d) {  // FADDP
        if (size & 1) scalar(c, rd, Db(D(c->v[rn].lo) + D(c->v[rn].hi)));
        else scalar(c, rd, Fb(F(c->v[rn].lo) + F(c->v[rn].lo >> 32)));
        return 1;
    }
    return 0;
}

static int simd_table(a64 *c, uint32_t i) {
    unsigned q = BIT(i, 30), len = BF(i, 14, 13), extend = BIT(i, 12);
    unsigned rd = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    uint8_t table[64] = {0}, index[16], out[16];
    for (unsigned r = 0; r <= len; r++) get_bytes(&c->v[(rn + r) & 31], table + 16 * r);
    get_bytes(&c->v[rm], index);
    get_bytes(&c->v[rd], out);
    for (int l = 0; l < (q ? 16 : 8); l++) {
        if (index[l] < 16 * (len + 1)) out[l] = table[index[l]];
        else if (!extend) out[l] = 0;
    }
    if (!q) memset(out + 8, 0, 8);
    put_bytes(&c->v[rd], out);
    return 1;
}

int a64_simd(a64 *c, uint32_t i) {
    if (BIT(i, 30) == 0 && BF(i, 28, 24) == 0x1e) return fp_data(c, i);
    if (BF(i, 28, 24) == 0x1f && BIT(i, 30) == 0) return fp_data(c, i);
    if (BIT(i, 31)) return 0;
    unsigned top = BF(i, 28, 24);
    if (top == 0x0e) {
        if (BIT(i, 21)) {
            if (BIT(i, 10)) return simd_three_same(c, i);
            if (BF(i, 11, 10) == 2 && BF(i, 20, 17) == 0) return simd_two_misc(c, i);
            if (BF(i, 11, 10) == 2 && BF(i, 20, 17) == 8) return simd_across(c, i);
            if (BF(i, 11, 10) == 0) return simd_three_different(c, i);
            return 0;
        }
        if (BIT(i, 29)) {
            if (BIT(i, 10)) return simd_copy(c, i);
            return simd_ext(c, i);
        }
        if (BIT(i, 10)) return simd_copy(c, i);
        if (BF(i, 11, 10) == 2) return simd_permute(c, i);
        return simd_table(c, i);
    }
    if (BF(i, 28, 23) == 0x1e) return simd_shift_imm(c, i);
    if (BF(i, 28, 23) == 0x3e) return simd_scalar_shift(c, i);
    if (top == 0x1e) {
        if (BIT(i, 21) && BF(i, 11, 10) == 2 && BF(i, 20, 17) == 0) return simd_scalar_misc(c, i);
        if (BIT(i, 21) && BF(i, 11, 10) == 2 && BF(i, 20, 17) == 8) return simd_scalar_pairwise(c, i);
        return simd_scalar_pairs_etc(c, i);
    }
    return 0;
}

int a64_simd_loadstore(a64 *c, uint32_t i) {
    // LD1/ST1 multiple structures (one to four consecutive registers)
    if (BF(i, 29, 24) != 0x0c) return 0;
    unsigned q = BIT(i, 30), post = BIT(i, 23), load = BIT(i, 22), opcode = BF(i, 15, 12);
    unsigned size = BF(i, 11, 10), rn = BF(i, 9, 5), rt = i & 31, rm = BF(i, 20, 16);
    int regs;
    switch (opcode) {
    case 7: regs = 1; break;
    case 10: regs = 2; break;
    case 6: regs = 3; break;
    case 2: regs = 4; break;
    default: return 0;
    }
    (void)size;
    uint64_t address = rn == 31 ? c->x[31] : c->x[rn];
    int total = q ? 16 : 8;
    for (int r = 0; r < regs; r++) {
        unsigned t = (rt + (unsigned)r) & 31;
        if (load) {
            uint64_t lo = rd(c, address, 8), hi = q ? rd(c, address + 8, 8) : 0;
            c->v[t].lo = lo; c->v[t].hi = hi;
        } else {
            wr(c, address, c->v[t].lo, 8);
            if (q) wr(c, address + 8, c->v[t].hi, 8);
        }
        address += (unsigned)total;
    }
    if (post) c->x[rn] += rm == 31 ? (uint64_t)(regs * total) : reg(c, rm);
    return 1;
}
