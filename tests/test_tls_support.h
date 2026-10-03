/* SPDX-License-Identifier: GPL-3.0-or-later
 * HOST TEST ONLY. Uses public upstream mbedTLS fixture identities, never a
 * real user/device identity. Not included by any firmware CMake component. */
#define _POSIX_C_SOURCE 200809L
#include "bridge_tls.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Linker-only allocation observation, not production global allocator hooks.
 * Counts requested calloc payload bytes (not libc overhead or stack). */
void *__real_calloc(size_t, size_t);
void __real_free(void *);
typedef struct { void *p; size_t n; } allocation;
static allocation allocations[8192];
static size_t heap_live, heap_peak, heap_count, fail_after = SIZE_MAX;
void *__wrap_calloc(size_t a, size_t b) {
    if (a && b > SIZE_MAX / a) return NULL;
    if (heap_count++ >= fail_after) return NULL;
    void *p = __real_calloc(a, b);
    if (!p) return NULL;
    for (size_t i = 0; i < sizeof allocations / sizeof allocations[0]; ++i) {
        if (!allocations[i].p) {
            allocations[i] = (allocation){p, a * b};
            heap_live += a * b;
            if (heap_live > heap_peak) heap_peak = heap_live;
            return p;
        }
    }
    abort();
}
void __wrap_free(void *p) {
    for (size_t i = 0; p && i < sizeof allocations / sizeof allocations[0]; ++i) {
        if (allocations[i].p == p) {
            heap_live -= allocations[i].n;
            allocations[i] = (allocation){0};
            break;
        }
    }
    __real_free(p);
}
typedef struct {
    int fd;
    size_t read_cap, write_cap, reads, writes;
    uint64_t fake_advance;
    bool overrun, overreport;
} transport;
static uint64_t clock_ms(void *ctx) {
    transport *t = ctx;
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u + t->fake_advance;
}
static ptrdiff_t transfer(transport *t, uint8_t *r, const uint8_t *w,
                          size_t n, uint32_t ms) {
    struct pollfd p = {t->fd, r ? POLLIN : POLLOUT, 0};
    if (!ms) return -(ptrdiff_t)BRIDGE_E_TIMEOUT;
    int timeout = ms > INT32_MAX ? INT32_MAX : (int)ms;
    int e = poll(&p, 1, timeout);
    if (!e) return -(ptrdiff_t)BRIDGE_E_TIMEOUT;
    if (e < 0) return -(ptrdiff_t)BRIDGE_E_IO;
    size_t requested = n;
    size_t cap = r ? t->read_cap : t->write_cap;
    if (n > cap) n = cap;
    ssize_t got = r ? recv(t->fd, r, n, 0) : send(t->fd, w, n, MSG_NOSIGNAL);
    if (got < 0) return -(ptrdiff_t)BRIDGE_E_IO;
    if (t->overrun) t->fake_advance += 6000;
    if (t->overreport) return (ptrdiff_t)requested + 1;
    return got;
}
static ptrdiff_t read_cb(void *ctx, uint8_t *p, size_t n, uint32_t ms) {
    transport *t = ctx; ++t->reads;
    return transfer(t, p, NULL, n, ms);
}
static ptrdiff_t write_cb(void *ctx, const uint8_t *p, size_t n, uint32_t ms) {
    transport *t = ctx; ++t->writes;
    return transfer(t, NULL, p, n, ms);
}
static uint8_t *read_file(const char *dir, const char *name, size_t *n) {
    char path[1024];
    assert(snprintf(path, sizeof path, "%s/%s", dir, name) > 0);
    FILE *f = fopen(path, "rb"); assert(f);
    uint8_t *b = malloc(BRIDGE_TLS_MAX_CERTIFICATE_BYTES + 1u); assert(b);
    *n = fread(b, 1, BRIDGE_TLS_MAX_CERTIFICATE_BYTES + 1u, f);
    assert(!ferror(f) && feof(f)); fclose(f);
    return b;
}
