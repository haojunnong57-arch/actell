/* SPDX-License-Identifier: GPL-3.0-or-later
 * Host-only ESP heap interface shim. Capability values match ESP-IDF 5.5.5
 * components/heap/include/esp_heap_caps.h. No target hardware is simulated. */
#ifndef TEST_ZLIB_ESP_HEAP_CAPS_H
#define TEST_ZLIB_ESP_HEAP_CAPS_H
#include <stddef.h>
#include <stdint.h>
#define MALLOC_CAP_8BIT (1u << 2)
#define MALLOC_CAP_SPIRAM (1u << 10)
void *heap_caps_malloc(size_t bytes, uint32_t capabilities);
void heap_caps_free(void *pointer);
#endif
