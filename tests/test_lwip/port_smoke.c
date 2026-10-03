#include "lwip/tcpip.h"
#include "lwip/sys.h"
#include <assert.h>
#include <stdio.h>
static void started(void *arg) { sys_sem_signal(arg); }
int main(void) {
    sys_sem_t done;
    assert(sys_sem_new(&done, 0) == ERR_OK);
    tcpip_init(started, &done);
    assert(sys_arch_sem_wait(&done, 5000) != SYS_ARCH_TIMEOUT);
    sys_sem_free(&done);
    puts("lwIP NO_SYS=0 pthread port ready");
    return 0;
}
