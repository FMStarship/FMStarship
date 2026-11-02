#include "internal.h"

#include <stdlib.h>

#define BIT(v, n) (((v) >> (n)) & 1)
#define BF(v, hi, lo) (((uint64_t)(v) >> (lo)) & ((1ull << ((hi) - (lo) + 1)) - 1))
#define PAC_MASK 0x00007fffffffffffull

static inline int64_t sext(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }
static inline uint64_t lowmask(int n) { return n >= 64 ? ~0ull : (1ull << n) - 1; }

static inline int condition(const a64 *c, unsigned cc) {
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

static inline uint64_t add_carry(a64 *c, uint64_t a, uint64_t b, unsigned carry, int is64, int flags) {
    if (is64) {
        unsigned __int128 u = (unsigned __int128)a + b + carry;
        uint64_t r = (uint64_t)u;
        if (flags) {
            c->n = r >> 63;
            c->z = r == 0;
            c->c = (uint8_t)(u >> 64);
            c->v_flag = ((~(a ^ b)) & (a ^ r)) >> 63;
        }
        return r;
    }
    uint32_t x = (uint32_t)a, y = (uint32_t)b;
    uint64_t u = (uint64_t)x + y + carry;
    uint32_t r = (uint32_t)u;
    if (flags) {
        c->n = r >> 31;
        c->z = r == 0;
        c->c = (uint8_t)(u >> 32);
        c->v_flag = ((~(x ^ y)) & (x ^ r)) >> 31;
    }
    return r;
}

static int bitmask(unsigned N, unsigned imms, unsigned immr, int is64, uint64_t *out) {
    unsigned combined = (N << 6) | (~imms & 0x3f);
    if (combined == 0) return 0;
    int len = 31 - __builtin_clz(combined);
    if (len < 1) return 0;
    unsigned esize = 1u << len, levels = esize - 1, S = imms & levels, R = immr & levels;
    if (S == levels) return 0;
    uint64_t element = lowmask((int)S + 1);
    uint64_t mask = lowmask((int)esize);
    uint64_t rotated = R ? ((element >> R) | (element << (esize - R))) & mask : element;
    uint64_t value = 0;
    for (unsigned i = 0; i < 64; i += esize) value |= rotated << i;
    *out = is64 ? value : (uint32_t)value;
    return 1;
}

static inline uint64_t shifted(uint64_t v, unsigned type, unsigned amount, int is64) {
    int size = is64 ? 64 : 32;
    if (!is64) v = (uint32_t)v;
    amount &= (unsigned)size - 1;
    if (amount == 0) return v;
    uint64_t r;
    switch (type) {
    case 0: r = v << amount; break;
    case 1: r = v >> amount; break;
    case 2: r = is64 ? (uint64_t)((int64_t)v >> amount) : (uint32_t)((int32_t)v >> amount); break;
    default: r = (v >> amount) | (v << (size - amount)); break;
    }
    return is64 ? r : (uint32_t)r;
}

static inline uint64_t extended(uint64_t v, unsigned option, unsigned shift) {
    uint64_t r;
    switch (option) {
    case 0: r = (uint8_t)v; break;
    case 1: r = (uint16_t)v; break;
    case 2: r = (uint32_t)v; break;
    case 3: r = v; break;
    case 4: r = (uint64_t)(int64_t)(int8_t)v; break;
    case 5: r = (uint64_t)(int64_t)(int16_t)v; break;
    case 6: r = (uint64_t)(int64_t)(int32_t)v; break;
    default: r = v; break;
    }
    return r << shift;
}

static int branch_register(a64 *c, uint64_t target, int link) {
    target &= PAC_MASK;
    uint64_t next = c->pc;
    int stub = a64_image_stub(c->image, target);
    if (stub) {
        if (link) c->x[30] = next;
        a64_run_stub(c, stub);
        if (c->status != A64_OK) return 0;
        c->pc = c->x[30] & PAC_MASK;
        return 1;
    }
    if (target < 0x10000) {
        c->status = A64_BAD_BRANCH;
        return 0;
    }
    // Remember which import we entered, for diagnosing anything that needs a new stub.
    if ((c->pc < c->image_low || c->pc >= c->image_high) == 0 && (target < c->image_low || target >= c->image_high))
        c->external_miss = target;
    if (link) c->x[30] = next;
    c->pc = target;
    return 1;
}

static int data_immediate(a64 *c, uint32_t i) {
    int is64 = BIT(i, 31);
    unsigned rd = i & 31, rn = (i >> 5) & 31;
    switch (BF(i, 25, 23)) {
    case 0: case 1: {  // ADR, ADRP
        int64_t imm = sext((BF(i, 23, 5) << 2) | BF(i, 30, 29), 21);
        uint64_t base = c->pc - 4;
        if (BIT(i, 31)) { base &= ~0xfffull; imm <<= 12; }
        set(c, rd, base + (uint64_t)imm);
        return 1;
    }
    case 2: case 3: {  // add/sub immediate
        uint64_t imm = BF(i, 21, 10);
        if (BIT(i, 22)) imm <<= 12;
        int sub = BIT(i, 30), flags = BIT(i, 29);
        uint64_t a = rn == 31 ? c->x[31] : c->x[rn];
        uint64_t r = sub ? add_carry(c, a, ~imm, 1, is64, flags) : add_carry(c, a, imm, 0, is64, flags);
        if (flags) set(c, rd, r);
        else c->x[rd] = r;  // rd 31 is SP here
        return 1;
    }
    case 4: {  // logical immediate
        uint64_t imm;
        if (!bitmask(BIT(i, 22), BF(i, 15, 10), BF(i, 21, 16), is64, &imm)) return 0;
        uint64_t a = reg(c, rn), r;
        switch (BF(i, 30, 29)) {
        case 0: r = a & imm; break;
        case 1: r = a | imm; break;
        case 2: r = a ^ imm; break;
        default:
            r = a & imm;
            c->n = is64 ? r >> 63 : (r >> 31) & 1;
            c->z = is64 ? r == 0 : (uint32_t)r == 0;
            c->c = c->v_flag = 0;
            break;
        }
        if (!is64) r = (uint32_t)r;
        if (BF(i, 30, 29) == 3) set(c, rd, r);
        else c->x[rd] = r;
        return 1;
    }
    case 5: {  // move wide
        uint64_t imm = BF(i, 20, 5);
        unsigned shift = (unsigned)BF(i, 22, 21) * 16;
        uint64_t r;
        switch (BF(i, 30, 29)) {
        case 0: r = ~(imm << shift); break;
        case 2: r = imm << shift; break;
        case 3: r = (reg(c, rd) & ~(0xffffull << shift)) | (imm << shift); break;
        default: return 0;
        }
        set(c, rd, is64 ? r : (uint32_t)r);
        return 1;
    }
    case 6: {  // bitfield
        unsigned opc = BF(i, 30, 29);
        int size = is64 ? 64 : 32;
        int r = (int)BF(i, 21, 16), s = (int)BF(i, 15, 10);
        uint64_t src = reg(c, rn);
        if (!is64) src = (uint32_t)src;
        int width, lsb;
        uint64_t field;
        if (s >= r) { width = s - r + 1; field = (src >> r) & lowmask(width); lsb = 0; }
        else { width = s + 1; field = src & lowmask(width); lsb = size - r; }
        uint64_t result;
        if (opc == 0) result = (uint64_t)(sext(field, width)) << lsb;
        else if (opc == 1) {
            uint64_t m = lowmask(width) << lsb;
            result = (reg(c, rd) & ~m) | ((field << lsb) & m);
        } else if (opc == 2) result = field << lsb;
        else return 0;
        set(c, rd, is64 ? result : (uint32_t)result);
        return 1;
    }
    default: {  // EXTR
        unsigned rm = (i >> 16) & 31, lsb = BF(i, 15, 10);
        if (is64) {
            uint64_t lo = reg(c, rm), hi = reg(c, rn);
            set(c, rd, lsb ? (lo >> lsb) | (hi << (64 - lsb)) : lo);
        } else {
            uint32_t lo = (uint32_t)reg(c, rm), hi = (uint32_t)reg(c, rn);
            set(c, rd, lsb ? (uint32_t)((lo >> lsb) | (hi << (32 - lsb))) : lo);
        }
        return 1;
    }
    }
}

static int branches(a64 *c, uint32_t i) {
    if ((i & 0x7c000000) == 0x14000000) {  // B, BL
        int64_t offset = sext(BF(i, 25, 0), 26) * 4;
        uint64_t target = c->pc - 4 + (uint64_t)offset;
        if (BIT(i, 31)) {
            if (target == c->watch[0] || target == c->watch[1]) {
                if (c->watch_handler) c->watch_handler(c->watch_context, c, c->x[1], c->x[2]);
                c->x[0] = 0;
                return 1;
            }
            c->x[30] = c->pc;
        }
        c->pc = target;
        return 1;
    }
    if ((i & 0x7e000000) == 0x34000000) {  // CBZ, CBNZ
        uint64_t v = reg(c, i & 31);
        if (!BIT(i, 31)) v = (uint32_t)v;
        if ((v == 0) != BIT(i, 24)) c->pc = c->pc - 4 + (uint64_t)(sext(BF(i, 23, 5), 19) * 4);
        return 1;
    }
    if ((i & 0x7e000000) == 0x36000000) {  // TBZ, TBNZ
        unsigned bit = (unsigned)(BIT(i, 31) << 5) | (unsigned)BF(i, 23, 19);
        if (BIT(reg(c, i & 31), bit) == BIT(i, 24)) c->pc = c->pc - 4 + (uint64_t)(sext(BF(i, 18, 5), 14) * 4);
        return 1;
    }
    if ((i & 0xff000010) == 0x54000000) {  // B.cond
        if (condition(c, i & 15)) c->pc = c->pc - 4 + (uint64_t)(sext(BF(i, 23, 5), 19) * 4);
        return 1;
    }
    if ((i & 0xfe000000) == 0xd6000000) {  // branch to register, including the arm64e forms
        unsigned opc = BF(i, 24, 21), rn = (i >> 5) & 31;
        switch (opc & 7) {
        case 0: return branch_register(c, reg(c, rn), 0);
        case 1: return branch_register(c, reg(c, rn), 1);
        case 2: return branch_register(c, BF(i, 11, 10) ? c->x[30] : reg(c, rn), 0);
        default: return 0;
        }
    }
    if ((i & 0xff000000) == 0xd4000000) {  // SVC, BRK and friends
        c->status = A64_TRAPPED;
        return 0;
    }
    if ((i & 0xffc00000) == 0xd5000000) {  // system
        unsigned l = BIT(i, 21), op0 = BF(i, 20, 19), rt = i & 31;
        if (op0 == 0) return 1;  // hints (NOP, PACIBSP, ...), barriers
        if (op0 >= 2) {
            unsigned sysreg = BF(i, 20, 5);
            if (l) {
                switch (sysreg) {
                case 0xde82: case 0xde83: set(c, rt, A64_TLS_BASE); return 1;  // TPIDR(RO)_EL0
                case 0xda20: set(c, rt, c->fpcr); return 1;                    // FPCR
                case 0xda21: set(c, rt, 0); return 1;                          // FPSR
                case 0xda10: set(c, rt, ((uint64_t)c->n << 31) | ((uint64_t)c->z << 30) | ((uint64_t)c->c << 29) | ((uint64_t)c->v_flag << 28)); return 1;
                case 0xdf02: set(c, rt, c->steps); return 1;                   // CNTVCT_EL0
                default: return 0;
                }
            }
            if (sysreg == 0xda20) { c->fpcr = (uint32_t)reg(c, rt); return 1; }
            if (sysreg == 0xda21) return 1;
            if (sysreg == 0xda10) {
                uint64_t v = reg(c, rt);
                c->n = BIT(v, 31); c->z = BIT(v, 30); c->c = BIT(v, 29); c->v_flag = BIT(v, 28);
                return 1;
            }
            return 0;
        }
        return 1;  // cache maintenance (DC, IC)
    }
    return 0;
}

static void atomic_store_value(a64 *c, uint64_t address, uint64_t value, int size) { wr(c, address, value, size); }

static int exclusive(a64 *c, uint32_t i) {
    unsigned size = BF(i, 31, 30), o2 = BIT(i, 23), l = BIT(i, 22), o1 = BIT(i, 21);
    unsigned rs = BF(i, 20, 16), rt2 = BF(i, 14, 10), rn = BF(i, 9, 5), rt = i & 31;
    uint64_t address = rn == 31 ? c->x[31] : c->x[rn];
    int bytes = 1 << size;
    if (o2 && o1) {  // CAS
        uint64_t expected = reg(c, rs), current = rd(c, address, bytes);
        uint64_t mask = lowmask(bytes * 8);
        if (((current ^ expected) & mask) == 0) wr(c, address, reg(c, rt), bytes);
        set(c, rs, current);
        return 1;
    }
    if (o2) {  // LDAR, STLR and the limited-ordering forms
        if (l) set(c, rt, rd(c, address, bytes));
        else wr(c, address, reg(c, rt), bytes);
        return 1;
    }
    if (o1) {  // LDXP, STXP
        if (l) {
            int part = size == 3 ? 8 : 4;
            set(c, rt, rd(c, address, part));
            set(c, rt2, rd(c, address + (unsigned)part, part));
            c->exclusive = address;
        } else {
            int part = size == 3 ? 8 : 4;
            atomic_store_value(c, address, reg(c, rt), part);
            atomic_store_value(c, address + (unsigned)part, reg(c, rt2), part);
            set(c, rs, 0);
            c->exclusive = 0;
        }
        return 1;
    }
    if (l) {
        set(c, rt, rd(c, address, bytes));
        c->exclusive = address;
    } else {
        wr(c, address, reg(c, rt), bytes);
        set(c, rs, 0);
        c->exclusive = 0;
    }
    return 1;
}

static int atomics(a64 *c, uint32_t i, int bytes, uint64_t address) {
    unsigned rs = BF(i, 20, 16), rt = i & 31, o3 = BIT(i, 15), opc = BF(i, 14, 12);
    uint64_t mask = lowmask(bytes * 8);
    uint64_t old = rd(c, address, bytes) & mask, operand = reg(c, rs) & mask, value;
    int bits = bytes * 8;
    if (o3) {
        if (opc == 0) value = operand;              // SWP
        else if (opc == 4) { set(c, rt, old); return 1; }  // LDAPR
        else return 0;
    } else {
        switch (opc) {
        case 0: value = old + operand; break;
        case 1: value = old & ~operand; break;
        case 2: value = old ^ operand; break;
        case 3: value = old | operand; break;
        case 4: value = sext(old, bits) > sext(operand, bits) ? old : operand; break;
        case 5: value = sext(old, bits) < sext(operand, bits) ? old : operand; break;
        case 6: value = old > operand ? old : operand; break;
        default: value = old < operand ? old : operand; break;
        }
    }
    wr(c, address, value, bytes);
    set(c, rt, old);
    return 1;
}

static int load_store_register(a64 *c, uint32_t i) {
    unsigned size = BF(i, 31, 30), simd = BIT(i, 26), opc = BF(i, 23, 22);
    unsigned rn = BF(i, 9, 5), rt = i & 31;
    uint64_t base = rn == 31 ? c->x[31] : c->x[rn];
    uint64_t address;
    int writeback = 0, post = 0;
    uint64_t updated = 0;

    if (size == 3 && !simd && !BIT(i, 24) && BIT(i, 21) && BIT(i, 10)) {  // LDRAA, LDRAB (arm64e)
        int64_t imm = sext((BIT(i, 22) << 9) | BF(i, 20, 12), 10) * 8;
        uint64_t at = (base & PAC_MASK) + (uint64_t)imm;
        uint64_t value = rd(c, at, 8);
        if (BIT(i, 11)) c->x[rn] = at;
        set(c, rt, value);
        return 1;
    }
    if (BIT(i, 24)) {
        unsigned scale = simd ? (opc >= 2 ? 4 : size) : size;
        address = base + (BF(i, 21, 10) << scale);
    } else if (!BIT(i, 21)) {
        int64_t imm = sext(BF(i, 20, 12), 9);
        switch (BF(i, 11, 10)) {
        case 0: case 2: address = base + (uint64_t)imm; break;
        case 1: address = base; updated = base + (uint64_t)imm; writeback = post = 1; break;
        default: address = base + (uint64_t)imm; updated = address; writeback = 1; break;
        }
    } else if (BF(i, 11, 10) == 2) {
        unsigned rm = BF(i, 20, 16), option = BF(i, 15, 13), s = BIT(i, 12);
        unsigned scale = simd ? (opc >= 2 ? 4 : size) : size;
        address = base + extended(reg(c, rm), option, s ? scale : 0);
    } else if (BF(i, 11, 10) == 0 && !simd) {
        return atomics(c, i, 1 << size, base);
    } else {
        return 0;
    }
    (void)post;

    if (simd) {
        unsigned bytes = opc >= 2 ? 16 : 1u << size;
        if (opc & 1) {  // load
            if (bytes == 16) {
                uint64_t lo = rd(c, address, 8), hi = rd(c, address + 8, 8);
                c->v[rt].lo = lo; c->v[rt].hi = hi;
            } else {
                c->v[rt].lo = rd(c, address, (int)bytes);
                c->v[rt].hi = 0;
            }
        } else if (bytes == 16) {
            wr(c, address, c->v[rt].lo, 8);
            wr(c, address + 8, c->v[rt].hi, 8);
        } else {
            wr(c, address, c->v[rt].lo, (int)bytes);
        }
    } else {
        int bytes = 1 << size;
        switch (opc) {
        case 0: wr(c, address, reg(c, rt), bytes); break;
        case 1: set(c, rt, rd(c, address, bytes)); break;
        case 2:
            if (size == 3) break;  // PRFM
            set(c, rt, (uint64_t)sext(rd(c, address, bytes), bytes * 8));
            break;
        default:
            if (size >= 2) return 0;
            set(c, rt, (uint32_t)sext(rd(c, address, bytes), bytes * 8));
            break;
        }
    }
    if (writeback) c->x[rn] = updated;
    return 1;
}

static int load_store_pair(a64 *c, uint32_t i) {
    unsigned opc = BF(i, 31, 30), simd = BIT(i, 26), mode = BF(i, 24, 23), load = BIT(i, 22);
    unsigned rt2 = BF(i, 14, 10), rn = BF(i, 9, 5), rt = i & 31;
    // No such instruction, but a call that has jumped into data can reach this, and rd can't read 32 bytes.
    if (opc == 3) return 0;
    int bytes = simd ? 4 << opc : (opc == 2 ? 8 : 4);
    int signed_word = !simd && opc == 1;
    if (signed_word) bytes = 4;
    int64_t offset = sext(BF(i, 21, 15), 7) * bytes;
    uint64_t base = rn == 31 ? c->x[31] : c->x[rn];
    uint64_t address = mode == 1 ? base : base + (uint64_t)offset;
    uint64_t second = address + (unsigned)bytes;

    if (simd) {
        if (load) {
            if (bytes == 16) {
                vreg a = {rd(c, address, 8), rd(c, address + 8, 8)};
                vreg b = {rd(c, second, 8), rd(c, second + 8, 8)};
                c->v[rt] = a; c->v[rt2] = b;
            } else {
                uint64_t a = rd(c, address, bytes), b = rd(c, second, bytes);
                c->v[rt].lo = a; c->v[rt].hi = 0;
                c->v[rt2].lo = b; c->v[rt2].hi = 0;
            }
        } else if (bytes == 16) {
            wr(c, address, c->v[rt].lo, 8); wr(c, address + 8, c->v[rt].hi, 8);
            wr(c, second, c->v[rt2].lo, 8); wr(c, second + 8, c->v[rt2].hi, 8);
        } else {
            wr(c, address, c->v[rt].lo, bytes);
            wr(c, second, c->v[rt2].lo, bytes);
        }
    } else if (load) {
        uint64_t a = rd(c, address, bytes), b = rd(c, second, bytes);
        if (signed_word) { a = (uint64_t)sext(a, 32); b = (uint64_t)sext(b, 32); }
        set(c, rt, a);
        set(c, rt2, b);
    } else {
        wr(c, address, reg(c, rt), bytes);
        wr(c, second, reg(c, rt2), bytes);
    }
    if (mode == 1 || mode == 3) c->x[rn] = base + (uint64_t)offset;
    return 1;
}

static int load_literal(a64 *c, uint32_t i) {
    unsigned opc = BF(i, 31, 30), rt = i & 31;
    uint64_t address = c->pc - 4 + (uint64_t)(sext(BF(i, 23, 5), 19) * 4);
    if (BIT(i, 26)) {
        int bytes = 4 << opc;
        if (bytes == 16) { c->v[rt].lo = rd(c, address, 8); c->v[rt].hi = rd(c, address + 8, 8); }
        else { c->v[rt].lo = rd(c, address, bytes); c->v[rt].hi = 0; }
        return 1;
    }
    switch (opc) {
    case 0: set(c, rt, rd(c, address, 4)); return 1;
    case 1: set(c, rt, rd(c, address, 8)); return 1;
    case 2: set(c, rt, (uint64_t)(int64_t)(int32_t)rd(c, address, 4)); return 1;
    default: return 1;  // PRFM
    }
}

static int loads_stores(a64 *c, uint32_t i) {
    unsigned top = BF(i, 29, 28);
    if (top == 3) return load_store_register(c, i);
    if (top == 2) return load_store_pair(c, i);
    if (top == 1) return load_literal(c, i);
    if (BIT(i, 26)) return a64_simd_loadstore(c, i);
    return exclusive(c, i);
}

static int data_register(a64 *c, uint32_t i) {
    int is64 = BIT(i, 31);
    unsigned rd_ = i & 31, rn = BF(i, 9, 5), rm = BF(i, 20, 16);
    if (!BIT(i, 28)) {
        if (!BIT(i, 24)) {  // logical shifted register
            unsigned opc = BF(i, 30, 29), n = BIT(i, 21), type = BF(i, 23, 22), amount = BF(i, 15, 10);
            uint64_t a = reg(c, rn), b = shifted(reg(c, rm), type, amount, is64), r;
            if (n) b = ~b;
            switch (opc) {
            case 0: r = a & b; break;
            case 1: r = a | b; break;
            case 2: r = a ^ b; break;
            default:
                r = a & b;
                c->n = is64 ? r >> 63 : (r >> 31) & 1;
                c->z = is64 ? r == 0 : (uint32_t)r == 0;
                c->c = c->v_flag = 0;
                break;
            }
            set(c, rd_, is64 ? r : (uint32_t)r);
            return 1;
        }
        int sub = BIT(i, 30), flags = BIT(i, 29);
        if (!BIT(i, 21)) {  // add/sub shifted register
            uint64_t a = reg(c, rn), b = shifted(reg(c, rm), BF(i, 23, 22), BF(i, 15, 10), is64);
            uint64_t r = sub ? add_carry(c, a, ~b, 1, is64, flags) : add_carry(c, a, b, 0, is64, flags);
            set(c, rd_, r);
            return 1;
        }
        // add/sub extended register
        uint64_t a = rn == 31 ? c->x[31] : c->x[rn];
        uint64_t b = extended(reg(c, rm), BF(i, 15, 13), BF(i, 12, 10));
        uint64_t r = sub ? add_carry(c, a, ~b, 1, is64, flags) : add_carry(c, a, b, 0, is64, flags);
        if (flags) set(c, rd_, r);
        else c->x[rd_] = r;
        return 1;
    }
    unsigned op = BF(i, 24, 21);
    if (BIT(i, 24)) {  // three source
        unsigned ra = BF(i, 14, 10), op31 = BF(i, 23, 21), o0 = BIT(i, 15);
        uint64_t a = reg(c, ra), n = reg(c, rn), m = reg(c, rm), r;
        switch (op31) {
        case 0: r = o0 ? a - n * m : a + n * m; if (!is64) r = (uint32_t)r; break;
        case 1: {
            int64_t p = (int64_t)(int32_t)n * (int64_t)(int32_t)m;
            r = o0 ? a - (uint64_t)p : a + (uint64_t)p;
            break;
        }
        case 5: {
            uint64_t p = (uint64_t)(uint32_t)n * (uint32_t)m;
            r = o0 ? a - p : a + p;
            break;
        }
        case 2: r = (uint64_t)(((__int128)(int64_t)n * (int64_t)m) >> 64); break;
        case 6: r = (uint64_t)(((unsigned __int128)n * m) >> 64); break;
        default: return 0;
        }
        set(c, rd_, r);
        return 1;
    }
    switch (op) {
    case 0: {  // ADC, SBC
        int sub = BIT(i, 30), flags = BIT(i, 29);
        uint64_t b = reg(c, rm);
        set(c, rd_, add_carry(c, reg(c, rn), sub ? ~b : b, c->c, is64, flags));
        return 1;
    }
    case 2: {  // CCMP, CCMN
        unsigned cc = BF(i, 15, 12), nzcv = i & 15;
        if (condition(c, cc)) {
            uint64_t a = reg(c, rn), b = BIT(i, 11) ? BF(i, 20, 16) : reg(c, rm);
            if (BIT(i, 30)) add_carry(c, a, ~b, 1, is64, 1);
            else add_carry(c, a, b, 0, is64, 1);
        } else {
            c->n = BIT(nzcv, 3); c->z = BIT(nzcv, 2); c->c = BIT(nzcv, 1); c->v_flag = BIT(nzcv, 0);
        }
        return 1;
    }
    case 4: {  // conditional select
        unsigned cc = BF(i, 15, 12), o2 = BF(i, 11, 10), op_ = BIT(i, 30);
        uint64_t r;
        if (condition(c, cc)) r = reg(c, rn);
        else {
            uint64_t m = reg(c, rm);
            if (!op_) r = o2 == 1 ? m + 1 : m;
            else r = o2 == 1 ? (uint64_t)0 - m : ~m;
        }
        set(c, rd_, is64 ? r : (uint32_t)r);
        return 1;
    }
    case 6: {
        if (BIT(i, 30)) {  // one source
            unsigned opcode = BF(i, 15, 10);
            uint64_t a = reg(c, rn), r;
            if (BF(i, 20, 16) == 1) {  // PAC, AUT, XPAC: signing is a no-op here, authenticating strips
                set(c, rd_, (opcode & 4) || opcode >= 16 ? a & PAC_MASK : a);
                return 1;
            }
            if (!is64) a = (uint32_t)a;
            switch (opcode) {
            case 0: {  // RBIT
                r = 0;
                int size = is64 ? 64 : 32;
                for (int b = 0; b < size; b++) if (BIT(a, b)) r |= 1ull << (size - 1 - b);
                break;
            }
            case 1:  // REV16
                r = ((a & 0x00ff00ff00ff00ffull) << 8) | ((a >> 8) & 0x00ff00ff00ff00ffull);
                break;
            case 2:  // REV32, or REV in 32-bit form
                r = is64 ? ((uint64_t)__builtin_bswap32((uint32_t)a) | ((uint64_t)__builtin_bswap32((uint32_t)(a >> 32)) << 32))
                         : __builtin_bswap32((uint32_t)a);
                break;
            case 3: r = __builtin_bswap64(a); break;
            case 4: r = a == 0 ? (is64 ? 64 : 32) : (is64 ? __builtin_clzll(a) : __builtin_clz((uint32_t)a)); break;
            case 5: {  // CLS
                uint64_t x = is64 ? (a ^ (a << 1)) : (uint32_t)(a ^ (a << 1));
                int bits = is64 ? 64 : 32;
                int leading = x == 0 ? bits : (is64 ? __builtin_clzll(x) : __builtin_clz((uint32_t)x));
                r = (uint64_t)(leading ? leading - 0 : 0);
                r = r >= (uint64_t)bits ? (uint64_t)bits - 1 : r;
                break;
            }
            default: return 0;
            }
            set(c, rd_, is64 ? r : (uint32_t)r);
            return 1;
        }
        unsigned opcode = BF(i, 15, 10);
        uint64_t a = reg(c, rn), b = reg(c, rm), r;
        if (!is64) { a = (uint32_t)a; b = (uint32_t)b; }
        switch (opcode) {
        case 2:  // UDIV
            r = b ? a / b : 0;
            break;
        case 3:  // SDIV
            if (is64) {
                int64_t x = (int64_t)a, y = (int64_t)b;
                r = y == 0 ? 0 : (x == INT64_MIN && y == -1) ? (uint64_t)x : (uint64_t)(x / y);
            } else {
                int32_t x = (int32_t)a, y = (int32_t)b;
                r = y == 0 ? 0 : (x == INT32_MIN && y == -1) ? (uint32_t)x : (uint32_t)(x / y);
            }
            break;
        case 8: r = shifted(a, 0, (unsigned)b, is64); break;
        case 9: r = shifted(a, 1, (unsigned)b, is64); break;
        case 10: r = shifted(a, 2, (unsigned)b, is64); break;
        case 11: r = shifted(a, 3, (unsigned)b, is64); break;
        default: return 0;
        }
        set(c, rd_, is64 ? r : (uint32_t)r);
        return 1;
    }
    default:
        return 0;
    }
}

static inline int step(a64 *c, uint32_t i) {
    unsigned group = BF(i, 28, 25);
    if ((group & 14) == 8) return data_immediate(c, i);
    if ((group & 14) == 10) return branches(c, i);
    if ((group & 5) == 4) return loads_stores(c, i);
    if ((group & 7) == 5) return data_register(c, i);
    if ((group & 7) == 7) return a64_simd(c, i);
    return 0;
}

a64_status a64_run(a64 *c, uint64_t pc, uint64_t max_steps) {
    uint64_t limit = c->steps + max_steps;
    c->pc = pc;
    c->status = A64_OK;
    while (c->pc != A64_RETURN_SENTINEL) {
        if (c->steps++ >= limit) return A64_STEP_LIMIT;
        uint64_t at = c->pc, page = at & ~(uint64_t)(A64_PAGE - 1);
        if (page != c->code_page) {
            c->code_data = page_r(c, page);
            c->code_page = page;
        }
        uint32_t i;
        memcpy(&i, c->code_data + (at & (A64_PAGE - 1)), 4);
        c->inst = i;
        c->pc = at + 4;
        if (!step(c, i)) {
            c->pc = at;
            return c->status != A64_OK ? c->status : A64_UNDEFINED;
        }
    }
    return A64_OK;
}

// ---- runtime stubs ----

uint64_t a64_heap_alloc(a64 *c, uint64_t size) {
    uint64_t at = c->heap_next, rounded = ((size ? size : 1) + 15) & ~15ull;
    if (at + rounded > A64_HEAP_END) {
        c->status = A64_HEAP_FULL;
        return 0;
    }
    c->heap_next += rounded;
    if (c->heap_count == c->heap_capacity) {
        c->heap_capacity = c->heap_capacity ? c->heap_capacity * 2 : 256;
        c->heap_sizes = realloc(c->heap_sizes, c->heap_capacity * sizeof(heap_block));
    }
    c->heap_sizes[c->heap_count++] = (heap_block){at, size};
    return at;
}

static uint64_t heap_size(a64 *c, uint64_t address) {
    size_t lo = 0, hi = c->heap_count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (c->heap_sizes[mid].address == address) return c->heap_sizes[mid].size;
        if (c->heap_sizes[mid].address < address) lo = mid + 1;
        else hi = mid;
    }
    return 0;
}

