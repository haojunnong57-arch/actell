#ifndef SIM_HEAP_H
#define SIM_HEAP_H
#include <stddef.h>
#define MALLOC_CAP_INTERNAL 1u
#define MALLOC_CAP_8BIT 2u
#define MALLOC_CAP_SPIRAM 4u
void *heap_caps_calloc(size_t n,size_t size,unsigned caps);
void heap_caps_free(void *p);
#endif
