#include "internal.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define STRIPES 256
#define MAX_SHARED_PAGES 400000

typedef struct shared_page {
    uint64_t address;
    struct shared_page *next;
    uint8_t data[A64_PAGE];
} shared_page;

typedef struct {
    pthread_mutex_t lock;
    shared_page **buckets;
    size_t bucket_count, count;
} stripe;

struct a64_image {
    a64_fetch_fn fetch;
    void *context;
    stripe stripes[STRIPES];
    a64_stub_entry *stubs;
    size_t stub_capacity;
    size_t pages;
    uint64_t si_vt, vmi_vt;
};

static inline uint64_t mix(uint64_t v) {
    v ^= v >> 33;
    v *= 0xff51afd7ed558ccdull;
    v ^= v >> 33;
    return v;
}

a64_image *a64_image_new(a64_fetch_fn fetch, void *context) {
    a64_image *image = calloc(1, sizeof *image);
    image->fetch = fetch;
    image->context = context;
    for (int i = 0; i < STRIPES; i++) {
        pthread_mutex_init(&image->stripes[i].lock, NULL);
        image->stripes[i].bucket_count = 1024;
        image->stripes[i].buckets = calloc(1024, sizeof(shared_page *));
    }
    image->stub_capacity = 4096;
    image->stubs = calloc(image->stub_capacity, sizeof(a64_stub_entry));
    return image;
}

void a64_image_clear_pages(a64_image *image) {
    for (int i = 0; i < STRIPES; i++) {
        stripe *s = &image->stripes[i];
        pthread_mutex_lock(&s->lock);
        for (size_t b = 0; b < s->bucket_count; b++) {
            for (shared_page *p = s->buckets[b]; p;) {
                shared_page *next = p->next;
                free(p);
                p = next;
            }
            s->buckets[b] = NULL;
        }
        s->count = 0;
        pthread_mutex_unlock(&s->lock);
    }
    image->pages = 0;
}

void a64_image_free(a64_image *image) {
    a64_image_clear_pages(image);
    for (int i = 0; i < STRIPES; i++) free(image->stripes[i].buckets);
    free(image->stubs);
    free(image);
}

size_t a64_image_pages(const a64_image *image) { return image->pages; }

void a64_image_set_rtti(a64_image *image, uint64_t class_vt, uint64_t si_vt, uint64_t vmi_vt) {
    (void)class_vt;
    image->si_vt = si_vt;
    image->vmi_vt = vmi_vt;
}

void a64_image_rtti(const a64_image *image, uint64_t *si_vt, uint64_t *vmi_vt) {
    *si_vt = image->si_vt;
    *vmi_vt = image->vmi_vt;
}

void a64_image_add_stub(a64_image *image, uint64_t address, a64_stub stub) {
    size_t mask = image->stub_capacity - 1;
    for (size_t i = mix(address) & mask;; i = (i + 1) & mask) {
        if (image->stubs[i].address == 0 || image->stubs[i].address == address) {
            image->stubs[i] = (a64_stub_entry){address, stub};
            return;
        }
    }
}

void a64_image_add_math_stub(a64_image *image, uint64_t address, int index) {
    a64_image_add_stub(image, address, (a64_stub)(A64_STUB_MATH_BASE + index));
}

int a64_image_stub(const a64_image *image, uint64_t address) {
    size_t mask = image->stub_capacity - 1;
    for (size_t i = mix(address) & mask;; i = (i + 1) & mask) {
        if (image->stubs[i].address == 0) return 0;
        if (image->stubs[i].address == address) return (int)image->stubs[i].stub;
    }
}