static void copy_memory(a64 *c, uint64_t to, uint64_t from, uint64_t count) {
    uint8_t buffer[A64_PAGE];
    if (to > from && to < from + count) {  // overlap: copy from the end
        while (count) {
            uint64_t n = count < A64_PAGE ? count : A64_PAGE;
            a64_read_bytes(c, from + count - n, buffer, n);
            a64_write_bytes(c, to + count - n, buffer, n);
            count -= n;
        }
        return;
    }
    while (count) {
        uint64_t n = count < A64_PAGE ? count : A64_PAGE;
        a64_read_bytes(c, from, buffer, n);
        a64_write_bytes(c, to, buffer, n);
        to += n; from += n; count -= n;
    }
}

static void fill_memory(a64 *c, uint64_t to, uint8_t value, uint64_t count) {
    uint8_t buffer[A64_PAGE];
    memset(buffer, value, sizeof buffer);
    while (count) {
        uint64_t n = count < A64_PAGE ? count : A64_PAGE;
        a64_write_bytes(c, to, buffer, n);
        to += n; count -= n;
    }
}

static int same_type(a64 *c, uint64_t a, uint64_t b) {
    if (a == b) return 1;
    uint64_t x = rd(c, a + 8, 8), y = rd(c, b + 8, 8);
    if (x == y) return 1;
    if (!((x | y) >> 63)) return 0;  // both names unique, and different
    x &= PAC_MASK; y &= PAC_MASK;
    for (uint64_t i = 0; i < 512; i++) {
        uint64_t p = rd(c, x + i, 1), q = rd(c, y + i, 1);
        if (p != q) return 0;
        if (!p) return 1;
    }
    return 0;
}

