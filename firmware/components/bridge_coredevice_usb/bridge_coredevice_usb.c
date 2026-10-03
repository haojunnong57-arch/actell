/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_coredevice_usb.h"
#include "bridge_lockdown_probe.h"
#include "esp_heap_caps.h"
#include <string.h>

typedef struct {
    bridge_usb_host *host;
    bridge_usb_stream streams[2];
    bridge_tls *tls[2];
    bridge_lockdown_session lockdown;
    bridge_cdtunnel tunnel;
    bridge_coredevice_usb_result *result;
    uint8_t workspace[BRIDGE_LOCKDOWN_SESSION_MAX_WORKSPACE];
} connection;
static void erase(void *data,size_t size) {
    volatile unsigned char *p=data;
    while(size--) *p++=0;
}
static void close_channel(void *context,bridge_lockdown_channel channel,bridge_io *io) {
    connection *c=context;
    if(channel!=BRIDGE_LOCKDOWN_CHANNEL_SESSION && channel!=BRIDGE_LOCKDOWN_CHANNEL_SERVICE) return;
    size_t index=(size_t)channel;
    if(c->tls[index]) {
        int error=bridge_tls_last_error(c->tls[index]);
        if(error && !c->result->tls_error) c->result->tls_error=error;
        bridge_tls_destroy(c->tls[index]); c->tls[index]=NULL;
    }
    (void)bridge_usb_stream_abort(&c->streams[index]);
    if(io) memset(io,0,sizeof *io);
}
static bridge_status open_service(void *context,uint16_t port,bridge_io *out,uint64_t deadline) {
    connection *c=context;
    bridge_status s=bridge_usb_stream_open(c->host,port,deadline,&c->streams[1]);
    if(s==BRIDGE_OK) *out=c->streams[1].io;
    return s;
}
static bridge_status start_tls(void *context,bridge_lockdown_channel channel,
    bridge_io *inout,const void *identity,uint64_t deadline) {
    connection *c=context;
    if(channel!=BRIDGE_LOCKDOWN_CHANNEL_SESSION && channel!=BRIDGE_LOCKDOWN_CHANNEL_SERVICE) return BRIDGE_E_ARGUMENT;
    size_t index=(size_t)channel;
    if(c->tls[index]) return BRIDGE_E_ARGUMENT;
    bridge_status s=bridge_tls_open(identity,&c->streams[index].io,&c->tls[index]);
    if(s==BRIDGE_OK) s=bridge_tls_handshake(c->tls[index],deadline);
    if(s==BRIDGE_OK) s=bridge_tls_get_io(c->tls[index],inout);
    if(c->tls[index] && s!=BRIDGE_OK) c->result->tls_error=bridge_tls_last_error(c->tls[index]);
    return s;
}
static bool identity_present(const bridge_coredevice_usb_config *config) {
    if(!config || !config->host_id || !config->host_id[0] ||
       !config->system_buid || !config->system_buid[0] || !config->tls) return false;
    const bridge_tls_config *t=config->tls;
    return t->host_certificate && t->host_certificate_len &&
        t->host_certificate_len<=BRIDGE_TLS_MAX_CERTIFICATE_BYTES &&
        t->host_private_key && t->host_private_key_len &&
        t->host_private_key_len<=BRIDGE_TLS_MAX_PRIVATE_KEY_BYTES &&
        t->expected_device_certificate && t->expected_device_certificate_len &&
        t->expected_device_certificate_len<=BRIDGE_TLS_MAX_CERTIFICATE_BYTES;
}
static bridge_status poll_link(void *context,uint64_t deadline) {
    connection *c=context;
    return bridge_usb_host_poll(c->host,deadline);
}
static bridge_status readable_link(void *context,bool *ready) {
    if(!ready) return BRIDGE_E_ARGUMENT;
    *ready=false;
    connection *c=context;
    size_t available=0;
    bridge_status s=BRIDGE_OK;
    if(c->tls[1]) {
        s=bridge_tls_pending(c->tls[1],&available);
        if(s!=BRIDGE_OK) return s;
        if(available) { *ready=true; return BRIDGE_OK; }
    }
    s=bridge_usb_stream_read_available(&c->streams[1],&available);
    if(s==BRIDGE_OK) *ready=available!=0;
    return s;
}
bridge_status bridge_coredevice_usb_run(bridge_usb_host *host,
    const bridge_coredevice_usb_config *config,bridge_coredevice_usb_result *result) {
    if(!result) return BRIDGE_E_ARGUMENT;
    memset(result,0,sizeof *result);
    result->status=BRIDGE_E_ARGUMENT;
    if(!host || !config || !config->consume) return result->status;
    if(!identity_present(config)) {
        result->lockdown_failure=BRIDGE_LOCKDOWN_FAILURE_MISSING_IDENTITY;
        return result->status;
    }
    if(bridge_usb_host_now_ms()>=config->deadline_ms) {
        result->status=BRIDGE_E_TIMEOUT; return result->status;
    }
    connection *c=heap_caps_calloc(1,sizeof *c,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    if(!c) { result->status=BRIDGE_E_IO; return result->status; }
    c->host=host; c->result=result;
    result->phase=BRIDGE_COREDEVICE_PHASE_OPEN_LOCKDOWN;
    bridge_status s=bridge_usb_stream_open(host,BRIDGE_LOCKDOWN_PORT,config->deadline_ms,&c->streams[0]);
    if(s!=BRIDGE_OK) goto done;
    result->phase=BRIDGE_COREDEVICE_PHASE_QUERY_TYPE;
    bridge_lockdown_probe_result probe;
    s=bridge_lockdown_probe_query_type(&c->streams[0].io,c->workspace,sizeof c->workspace,config->deadline_ms,&probe);
    if(s!=BRIDGE_OK) goto done;
    result->query_type_verified=true;
    bridge_lockdown_session_ops ops={c,open_service,start_tls,close_channel};
    bridge_lockdown_pair_identity identity={config->host_id,config->system_buid,config->tls};
    s=bridge_lockdown_session_init(&c->lockdown,&c->streams[0].io,&ops,&identity,c->workspace,sizeof c->workspace);
    if(s!=BRIDGE_OK) goto done;
    result->phase=BRIDGE_COREDEVICE_PHASE_START_SESSION;
    s=bridge_lockdown_session_start(&c->lockdown,config->deadline_ms);
    if(s!=BRIDGE_OK) goto done;
    result->session_authenticated=true;
    result->phase=BRIDGE_COREDEVICE_PHASE_START_SERVICE;
    s=bridge_lockdown_session_start_coredevice_proxy(&c->lockdown,config->deadline_ms);
    if(s!=BRIDGE_OK) goto done;
    result->service_opened=true;
    result->phase=BRIDGE_COREDEVICE_PHASE_CDTUNNEL;
    s=bridge_cdtunnel_init(&c->tunnel,bridge_lockdown_session_service_io(&c->lockdown),BRIDGE_CDTUNNEL_REQUESTED_MTU);
    if(s==BRIDGE_OK) s=bridge_cdtunnel_handshake(&c->tunnel,c->workspace,sizeof c->workspace,config->deadline_ms);
    if(s!=BRIDGE_OK) goto done;
    result->tunnel_negotiated=true;
    result->phase=BRIDGE_COREDEVICE_PHASE_CONSUMER;
    bridge_packet_link link={&c->tunnel,c,poll_link,readable_link};
    s=config->consume(config->context,&link,config->deadline_ms);
    if(bridge_usb_host_now_ms()>=config->deadline_ms) s=BRIDGE_E_TIMEOUT;
    if(s!=BRIDGE_OK) goto done;
    result->consumer_completed=true;
    result->phase=BRIDGE_COREDEVICE_PHASE_STOP_SESSION;
    s=bridge_lockdown_session_stop(&c->lockdown,config->deadline_ms);
    if(s==BRIDGE_OK) {
        result->stop_session_confirmed=true;
        result->phase=BRIDGE_COREDEVICE_PHASE_DONE;
    }
done:
    result->lockdown_failure=c->lockdown.failure;
    result->peer_error=c->lockdown.peer_error;
    bridge_lockdown_session_close(&c->lockdown);
    close_channel(c,BRIDGE_LOCKDOWN_CHANNEL_SERVICE,NULL);
    close_channel(c,BRIDGE_LOCKDOWN_CHANNEL_SESSION,NULL);
    erase(c,sizeof *c); heap_caps_free(c);
    result->status=s;
    return s;
}
