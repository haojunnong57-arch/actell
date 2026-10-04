/* SPDX-License-Identifier: GPL-3.0-or-later
 * Purely synthetic IDF API peer + mux API peer, exercising the actual adapter.
 * Does NOT validate IDF execution, USB hardware, raw mux packets, or iPhone reachability.
 * Real ESP-IDF build and raw-protocol fixtures are separate tests.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bridge_usb_host.h"
#include "usb/usb_host.h"
#include "freertos/task.h"

/* Include the adapter so failure-state invariants and enqueue ownership can be
 * inspected, without adding test accessors to production firmware. */
#include "../../firmware/components/bridge_usb_host/bridge_usb_host.c"

typedef struct { usb_transfer_t *t; bool inflight, completion; usb_transfer_status_t status; int actual; } sim_transfer;
static struct {
    volatile uint64_t now; /* Model an externally advancing monotonic clock. */
    TaskHandle_t task;
    bool installed,powered,client,device,claimed,available,announced,opened,free_pending;
    bool fail_install,fail_register,fail_power,freeze_callbacks,send_error,send_short,disconnect;
    unsigned install_calls,uninstall_calls,heap_live,alloc_calls,fail_alloc,submit_calls,fail_submit;
    unsigned session_calls,callbacks,freed,feed_calls,disconnect_calls,claim_calls,slow_attach;
    uint32_t flags;
    bool in_send, defer_close;
    uint8_t selected;
    usb_host_config_t hc;
    usb_host_client_config_t cc;
    sim_transfer transfers[16];
} sim;
#ifdef SIM_REAL_PROTOCOL
static void sim_protocol_receive(const uint8_t *,size_t);
static void sim_protocol_poll(void);
#endif
static usb_device_desc_t sim_desc={.idVendor=BRIDGE_USB_APPLE_VID,.bNumConfigurations=1};
static uint8_t sim_config[]={9,2,32,0,1,1,0,0x80,50,9,4,2,0,2,255,254,2,0,7,5,0x81,2,64,0,0,7,5,2,2,64,0,0};
static void sim_reset(bool available) {
    assert(active==NULL && !run_reserved);
    assert(sim.heap_live==0);
    for(size_t i=0;i<16;i++) assert(!sim.transfers[i].t);
    memset(&sim,0,sizeof sim); sim.task=(void *)(uintptr_t)1; sim.available=available;
    sim_desc.idVendor=BRIDGE_USB_APPLE_VID;sim_desc.bNumConfigurations=1;
    sim_config[5]=1;sim_config[12]=0;
}
static sim_transfer *sim_find(usb_transfer_t *t) {
    for(size_t i=0;i<16;i++) if(sim.transfers[i].t==t) return &sim.transfers[i];
    assert(0 && "unowned transfer");return NULL;
}
static void sim_check_clean(void) {
    assert(!sim.installed && !sim.client && !sim.claimed && !sim.opened);
    assert(sim.heap_live==0 && !active && !run_reserved);
    for(size_t i=0;i<16;i++) assert(!sim.transfers[i].t);
}
int64_t esp_timer_get_time(void) { return (int64_t)(sim.now*1000); }
void vTaskDelay(TickType_t n) { sim.now+=n; }
TaskHandle_t xTaskGetCurrentTaskHandle(void) {return sim.task;}
void *heap_caps_calloc(size_t n,size_t size,unsigned caps) {
    (void)caps;void *p=calloc(n,size);if(p)sim.heap_live++;return p;
}
void heap_caps_free(void *p) {if(p){assert(sim.heap_live>0);sim.heap_live--;free(p);}}
esp_err_t usb_host_install(const usb_host_config_t *c) {
    sim.install_calls++;assert(!sim.installed);assert(c->root_port_unpowered);
    if(sim.fail_install)return ESP_ERR_NO_MEM;
    sim.hc=*c;sim.installed=true;return ESP_OK;
}
esp_err_t usb_host_uninstall(void) {
    sim.uninstall_calls++;
    /* IDF usb_host.c:622-625 refuses pending library flags, including NO_CLIENTS. */
    if(sim.flags || sim.client || sim.device || sim.free_pending)return ESP_ERR_INVALID_STATE;
    assert(sim.installed && !sim.powered);sim.installed=false;return ESP_OK;
}
esp_err_t usb_host_lib_handle_events(TickType_t ticks,uint32_t *flags) {
    (void)ticks;assert(sim.installed);
    if(sim.free_pending){sim.free_pending=false;sim.device=false;sim.flags|=USB_HOST_LIB_EVENT_FLAGS_ALL_FREE;}
    if(sim.powered && sim.available && !sim.announced){
        uint8_t chosen=1;sim.announced=true;
        if(sim.hc.enum_filter_cb(&sim_desc,&chosen)){
            /* Mirror IDF enum.c fallback to detect unguarded configuration input. */
            if(!chosen || chosen>sim_desc.bNumConfigurations)chosen=1;
            sim.selected=chosen;sim.device=true;
        }
    }
    *flags=sim.flags;sim.flags=0;return ESP_OK;
}
esp_err_t usb_host_lib_set_root_port_power(bool on) {
    assert(sim.installed);
    if(on && sim.fail_power)return ESP_ERR_INVALID_STATE;
    sim.powered=on;
    if(!on)for(size_t i=0;i<16;i++)if(sim.transfers[i].inflight){sim.transfers[i].completion=true;sim.transfers[i].status=USB_TRANSFER_STATUS_CANCELED;}
    return ESP_OK;
}
esp_err_t usb_host_client_register(const usb_host_client_config_t *c,usb_host_client_handle_t *h) {
    assert(sim.installed && !sim.client);
    if(sim.fail_register)return ESP_ERR_NO_MEM;
    sim.cc=*c;sim.client=true;*h=&sim.cc;return ESP_OK;
}
esp_err_t usb_host_client_deregister(usb_host_client_handle_t h) {
    assert(h==&sim.cc && sim.client && !sim.opened && !sim.claimed);
    sim.client=false;sim.flags|=USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS;return ESP_OK;
}
esp_err_t usb_host_client_handle_events(usb_host_client_handle_t h,TickType_t ticks) {
    (void)ticks;assert(h==&sim.cc && sim.client);
#ifdef SIM_REAL_PROTOCOL
    sim_protocol_poll();
#endif
    if(!sim.freeze_callbacks)for(size_t i=0;i<16;i++){
        sim_transfer *q=&sim.transfers[i];if(!q->t || !q->inflight || !q->completion)continue;
        usb_transfer_t *t=q->t;q->inflight=false;q->completion=false;
        t->status=q->status;t->actual_num_bytes=q->status==USB_TRANSFER_STATUS_COMPLETED?((t->bEndpointAddress&0x80u)?q->actual:t->num_bytes):0;
        if(sim.send_short && !(t->bEndpointAddress&0x80u) && t->actual_num_bytes>0){t->actual_num_bytes--;sim.send_short=false;}
        sim.callbacks++;t->callback(t);
    }
    if(sim.device && !sim.opened && sim.selected){
        usb_host_client_event_msg_t e={.event=USB_HOST_CLIENT_EVENT_NEW_DEV,.new_dev={.address=1}};
        sim.selected=0;sim.cc.async.client_event_callback(&e,sim.cc.async.callback_arg);
    }
    if(sim.disconnect && sim.opened){
        sim.disconnect=false;
        usb_host_client_event_msg_t e={.event=USB_HOST_CLIENT_EVENT_DEV_GONE,.dev_gone={.dev_hdl=&sim_desc}};
        sim.cc.async.client_event_callback(&e,sim.cc.async.callback_arg);
    }
    return ESP_OK;
}
esp_err_t usb_host_device_open(usb_host_client_handle_t h,uint8_t address,usb_device_handle_t *d) {
    assert(h==&sim.cc && address==1 && sim.device && !sim.opened);sim.opened=true;*d=&sim_desc;return ESP_OK;
}
esp_err_t usb_host_device_close(usb_host_client_handle_t h,usb_device_handle_t d) {
    assert(h==&sim.cc && d==&sim_desc && sim.opened && !sim.claimed);sim.opened=false;return ESP_OK;
}
esp_err_t usb_host_device_info(usb_device_handle_t d,usb_device_info_t *out) {
    assert(d==&sim_desc);*out=(usb_device_info_t){USB_SPEED_FULL,sim_config[5]};return ESP_OK;
}
esp_err_t usb_host_get_device_descriptor(usb_device_handle_t d,const usb_device_desc_t **out) {assert(d==&sim_desc);*out=&sim_desc;return ESP_OK;}
esp_err_t usb_host_get_active_config_descriptor(usb_device_handle_t d,const usb_config_desc_t **out) {assert(d==&sim_desc);*out=(const usb_config_desc_t *)sim_config;return ESP_OK;}
esp_err_t usb_host_interface_claim(usb_host_client_handle_t h,usb_device_handle_t d,uint8_t interface,uint8_t alt) {
    assert(h==&sim.cc && d==&sim_desc && interface==2 && alt==0 && !sim.claimed);
    sim.claimed=true;sim.claim_calls++;sim.now+=sim.slow_attach;return ESP_OK;
}
esp_err_t usb_host_interface_release(usb_host_client_handle_t h,usb_device_handle_t d,uint8_t interface) {
    assert(h==&sim.cc && d==&sim_desc && interface==2 && sim.claimed);
    for(size_t i=0;i<16;i++)assert(!sim.transfers[i].inflight);
    sim.claimed=false;return ESP_OK;
}
esp_err_t usb_host_endpoint_halt(usb_device_handle_t d,uint8_t ep) {assert(d==&sim_desc && (ep==0x81 || ep==2));return ESP_OK;}
esp_err_t usb_host_endpoint_flush(usb_device_handle_t d,uint8_t ep) {
    assert(d==&sim_desc);
    for(size_t i=0;i<16;i++)if(sim.transfers[i].inflight && sim.transfers[i].t->bEndpointAddress==ep){sim.transfers[i].completion=true;sim.transfers[i].status=USB_TRANSFER_STATUS_CANCELED;}
    return ESP_OK;
}
esp_err_t usb_host_transfer_alloc(size_t bytes,int iso,usb_transfer_t **out) {
    assert(!iso);sim.alloc_calls++;if(sim.alloc_calls==sim.fail_alloc)return ESP_ERR_NO_MEM;
    for(size_t i=0;i<16;i++)if(!sim.transfers[i].t){
        usb_transfer_t *t=calloc(1,sizeof *t);assert(t);t->data_buffer=calloc(1,bytes);assert(t->data_buffer);t->data_buffer_size=bytes;
        sim.transfers[i].t=t;*out=t;return ESP_OK;
    }assert(0 && "too many transfers");return ESP_FAIL;
}
esp_err_t usb_host_transfer_free(usb_transfer_t *t) {
    sim_transfer *q=sim_find(t);assert(!q->inflight && !q->completion);
    free(t->data_buffer);free(t);memset(q,0,sizeof *q);sim.freed++;return ESP_OK;
}
esp_err_t usb_host_transfer_submit(usb_transfer_t *t) {
    sim_transfer *q=sim_find(t);assert(!q->inflight && sim.claimed && sim.powered);
    assert(t->num_bytes>=0 && (size_t)t->num_bytes<=t->data_buffer_size);sim.submit_calls++;
    if(sim.submit_calls==sim.fail_submit)return ESP_ERR_INVALID_STATE;
    q->inflight=true;q->status=USB_TRANSFER_STATUS_COMPLETED;
    if(t->bEndpointAddress&0x80u){assert(t->flags==0 && t->num_bytes%64==0);q->completion=false;}
    else {assert(t->flags==USB_TRANSFER_FLAG_ZERO_PACK);q->completion=true;if(sim.send_error)q->status=USB_TRANSFER_STATUS_ERROR;
#ifdef SIM_REAL_PROTOCOL
        if(!sim.send_error)sim_protocol_receive(t->data_buffer,(size_t)t->num_bytes);
#endif
    }
    return ESP_OK;
}
esp_err_t usb_host_device_free_all(void) {
    assert(sim.installed && !sim.client);
    if(!sim.device)return ESP_OK;
    sim.free_pending=true;return ESP_ERR_NOT_FINISHED;
}