const uint8_t *a64_image_page(a64_image *image, uint64_t page) {
    uint64_t h = mix(page >> 12);
    stripe *s = &image->stripes[h % STRIPES];
    pthread_mutex_lock(&s->lock);
    size_t bucket = (h >> 16) & (s->bucket_count - 1);
    for (shared_page *p = s->buckets[bucket]; p; p = p->next) {
        if (p->address == page) {
            pthread_mutex_unlock(&s->lock);
            return p->data;
        }
    }
    pthread_mutex_unlock(&s->lock);

    shared_page *fresh = malloc(sizeof *fresh);
    fresh->address = page;
    if (!image->fetch(image->context, page, fresh->data)) {
        // Unmapped memory reads as zero. Not caching it keeps wild pointers from using up memory.
        static const uint8_t zeros[A64_PAGE];
        free(fresh);
        return zeros;
    }

    pthread_mutex_lock(&s->lock);
    for (shared_page *p = s->buckets[bucket]; p; p = p->next) {
        if (p->address == page) {
            pthread_mutex_unlock(&s->lock);
            free(fresh);
            return p->data;
        }
    }
    fresh->next = s->buckets[bucket];
    s->buckets[bucket] = fresh;
    s->count++;
    __sync_fetch_and_add(&image->pages, 1);
    pthread_mutex_unlock(&s->lock);
    return fresh->data;
}

// ---- per-run overlay ----

static int is_private(uint64_t page) {
    return (page >= 0x7f0000000000ull && page < 0x7f0000900000ull) ||
           page == (A64_RETURN_SENTINEL & ~(uint64_t)(A64_PAGE - 1)) ||
           (page >= A64_HEAP_BASE && page < A64_HEAP_END);
}

static uint8_t *overlay_new_page(a64 *c) {
    if (c->arena_used == c->arena_count) {
        if (c->arena_count == c->arena_capacity) {
            size_t grown = c->arena_capacity ? c->arena_capacity * 2 : 256;
            c->arena = realloc(c->arena, grown * sizeof(uint8_t *));
            c->arena_capacity = grown;
        }
        c->arena[c->arena_count++] = malloc(A64_PAGE);
    }
    return c->arena[c->arena_used++];
}

// Keys are page | 1, so that page zero isn't mistaken for an empty slot.
static uint8_t **overlay_slot(a64 *c, uint64_t key) {
    size_t mask = c->overlay_capacity - 1;
    for (size_t i = mix(key >> 12) & mask;; i = (i + 1) & mask) {
        if (c->overlay_keys[i] == 0 || c->overlay_keys[i] == key) {
            c->overlay_keys[i] = key;
            return &c->overlay_pages[i];
        }
    }
}

static void overlay_grow(a64 *c) {
    size_t old_capacity = c->overlay_capacity;
    uint64_t *old_keys = c->overlay_keys;
    uint8_t **old_pages = c->overlay_pages;
    c->overlay_capacity = old_capacity * 2;
    c->overlay_keys = calloc(c->overlay_capacity, sizeof(uint64_t));
    c->overlay_pages = calloc(c->overlay_capacity, sizeof(uint8_t *));
    for (size_t i = 0; i < old_capacity; i++)
        if (old_keys[i]) *overlay_slot(c, old_keys[i]) = old_pages[i];
    free(old_keys);
    free(old_pages);
}

static uint8_t *overlay_find(a64 *c, uint64_t page) {
    uint64_t key = page | 1;
    size_t mask = c->overlay_capacity - 1;
    for (size_t i = mix(key >> 12) & mask;; i = (i + 1) & mask) {
        if (c->overlay_keys[i] == 0) return NULL;
        if (c->overlay_keys[i] == key) return c->overlay_pages[i];
    }
}

static uint8_t *overlay_create(a64 *c, uint64_t page, int copy_from_image) {
    if (c->overlay_count * 2 >= c->overlay_capacity) overlay_grow(c);
    uint8_t *data = overlay_new_page(c);
    if (copy_from_image) memcpy(data, a64_image_page(c->image, page), A64_PAGE);
    else memset(data, 0, A64_PAGE);
    *overlay_slot(c, page | 1) = data;
    c->overlay_count++;
    return data;
}

const uint8_t *a64_page_read_slow(a64 *c, uint64_t page) {
    unsigned slot = (unsigned)(page >> 12) & (A64_TLB - 1);
    const uint8_t *data = overlay_find(c, page);
    int writable = 1;
    if (!data) {
        if (is_private(page)) {
            data = overlay_create(c, page, 0);
        } else {
            data = a64_image_page(c->image, page);
            writable = 0;
        }
    }
    c->tlb_tag[slot] = page;
    c->tlb_data[slot] = (uint8_t *)data;
    c->tlb_writable[slot] = (uint8_t)writable;
    return data;
}

