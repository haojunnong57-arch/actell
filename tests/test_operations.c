/* SPDX-License-Identifier: GPL-3.0-or-later
 * Actual operations + HTTP2/RemoteXPC + request/PNG code. RSD and TCP ACK drain
 * boundary are synthetic; their actual implementations have separate suites.
 */
#include "bridge_operations.h"
#include "operations_fixtures.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
enum fault {NONE,OPEN,SEND,REPLY_ID,SINK,DRAIN_DOWN,DRAIN_UP,WAIT_FAIL,WAIT_SHORT,WAIT_TIMEOUT};
static struct {uint8_t input[4096],output[32768],image[1024];size_t in_size,in_pos,out_size,image_size;uint64_t now;unsigned opens,closes,drains,waits;enum fault fault;uint32_t reply_stream;bool capture,ready;} peer;
static uint32_t be32(const uint8_t *p) {return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];}
static void frame(uint8_t type,uint32_t id,const uint8_t *p,size_t n) {
    assert(peer.in_size+9+n<=sizeof peer.input);uint8_t *b=peer.input+peer.in_size;
    b[0]=(uint8_t)(n>>16);b[1]=(uint8_t)(n>>8);b[2]=(uint8_t)n;b[3]=type;b[4]=0;b[5]=(uint8_t)(id>>24);b[6]=(uint8_t)(id>>16);b[7]=(uint8_t)(id>>8);b[8]=(uint8_t)id;
    if(n)memcpy(b+9,p,n);
    peer.in_size+=9+n;
}
static uint64_t clock_ms(void *unused) {(void)unused;return peer.now;}
static ptrdiff_t read_bytes(void *unused,uint8_t *out,size_t n,uint32_t ms) {
    (void)unused;assert(ms);if(n>7)n=7;if(n>peer.in_size-peer.in_pos)n=peer.in_size-peer.in_pos;
    memcpy(out,peer.input+peer.in_pos,n);peer.in_pos+=n;return (ptrdiff_t)n;
}
static ptrdiff_t write_bytes(void *unused,const uint8_t *p,size_t n,uint32_t ms) {
    (void)unused;assert(ms);if(peer.fault==SEND && peer.ready)return -BRIDGE_E_IO;
    if(n>5)n=5;
    assert(peer.out_size+n<=sizeof peer.output);memcpy(peer.output+peer.out_size,p,n);peer.out_size+=n;return (ptrdiff_t)n;
}
static bridge_status sink(void *unused,const uint8_t *data,size_t n) {
    (void)unused;if(peer.fault==SINK)return BRIDGE_E_IO;
    assert(n<=sizeof peer.image-peer.image_size);memcpy(peer.image+peer.image_size,data,n);peer.image_size+=n;return BRIDGE_OK;
}
bridge_status bridge_rsd_open_service(bridge_rsd *rsd,bridge_rsd_service kind,bridge_rsd_feature feature,
    bridge_rsd_connection *out,uint64_t maximum,bridge_remotexpc_consumer consume,void *context,uint64_t deadline) {
    peer.opens++;if(peer.fault==OPEN)return BRIDGE_E_IO;
    assert(kind==(peer.capture?BRIDGE_RSD_SCREENSHOT:BRIDGE_RSD_INDIGO));
    assert(feature==(peer.capture?BRIDGE_RSD_CAPTURE_SCREENSHOT:BRIDGE_RSD_FEATURE_NONE));
    out->io=(bridge_io){NULL,read_bytes,write_bytes,clock_ms};out->dialer=rsd->dialer;out->open=true;
    frame(4,0,NULL,0);
    bridge_status s=bridge_remotexpc_init(&out->session,&out->io,maximum,consume,context);
    if(s==BRIDGE_OK)s=bridge_remotexpc_handshake(&out->session,deadline);
    assert(s==BRIDGE_OK);peer.ready=true;
    if(peer.capture) {uint8_t b[sizeof capture_reply];memcpy(b,capture_reply,sizeof b);if(peer.fault==REPLY_ID)b[16]=2;frame(0,peer.reply_stream,b,sizeof b);}
    return s;
}
void bridge_rsd_close_service(bridge_rsd_connection *c) {if(c->open) {peer.closes++;c->open=false;}}
static bridge_status drain(void *context,bridge_io *io,uint64_t deadline) {(void)context;(void)io;(void)deadline;return BRIDGE_OK;}
bridge_status bridge_rsd_drain_service(bridge_rsd_connection *c,uint64_t deadline) {
    (void)c;assert(peer.now<deadline);peer.drains++;
    return ((peer.fault==DRAIN_DOWN && peer.drains==1)||(peer.fault==DRAIN_UP && peer.drains==2))?BRIDGE_E_IO:BRIDGE_OK;
}
static bridge_status wait_ms(void *context,uint32_t ms,uint64_t deadline) {
    assert(context==&peer && ms==50);peer.waits++;
    if(peer.fault==WAIT_TIMEOUT)peer.now=deadline;
    else if(peer.fault!=WAIT_SHORT)peer.now+=ms;
    return peer.fault==WAIT_FAIL?BRIDGE_E_IO:BRIDGE_OK;
}
static unsigned inspect_requests(bool capture) {
    size_t pos=24;unsigned count=0;
    while(pos<peer.out_size) {
        assert(peer.out_size-pos>=9);const uint8_t *h=peer.output+pos;
        size_t n=(size_t)h[0]<<16|(size_t)h[1]<<8|h[2];assert(n<=peer.out_size-pos-9);
        if(h[3]==0 && be32(h+5)==1) {
            bridge_xpc_message m;assert(bridge_xpc_parse(h+9,n,&m)==BRIDGE_OK);
            if(m.message_id) {
                count++;assert(m.message_id==count);
                bridge_xpc_view v;
                if(capture) {assert(bridge_xpc_dict_find(&m.root,"CoreDevice.featureIdentifier",&v)==BRIDGE_OK);assert(v.size==strlen("com.apple.coredevice.feature.capturescreenshot") && !memcmp(v.payload,"com.apple.coredevice.feature.capturescreenshot",v.size));}
                else {bridge_xpc_view payload;uint64_t state=0;assert(bridge_xpc_dict_find(&m.root,"payload",&payload)==BRIDGE_OK);assert(bridge_xpc_dict_find(&payload,"state",&v)==BRIDGE_OK && bridge_xpc_uint64(&v,&state)==BRIDGE_OK);assert(state==count);}
            }
        }
        pos+=9+n;
    }
    return count;
}
int main(void) {
    uint8_t scratch[2048];bridge_rsd rsd={0};rsd.dialer.drain=drain;
    bridge_invocation invocation={"11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222",999};
    for(unsigned stream=1;stream<=3;stream+=2) for(unsigned f=NONE;f<=SINK;f++) {
        memset(&peer,0,sizeof peer);peer.now=1;peer.capture=true;peer.reply_stream=stream;peer.fault=(enum fault)f;
        bridge_png_info info;
        bridge_status s=bridge_capture_screenshot(&rsd,&invocation,NULL,scratch,sizeof scratch,16u*1024u*1024u,sink,NULL,10000,&info);
        if(f==NONE) {assert(s==BRIDGE_OK && info.message_id==1 && info.width==2 && info.height==3 && info.image_bytes==sizeof png_bytes);assert(peer.image_size==sizeof png_bytes && !memcmp(peer.image,png_bytes,sizeof png_bytes));assert(inspect_requests(true)==1);}
        else assert(s!=BRIDGE_OK && !info.image_bytes);
        assert(peer.closes==(f==OPEN?0u:1u));
    }
    for(unsigned f=NONE;f<=WAIT_TIMEOUT;f++) {
        if(f==REPLY_ID || f==SINK)continue;
        memset(&peer,0,sizeof peer);peer.now=1;peer.fault=(enum fault)f;
        bridge_home_result result;bridge_status s=bridge_press_home(&rsd,wait_ms,&peer,scratch,sizeof scratch,10000,&result);
        if(f==NONE) {assert(s==BRIDGE_OK && result.down_written && result.down_peer_acked && result.up_written && result.bytes_peer_acked);assert(peer.drains==2 && peer.waits==1 && inspect_requests(false)==2);}
        else assert(s!=BRIDGE_OK);
        if(f==WAIT_FAIL || f==WAIT_SHORT)assert(result.up_written && result.bytes_peer_acked);
        if(f==WAIT_TIMEOUT)assert(result.down_peer_acked && !result.up_written);
        assert(peer.closes==(f==OPEN?0u:1u));
    }
    memset(&peer,0,sizeof peer);rsd.dialer.drain=NULL;bridge_home_result result;
    assert(bridge_press_home(&rsd,wait_ms,&peer,scratch,sizeof scratch,10000,&result)==BRIDGE_E_UNSUPPORTED && !peer.opens);
    puts("PASS: actual screenshot/Home operations + HTTP2/XPC/request/PNG code with synthetic RSD/ACK boundaries; reply streams1/3, errors, release and provisional output");
    puts("Home flags are transport evidence, not observed UI effects. No automatic touch/media session is enabled.");
}