#ifndef SIM_REAL_PROTOCOL
/* Mux API peer deliberately accepts no real device protocol. It exists solely
 * to get the adapter through lifecycle/error paths in deterministic host tests. */
static bridge_status sim_send(bridge_usbmux *m,const uint8_t *p,size_t n) {
    assert(!sim.in_send);sim.in_send=true;bridge_status s=m->send(m->send_context,p,n);sim.in_send=false;
    if(s!=BRIDGE_OK && s!=BRIDGE_E_LIMIT){m->state=BRIDGE_USBMUX_DEAD;m->error=s;}
    return s;
}
bridge_status bridge_usbmux_init(bridge_usbmux *m,bridge_usbmux_send_fn f,void *c) {memset(m,0,sizeof *m);m->send=f;m->send_context=c;return BRIDGE_OK;}
bridge_status bridge_usbmux_start(bridge_usbmux *m,uint64_t now) {
    static const uint8_t frame[64]={0xAA};m->state_since_ms=now;
    bridge_status s=sim_send(m,frame,sizeof frame);if(s==BRIDGE_OK)m->state=BRIDGE_USBMUX_READY;return s;
}
bridge_status bridge_usbmux_feed(bridge_usbmux *m,const uint8_t *p,size_t n,uint64_t now) {(void)m;(void)p;(void)n;(void)now;sim.feed_calls++;return BRIDGE_OK;}
bridge_status bridge_usbmux_tick(bridge_usbmux *m,uint64_t now) {assert(now>=m->state_since_ms);return m->error;}
void bridge_usbmux_disconnect(bridge_usbmux *m) {assert(!sim.in_send);sim.disconnect_calls++;m->state=BRIDGE_USBMUX_DEAD;m->error=BRIDGE_E_IO;}
bridge_usbmux_state bridge_usbmux_get_state(const bridge_usbmux *m) {return m->state;}
bridge_status bridge_usbmux_get_error(const bridge_usbmux *m) {return m->error;}
bridge_status bridge_usbmux_open(bridge_usbmux *m,uint16_t port,uint64_t now,bridge_usbmux_channel_id *id) {
    (void)now;if(m->state!=BRIDGE_USBMUX_READY)return BRIDGE_E_IO;
    m->channels[0].state=BRIDGE_USBMUX_CH_OPEN;m->channels[0].remote_port=port;m->channels[0].id=1;*id=1;return BRIDGE_OK;
}
bridge_status bridge_usbmux_channel_status(const bridge_usbmux *m,bridge_usbmux_channel_id id,bridge_usbmux_channel_state *state,bridge_usbmux_reason *reason) {
    if(id!=1)return BRIDGE_E_ARGUMENT;
    *state=m->channels[0].state;*reason=m->channels[0].reason;return BRIDGE_OK;
}
bridge_status bridge_usbmux_write(bridge_usbmux *m,bridge_usbmux_channel_id id,const uint8_t *p,size_t n,size_t *sent,uint64_t now) {
    (void)now;*sent=0;if(id!=1)return BRIDGE_E_ARGUMENT;if(m->state==BRIDGE_USBMUX_DEAD)return BRIDGE_E_IO;
    bridge_status s=sim_send(m,p,n);if(s==BRIDGE_E_LIMIT)return BRIDGE_OK;if(s==BRIDGE_OK)*sent=n;return s;
}
bridge_status bridge_usbmux_read(bridge_usbmux *m,bridge_usbmux_channel_id id,uint8_t *p,size_t n,size_t *got) {
    (void)p;(void)n;*got=0;if(id!=1)return BRIDGE_E_ARGUMENT;return m->state==BRIDGE_USBMUX_DEAD?BRIDGE_E_IO:BRIDGE_OK;
}
bridge_status bridge_usbmux_close(bridge_usbmux *m,bridge_usbmux_channel_id id,uint64_t now) {
    (void)now;if(id!=1)return BRIDGE_E_ARGUMENT;m->channels[0].state=sim.defer_close?BRIDGE_USBMUX_CH_CLOSING:BRIDGE_USBMUX_CH_CLOSED;m->channels[0].reason=BRIDGE_USBMUX_REASON_LOCAL_CLOSE;return BRIDGE_OK;
}
bridge_status bridge_usbmux_release(bridge_usbmux *m,bridge_usbmux_channel_id id) {if(id!=1)return BRIDGE_E_ARGUMENT;m->channels[0].state=BRIDGE_USBMUX_CH_FREE;return BRIDGE_OK;}