uint8_t *a64_page_write_slow(a64 *c, uint64_t page) {
    unsigned slot = (unsigned)(page >> 12) & (A64_TLB - 1);
    uint8_t *data = overlay_find(c, page);
    if (!data) data = overlay_create(c, page, !is_private(page));
    c->tlb_tag[slot] = page;
    c->tlb_data[slot] = data;
    c->tlb_writable[slot] = 1;
    return data;
}

a64 *a64_new(a64_image *image) {
    a64 *c = calloc(1, sizeof *c);
    c->image = image;
    c->overlay_capacity = 4096;
    c->overlay_keys = calloc(c->overlay_capacity, sizeof(uint64_t));
    c->overlay_pages = calloc(c->overlay_capacity, sizeof(uint8_t *));
    a64_reset(c);
    return c;
}

void a64_free(a64 *c) {
    for (size_t i = 0; i < c->arena_count; i++) free(c->arena[i]);
    free(c->arena);
    free(c->overlay_keys);
    free(c->overlay_pages);
    free(c->heap_sizes);
    free(c);
}

void a64_reset(a64 *c) {
    memset(c->overlay_keys, 0, c->overlay_capacity * sizeof(uint64_t));
    c->overlay_count = 0;
    c->arena_used = 0;
    memset(c->tlb_tag, 0xff, sizeof c->tlb_tag);
    memset(c->x, 0, sizeof c->x);
    memset(c->v, 0, sizeof c->v);
    c->n = c->z = c->c = c->v_flag = 0;
    c->steps = 0;
    c->heap_next = A64_HEAP_BASE;
    c->heap_count = 0;
    c->exclusive = 0;
    c->external_miss = 0;
    c->watch[0] = c->watch[1] = 0;
    c->watched_key = c->watched_value = 0;
    c->code_page = ~(uint64_t)0;
}

uint64_t a64_get_x(const a64 *c, int i) { return c->x[i]; }
void a64_set_x(a64 *c, int i, uint64_t v) { c->x[i] = v; }
uint64_t a64_get_v_low(const a64 *c, int i) { return c->v[i].lo; }
void a64_set_v_low(a64 *c, int i, uint64_t v) { c->v[i].lo = v; c->v[i].hi = 0; }
uint64_t a64_pc(const a64 *c) { return c->pc; }
uint64_t a64_steps(const a64 *c) { return c->steps; }
uint32_t a64_last_instruction(const a64 *c) { return c->inst; }
uint64_t a64_external_miss(const a64 *c) { return c->external_miss; }
void a64_set_image_bounds(a64 *c, uint64_t low, uint64_t high) { c->image_low = low; c->image_high = high; }
void a64_set_watch_handler(a64 *c, a64_watch_fn handler, void *context) { c->watch_handler = handler; c->watch_context = context; }
void a64_set_watch(a64 *c, int index, uint64_t address) { if (index >= 0 && index < 2) c->watch[index] = address; }

uint64_t a64_read(a64 *c, uint64_t address, int size) { return rd(c, address, size); }
void a64_write(a64 *c, uint64_t address, uint64_t value, int size) { wr(c, address, value, size); }

void a64_read_bytes(a64 *c, uint64_t address, void *out, size_t count) {
    uint8_t *to = out;
    while (count) {
        size_t in_page = A64_PAGE - (address & (A64_PAGE - 1));
        size_t n = count < in_page ? count : in_page;
        memcpy(to, page_r(c, address & ~(uint64_t)(A64_PAGE - 1)) + (address & (A64_PAGE - 1)), n);
        to += n; address += n; count -= n;
    }
}

void a64_write_bytes(a64 *c, uint64_t address, const void *data, size_t count) {
    const uint8_t *from = data;
    while (count) {
        size_t in_page = A64_PAGE - (address & (A64_PAGE - 1));
        size_t n = count < in_page ? count : in_page;
        memcpy(page_w(c, address & ~(uint64_t)(A64_PAGE - 1)) + (address & (A64_PAGE - 1)), from, n);
        from += n; address += n; count -= n;
    }
}
