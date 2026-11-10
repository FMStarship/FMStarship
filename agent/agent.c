// FM Starship agent. Loaded into Football Manager at launch through DYLD_INSERT_LIBRARIES.
//
// macOS refuses task_for_pid on hardened apps, and a process that sends its own task port is
// killed by the kernel (EXC_GUARD ILLEGAL_MOVE), so the Mac port cannot read FM from outside.
// This agent answers read requests from inside the process over a private Unix socket instead.
//
// It is passive: it patches nothing, hooks nothing and runs no game code. The protocol has no
// write operation. Reads go through mach_vm_read_overwrite, which reports a bad address as an
// error rather than faulting, so a stale pointer from the client cannot crash the game.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "starship_protocol.h"

static int write_all(int fd, const void *data, size_t size) {
    const char *p = data;
    while (size > 0) {
        ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
        if (n <= 0) return -1;
        p += n;
        size -= (size_t)n;
    }
    return 0;
}

static int read_all(int fd, void *data, size_t size) {
    char *p = data;
    while (size > 0) {
        ssize_t n = read(fd, p, size);
        if (n <= 0) return -1;
        p += n;
        size -= (size_t)n;
    }
    return 0;
}

static int reply(int fd, uint32_t status, const void *payload, uint32_t len) {
    starship_response r = {status, len};
    if (write_all(fd, &r, sizeof r) != 0) return -1;
    return len ? write_all(fd, payload, len) : 0;
}

static int send_hello(int fd) {
    starship_hello h = {STARSHIP_PROTOCOL_VERSION, (uint32_t)getpid()};
    return reply(fd, STARSHIP_OK, &h, sizeof h);
}

// Readable regions that hold real data. Never-touched reservations are skipped: reading them
// would only fault in zero pages inside the game.
static int send_regions(int fd) {
    size_t cap = 4096, count = 0;
    starship_region *rows = malloc(cap * sizeof *rows);
    if (!rows) return reply(fd, STARSHIP_ERROR, NULL, 0);

    mach_vm_address_t address = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t info_count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = mach_vm_region_recurse(mach_task_self(), &address, &size, &depth,
                                                  (vm_region_recurse_info_t)&info, &info_count);
        if (kr != KERN_SUCCESS) break;
        int touched = info.pages_resident + info.pages_swapped_out + info.pages_dirtied > 0;
        if (!info.is_submap && (info.protection & VM_PROT_READ) && touched) {
            if (count == cap) {
                cap *= 2;
                starship_region *grown = realloc(rows, cap * sizeof *rows);
                if (!grown) break;
                rows = grown;
            }
            rows[count++] = (starship_region){address, size, (uint32_t)info.protection, info.user_tag};
        }
        address += size;
    }
    int result = reply(fd, STARSHIP_OK, rows, (uint32_t)(count * sizeof *rows));
    free(rows);
    return result;
}

static uint64_t image_span(const struct mach_header_64 *header, intptr_t slide) {
    const char *cursor = (const char *)(header + 1);
    uint64_t end = (uint64_t)header;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__LINKEDIT") != 0 && strcmp(seg->segname, "__PAGEZERO") != 0) {
                uint64_t seg_end = seg->vmaddr + (uint64_t)slide + seg->vmsize;
                if (seg_end > end) end = seg_end;
            }
        }
        cursor += lc->cmdsize;
    }
    return end - (uint64_t)header;
}

static int send_images(int fd) {
    uint32_t count = _dyld_image_count();
    starship_image *rows = calloc(count, sizeof *rows);
    if (!rows) return reply(fd, STARSHIP_ERROR, NULL, 0);
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const char *path = _dyld_get_image_name(i);
        if (!header || !path) continue;
        rows[i].base = (uint64_t)header;
        rows[i].size = image_span(header, _dyld_get_image_vmaddr_slide(i));
        strlcpy(rows[i].path, path, sizeof rows[i].path);
    }
    int result = reply(fd, STARSHIP_OK, rows, count * (uint32_t)sizeof *rows);
    free(rows);
    return result;
}

static int send_memory(int fd, char *buffer, uint64_t address, uint32_t len) {
    if (len == 0 || len > STARSHIP_MAX_READ) return reply(fd, STARSHIP_BAD_REQUEST, NULL, 0);
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), address, len,
                                              (mach_vm_address_t)buffer, &got);
    if (kr != KERN_SUCCESS || got != len) return reply(fd, STARSHIP_UNREADABLE, NULL, 0);
    return reply(fd, STARSHIP_OK, buffer, len);
}

static void *serve_client(void *arg) {
    int fd = (int)(intptr_t)arg;
    char *buffer = NULL;
    mach_vm_address_t mapped = 0;
    if (mach_vm_allocate(mach_task_self(), &mapped, STARSHIP_MAX_READ, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
        buffer = (char *)mapped;

    starship_request req;
    while (buffer && read_all(fd, &req, sizeof req) == 0) {
        int result;
        switch (req.op) {
        case STARSHIP_OP_HELLO: result = send_hello(fd); break;
        case STARSHIP_OP_REGIONS: result = send_regions(fd); break;
        case STARSHIP_OP_IMAGES: result = send_images(fd); break;
        case STARSHIP_OP_READ: result = send_memory(fd, buffer, req.address, req.length); break;
        default: result = reply(fd, STARSHIP_BAD_REQUEST, NULL, 0); break;
        }
        if (result != 0) break;
    }
    if (mapped) mach_vm_deallocate(mach_task_self(), mapped, STARSHIP_MAX_READ);
    close(fd);
    return NULL;
}

static void *accept_loop(void *arg) {
    int listener = (int)(intptr_t)arg;
    uid_t me = getuid();

    // A SIGPIPE would kill the game, so it stays blocked here and in every client thread.
    sigset_t pipe_only;
    sigemptyset(&pipe_only);
    sigaddset(&pipe_only, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe_only, NULL);

    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) { usleep(100000); continue; }

        uid_t peer_uid = (uid_t)-1;
        gid_t peer_gid;
        if (getpeereid(fd, &peer_uid, &peer_gid) != 0 || peer_uid != me) { close(fd); continue; }

        // setsockopt fails once the peer has hung up. Nothing may be written in that case.
        int on = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on) != 0) { close(fd); continue; }
        // The default 8 KiB send buffer cuts every read of the sweep into a thousand pushes. 256 KiB made bulk reads
        // about four times as fast in testing, and more was no faster. Without it, reads still work, just slower.
        int send_buffer = 256 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof send_buffer);

        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&thread, &attr, serve_client, (void *)(intptr_t)fd) != 0) close(fd);
        pthread_attr_destroy(&attr);
    }
    return NULL;
}

__attribute__((constructor)) static void agent_start(void) {
    // Keep the agent out of anything the game spawns.
    unsetenv("DYLD_INSERT_LIBRARIES");

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, STARSHIP_SOCKET_FORMAT, getuid(), getpid());
    unlink(addr.sun_path);

    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return;
    mode_t old_mask = umask(0077);
    int bound = bind(listener, (struct sockaddr *)&addr, sizeof addr);
    umask(old_mask);
    if (bound != 0 || listen(listener, 16) != 0) { close(listener); return; }

    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, accept_loop, (void *)(intptr_t)listener) != 0) close(listener);
    pthread_attr_destroy(&attr);
}
