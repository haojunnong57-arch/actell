/* SPDX-License-Identifier: GPL-3.0-or-later
 * Actual adapter + actual raw mux + actual QueryType parser, against only a
 * synthetic USB API and device peer. No real phone or USB controller involved.
 */
#define SIM_REAL_PROTOCOL 1
#include "test_lifecycle.c"
#include "bridge_lockdown_probe.h"

static struct {
    uint8_t pending[8192], request[1024];
    size_t used,request_size,fragment;
    uint16_t local_port,tx_seq;
    uint32_t host_next,device_next;
    unsigned mode,versions,setups,syns,queries,resets;
    bool replied;
} peer;
enum { PEER_OK,PEER_WRONG_TYPE,PEER_WRONG_MAGIC,PEER_RESET,PEER_SILENT };
static uint32_t peer_get32(const uint8_t *p) {return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];}
static uint16_t peer_get16(const uint8_t *p) {return (uint16_t)((uint16_t)p[0]<<8|p[1]);}
static void peer_put32(uint8_t *p,uint32_t n) {p[0]=(uint8_t)(n>>24);p[1]=(uint8_t)(n>>16);p[2]=(uint8_t)(n>>8);p[3]=(uint8_t)n;}
static void peer_put16(uint8_t *p,uint16_t n) {p[0]=(uint8_t)(n>>8);p[1]=(uint8_t)n;}
static void peer_append(const uint8_t *p,size_t n) {assert(n<=sizeof peer.pending-peer.used);memcpy(peer.pending+peer.used,p,n);peer.used+=n;}
static void peer_tcp(uint8_t flags,const uint8_t *payload,size_t n) {
    uint8_t frame[1024]={0};assert(n<=sizeof frame-36);
    peer_put32(frame,6);peer_put32(frame+4,(uint32_t)(36+n));
    peer_put32(frame+8,peer.mode==PEER_WRONG_MAGIC?UINT32_C(0xfeedface):UINT32_C(0xfaceface));
    peer_put16(frame+12,peer.tx_seq++);peer_put16(frame+14,0);
    peer_put16(frame+16,BRIDGE_LOCKDOWN_PORT);peer_put16(frame+18,peer.local_port);
    peer_put32(frame+20,peer.device_next);peer_put32(frame+24,peer.host_next);
    frame[28]=0x50;frame[29]=flags;peer_put16(frame+30,32);
    if(n)memcpy(frame+36,payload,n);
    peer_append(frame,36+n);peer.device_next+=(uint32_t)n;
}
static void sim_protocol_receive(const uint8_t *p,size_t n) {
    assert(n>=8 && peer_get32(p+4)==n);
    uint32_t protocol=peer_get32(p);
    if(protocol==0){
        assert(n==20 && peer_get32(p+8)==2);peer.versions++;
        if(peer.mode!=PEER_SILENT){static const uint8_t version[]={0,0,0,0,0,0,0,20,0,0,0,2,0,0,0,0,0,0,0,0};peer_append(version,sizeof version);}
        return;
    }
    assert(n>=16 && peer_get32(p+8)==UINT32_C(0xfeedface));
    if(protocol==2){assert(n==17 && p[16]==7);peer.setups++;return;}
    assert(protocol==6 && n>=36 && p[28]==0x50 && peer_get16(p+18)==BRIDGE_LOCKDOWN_PORT);
    const uint8_t *data=p+36;size_t payload=n-36;uint8_t flags=p[29];
    if(flags==2){
        assert(!payload && peer_get32(p+20)==0 && peer.setups==1);peer.syns++;
        peer.local_port=peer_get16(p+16);peer.host_next=1;peer.device_next=0;
        peer_tcp(0x12,NULL,0);peer.device_next=1;return;
    }
    assert(peer_get16(p+16)==peer.local_port);
    if(flags==4){peer.resets++;return;}
    assert(flags==0x10);
    if(!payload)return;
    assert(peer_get32(p+20)==peer.host_next);
    peer.host_next+=(uint32_t)payload;
    assert(payload<sizeof peer.request-peer.request_size);
    memcpy(peer.request+peer.request_size,data,payload);peer.request_size+=payload;
    peer.request[peer.request_size]=0;
    if(peer.request_size<4 || peer.request_size<4u+peer_get32(peer.request)){peer_tcp(0x10,NULL,0);return;}
    assert(peer.request_size==4u+peer_get32(peer.request) && !peer.replied);
    const char *xml=(const char *)peer.request+4;
    assert(strstr(xml,"<key>Request</key><string>QueryType</string>") && strstr(xml,BRIDGE_LOCKDOWN_PROBE_LABEL));
    assert(!strstr(xml,"<string>Pair</string>") && !strstr(xml,"StartSession") && !strstr(xml,"GetValue"));
    peer.queries++;peer.replied=true;
    if(peer.mode==PEER_RESET){peer_tcp(4,NULL,0);return;}
    const char *reply=peer.mode==PEER_WRONG_TYPE?
        "<plist version=\"1.0\"><dict><key>Type</key><string>wrong.service</string></dict></plist>":
        "<plist version=\"1.0\"><dict><key>Request</key><string>QueryType</string><key>Type</key><string>com.apple.mobile.lockdown</string></dict></plist>";
    size_t length=strlen(reply);uint8_t prefix[4];peer_put32(prefix,(uint32_t)length);
    /* Two real mux frames in one queued stream: prefix and plist are intentionally
     * not aligned to USB completion boundaries. fragment selects 1..4096 bytes. */
    peer_tcp(0x10,prefix,sizeof prefix);peer_tcp(0x10,(const uint8_t *)reply,length);
}
static void sim_protocol_poll(void) {
    if(!sim.powered || !peer.used)return;
    for(size_t i=0;i<16;i++){
        sim_transfer *q=&sim.transfers[i];
        if(q->t && q->inflight && !q->completion && (q->t->bEndpointAddress&0x80u)){
            size_t n=peer.used;if(n>peer.fragment)n=peer.fragment;
            assert(n<=(size_t)q->t->num_bytes);
            memcpy(q->t->data_buffer,peer.pending,n);memmove(peer.pending,peer.pending+n,peer.used-n);peer.used-=n;
            q->actual=(int)n;q->status=USB_TRANSFER_STATUS_COMPLETED;q->completion=true;return;
        }
    }
}
static bridge_status peer_query_session(bridge_usb_host *h,void *ctx) {
    bridge_lockdown_probe_result *out=ctx;sim.session_calls++;
    bridge_usb_stream stream;
    bridge_status s=bridge_usb_stream_open(h,BRIDGE_LOCKDOWN_PORT,sim.now+200,&stream);
    if(s!=BRIDGE_OK)return s;
    assert(bridge_usb_stream_close(&stream,sim.now)==BRIDGE_E_TIMEOUT);
    uint8_t reply[4096];s=bridge_lockdown_probe_query_type(&stream.io,reply,sizeof reply,sim.now+600,out);
    bridge_status close_status=bridge_usb_stream_close(&stream,sim.now+100);
    return s!=BRIDGE_OK?s:close_status;
}
static void integration(unsigned mode,size_t fragment,bridge_status expected) {
    sim_reset(true);sim.slow_attach=5;memset(&peer,0,sizeof peer);peer.mode=mode;peer.fragment=fragment;
    bridge_lockdown_probe_result response={0};bridge_usb_host_result r;
    bridge_usb_host_config c={.wiring_and_vbus_confirmed=true,.enable_controller_requested=true,.configuration_value=1,.runtime_ms=1000,.session=peer_query_session,.session_context=&response};
    bridge_status got=bridge_usb_host_run(&c,&r);
    if(got!=expected)fprintf(stderr,"integration mode=%u fragment=%zu got=%d expected=%d clock=%llu\n",mode,fragment,got,expected,(unsigned long long)sim.now);
    assert(got==expected && r.cleanup_complete);assert(peer.versions==1);
    if(expected==BRIDGE_OK){assert(response.lockdown_type_verified && response.request_echoed && r.session_completed);assert(peer.setups==1 && peer.syns==1 && peer.queries==1 && peer.resets==1);}
    else assert(!response.lockdown_type_verified && !r.session_completed);
    sim_check_clean();
}
int main(void) {
    const size_t fragments[]={1,7,64,4096};
    for(size_t i=0;i<sizeof fragments/sizeof fragments[0];i++)integration(PEER_OK,fragments[i],BRIDGE_OK);
    integration(PEER_WRONG_TYPE,7,BRIDGE_E_TYPE);integration(PEER_WRONG_MAGIC,7,BRIDGE_E_FORMAT);
    integration(PEER_RESET,7,BRIDGE_E_IO);integration(PEER_SILENT,7,BRIDGE_E_TIMEOUT);
    puts("PASS: actual USB Host adapter + raw mux + QueryType composition against synthetic IDF/phone peer (fragmented/coalesced VERSION, SYNACK, plist; wrong service/magic, reset, silence)");
    puts("No hardware, actual IDF runtime, Apple firmware compatibility, pairing, TLS, screenshot or input validation.");
}
