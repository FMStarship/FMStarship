#ifndef A64_INTERNAL_H
#define A64_INTERNAL_H

#include "a64.h"

#include <string.h>

#define A64_TLB 4096
#define A64_STUB_MATH_BASE 1000

typedef struct { uint64_t address; a64_stub stub; } a64_stub_entry;
typedef struct { uint64_t lo, hi; } vreg;
typedef struct { uint64_t address, size; } heap_block;

struct a64 {
    uint64_t x[32];  // x[31] is SP; the zero register is handled by the accessors
    vreg v[32];
    uint64_t pc;
    uint8_t n, z, c, v_flag;
    uint32_t inst;
    uint64_t steps;
    uint32_t fpcr;

    a64_image *image;
    uint64_t tlb_tag[A64_TLB];
    uint8_t *tlb_data[A64_TLB];
    uint8_t tlb_writable[A64_TLB];

    uint64_t code_page;
    const uint8_t *code_data;

    uint64_t *overlay_keys;
    uint8_t **overlay_pages;
    size_t overlay_capacity, overlay_count;
    size_t *overlay_used;  // the slots filled since the last reset, so a reset clears only those
    uint8_t **arena;
    size_t arena_count, arena_capacity, arena_used;

    uint64_t heap_next;
    heap_block *heap_sizes;
    size_t heap_count, heap_capacity;

    uint64_t exclusive;
    uint64_t external_miss;
    uint64_t image_low, image_high;
    uint64_t watch[2];
    uint64_t watched_key, watched_value;
    a64_watch_fn watch_handler;
    void *watch_context;
    a64_status status;
};

const uint8_t *a64_image_page(a64_image *image, uint64_t page);
int a64_image_stub(const a64_image *image, uint64_t address);
void a64_image_rtti(const a64_image *image, uint64_t *si_vt, uint64_t *vmi_vt);
const uint8_t *a64_page_read_slow(a64 *c, uint64_t page);
uint8_t *a64_page_write_slow(a64 *c, uint64_t page);
void a64_run_stub(a64 *c, int stub);
void a64_run_math(a64 *c, int stub);
uint64_t a64_heap_alloc(a64 *c, uint64_t size);
int a64_simd(a64 *c, uint32_t i);
int a64_simd_loadstore(a64 *c, uint32_t i);

static inline const uint8_t *page_r(a64 *c, uint64_t page) {
    unsigned slot = (unsigned)(page >> 12) & (A64_TLB - 1);
    if (__builtin_expect(c->tlb_tag[slot] == page, 1)) return c->tlb_data[slot];
    return a64_page_read_slow(c, page);
}

static inline uint8_t *page_w(a64 *c, uint64_t page) {
    unsigned slot = (unsigned)(page >> 12) & (A64_TLB - 1);
    if (__builtin_expect(c->tlb_tag[slot] == page && c->tlb_writable[slot], 1)) return c->tlb_data[slot];
    return a64_page_write_slow(c, page);
}

static inline uint64_t rd(a64 *c, uint64_t a, int size) {
    uint64_t offset = a & (A64_PAGE - 1);
    if (__builtin_expect(offset + (unsigned)size <= A64_PAGE, 1)) {
        const uint8_t *p = page_r(c, a - offset) + offset;
        uint64_t v = 0;
        memcpy(&v, p, (size_t)size);
        return v;
    }
    uint64_t v = 0;
    for (int i = 0; i < size; i++) {
        uint64_t b = a + (unsigned)i;
        v |= (uint64_t)page_r(c, b & ~(uint64_t)(A64_PAGE - 1))[b & (A64_PAGE - 1)] << (8 * i);
    }
    return v;
}

static inline void wr(a64 *c, uint64_t a, uint64_t v, int size) {
    uint64_t offset = a & (A64_PAGE - 1);
    if (__builtin_expect(offset + (unsigned)size <= A64_PAGE, 1)) {
        memcpy(page_w(c, a - offset) + offset, &v, (size_t)size);
        return;
    }
    for (int i = 0; i < size; i++) {
        uint64_t b = a + (unsigned)i;
        page_w(c, b & ~(uint64_t)(A64_PAGE - 1))[b & (A64_PAGE - 1)] = (uint8_t)(v >> (8 * i));
    }
}

static inline uint64_t reg(const a64 *c, unsigned n) { return n == 31 ? 0 : c->x[n]; }
static inline void set(a64 *c, unsigned n, uint64_t v) { if (n != 31) c->x[n] = v; }

#endif
