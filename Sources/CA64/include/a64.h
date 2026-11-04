// A sandboxed ARM64 interpreter, the Mac counterpart of FM Starship's x86-64 emulator.
// It runs the game's own functions over a read-through view of its memory. Every write lands in
// a private overlay that is discarded afterwards, so running code here can never change the game.
#ifndef A64_H
#define A64_H

#include <stddef.h>
#include <stdint.h>

#define A64_PAGE 4096u
#define A64_RETURN_SENTINEL 0x7f0000f00000ull
#define A64_STACK_TOP 0x7f0000100000ull
#define A64_SCRATCH 0x7f0000080000ull
#define A64_HEAP_BASE 0x7f0010000000ull
#define A64_HEAP_END 0x7f0050000000ull
#define A64_TLS_BASE 0x7f0000800000ull

typedef int (*a64_fetch_fn)(void *context, uint64_t page, void *out);

typedef struct a64_image a64_image;
typedef struct a64 a64;

typedef enum {
    A64_OK = 0,
    A64_STEP_LIMIT = 1,
    A64_UNDEFINED = 2,
    A64_HEAP_FULL = 3,
    A64_TRAPPED = 4,
    A64_BAD_BRANCH = 5,
} a64_status;

// What to do instead of running an external function.
typedef enum {
    A64_STUB_RET0 = 1, A64_STUB_RET1, A64_STUB_MEMCPY, A64_STUB_MEMSET, A64_STUB_BZERO, A64_STUB_MEMCMP,
    A64_STUB_MEMCHR, A64_STUB_STRLEN, A64_STUB_STRCMP, A64_STUB_STRNCMP, A64_STUB_MALLOC, A64_STUB_CALLOC,
    A64_STUB_REALLOC, A64_STUB_FREE, A64_STUB_TLV, A64_STUB_GUARD_ACQUIRE, A64_STUB_GUARD_RELEASE, A64_STUB_ABORT,
    A64_STUB_MALLOC_SIZE, A64_STUB_POSIX_MEMALIGN, A64_STUB_DYNAMIC_CAST, A64_STUB_TLV_PACKED,
} a64_stub;

a64_image *a64_image_new(a64_fetch_fn fetch, void *context);
void a64_image_free(a64_image *image);
void a64_image_add_stub(a64_image *image, uint64_t address, a64_stub stub);
void a64_image_add_math_stub(a64_image *image, uint64_t address, int index);
void a64_image_clear_pages(a64_image *image);
// Addresses of libc++abi's type_info vtables, needed to walk class hierarchies for dynamic_cast.
void a64_image_set_rtti(a64_image *image, uint64_t class_vt, uint64_t si_vt, uint64_t vmi_vt);
size_t a64_image_pages(const a64_image *image);

a64 *a64_new(a64_image *image);
void a64_free(a64 *cpu);
void a64_reset(a64 *cpu);

uint64_t a64_get_x(const a64 *cpu, int index);
void a64_set_x(a64 *cpu, int index, uint64_t value);
uint64_t a64_get_v_low(const a64 *cpu, int index);
void a64_set_v_low(a64 *cpu, int index, uint64_t value);
uint64_t a64_read(a64 *cpu, uint64_t address, int size);
void a64_write(a64 *cpu, uint64_t address, uint64_t value, int size);
void a64_read_bytes(a64 *cpu, uint64_t address, void *out, size_t count);
void a64_write_bytes(a64 *cpu, uint64_t address, const void *data, size_t count);

a64_status a64_run(a64 *cpu, uint64_t pc, uint64_t max_steps);
uint64_t a64_pc(const a64 *cpu);
uint64_t a64_steps(const a64 *cpu);
uint32_t a64_last_instruction(const a64 *cpu);
uint64_t a64_external_miss(const a64 *cpu);
void a64_set_image_bounds(a64 *cpu, uint64_t low, uint64_t high);
// Calls to a watched function are skipped. It returns 0, and its (key, value) arguments are kept for
// a64_watched(), which returns them per key through the callback set with a64_set_watch_handler.
void a64_set_watch(a64 *cpu, int index, uint64_t address);
typedef void (*a64_watch_fn)(void *context, a64 *cpu, uint64_t key, uint64_t value);
void a64_set_watch_handler(a64 *cpu, a64_watch_fn handler, void *context);

#endif
