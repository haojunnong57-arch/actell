/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_network.h"
#include "lwip/sys.h"
#include <string.h>
static bridge_lwip_tcp *find_stream(bridge_network *n,const bridge_io *io) {
    for(size_t i=0;i<BRIDGE_LWIP_TCP_SLOTS;i++)
        if(io->context==&n->streams[i]) return &n->streams[i];
    return NULL;
}
static void stop(bridge_network *n,bridge_status status) {
    if(n->failure==BRIDGE_OK) n->failure=status;
    n->ready=false;n->stopping=true;
    if(n->net) (void)bridge_lwip_shutdown(n->net);
}
static void close_stream(void *context,bridge_io *io) {
    bridge_network *n=context;
    bridge_lwip_tcp *stream=find_stream(n,io);
    if(stream && stream->net && !n->stopping) {
        uint64_t now=io->clock_ms(io->context);
        uint64_t deadline=UINT64_MAX-now<100u?UINT64_MAX:now+100u;
        bridge_status s=bridge_lwip_tcp_close(stream,deadline);
        if(s!=BRIDGE_OK) stop(n,s);
    }
    if(stream) memset(stream,0,sizeof *stream);
    memset(io,0,sizeof *io);
}
static bridge_status dial(void *context,const uint8_t address[16],uint16_t port,
    uint64_t deadline,bridge_io *out) {
    bridge_network *n=context;
    if(!out) return BRIDGE_E_ARGUMENT;
    memset(out,0,sizeof *out);
    if(n->stopping || !n->net || memcmp(address,n->server_address,16)) return BRIDGE_E_ARGUMENT;
    bridge_lwip_tcp *stream=NULL;
    for(size_t i=0;i<BRIDGE_LWIP_TCP_SLOTS;i++) if(!n->streams[i].net) {stream=&n->streams[i];break;}
    if(!stream) return BRIDGE_E_LIMIT;
    bridge_status s=bridge_lwip_tcp_connect(n->net,port,deadline,stream);
    if(s==BRIDGE_OK) *out=bridge_lwip_tcp_io(stream);
    else if(stream->net) {
        bridge_io partial=bridge_lwip_tcp_io(stream);
        close_stream(n,&partial);
    }
    return s;
}
static bridge_status drain(void *context,bridge_io *io,uint64_t deadline) {
    bridge_network *n=context;bridge_lwip_tcp *stream=find_stream(n,io);
    if(n->stopping || !stream || !stream->net) return BRIDGE_E_ARGUMENT;
    return bridge_lwip_tcp_drain(stream,deadline);
}
bridge_status bridge_network_start(bridge_network *n,const bridge_packet_link *link,
    const uint8_t uuid[16],uint8_t *scratch,size_t capacity,uint64_t deadline) {
    if(!n || !link || !link->tunnel || !uuid || !scratch || !capacity) return BRIDGE_E_ARGUMENT;
    if(n->net) return BRIDGE_E_ARGUMENT;
    memset(n,0,sizeof *n);
    memcpy(n->server_address,link->tunnel->parameters.server_address,16);
    bridge_status s=bridge_lwip_create(link,&n->net,deadline);
    if(s!=BRIDGE_OK) {stop(n,s);return s;}
    bridge_rsd_dialer dialer={.context=n,.dial=dial,.close=close_stream,.drain=drain};
    s=bridge_rsd_init(&n->rsd,&dialer,n->server_address,link->tunnel->parameters.server_rsd_port);
    if(s==BRIDGE_OK) s=bridge_rsd_connect(&n->rsd,uuid,scratch,capacity,deadline);
    if(s!=BRIDGE_OK) {stop(n,s);return s;}
    n->ready=true;return BRIDGE_OK;
}
bridge_status bridge_network_poll(bridge_network *n,uint64_t deadline) {
    if(!n || !n->ready || n->stopping || !n->net) return BRIDGE_E_ARGUMENT;
    bridge_status s=bridge_lwip_poll(n->net,deadline);
    if(s==BRIDGE_OK && n->rsd.control_open) {
        bridge_lwip_tcp *control=find_stream(n,&n->rsd.control_io);
        size_t available=0;
        s=control?bridge_lwip_tcp_pending(control,&available):BRIDGE_E_ARGUMENT;
        if(s==BRIDGE_OK && available) s=bridge_rsd_pump(&n->rsd,deadline);
    }
    if(s!=BRIDGE_OK) stop(n,s);
    return s;
}
bridge_status bridge_network_wait(void *context,uint32_t milliseconds,uint64_t deadline) {
    bridge_network *n=context;
    if(!n || !n->ready || n->stopping || !n->rsd.control_open) return BRIDGE_E_ARGUMENT;
    uint64_t start=n->rsd.control_io.clock_ms(n->rsd.control_io.context);
    if(start>=deadline || (uint64_t)milliseconds>=deadline-start) return BRIDGE_E_TIMEOUT;
    for(;;) {
        uint64_t now=n->rsd.control_io.clock_ms(n->rsd.control_io.context);
        if(now>=deadline) return BRIDGE_E_TIMEOUT;
        if(now<start) return BRIDGE_E_IO;
        if(now-start>=milliseconds) return BRIDGE_OK;
        /* Control-plane parsing must not hold a pressed Home button hostage
         * to the rest of an unrelated partially received HTTP/2 frame. */
        bridge_status s=bridge_lwip_poll(n->net,deadline);
        if(s!=BRIDGE_OK) {stop(n,s);return s;}
        sys_msleep(1);
    }
}
bridge_status bridge_network_close(bridge_network *n) {
    if(!n) return BRIDGE_E_ARGUMENT;
    n->ready=false;n->stopping=true;
    if(n->net) (void)bridge_lwip_shutdown(n->net);
    bridge_rsd_close(&n->rsd);
    memset(n->streams,0,sizeof n->streams);
    if(!n->net) return BRIDGE_OK;
    bridge_status s=bridge_lwip_destroy(n->net);
    if(s==BRIDGE_OK) n->net=NULL;
    return s;
}
