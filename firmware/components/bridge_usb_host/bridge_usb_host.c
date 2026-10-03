/* SPDX-License-Identifier: GPL-3.0-or-later
 * Actual ESP-IDF USB Host adapter. USB Host API v5.5.5; raw protocol in bridge_usbmux.
 * No fake device success, automatic pairing, credentials or power GPIO controls.
 */
#include "bridge_usb_host.h"
#include "bridge_usb_descriptors.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "usb/usb_host.h"
#include <string.h>
#define RX_COUNT 2u
#define TX_COUNT 4u
#define RX_BYTES 4096u
#define CLEANUP_MS UINT64_C(2000)
#define TX_TIMEOUT_MS UINT64_C(5000)

typedef struct {
    struct bridge_usb_host *host;
    usb_transfer_t *transfer;
    uint64_t queued_ms;
    bool receive, busy;
} transfer_slot;
struct bridge_usb_host {
    bridge_usb_host_config config;
    bridge_usb_host_result result;
    bridge_usbmux *mux;
    usb_host_client_handle_t client;
    usb_device_handle_t device;
    bridge_usb_interface interface;
    TaskHandle_t owner;
    transfer_slot rx[RX_COUNT], tx[TX_COUNT];
    uint64_t deadline, generation;
    uint8_t pending_address;
    bool installed, claimed, closing, session_active;
    bool all_free;
};
/* Owns the enum callback context. Retained on unsafe cleanup failure; a second
 * run is rejected rather than freeing buffers which the controller still owns. */
