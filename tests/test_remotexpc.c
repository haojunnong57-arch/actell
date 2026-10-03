/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_remotexpc.h"
#include "bridge_screenshot_stream.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "remotexpc_fixtures.h"
#define CAPACITY (256u * 1024u)
#define DEADLINE UINT64_C(100000000)
typedef struct {
    uint8_t input[CAPACITY], output[CAPACITY];
    size_t in_size, in_pos, out_size, fragment;
    uint64_t clock, tick;
    FILE *file;
    bool fail_write, timeout_read;
} peer;
static peer p;
static uint32_t get32(const uint8_t *b) { return (uint32_t)b[0]<<24 | (uint32_t)b[1]<<16 | (uint32_t)b[2]<<8 | b[3]; }
static void put32(uint8_t *b, uint32_t n) { b[0]=(uint8_t)(n>>24); b[1]=(uint8_t)(n>>16); b[2]=(uint8_t)(n>>8); b[3]=(uint8_t)n; }
static void append_frame(peer *q, uint8_t type, uint8_t flags, uint32_t stream, const uint8_t *data, size_t n) {
    assert(q->in_size + 9 + n <= sizeof q->input);
    uint8_t *h=q->input+q->in_size;
    h[0]=(uint8_t)(n>>16); h[1]=(uint8_t)(n>>8); h[2]=(uint8_t)n; h[3]=type; h[4]=flags; put32(h+5,stream);
    if(n) memcpy(h+9,data,n);
    q->in_size+=9+n;
}
static void settings_frame(peer *q, uint32_t size) { uint8_t b[6]={0,4,0,0,0,0}; put32(b+2,size); append_frame(q,4,0,0,b,6); }
static void update_frame(peer *q, uint32_t stream, uint32_t increment) { uint8_t b[4];put32(b,increment);append_frame(q,8,0,stream,b,4); }
static ptrdiff_t rd(void *ctx,uint8_t *b,size_t n,uint32_t timeout) {
    peer *q=ctx; assert(timeout); q->clock+=q->tick;
    if(q->timeout_read) return -(ptrdiff_t)BRIDGE_E_TIMEOUT;
    if(n>q->fragment)n=q->fragment;
    if(q->file) return (ptrdiff_t)fread(b,1,n,q->file);
    if(n>q->in_size-q->in_pos)n=q->in_size-q->in_pos;
    if(n)memcpy(b,q->input+q->in_pos,n);
    q->in_pos+=n;return (ptrdiff_t)n;
}
static ptrdiff_t wr(void *ctx,const uint8_t *b,size_t n,uint32_t timeout) {
    peer *q=ctx;assert(timeout);q->clock+=q->tick;
    if(q->fail_write)return -(ptrdiff_t)BRIDGE_E_IO;
    if(n>q->fragment)n=q->fragment;
    assert(n<=sizeof q->output-q->out_size);
    memcpy(q->output+q->out_size,b,n);q->out_size+=n;return (ptrdiff_t)n;
}
static uint64_t clk(void *ctx) { return ((peer*)ctx)->clock; }
static bridge_io transport;
static bridge_remotexpc session;
typedef struct { size_t begin[2],end[2],bytes[2];uint8_t message[256];size_t used;uint64_t id;bool reject; } events;
static events ev;
static bridge_status consume(void *ctx, bridge_remotexpc_event event,const bridge_remotexpc_message *m,const uint8_t *b,size_t n) {
    events *e=ctx;size_t ix=m->stream_id==1?0u:1u;
    if(e->reject)return BRIDGE_E_TYPE;
    if(event==BRIDGE_RXPC_BEGIN){e->begin[ix]++;e->id=m->message_id;}
    if(event==BRIDGE_RXPC_END)e->end[ix]++;
    if(event==BRIDGE_RXPC_CHUNK){
        assert(n<=BRIDGE_RXPC_CHUNK_SIZE);e->bytes[ix]+=n;
        if(e->used+n<=sizeof e->message){memcpy(e->message+e->used,b,n);e->used+=n;}
    }
    return BRIDGE_OK;
}
static void reset(size_t fragment, bool with_consumer) {
    memset(&p,0,sizeof p); memset(&ev,0,sizeof ev); p.fragment=fragment;
    transport=(bridge_io){&p,rd,wr,clk};
    assert(bridge_remotexpc_init(&session,&transport,32u*1024u*1024u,with_consumer?consume:NULL,&ev)==BRIDGE_OK);
}
static void start(void) { assert(bridge_remotexpc_handshake(&session,DEADLINE)==BRIDGE_OK); }
static void pump_until(size_t end_count) {
    while(ev.end[0]+ev.end[1]<end_count)assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK);
}
static void handshake_and_fragmentation(void) {
    for(size_t step=1;step<=37;step++) {
        reset(step,true); settings_frame(&p,65535); start();
        assert(p.out_size==sizeof fixture_handshake);
        assert(!memcmp(p.output,fixture_handshake,sizeof fixture_handshake));
        assert(session.next_message_id==1 && session.ready);
        assert(session.streams[0].send_window==65535-68);
        assert(session.streams[1].send_window==65535-24);
        assert(session.send_window==65535-92);
        for(size_t i=0;i<sizeof fixture_response;i++)append_frame(&p,0,0,3,fixture_response+i,1);
        pump_until(1);
        assert(ev.begin[1]==1 && ev.end[1]==1 && ev.used==sizeof fixture_response);
        assert(!memcmp(ev.message,fixture_response,ev.used));
    }
}
static void interleaving_and_multiple(void) {
    reset(3,true);settings_frame(&p,65535);start();
    append_frame(&p,0,0,1,fixture_response,5);
    append_frame(&p,0,0,3,fixture_response,18);
    append_frame(&p,0,0,1,fixture_response+5,sizeof fixture_response-5);
    uint8_t pair[sizeof fixture_response*2];memcpy(pair,fixture_response,sizeof fixture_response);memcpy(pair+sizeof fixture_response,fixture_response,sizeof fixture_response);
    append_frame(&p,0,0,3,fixture_response+18,sizeof fixture_response-18);
    append_frame(&p,0,0,1,pair,sizeof pair);
    pump_until(4);assert(ev.begin[0]==3 && ev.end[0]==3 && ev.begin[1]==1 && ev.end[1]==1);
}
static void controls(void) {
    reset(1,true);update_frame(&p,0,25);settings_frame(&p,32768);start();assert(session.send_window==65535-92+25);
    append_frame(&p,4,1,0,NULL,0);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK && session.settings_acked);
    const uint8_t ping[8]={1,2,3,4,5,6,7,8};size_t before=p.out_size;
    append_frame(&p,6,0,0,ping,8);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK);
    assert(p.out_size==before+17 && p.output[before+3]==6 && p.output[before+4]==1 && !memcmp(p.output+before+9,ping,8));
    append_frame(&p,6,1,0,ping,8);before=p.out_size;assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK && p.out_size==before);
    append_frame(&p,1,0,3,NULL,0);append_frame(&p,9,4,3,NULL,0);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK && session.continuation_stream==3);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK && !session.continuation_stream);
    append_frame(&p,254,0,0,ping,8);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK);
    settings_frame(&p,1024);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK);
    assert(session.streams[0].send_window==1024-68);
}
static void error_case(uint8_t type,uint8_t flags,uint32_t stream,const uint8_t *bytes,size_t n,bridge_status expected) {
    reset(2,true);settings_frame(&p,65535);start();append_frame(&p,type,flags,stream,bytes,n);
    bridge_status result=bridge_remotexpc_pump(&session,DEADLINE);
    assert(result==expected && session.failure==expected);
    size_t pos=p.in_pos;assert(bridge_remotexpc_pump(&session,DEADLINE)==expected && p.in_pos==pos);
}
static void errors(void) {
    uint8_t bytes[32]={0};
    error_case(0,0,0,NULL,0,BRIDGE_E_FORMAT);
    error_case(0,0,2,NULL,0,BRIDGE_E_UNSUPPORTED);
    error_case(0,8,3,bytes,1,BRIDGE_E_UNSUPPORTED);
    error_case(1,4,3,bytes,1,BRIDGE_E_UNSUPPORTED);
    error_case(9,4,3,NULL,0,BRIDGE_E_FORMAT);
    error_case(4,1,0,bytes,1,BRIDGE_E_FORMAT);
    error_case(4,0,1,NULL,0,BRIDGE_E_FORMAT);
    error_case(4,0,0,bytes,1,BRIDGE_E_FORMAT);
    error_case(6,0,0,bytes,7,BRIDGE_E_FORMAT);
    error_case(8,0,0,bytes,4,BRIDGE_E_FORMAT);
    put32(bytes,0x7fffffff);error_case(8,0,0,bytes,4,BRIDGE_E_FORMAT);
    put32(bytes,11);error_case(3,0,3,bytes,4,BRIDGE_E_EOF);assert(session.peer_error==11);
    put32(bytes+4,9);error_case(7,0,0,bytes,8,BRIDGE_E_EOF);assert(session.peer_error==9);
    error_case(5,0,1,NULL,0,BRIDGE_E_UNSUPPORTED);
    reset(9,true);settings_frame(&p,65535);start();
    append_frame(&p,1,0,3,NULL,0);append_frame(&p,6,0,0,bytes,8);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_FORMAT);
    reset(9,true);settings_frame(&p,65535);start();
    append_frame(&p,0,1,3,fixture_response,7);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_FORMAT);
    reset(9,true);settings_frame(&p,65535);start();
    uint8_t bad[24];memcpy(bad,fixture_response,24);bad[0]=0;
    append_frame(&p,0,0,3,bad,24);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_FORMAT);
    reset(9,true);settings_frame(&p,65535);start();session.max_wrapper_size=24;
    append_frame(&p,0,0,3,fixture_response,24);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_LIMIT);
    reset(9,true);settings_frame(&p,65535);start();p.timeout_read=true;
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_TIMEOUT);
    reset(9,true);p.fail_write=true;assert(bridge_remotexpc_handshake(&session,DEADLINE)==BRIDGE_E_IO);
    reset(1,true);settings_frame(&p,65535);p.tick=1;
    assert(bridge_remotexpc_handshake(&session,2)==BRIDGE_E_TIMEOUT);
    reset(9,true);settings_frame(&p,65535);start();ev.reject=true;
    append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_TYPE);
    reset(9,false);settings_frame(&p,65535);start();append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_UNSUPPORTED);
    uint8_t setting[6]={0,4,0x80,0,0,0};error_case(4,0,0,setting,6,BRIDGE_E_FORMAT);
    setting[1]=5;put32(setting+2,16383);error_case(4,0,0,setting,6,BRIDGE_E_FORMAT);
    setting[1]=3;put32(setting+2,1);error_case(4,0,0,setting,6,BRIDGE_E_UNSUPPORTED);
    reset(9,true);settings_frame(&p,65535);start();
    append_frame(&p,0,0,3,NULL,0);p.input[p.in_size-9]=0;p.input[p.in_size-8]=0x40;p.input[p.in_size-7]=1;
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_LIMIT);
    reset(9,true);settings_frame(&p,65535);start();session.streams[1].receive_window=0;
    append_frame(&p,0,0,3,bytes,1);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_FORMAT);
    reset(9,true);settings_frame(&p,65535);start();
    memcpy(bad,fixture_response,24);bad[6]=0x10;
    append_frame(&p,0,0,3,bad,24);assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_UNSUPPORTED);
    reset(9,true);settings_frame(&p,65535);start();
    append_frame(&p,1,1,3,NULL,0);append_frame(&p,9,4,3,NULL,0);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK && !session.streams[1].remote_closed);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK && session.streams[1].remote_closed);
    reset(9,true);settings_frame(&p,65535);start();
    append_frame(&p,4,1,0,NULL,0);append_frame(&p,4,1,0,NULL,0);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_OK);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_FORMAT);

}
static void outbound_flow_control(void) {
    reset(13,true);settings_frame(&p,0);start();
    update_frame(&p,1,50000);
    append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    update_frame(&p,0,50000);update_frame(&p,1,20000);
    static uint8_t payload[60000],scratch[61000];memset(payload,0x55,sizeof payload);
    bridge_xpc_object object={.type=BRIDGE_XPC_DATA,.value.bytes={payload,sizeof payload}};
    uint64_t id=99;size_t begin=p.out_size;
    assert(bridge_remotexpc_send(&session,&object,true,scratch,sizeof scratch,DEADLINE,&id)==BRIDGE_OK);
    assert(id==1 && session.next_message_id==2 && ev.end[1]==1 && ev.id==42);
    size_t pos=begin,total=0,count=0;
    while(pos<p.out_size){
        size_t n=(size_t)p.output[pos]<<16|(size_t)p.output[pos+1]<<8|p.output[pos+2];
        if(p.output[pos+3]==0){assert(n<=16384 && get32(p.output+pos+5)==1);total+=n;count++;}
        pos+=9+n;
    }
    assert(total==60040 && count>=4);
    assert(session.streams[0].send_window==70000-68-60040);
    assert(session.send_window==65535-92+50000-60040);
    /* A stale caller envelope must never consume an ID or touch transport. */
    size_t size;assert(bridge_xpc_encode(&object,0x101,1,scratch,sizeof scratch,&size)==BRIDGE_OK);
    begin=p.out_size;assert(bridge_remotexpc_send_encoded(&session,scratch,size,DEADLINE,&id)==BRIDGE_E_ARGUMENT);
    assert(p.out_size==begin && session.next_message_id==2);
    reset(9,true);settings_frame(&p,0);start();p.timeout_read=true;
    assert(bridge_remotexpc_send(&session,&object,true,scratch,sizeof scratch,DEADLINE,&id)==BRIDGE_E_TIMEOUT);
}
static void correlation(void) {
    reset(1,true);settings_frame(&p,65535);start();
    uint8_t wrong[sizeof fixture_response];memcpy(wrong,fixture_response,sizeof wrong);wrong[16]=41;
    append_frame(&p,0,0,3,wrong,sizeof wrong);append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    bridge_remotexpc_response response;assert(bridge_remotexpc_response_open(&session,&response,3,true,42)==BRIDGE_OK);
    uint8_t request_scratch[100];uint64_t unused_id=0;
    bridge_xpc_object null_object={.type=BRIDGE_XPC_NULL};size_t before=p.out_size;
    assert(bridge_remotexpc_send(&session,&null_object,true,request_scratch,sizeof request_scratch,DEADLINE,&unused_id)==BRIDGE_E_ARGUMENT);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_ARGUMENT);
    assert(p.out_size==before && session.failure==BRIDGE_OK);
    uint8_t got[sizeof fixture_response];assert(bridge_read_exact(&response.io,got,sizeof got,DEADLINE)==BRIDGE_OK);
    assert(!memcmp(got,fixture_response,sizeof got));assert(ev.end[1]==1 && ev.id==41);
    assert(response.message.message_id==42 && response.complete);
    assert(response.io.read(response.io.context,got,1,100)==0);
    assert(bridge_remotexpc_response_finish(&response,BRIDGE_OK)==BRIDGE_OK);
    reset(1,true);settings_frame(&p,65535);start();append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    assert(bridge_remotexpc_response_open(&session,&response,3,true,42)==BRIDGE_OK);
    assert(bridge_read_exact(&response.io,got,1,DEADLINE)==BRIDGE_OK);
    assert(bridge_remotexpc_response_finish(&response,BRIDGE_OK)==BRIDGE_E_FORMAT);
    reset(7,false);settings_frame(&p,65535);start();
    uint8_t control[24];size_t control_size=0;
    assert(bridge_xpc_encode(NULL,BRIDGE_XPC_FLAG_ALWAYS_SET|BRIDGE_XPC_FLAG_INIT_HANDSHAKE,0,control,sizeof control,&control_size)==BRIDGE_OK);
    append_frame(&p,0,0,3,control,control_size);append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    assert(bridge_remotexpc_response_open(&session,&response,3,false,0)==BRIDGE_OK);
    assert(bridge_read_exact(&response.io,got,sizeof got,DEADLINE)==BRIDGE_OK);
    assert(response.message.message_id==42 && !memcmp(got,fixture_response,sizeof got));
    assert(bridge_remotexpc_response_finish(&response,BRIDGE_OK)==BRIDGE_OK);
    before=p.out_size;assert(bridge_remotexpc_abort(&session,BRIDGE_E_TYPE)==BRIDGE_E_TYPE);
    assert(bridge_remotexpc_abort(&session,BRIDGE_E_FORMAT)==BRIDGE_E_TYPE);
    assert(bridge_remotexpc_pump(&session,DEADLINE)==BRIDGE_E_TYPE && p.out_size==before);

}
static void any_stream_response(void) {
    for(unsigned stream=1;stream<=3;stream+=2) {
        reset(2,false);settings_frame(&p,65535);start();
        uint8_t control[24];size_t size=0;
        assert(bridge_xpc_encode(NULL,0x400001,42,control,sizeof control,&size)==BRIDGE_OK);
        append_frame(&p,0,0,stream,control,size);
        append_frame(&p,1,5,stream==1?3u:1u,NULL,0); /* The other side can close first. */
        append_frame(&p,0,0,stream,fixture_response,sizeof fixture_response);
        bridge_remotexpc_response response;
        assert(bridge_remotexpc_response_open(&session,&response,BRIDGE_RXPC_ANY_STREAM,true,42)==BRIDGE_OK);
        uint8_t got[sizeof fixture_response];
        assert(bridge_read_exact(&response.io,got,sizeof got,DEADLINE)==BRIDGE_OK);
        assert(response.message.stream_id==stream && !memcmp(got,fixture_response,sizeof got));
        assert(bridge_remotexpc_response_finish(&response,BRIDGE_OK)==BRIDGE_OK);
    }
    reset(3,false);settings_frame(&p,65535);start();
    append_frame(&p,0,0,1,fixture_response,24);
    append_frame(&p,0,0,3,fixture_response,sizeof fixture_response);
    bridge_remotexpc_response response;
    assert(bridge_remotexpc_response_open(&session,&response,BRIDGE_RXPC_ANY_STREAM,true,42)==BRIDGE_OK);
    uint8_t got[sizeof fixture_response];
    assert(bridge_read_exact(&response.io,got,sizeof got,DEADLINE)==BRIDGE_E_IO);
    assert(bridge_remotexpc_response_finish(&response,BRIDGE_OK)==BRIDGE_E_FORMAT);
}
typedef struct { size_t bytes,calls;uint32_t hash; } sink_state;
static bridge_status png_sink(void *ctx,const uint8_t *data,size_t n) {
    sink_state *s=ctx;assert(n<=127);s->bytes+=n;s->calls++;
    for(size_t i=0;i<n;i++)s->hash=s->hash*33u+data[i];
    return BRIDGE_OK;
}
static void streamed_png(void) {
    reset(17,true);p.file=fopen(".build/remotexpc-fixtures/stream.bin","rb");assert(p.file);start();
    bridge_remotexpc_response response;assert(bridge_remotexpc_response_open(&session,&response,3,true,42)==BRIDGE_OK);
    uint8_t scratch[127];bridge_png_info info;sink_state sink={0};
    bridge_status result=bridge_xpc_extract_png(&response.io,32u*1024u*1024u,scratch,sizeof scratch,png_sink,&sink,DEADLINE,&info);
    assert(result==BRIDGE_OK);assert(bridge_remotexpc_response_finish(&response,result)==BRIDGE_OK);
    assert(info.image_bytes==FIXTURE_PNG_SIZE && info.width==FIXTURE_WIDTH && info.height==FIXTURE_HEIGHT && info.message_id==42);
    assert(sink.bytes==FIXTURE_PNG_SIZE && sink.bytes>9u*1024u*1024u && sink.calls>70000);
    assert(sink.hash==FIXTURE_PNG_HASH);
    assert(ev.begin[0]==1 && ev.end[0]==1 && session.settings_acked);
    assert(response.message.wrapper_size==FIXTURE_WRAPPER_SIZE);
    assert(session.receive_window<=65535 && session.receive_window>=65535-16384);
    assert(session.streams[1].receive_window<=16384 && session.streams[1].receive_window>=8192);
    size_t pos=24,updates=0,pings=0;uint64_t conn_credit=0,stream_credit=0;
    while(pos<p.out_size){
        size_t n=(size_t)p.output[pos]<<16|(size_t)p.output[pos+1]<<8|p.output[pos+2];
        uint8_t type=p.output[pos+3];uint32_t sid=get32(p.output+pos+5);
        if(type==8){assert(n==4);uint32_t inc=get32(p.output+pos+9);assert(inc>=8192 && inc<=9215);updates++;if(sid==0)conn_credit+=inc;else if(sid==3)stream_credit+=inc;}
        if(type==6){assert(p.output[pos+4]==1);pings++;}pos+=9+n;
    }
    assert(updates>2000 && pings>10 && conn_credit>=FIXTURE_WRAPPER_SIZE-8192u && stream_credit>=FIXTURE_WRAPPER_SIZE-8192u);
    fclose(p.file);p.file=NULL;
    printf("RemoteXPC streamed %zu PNG bytes using %zu-byte session / %zu-byte pull adapter\n",sink.bytes,sizeof session,sizeof response);
}
int main(void) {
    handshake_and_fragmentation();interleaving_and_multiple();controls();errors();outbound_flow_control();correlation();any_stream_response();streamed_png();
    puts("RemoteXPC synthetic peer: handshake, framing, flow-control, correlation, interleaving, errors and >9 MiB streaming passed");return 0;
}
