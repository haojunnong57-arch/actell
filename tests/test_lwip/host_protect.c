/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Host OS portability only. The pinned contrib Unix port detects recursion by
 * reading a shared pthread_t without holding a mutex. ThreadSanitizer correctly
 * reports that data race. Compile that port's two protection functions under
 * unused names and replace only them with a proper recursive pthread mutex.
 * All lwIP IPv6/TCP/UDP, timers, mailbox, netif and pbuf code stays unmodified. */
#include "lwip/sys.h"
#include <assert.h>
#include <pthread.h>
static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t protection;
static void initialize_protection(void) {
    pthread_mutexattr_t attributes;
    assert(pthread_mutexattr_init(&attributes) == 0);
    assert(pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE) == 0);
    assert(pthread_mutex_init(&protection, &attributes) == 0);
    assert(pthread_mutexattr_destroy(&attributes) == 0);
}
sys_prot_t sys_arch_protect(void) {
    assert(pthread_once(&once, initialize_protection) == 0);
    assert(pthread_mutex_lock(&protection) == 0);
    return 0;
}
void sys_arch_unprotect(sys_prot_t previous) {
    (void)previous;
    assert(pthread_mutex_unlock(&protection) == 0);
}
