// Runs production main.c and its ledger/motion on POSIX TCP. USB is simulated.
#include "usb_device.h"
#include "hid_motion.h"
#include "nvs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
static pa_motion motion;
static bool hid_enabled;
static volatile sig_atomic_t bus_epoch;
static void suspend_resume(int signal) { (void)signal; bus_epoch++; }
int64_t esp_timer_get_time(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000LL+t.tv_nsec/1000; }
void esp_fill_random(void *out,size_t length) { arc4random_buf(out,length); }
esp_err_t nvs_open(const char *name,int mode,nvs_handle_t *handle) { (void)name;(void)mode;*handle=1;return ESP_OK; }
esp_err_t nvs_get_blob(nvs_handle_t handle,const char *name,void *out,size_t *length) {
    (void)handle;(void)name;
    if (getenv("PA_TEST_LOCKED")) return ESP_FAIL;
    if (*length!=32) return ESP_FAIL;
    for (unsigned i=0;i<32;i++) ((unsigned char*)out)[i]=i;
    return ESP_OK;
}
esp_err_t usb_network_start(void) { hid_enabled=getenv("PA_TEST_HID")!=NULL; return ESP_OK; }
uint32_t usb_epoch(void) { return (uint32_t)bus_epoch; }
bool usb_online(void) { return true; }
bool usb_hid_enabled(void) { return hid_enabled; }
bool usb_hid_start(const pa_command *c,int64_t now) { (void)now;return hid_enabled && pa_motion_start(&motion,c); }
void usb_hid_cancel(void) { pa_motion_cancel(&motion); }
void usb_hid_tick(int64_t now) {
    if (!hid_enabled) { motion.phase=HID_IDLE;return; }
    // Simulated USB host completes exactly one queued report per iteration.
    if (motion.waiting) pa_motion_ack(&motion,now);
    pa_report report;
    if (pa_motion_next(&motion,now,&report)) pa_motion_sent(&motion,&report,now);
}
bool usb_hid_neutral(void) { return motion.phase==HID_IDLE; }
uint32_t usb_hid_completed(void) { uint32_t id=motion.completed;motion.completed=0;return id; }
void app_main(void);
int main(void) { signal(SIGPIPE,SIG_IGN); signal(SIGUSR1,suspend_resume); app_main(); }
