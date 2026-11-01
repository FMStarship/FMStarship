// Wire format between the FM Starship app and the agent inside Football Manager.
// There is deliberately no write operation.
#ifndef STARSHIP_PROTOCOL_H
#define STARSHIP_PROTOCOL_H

#include <stdint.h>

#define STARSHIP_PROTOCOL_VERSION 1
#define STARSHIP_SOCKET_FORMAT "/tmp/fmstarship-%u-%d.sock"
#define STARSHIP_MAX_READ 16777216u

enum {
    STARSHIP_OP_HELLO = 1,
    STARSHIP_OP_REGIONS = 2,
    STARSHIP_OP_IMAGES = 3,
    STARSHIP_OP_READ = 4,
};

enum {
    STARSHIP_OK = 0,
    STARSHIP_ERROR = 1,
    STARSHIP_BAD_REQUEST = 2,
    STARSHIP_UNREADABLE = 3,
};

typedef struct {
    uint32_t op;
    uint32_t length;
    uint64_t address;
} starship_request;

typedef struct {
    uint32_t status;
    uint32_t length;
} starship_response;

typedef struct {
    uint32_t version;
    uint32_t pid;
} starship_hello;

typedef struct {
    uint64_t base;
    uint64_t size;
    uint32_t protection;
    uint32_t tag;
} starship_region;

typedef struct {
    uint64_t base;
    uint64_t size;
    char path[1024];
} starship_image;

#endif
