/* HOST TEST ONLY: Darwin equivalent of static-link GNU allocator --wrap.
 * Force-include in tested objects and static dependencies, never firmware. */
#include <stdlib.h>
void *__wrap_malloc(size_t);
void *__wrap_calloc(size_t, size_t);
void *__wrap_realloc(void *, size_t);
void __wrap_free(void *);
#ifdef HOST_WRAP_ALL_ALLOC
#define malloc __wrap_malloc
#define realloc __wrap_realloc
#endif
#define calloc __wrap_calloc
#define free __wrap_free