static bridge_status sim_session_ok(bridge_usb_host *h,void *ctx) {(void)h;(void)ctx;sim.session_calls++;return BRIDGE_OK;}
static bridge_usb_host_config sim_run_config(bridge_usb_session_fn session) {
    return (bridge_usb_host_config){.wiring_and_vbus_confirmed=true,.enable_controller_requested=true,.configuration_value=1,.runtime_ms=1000,.session=session};
}
static void test_run_gates_and_no_device(void) {
    sim_reset(false);bridge_usb_host_config c=sim_run_config(sim_session_ok);bridge_usb_host_result r;
    c.wiring_and_vbus_confirmed=false;assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_ARGUMENT);assert(!sim.install_calls);
    c=sim_run_config(sim_session_ok);c.enable_controller_requested=false;assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_ARGUMENT);assert(!sim.install_calls);
    c=sim_run_config(sim_session_ok);c.runtime_ms=999;assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_ARGUMENT);assert(!sim.install_calls);
    c=sim_run_config(sim_session_ok);
    for(unsigned i=0;i<2;i++){assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_TIMEOUT);assert(r.cleanup_complete && !r.session_completed);sim_check_clean();}
    assert(sim.install_calls==2 && sim.uninstall_calls==2);
}
static void test_install_failures(void) {
    for(unsigned i=0;i<3;i++){
        sim_reset(false);sim.fail_install=i==0;sim.fail_register=i==1;sim.fail_power=i==2;
        bridge_usb_host_config c=sim_run_config(sim_session_ok);bridge_usb_host_result r;
        assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_IO);assert(r.cleanup_complete);sim_check_clean();
    }
}
static void test_attach_and_partial_failures(void) {
    sim_reset(true);sim.slow_attach=7;bridge_usb_host_config c=sim_run_config(sim_session_ok);bridge_usb_host_result r;
    assert(bridge_usb_host_run(&c,&r)==BRIDGE_OK);assert(r.enumerated && r.interface_claimed && r.mux_ready && r.session_completed && r.cleanup_complete);
    assert(sim.session_calls==1 && sim.freed==6 && sim.callbacks==3 && !sim.feed_calls);sim_check_clean();
    for(unsigned i=1;i<=6;i++){
        sim_reset(true);sim.fail_alloc=i;assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_IO);assert(r.cleanup_complete && !r.session_completed);assert(sim.freed==i-1);sim_check_clean();
    }
    for(unsigned i=1;i<=3;i++){
        sim_reset(true);sim.fail_submit=i;assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_IO);assert(r.cleanup_complete && !r.session_completed);assert(sim.freed==6);sim_check_clean();
    }
}
static void test_config_and_alt_gates(void) {
    sim_reset(true);bridge_usb_host_config c=sim_run_config(sim_session_ok);bridge_usb_host_result r;c.configuration_value=2;
    assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_UNSUPPORTED);assert(!sim.claim_calls && !sim.selected && r.cleanup_complete);sim_check_clean();
    sim_reset(true);c.configuration_value=1;sim_config[12]=1;
    assert(bridge_usb_host_run(&c,&r)!=BRIDGE_OK);assert(!sim.claim_calls && r.cleanup_complete);sim_check_clean();
}
static bridge_usb_stream sim_saved_stream;
static bridge_status sim_session_queue(bridge_usb_host *h,void *ctx) {
    (void)ctx;sim.session_calls++;
    bridge_usb_host_result nested;bridge_usb_host_config c=sim_run_config(sim_session_ok);
    assert(bridge_usb_host_run(&c,&nested)==BRIDGE_E_ARGUMENT && sim.install_calls==1);
    assert(bridge_usb_stream_open(h,62078,sim.now+200,&sim_saved_stream)==BRIDGE_OK);
    assert(bridge_usb_stream_close(&sim_saved_stream,sim.now)==BRIDGE_E_TIMEOUT);
    assert(h->mux->channels[0].state==BRIDGE_USBMUX_CH_OPEN);
    bridge_usb_stream stale=sim_saved_stream;
    stale.generation--; /* Same current host address, token from a previous run. */
    uint8_t test_byte=0;
    assert(stale.io.read(&stale,&test_byte,1,10)==-BRIDGE_E_ARGUMENT);
    assert(stale.io.write(&stale,&test_byte,1,10)==-BRIDGE_E_ARGUMENT);
    assert(bridge_usb_stream_close(&stale,sim.now+10)==BRIDGE_E_ARGUMENT);
    uint8_t payload[64];memset(payload,0x5a,sizeof payload);
    unsigned queued=0;for(size_t i=0;i<TX_COUNT;i++)queued+=h->tx[i].busy?1u:0u;
    for(unsigned i=queued;i<TX_COUNT;i++)assert(enqueue(h,payload,sizeof payload)==BRIDGE_OK);
    assert(enqueue(h,payload,sizeof payload)==BRIDGE_E_LIMIT);
    memset(payload,0xcc,sizeof payload);
    for(size_t i=1;i<TX_COUNT;i++)assert(h->tx[i].transfer->data_buffer[0]==0x5a);
    sim.task=(void *)(uintptr_t)2;assert(sim_saved_stream.io.read(&sim_saved_stream,payload,1,10)==-BRIDGE_E_ARGUMENT);sim.task=(void *)(uintptr_t)1;
    assert(pump(h)==BRIDGE_OK);
    assert(enqueue(h,payload,sizeof payload)==BRIDGE_OK);
    assert(bridge_usb_stream_close(&sim_saved_stream,sim.now+10)==BRIDGE_OK);return BRIDGE_OK;
}
static void test_queue_and_serialization(void) {
    sim_reset(true);bridge_usb_host_config c=sim_run_config(sim_session_queue);bridge_usb_host_result r;
    assert(bridge_usb_host_run(&c,&r)==BRIDGE_OK);assert(r.cleanup_complete);sim_check_clean();
    assert(sim_saved_stream.host==NULL);
}
static bridge_status sim_session_abort(bridge_usb_host *h,void *context) {
    (void)context;
    bridge_usb_stream stream={0};
    assert(bridge_usb_stream_abort(NULL)==BRIDGE_E_ARGUMENT);
    assert(bridge_usb_stream_abort(&stream)==BRIDGE_OK);
    assert(bridge_usb_stream_open(h,62078,sim.now+200,&stream)==BRIDGE_OK);
    bridge_usb_stream stale=stream; stale.generation--;
    assert(bridge_usb_stream_abort(&stale)==BRIDGE_E_ARGUMENT);
    assert(stale.host==h);
    size_t available=999;
    assert(bridge_usb_stream_read_available(&stale,&available)==BRIDGE_E_ARGUMENT && !available);
    assert(bridge_usb_stream_read_available(&stream,&available)==BRIDGE_OK && !available);
    h->mux->channels[0].rx_size=3;
    assert(bridge_usb_stream_read_available(&stream,&available)==BRIDGE_OK && available==3);
    h->mux->channels[0].rx_size=0;
    assert(bridge_usb_host_poll(h,sim.now)==BRIDGE_E_TIMEOUT);
    assert(bridge_usb_host_poll(h,sim.now+100)==BRIDGE_OK);
    uint64_t before=sim.now;
    assert(bridge_usb_stream_abort(&stream)==BRIDGE_OK);
    assert(bridge_usb_stream_read_available(&stream,&available)==BRIDGE_E_ARGUMENT && !available);
    assert(!stream.host && !stream.channel && !stream.generation && !stream.io.read);
    assert(sim.now==before); /* Abort must not pump, wait, or consume a deadline. */
    assert(h->mux->channels[0].state==(sim.defer_close?BRIDGE_USBMUX_CH_CLOSING:BRIDGE_USBMUX_CH_FREE));
    assert(bridge_usb_stream_abort(&stream)==BRIDGE_OK);
    return BRIDGE_OK;
}
static void test_nonblocking_abort(void) {
    for(unsigned i=0;i<2;i++) {
        sim_reset(true); sim.defer_close=i!=0;
        bridge_usb_host_config c=sim_run_config(sim_session_abort); bridge_usb_host_result r;
        assert(bridge_usb_host_run(&c,&r)==BRIDGE_OK);
        assert(r.cleanup_complete); sim_check_clean();
    }
}
static bridge_status sim_session_read_error(bridge_usb_host *h,void *ctx) {
    unsigned kind=*(unsigned *)ctx;sim.session_calls++;
    bridge_usb_stream s;assert(bridge_usb_stream_open(h,62078,sim.now+200,&s)==BRIDGE_OK);
    if(kind==0)sim.disconnect=true;
    if(kind==1){for(size_t i=0;i<16;i++)if(sim.transfers[i].inflight && !(sim.transfers[i].t->bEndpointAddress&0x80u))sim.transfers[i].status=USB_TRANSFER_STATUS_ERROR;}
    if(kind==2)sim.send_short=true;
    uint8_t byte;ptrdiff_t result=s.io.read(&s,&byte,1,100);
    assert(result==-BRIDGE_E_IO);return BRIDGE_E_IO;
}
static void test_async_failure_propagation(void) {
    for(unsigned i=0;i<3;i++){
        sim_reset(true);bridge_usb_host_config c=sim_run_config(sim_session_read_error);c.session_context=&i;bridge_usb_host_result r;
        assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_IO);assert(r.cleanup_complete && !r.session_completed);sim_check_clean();
    }
}
static bridge_status sim_session_overrun(bridge_usb_host *h,void *ctx) {(void)h;(void)ctx;sim.now+=2000;return BRIDGE_OK;}
static void test_session_deadline(void) {
    sim_reset(true);bridge_usb_host_config c=sim_run_config(sim_session_overrun);bridge_usb_host_result r;
    assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_TIMEOUT);assert(!r.session_completed && r.cleanup_complete);sim_check_clean();
}
static bridge_status sim_session_freeze(bridge_usb_host *h,void *ctx) {(void)h;(void)ctx;sim.freeze_callbacks=true;return BRIDGE_OK;}
static void test_unsafe_cleanup_retains_dma(void) {
    sim_reset(true);bridge_usb_host_config c=sim_run_config(sim_session_freeze);bridge_usb_host_result r;
    assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_IO);assert(!r.cleanup_complete && active && run_reserved);assert(!sim.freed && sim.heap_live==2);
    assert(bridge_usb_host_run(&c,&r)==BRIDGE_E_ARGUMENT);assert(sim.install_calls==1);
    /* Test-only recovery to keep ASan leak detection strict. Production intentionally
     * retains this state and refuses rerun; this is not a public recovery API. */
    sim.freeze_callbacks=false;bridge_usb_host *saved=active;assert(cleanup(saved));heap_caps_free(saved->mux);heap_caps_free(saved);release_run();sim_check_clean();
}
int main(void) {
    test_run_gates_and_no_device();test_install_failures();test_attach_and_partial_failures();test_config_and_alt_gates();
    test_queue_and_serialization();test_nonblocking_abort();test_async_failure_propagation();test_session_deadline();test_unsafe_cleanup_retains_dma();
    puts("PASS: synthetic USB Host adapter lifecycle, queue ownership/ZLP flags, callback draining, configuration/alt gates, deadline/error propagation and no in-flight free");
    puts("Synthetic IDF + mux API peers only. NOT hardware, IDF runtime, USB wire protocol or iPhone reachability validation.");
}

#endif /* !SIM_REAL_PROTOCOL */
