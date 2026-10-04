/* HOST TEST ONLY. Compile without allocator redirection. */
#include <stdlib.h>
void *__real_malloc(size_t n) { return malloc(n); }
void *__real_calloc(size_t n, size_t s) { return calloc(n, s); }
void *__real_realloc(void *p, size_t n) { return realloc(p, n); }
void __real_free(void *p) { free(p); }