static bridge_usb_host *active;
static portMUX_TYPE run_lock=portMUX_INITIALIZER_UNLOCKED;
static bool run_reserved;
static uint64_t next_generation;
static bool reserve_run(void) {
    portENTER_CRITICAL(&run_lock);
    bool available=!run_reserved && next_generation!=UINT64_MAX;
    if(available) { run_reserved=true; next_generation++; }
    portEXIT_CRITICAL(&run_lock);
    return available;
}
static void release_run(void) {
    portENTER_CRITICAL(&run_lock);
    active=NULL; run_reserved=false;
    portEXIT_CRITICAL(&run_lock);
}
uint64_t bridge_usb_host_now_ms(void) { return (uint64_t)esp_timer_get_time()/1000u; }
static void fail(bridge_usb_host *h, bridge_status s, esp_err_t e) {
    if(h->result.status==BRIDGE_OK) { h->result.status=s; h->result.driver_error=e; }
}
static bool enum_filter(const usb_device_desc_t *d,uint8_t *configuration) {
    if(!active || active->closing || d->idVendor!=BRIDGE_USB_APPLE_VID) return false;
    /* IDF v5.5.5 maps out-of-range choices to configuration 1. Reject instead
     * of silently selecting a different configuration. Its enum path assumes
     * contiguous values 1..bNumConfigurations; unusual devices are unsupported. */
    if(active->config.configuration_value>d->bNumConfigurations) {
        fail(active,BRIDGE_E_UNSUPPORTED,ESP_ERR_NOT_SUPPORTED);
        return false;
    }
    *configuration=active->config.configuration_value;
    return true;
}
static void client_event(const usb_host_client_event_msg_t *event,void *context) {
    bridge_usb_host *h=context;
    if(event->event==USB_HOST_CLIENT_EVENT_NEW_DEV) {
        if(!h->closing && !h->device && !h->pending_address) h->pending_address=event->new_dev.address;
    } else if(event->event==USB_HOST_CLIENT_EVENT_DEV_GONE && event->dev_gone.dev_hdl==h->device) {
        if(!h->closing) fail(h,BRIDGE_E_IO,ESP_ERR_NOT_FOUND);
    }
}
static bridge_status submit(transfer_slot *slot) {
    slot->queued_ms=bridge_usb_host_now_ms(); slot->busy=true;
    esp_err_t e=usb_host_transfer_submit(slot->transfer);
    if(e!=ESP_OK) { slot->busy=false; fail(slot->host,BRIDGE_E_IO,e); return BRIDGE_E_IO; }
    return BRIDGE_OK;
}
static void transfer_complete(usb_transfer_t *t) {
    transfer_slot *slot=t->context; bridge_usb_host *h=slot->host; slot->busy=false;
    if(h->closing) return;
    if(t->status!=USB_TRANSFER_STATUS_COMPLETED || t->actual_num_bytes<0 ||
       t->actual_num_bytes>t->num_bytes) { fail(h,BRIDGE_E_IO,ESP_ERR_INVALID_RESPONSE); return; }
    if(slot->receive) {
        h->result.rx_bytes+=(uint64_t)t->actual_num_bytes;
        bridge_status s=bridge_usbmux_feed(h->mux,t->data_buffer,(size_t)t->actual_num_bytes,bridge_usb_host_now_ms());
        if(s!=BRIDGE_OK) { fail(h,s,ESP_ERR_INVALID_RESPONSE); return; }
        if(h->result.status==BRIDGE_OK) (void)submit(slot);
    } else {
        if(t->actual_num_bytes!=t->num_bytes) { fail(h,BRIDGE_E_IO,ESP_ERR_INVALID_SIZE); return; }
        h->result.tx_bytes+=(uint64_t)t->actual_num_bytes;
    }
}
static bridge_status enqueue(void *context,const uint8_t *data,size_t n) {
    bridge_usb_host *h=context;
    if(!h->claimed || h->closing || h->result.status!=BRIDGE_OK || n>BRIDGE_USBMUX_TX_FRAME)
        return BRIDGE_E_IO;
    for(size_t i=0;i<TX_COUNT;i++) if(!h->tx[i].busy) {
        usb_transfer_t *t=h->tx[i].transfer;
        memcpy(t->data_buffer,data,n); t->num_bytes=(int)n;
        return submit(&h->tx[i]);
    }
    return BRIDGE_E_LIMIT;
}
static esp_err_t allocate_transfer(bridge_usb_host *h,transfer_slot *slot,bool receive) {
    slot->host=h; slot->receive=receive;
    esp_err_t e=usb_host_transfer_alloc(receive?RX_BYTES:BRIDGE_USBMUX_TX_FRAME,0,&slot->transfer);
    if(e!=ESP_OK) return e;
    usb_transfer_t *t=slot->transfer;
    t->device_handle=h->device; t->bEndpointAddress=receive?h->interface.endpoint_in:h->interface.endpoint_out;
    t->num_bytes=receive?(int)RX_BYTES:0; t->callback=transfer_complete; t->context=slot;
    /* Only complete mux packets enter this queue. IDF adds the ZLP exactly when
     * length is endpoint-MPS aligned; no ZLP is inserted between fragments. */
    t->flags=receive?0:USB_TRANSFER_FLAG_ZERO_PACK;
    return ESP_OK;
}
static void attach_device(bridge_usb_host *h) {
    uint8_t address=h->pending_address; h->pending_address=0;
    esp_err_t e=usb_host_device_open(h->client,address,&h->device);
    if(e!=ESP_OK) { fail(h,BRIDGE_E_IO,e); return; }
    const usb_device_desc_t *descriptor;
    usb_device_info_t info;
    if((e=usb_host_get_device_descriptor(h->device,&descriptor))!=ESP_OK ||
       (e=usb_host_device_info(h->device,&info))!=ESP_OK) { fail(h,BRIDGE_E_IO,e); return; }
    h->result.enumerated=true;
    if(descriptor->idVendor!=BRIDGE_USB_APPLE_VID || info.speed!=USB_SPEED_FULL ||
       info.bConfigurationValue!=h->config.configuration_value) { fail(h,BRIDGE_E_UNSUPPORTED,ESP_ERR_NOT_SUPPORTED); return; }
    const usb_config_desc_t *configuration;
    e=usb_host_get_active_config_descriptor(h->device,&configuration);
    if(e!=ESP_OK) { fail(h,BRIDGE_E_IO,e); return; }
    bridge_status s=bridge_usb_find_mux_interface((const uint8_t *)configuration,configuration->wTotalLength,&h->interface);
    if(s!=BRIDGE_OK) { fail(h,s,ESP_ERR_NOT_SUPPORTED); return; }
    e=usb_host_interface_claim(h->client,h->device,h->interface.interface_number,h->interface.alternate_setting);
    if(e!=ESP_OK) { fail(h,BRIDGE_E_IO,e); return; }
    h->claimed=true; h->result.interface_claimed=true;
    for(size_t i=0;i<RX_COUNT;i++) if((e=allocate_transfer(h,&h->rx[i],true))!=ESP_OK) { fail(h,BRIDGE_E_IO,e); return; }
    for(size_t i=0;i<TX_COUNT;i++) if((e=allocate_transfer(h,&h->tx[i],false))!=ESP_OK) { fail(h,BRIDGE_E_IO,e); return; }
    for(size_t i=0;i<RX_COUNT;i++) if(submit(&h->rx[i])!=BRIDGE_OK) return;
    s=bridge_usbmux_start(h->mux,bridge_usb_host_now_ms());
    if(s!=BRIDGE_OK) fail(h,s,ESP_FAIL);
}
static bridge_status pump(bridge_usb_host *h) {
    uint32_t flags=0;
    esp_err_t e=usb_host_lib_handle_events(0,&flags);
    if(e!=ESP_OK && e!=ESP_ERR_TIMEOUT) fail(h,BRIDGE_E_IO,e);
    if(flags&USB_HOST_LIB_EVENT_FLAGS_ALL_FREE) h->all_free=true;
    if(h->client) {
        e=usb_host_client_handle_events(h->client,0);
        if(e!=ESP_OK && e!=ESP_ERR_TIMEOUT) fail(h,BRIDGE_E_IO,e);
    }
    uint64_t now=bridge_usb_host_now_ms();
    if(h->result.status!=BRIDGE_OK && h->mux) bridge_usbmux_disconnect(h->mux);
    if(!h->closing) {
        if(h->pending_address && h->result.status==BRIDGE_OK) attach_device(h);
        now=bridge_usb_host_now_ms();
        if(h->claimed && h->result.status==BRIDGE_OK) {
            bridge_status s=bridge_usbmux_tick(h->mux,now);
            if(s!=BRIDGE_OK) fail(h,s,ESP_FAIL);
        }
        now=bridge_usb_host_now_ms();
        for(size_t i=0;i<TX_COUNT;i++)
            if(h->tx[i].busy && now>=h->tx[i].queued_ms && now-h->tx[i].queued_ms>=TX_TIMEOUT_MS) fail(h,BRIDGE_E_TIMEOUT,ESP_ERR_TIMEOUT);
        if(now>=h->deadline) fail(h,BRIDGE_E_TIMEOUT,ESP_ERR_TIMEOUT);
    }
    vTaskDelay(1);
    return h->result.status;
}
static bool transfers_busy(const bridge_usb_host *h) {
    for(size_t i=0;i<RX_COUNT;i++) if(h->rx[i].busy) return true;
    for(size_t i=0;i<TX_COUNT;i++) if(h->tx[i].busy) return true;
    return false;
}
static bool cleanup(bridge_usb_host *h) {
    h->closing=true;
    if(h->mux) bridge_usbmux_disconnect(h->mux);
    if(h->installed) (void)usb_host_lib_set_root_port_power(false);
    if(h->claimed) {
        (void)usb_host_endpoint_halt(h->device,h->interface.endpoint_in);
        (void)usb_host_endpoint_flush(h->device,h->interface.endpoint_in);
        (void)usb_host_endpoint_halt(h->device,h->interface.endpoint_out);
        (void)usb_host_endpoint_flush(h->device,h->interface.endpoint_out);
    }
    uint64_t end=bridge_usb_host_now_ms()+CLEANUP_MS;
    while(transfers_busy(h) && bridge_usb_host_now_ms()<end) (void)pump(h);
    if(transfers_busy(h)) return false; /* Do not free in-flight DMA memory. */
    for(size_t i=0;i<RX_COUNT;i++) if(h->rx[i].transfer) { (void)usb_host_transfer_free(h->rx[i].transfer); h->rx[i].transfer=NULL; }
    for(size_t i=0;i<TX_COUNT;i++) if(h->tx[i].transfer) { (void)usb_host_transfer_free(h->tx[i].transfer); h->tx[i].transfer=NULL; }
    if(h->claimed) {
        if(usb_host_interface_release(h->client,h->device,h->interface.interface_number)!=ESP_OK) return false;
        h->claimed=false;
    }
    if(h->device) {
        if(usb_host_device_close(h->client,h->device)!=ESP_OK) return false;
        h->device=NULL;
    }
    if(h->client) {
        if(usb_host_client_deregister(h->client)!=ESP_OK) return false;
        h->client=NULL;
    }
    if(h->installed) {
        h->all_free=false;
        esp_err_t e=usb_host_device_free_all();
        if(e!=ESP_OK && e!=ESP_ERR_NOT_FINISHED) return false;
        if(e==ESP_ERR_NOT_FINISHED) {
            end=bridge_usb_host_now_ms()+CLEANUP_MS;
            while(!h->all_free && bridge_usb_host_now_ms()<end) (void)pump(h);
            if(!h->all_free) return false;
        }
        /* Last-client deregistration queues NO_CLIENTS even with no device.
         * IDF rejects uninstall while these library flags remain pending. */
        end=bridge_usb_host_now_ms()+CLEANUP_MS;
        for(;;) {
            uint32_t flags=0;
            e=usb_host_lib_handle_events(0,&flags);
            if(e!=ESP_OK && e!=ESP_ERR_TIMEOUT) return false;
            if(flags==0) break;
            if(bridge_usb_host_now_ms()>=end) return false;
            vTaskDelay(1);
        }
        if(usb_host_uninstall()!=ESP_OK) return false;
        h->installed=false;
    }
    return true;
}
static bridge_status channel_error(bridge_usbmux_reason reason) {
    if(reason==BRIDGE_USBMUX_REASON_LOCAL_CLOSE) return BRIDGE_E_EOF;
    if(reason==BRIDGE_USBMUX_REASON_TIMEOUT) return BRIDGE_E_TIMEOUT;
    if(reason==BRIDGE_USBMUX_REASON_PROTOCOL) return BRIDGE_E_FORMAT;
    if(reason==BRIDGE_USBMUX_REASON_OVERFLOW) return BRIDGE_E_LIMIT;
    return BRIDGE_E_IO;
}
static bool owner_session(bridge_usb_host *h) { return h && h==active && h->session_active && h->owner==xTaskGetCurrentTaskHandle(); }
static ptrdiff_t stream_read(void *context,uint8_t *out,size_t n,uint32_t timeout) {
    bridge_usb_stream *s=context; bridge_usb_host *h=s->host;
    if(!owner_session(h) || s->generation!=h->generation) return -BRIDGE_E_ARGUMENT;
    uint64_t end=bridge_usb_host_now_ms()+timeout;
    if(end>h->deadline) end=h->deadline;
    while(bridge_usb_host_now_ms()<end) {
        if(h->result.status!=BRIDGE_OK) return -(ptrdiff_t)h->result.status;
        size_t got=0; bridge_status st=bridge_usbmux_read(h->mux,s->channel,out,n,&got);
        if(st!=BRIDGE_OK) return st==BRIDGE_E_EOF?0:-(ptrdiff_t)st;
        if(got) return (ptrdiff_t)got;
        (void)pump(h);
    }
    return -BRIDGE_E_TIMEOUT;
}
static ptrdiff_t stream_write(void *context,const uint8_t *data,size_t n,uint32_t timeout) {
    bridge_usb_stream *s=context; bridge_usb_host *h=s->host;
    if(!owner_session(h) || s->generation!=h->generation) return -BRIDGE_E_ARGUMENT;
    uint64_t end=bridge_usb_host_now_ms()+timeout;
    if(end>h->deadline) end=h->deadline;
    while(bridge_usb_host_now_ms()<end) {
        if(h->result.status!=BRIDGE_OK) return -(ptrdiff_t)h->result.status;
        size_t sent=0; bridge_status st=bridge_usbmux_write(h->mux,s->channel,data,n,&sent,bridge_usb_host_now_ms());
        if(st!=BRIDGE_OK) return -(ptrdiff_t)st;
        if(sent) return (ptrdiff_t)sent;
        (void)pump(h);
    }
    return -BRIDGE_E_TIMEOUT;
}
static uint64_t stream_clock(void *unused) { (void)unused; return bridge_usb_host_now_ms(); }
bridge_status bridge_usb_stream_open(bridge_usb_host *h,uint16_t port,uint64_t deadline,bridge_usb_stream *out) {
    if(!owner_session(h) || !port || !out) return BRIDGE_E_ARGUMENT;
    memset(out,0,sizeof *out);
    if(deadline>h->deadline) deadline=h->deadline;
    if(bridge_usb_host_now_ms()>=deadline) return BRIDGE_E_TIMEOUT;
    bridge_usbmux_channel_id id;
    bridge_status s=bridge_usbmux_open(h->mux,port,bridge_usb_host_now_ms(),&id);
    if(s!=BRIDGE_OK) return s;
    while(bridge_usb_host_now_ms()<deadline && h->result.status==BRIDGE_OK) {
        bridge_usbmux_channel_state state; bridge_usbmux_reason reason;
        s=bridge_usbmux_channel_status(h->mux,id,&state,&reason);
        if(s!=BRIDGE_OK) return s;
        if(state==BRIDGE_USBMUX_CH_OPEN) {
            out->host=h; out->channel=id; out->generation=h->generation;
            out->io=(bridge_io){out,stream_read,stream_write,stream_clock}; return BRIDGE_OK;
        }
        if(state==BRIDGE_USBMUX_CH_CLOSED) { (void)bridge_usbmux_release(h->mux,id); return channel_error(reason); }
        (void)pump(h);
    }
    (void)bridge_usbmux_close(h->mux,id,bridge_usb_host_now_ms());
    /* An unreturned handle must not linger across retries. Abort this bounded
     * host attempt; cleanup cancels/drains it before releasing storage. */
    if(h->result.status==BRIDGE_OK) fail(h,BRIDGE_E_TIMEOUT,ESP_ERR_TIMEOUT);
    return h->result.status!=BRIDGE_OK?h->result.status:BRIDGE_E_TIMEOUT;
}
bridge_status bridge_usb_stream_close(bridge_usb_stream *s,uint64_t deadline) {
    if(!s || !owner_session(s->host) || s->generation!=s->host->generation) return BRIDGE_E_ARGUMENT;
    bridge_usb_host *h=s->host;
    if(deadline>h->deadline) deadline=h->deadline;
    if(bridge_usb_host_now_ms()>=deadline) return BRIDGE_E_TIMEOUT;
    bridge_status result=bridge_usbmux_close(h->mux,s->channel,bridge_usb_host_now_ms());
    if(result!=BRIDGE_OK) return result;
    while(bridge_usb_host_now_ms()<deadline && h->result.status==BRIDGE_OK) {
        bridge_usbmux_channel_state state; bridge_usbmux_reason reason;
        result=bridge_usbmux_channel_status(h->mux,s->channel,&state,&reason);
        if(result!=BRIDGE_OK) return result;
        if(state==BRIDGE_USBMUX_CH_CLOSED) {
            result=bridge_usbmux_release(h->mux,s->channel); memset(s,0,sizeof *s); return result;
        }
        (void)pump(h);
    }
    return h->result.status!=BRIDGE_OK?h->result.status:BRIDGE_E_TIMEOUT;
}
bridge_status bridge_usb_stream_abort(bridge_usb_stream *s) {
    if(!s) return BRIDGE_E_ARGUMENT;
    if(!s->host && !s->channel && !s->generation) return BRIDGE_OK;
    if(!owner_session(s->host) || s->generation!=s->host->generation) return BRIDGE_E_ARGUMENT;
    bridge_usb_host *h=s->host;
    bridge_status result=bridge_usbmux_close(h->mux,s->channel,bridge_usb_host_now_ms());
    bridge_usbmux_channel_state state; bridge_usbmux_reason reason;
    if(bridge_usbmux_channel_status(h->mux,s->channel,&state,&reason)==BRIDGE_OK &&
       state==BRIDGE_USBMUX_CH_CLOSED) {
        bridge_status released=bridge_usbmux_release(h->mux,s->channel);
        if(result==BRIDGE_OK) result=released;
    }
    memset(s,0,sizeof *s);
    return result;
}
bridge_status bridge_usb_host_poll(bridge_usb_host *h,uint64_t deadline) {
    if(!owner_session(h)) return BRIDGE_E_ARGUMENT;
    if(deadline>h->deadline) deadline=h->deadline;
    if(bridge_usb_host_now_ms()>=deadline) return BRIDGE_E_TIMEOUT;
    bridge_status result=pump(h);
    if(result==BRIDGE_OK && bridge_usb_host_now_ms()>=deadline) result=BRIDGE_E_TIMEOUT;
    return result;
}
bridge_status bridge_usb_stream_read_available(bridge_usb_stream *s,size_t *bytes) {
    if(!bytes) return BRIDGE_E_ARGUMENT;
    *bytes=0;
    if(!s || !owner_session(s->host) || s->generation!=s->host->generation) return BRIDGE_E_ARGUMENT;
    bridge_usb_host *h=s->host;
    if(h->result.status!=BRIDGE_OK) return h->result.status;
    for(size_t i=0;i<BRIDGE_USBMUX_CHANNELS;i++) {
        const bridge_usbmux_channel *channel=&h->mux->channels[i];
        if(channel->id!=s->channel || channel->state==BRIDGE_USBMUX_CH_FREE) continue;
        *bytes=channel->rx_size;
        if(*bytes) return BRIDGE_OK;
        return channel->state==BRIDGE_USBMUX_CH_CLOSED?channel_error(channel->reason):BRIDGE_OK;
    }
    return BRIDGE_E_ARGUMENT;
}
bridge_status bridge_usb_host_run(const bridge_usb_host_config *config,bridge_usb_host_result *out) {
    if(!out) return BRIDGE_E_ARGUMENT;
    memset(out,0,sizeof *out);
    out->cleanup_complete=true; /* Early rejection acquired no resources for this attempt. */
    if(!config || !config->wiring_and_vbus_confirmed || !config->enable_controller_requested ||
       !config->configuration_value || !config->session || config->runtime_ms<1000 || config->runtime_ms>600000) {
        out->status=BRIDGE_E_ARGUMENT; out->driver_error=ESP_ERR_INVALID_STATE; return out->status;
    }
    if(!reserve_run()) { out->status=BRIDGE_E_ARGUMENT; out->driver_error=ESP_ERR_INVALID_STATE; return out->status; }
    bridge_usb_host *h=heap_caps_calloc(1,sizeof *h,MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
    if(!h) { release_run(); out->status=BRIDGE_E_IO; out->driver_error=ESP_ERR_NO_MEM; return out->status; }
    h->mux=heap_caps_calloc(1,sizeof *h->mux,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    if(!h->mux) { heap_caps_free(h); release_run(); out->status=BRIDGE_E_IO; out->driver_error=ESP_ERR_NO_MEM; return out->status; }
    active=h; h->generation=next_generation; h->config=*config; h->owner=xTaskGetCurrentTaskHandle();
    h->deadline=bridge_usb_host_now_ms()+config->runtime_ms;
    bridge_status status=bridge_usbmux_init(h->mux,enqueue,h);
    if(status!=BRIDGE_OK) fail(h,status,ESP_FAIL);
    usb_host_config_t hc={.skip_phy_setup=false,.root_port_unpowered=true,.intr_flags=ESP_INTR_FLAG_LEVEL1,.enum_filter_cb=enum_filter};
    esp_err_t e=usb_host_install(&hc);
    if(e!=ESP_OK) fail(h,BRIDGE_E_IO,e); else h->installed=true;
    if(h->result.status==BRIDGE_OK) {
        usb_host_client_config_t cc={.is_synchronous=false,.max_num_event_msg=5,.async={.client_event_callback=client_event,.callback_arg=h}};
        e=usb_host_client_register(&cc,&h->client);
        if(e!=ESP_OK) fail(h,BRIDGE_E_IO,e);
    }
    if(h->result.status==BRIDGE_OK && (e=usb_host_lib_set_root_port_power(true))!=ESP_OK) fail(h,BRIDGE_E_IO,e);
    while(h->result.status==BRIDGE_OK) {
        (void)pump(h);
        if(h->result.status==BRIDGE_OK && bridge_usbmux_get_state(h->mux)==BRIDGE_USBMUX_READY) {
            h->result.mux_ready=true; h->session_active=true;
            status=config->session(h,config->session_context);
            h->session_active=false;
            if(bridge_usb_host_now_ms()>=h->deadline) fail(h,BRIDGE_E_TIMEOUT,ESP_ERR_TIMEOUT);
            else if(status!=BRIDGE_OK) fail(h,status,ESP_FAIL);
            else if(h->result.status==BRIDGE_OK) h->result.session_completed=true;
            break;
        }
    }
    h->result.cleanup_complete=cleanup(h);
    if(!h->result.cleanup_complete && h->result.status==BRIDGE_OK) fail(h,BRIDGE_E_IO,ESP_ERR_NOT_FINISHED);
    *out=h->result;
    if(h->result.cleanup_complete) { heap_caps_free(h->mux); heap_caps_free(h); release_run(); }
    return out->status;
}