// Finds the subobject of type `target` inside `object`, whose dynamic type is `type`.
static int find_base(a64 *c, uint64_t type, uint64_t target, uint64_t object, uint64_t *found, int depth) {
    if (same_type(c, type, target)) {
        *found = object;
        return 1;
    }
    if (depth > 32) return 0;
    uint64_t si_vt, vmi_vt, kind = rd(c, type, 8) & PAC_MASK;
    a64_image_rtti(c->image, &si_vt, &vmi_vt);
    if (kind == si_vt) return find_base(c, rd(c, type + 16, 8), target, object, found, depth + 1);
    if (kind != vmi_vt) return 0;
    uint64_t count = rd(c, type + 20, 4);
    for (uint64_t i = 0; i < count; i++) {
        uint64_t base = rd(c, type + 24 + i * 16, 8);
        int64_t flags = (int64_t)rd(c, type + 32 + i * 16, 8), offset = flags >> 8;
        if (!(flags & 2)) continue;  // not public
        if (flags & 1) offset = (int64_t)rd(c, rd(c, object, 8) + (uint64_t)offset, 8);
        if (find_base(c, base, target, object + (uint64_t)offset, found, depth + 1)) return 1;
    }
    return 0;
}

static uint64_t dynamic_cast_stub(a64 *c, uint64_t source, uint64_t target) {
    if (!source) return 0;
    uint64_t vtable = rd(c, source, 8) & PAC_MASK;
    int64_t to_top = (int64_t)rd(c, vtable - 16, 8);
    uint64_t whole = source + (uint64_t)to_top, type = rd(c, vtable - 8, 8) & PAC_MASK, found = 0;
    return find_base(c, type, target, whole, &found, 0) ? found : 0;
}

// Stub work is not counted in steps, so a garbage length must not run for ever.
#define STUB_LIMIT (64ull * 1024 * 1024)

void a64_run_stub(a64 *c, int stub) {
    uint64_t a = c->x[0], b = c->x[1], d = c->x[2];
    if (stub >= A64_STUB_MATH_BASE) {
        a64_run_math(c, stub);
        return;
    }
    uint64_t size = stub == A64_STUB_BZERO ? b : d;
    if ((stub == A64_STUB_MEMCPY || stub == A64_STUB_MEMSET || stub == A64_STUB_BZERO || stub == A64_STUB_MEMCMP ||
         stub == A64_STUB_MEMCHR || stub == A64_STUB_STRNCMP) && size > STUB_LIMIT) {
        c->status = A64_TRAPPED;
        return;
    }
    // Charge the work to the step budget, or a loop of big copies would never hit its limit.
    if (stub == A64_STUB_MEMCPY || stub == A64_STUB_MEMSET || stub == A64_STUB_BZERO) c->steps += size >> 4;
    switch ((a64_stub)stub) {
    case A64_STUB_RET0: c->x[0] = 0; break;
    case A64_STUB_RET1: c->x[0] = 1; break;
    case A64_STUB_MEMCPY: copy_memory(c, a, b, d); break;
    case A64_STUB_MEMSET: fill_memory(c, a, (uint8_t)b, d); break;
    case A64_STUB_BZERO: fill_memory(c, a, 0, b); break;
    case A64_STUB_MEMCMP: {
        int result = 0;
        for (uint64_t i = 0; i < d && !result; i++) result = (int)rd(c, a + i, 1) - (int)rd(c, b + i, 1);
        c->x[0] = (uint64_t)(int64_t)result;
        break;
    }
    case A64_STUB_MEMCHR: {
        uint64_t found = 0;
        for (uint64_t i = 0; i < d; i++) if ((uint8_t)rd(c, a + i, 1) == (uint8_t)b) { found = a + i; break; }
        c->x[0] = found;
        break;
    }
    case A64_STUB_STRLEN: {
        uint64_t n = 0;
        while (n < STUB_LIMIT && rd(c, a + n, 1)) n++;
        c->x[0] = n;
        break;
    }
    case A64_STUB_STRCMP: {
        int x, y;
        uint64_t i = 0;
        do { x = (int)rd(c, a + i, 1); y = (int)rd(c, b + i, 1); i++; } while (x && x == y && i < STUB_LIMIT);
        c->x[0] = (uint64_t)(int64_t)(x - y);
        break;
    }
    case A64_STUB_STRNCMP: {
        int x = 0, y = 0;
        for (uint64_t i = 0; i < d; i++) {
            x = (int)rd(c, a + i, 1); y = (int)rd(c, b + i, 1);
            if (!x || x != y) break;
        }
        c->x[0] = (uint64_t)(int64_t)(x - y);
        break;
    }
    case A64_STUB_MALLOC: c->x[0] = a64_heap_alloc(c, a); break;
    case A64_STUB_CALLOC: c->x[0] = a64_heap_alloc(c, a * b); break;
    case A64_STUB_REALLOC: {
        uint64_t fresh = a64_heap_alloc(c, b);
        if (a && fresh) {
            uint64_t old = heap_size(c, a);
            copy_memory(c, fresh, a, old < b ? old : b);
        }
        c->x[0] = fresh;
        break;
    }
    case A64_STUB_FREE: break;
    case A64_STUB_MALLOC_SIZE: c->x[0] = heap_size(c, a); break;
    case A64_STUB_POSIX_MEMALIGN: {
        uint64_t mask = b > 16 ? b - 1 : 15;
        uint64_t block = a64_heap_alloc(c, d + mask);
        wr(c, a, (block + mask) & ~mask, 8);
        c->x[0] = 0;
        break;
    }
    case A64_STUB_TLV: c->x[0] = A64_TLS_BASE + rd(c, a + 16, 8); break;
    case A64_STUB_GUARD_ACQUIRE: c->x[0] = rd(c, a, 1) ? 0 : 1; break;
    case A64_STUB_GUARD_RELEASE: wr(c, a, 1, 1); break;
    case A64_STUB_DYNAMIC_CAST: c->x[0] = dynamic_cast_stub(c, a, d); break;
    case A64_STUB_ABORT: c->status = A64_TRAPPED; break;
    }
}
