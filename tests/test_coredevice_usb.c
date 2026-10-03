/* SPDX-License-Identifier: GPL-3.0-or-later
 * Binding test: actual QueryType/lockdown/CDTunnel code, FAKE USB and TLS APIs.
 * Cryptography and raw USB state machines have separate tests. Never firmware.
 */
#include "bridge_coredevice_usb.h"
#include "bridge_lockdown_probe.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum fault {NONE,ALLOC,OPEN_LOCK,QUERY,START,SESSION_TLS,OPEN_SERVICE,SERVICE_TLS,TUNNEL,CONSUMER,OVERRUN,STOP};
typedef struct {uint8_t tx[8192],rx[8192];size_t tx_used,rx_used,rx_pos;unsigned index,requests;bool encrypted,cd_started;} peer;
static struct {peer p[2];uint64_t now;enum fault fault;bool service_ssl;unsigned opens,aborts,tls_open,tls_destroy,consumer,live;int host_marker;} sim;
struct bridge_tls {bridge_io *raw;bool ready;int error;unsigned index;};
static void queue_bytes(peer *p,const uint8_t *bytes,size_t n) {
    assert(p->rx_pos==p->rx_used && n<=sizeof p->rx);memcpy(p->rx,bytes,n);p->rx_used=n;p->rx_pos=0;
}
static void queue_plist(peer *p,const char *body) {
    uint8_t bytes[4096];size_t n=strlen(body);assert(n+4<=sizeof bytes);
    bytes[0]=(uint8_t)(n>>24);bytes[1]=(uint8_t)(n>>16);bytes[2]=(uint8_t)(n>>8);bytes[3]=(uint8_t)n;
    memcpy(bytes+4,body,n);queue_bytes(p,bytes,n+4);
}
#define XML_PRE "<plist version=\"1.0\"><dict>"
#define XML_POST "</dict></plist>"
static void request(peer *p) {
    assert(p->tx_used<sizeof p->tx);p->tx[p->tx_used]=0;
    const char *xml=(const char *)p->tx+4;p->requests++;
    if(strstr(xml,"<string>QueryType</string>")) {
        assert(!p->encrypted && p->requests==1);
        queue_plist(p,sim.fault==QUERY?XML_PRE "<key>Type</key><string>wrong</string>" XML_POST:
            XML_PRE "<key>Type</key><string>com.apple.mobile.lockdown</string>" XML_POST);
    } else if(strstr(xml,"<string>StartSession</string>")) {
        assert(!p->encrypted && p->requests==2);
        assert(strstr(xml,"<string>fixture-host</string>") && strstr(xml,"<string>fixture-buid</string>"));
        queue_plist(p,sim.fault==START?XML_PRE "<key>Request</key><string>StartSession</string><key>Error</key><string>InvalidHostID</string>" XML_POST:
            XML_PRE "<key>Request</key><string>StartSession</string><key>SessionID</key><string>fixture-session</string><key>EnableSessionSSL</key><true/>" XML_POST);
    } else if(strstr(xml,"<string>StartService</string>")) {
        assert(p->encrypted && p->requests==3);
        assert(strstr(xml,"<string>" BRIDGE_LOCKDOWN_COREDEVICE_PROXY "</string>"));
        queue_plist(p,sim.service_ssl?
            XML_PRE "<key>Request</key><string>StartService</string><key>Port</key><integer>12345</integer><key>EnableServiceSSL</key><true/>" XML_POST:
            XML_PRE "<key>Request</key><string>StartService</string><key>Port</key><integer>12345</integer><key>EnableServiceSSL</key><false/>" XML_POST);
    } else if(strstr(xml,"<string>StopSession</string>")) {
        assert(p->encrypted && p->requests==4 && strstr(xml,"<string>fixture-session</string>"));
        queue_plist(p,sim.fault==STOP?XML_PRE "<key>Request</key><string>StopSession</string><key>Error</key><string>SessionInactive</string>" XML_POST:
            XML_PRE "<key>Request</key><string>StopSession</string><key>Result</key><string>Success</string>" XML_POST);
    } else assert(false);
    p->tx_used=0;
}
static ptrdiff_t rd(void *context,uint8_t *out,size_t n,uint32_t timeout) {
    peer *p=context;assert(timeout);if(p->rx_pos==p->rx_used)return -BRIDGE_E_TIMEOUT;
    if(n>7)n=7;
    if(n>p->rx_used-p->rx_pos)n=p->rx_used-p->rx_pos;
    memcpy(out,p->rx+p->rx_pos,n);p->rx_pos+=n;return (ptrdiff_t)n;
}
static ptrdiff_t wr(void *context,const uint8_t *in,size_t n,uint32_t timeout) {
    peer *p=context;assert(timeout);if(n>5)n=5;assert(n<=sizeof p->tx-p->tx_used);
    memcpy(p->tx+p->tx_used,in,n);p->tx_used+=n;
    if(!p->index && p->tx_used>=4) {
        size_t len=(size_t)p->tx[0]<<24|(size_t)p->tx[1]<<16|(size_t)p->tx[2]<<8|p->tx[3];
        assert(p->tx_used<=len+4);if(p->tx_used==len+4)request(p);
    } else if(p->index && !p->cd_started && p->tx_used>=10) {
        size_t len=(size_t)p->tx[8]<<8|p->tx[9];assert(p->tx_used<=len+10);
        if(p->tx_used==len+10) {
            assert(!memcmp(p->tx,"CDTunnel",8));assert(p->encrypted==sim.service_ssl);
            const char *json="{\"type\":\"serverHandshakeResponse\",\"clientParameters\":{\"address\":\"fd00::2\",\"mtu\":1280},\"serverAddress\":\"fd00::1\",\"serverRSDPort\":1234}";
            uint8_t b[512];size_t j=strlen(json);memcpy(b,sim.fault==TUNNEL?"NotMagic":"CDTunnel",8);b[8]=(uint8_t)(j>>8);b[9]=(uint8_t)j;memcpy(b+10,json,j);queue_bytes(p,b,j+10);
            p->tx_used=0;p->cd_started=true;
        }
    } else if(p->index && p->cd_started && p->tx_used==40) {queue_bytes(p,p->tx,40);p->tx_used=0;}
    return (ptrdiff_t)n;
}
static uint64_t clk(void *context) {(void)context;return sim.now;}
uint64_t bridge_usb_host_now_ms(void) {return sim.now;}
bridge_status bridge_usb_stream_open(bridge_usb_host *host,uint16_t port,uint64_t deadline,bridge_usb_stream *out) {
    assert(host==(bridge_usb_host *)&sim.host_marker && deadline>sim.now);sim.opens++;
    unsigned i=port==62078?0u:1u;assert(i==0 || port==12345);
    if((!i && sim.fault==OPEN_LOCK)||(i && sim.fault==OPEN_SERVICE))return BRIDGE_E_IO;
    peer *p=&sim.p[i];p->index=i;out->host=host;out->channel=i+1;out->generation=1;out->io=(bridge_io){p,rd,wr,clk};return BRIDGE_OK;
}
bridge_status bridge_usb_stream_abort(bridge_usb_stream *s) {
    if(s->host) {sim.aborts++;memset(s,0,sizeof *s);}return BRIDGE_OK;
}
bridge_status bridge_usb_host_poll(bridge_usb_host *host,uint64_t deadline) {
    assert(host==(bridge_usb_host *)&sim.host_marker);
    return sim.now<deadline?BRIDGE_OK:BRIDGE_E_TIMEOUT;
}
bridge_status bridge_usb_stream_read_available(bridge_usb_stream *stream,size_t *count) {
    peer *p=stream->io.context;*count=p->rx_used-p->rx_pos;return BRIDGE_OK;
}
void *heap_caps_calloc(size_t n,size_t size,unsigned caps) {
    (void)caps;if(sim.fault==ALLOC)return NULL;void *p=calloc(n,size);assert(p);sim.live++;return p;
}
void heap_caps_free(void *p) {if(p) {assert(sim.live);sim.live--;free(p);}}
bridge_status bridge_tls_open(const bridge_tls_config *config,bridge_io *raw,bridge_tls **out) {
    assert(config && raw && out);bridge_tls *t=calloc(1,sizeof *t);assert(t);t->raw=raw;t->index=((peer *)raw->context)->index;*out=t;sim.tls_open++;return BRIDGE_OK;
}
bridge_status bridge_tls_handshake(bridge_tls *t,uint64_t deadline) {
    assert(deadline>sim.now);if((!t->index && sim.fault==SESSION_TLS)||(t->index && sim.fault==SERVICE_TLS)) {t->error=-123;return BRIDGE_E_TYPE;}
    t->ready=true;((peer *)t->raw->context)->encrypted=true;return BRIDGE_OK;
}
bridge_status bridge_tls_get_io(bridge_tls *t,bridge_io *out) {assert(t->ready);*out=*t->raw;return BRIDGE_OK;}
bridge_status bridge_tls_pending(bridge_tls *t,size_t *out) {assert(t->ready);*out=0;return BRIDGE_OK;}
int bridge_tls_last_error(const bridge_tls *t) {return t->error;}
void bridge_tls_destroy(bridge_tls *t) {if(t) {sim.tls_destroy++;free(t);}}
static bridge_status consume(void *context,bridge_packet_link *link,uint64_t deadline) {
    bridge_cdtunnel *t=link->tunnel;
    assert(context==&sim && t->state==BRIDGE_CDTUNNEL_READY);sim.consumer++;
    if(sim.fault==CONSUMER)return BRIDGE_E_FORMAT;
    if(sim.fault==OVERRUN) {sim.now=deadline;return BRIDGE_OK;}
    uint8_t packet[1280]={0x60};packet[6]=59;packet[7]=64;
    bool readable=true;
    assert(link->readable(link->context,&readable)==BRIDGE_OK && !readable);
    assert(link->poll(link->context,deadline)==BRIDGE_OK);
    assert(bridge_cdtunnel_send_ipv6(t,packet,40,deadline)==BRIDGE_OK);
    assert(link->readable(link->context,&readable)==BRIDGE_OK && readable);
    size_t got=0;assert(bridge_cdtunnel_recv_ipv6(t,packet,sizeof packet,&got,deadline)==BRIDGE_OK && got==40);return BRIDGE_OK;
}
int main(void) {
    static const uint8_t FAKE[]={1}; /* Intentionally NOT a valid credential. TLS is stubbed in this test only. */
    bridge_tls_config tls={FAKE,sizeof FAKE,FAKE,sizeof FAKE,FAKE,sizeof FAKE};
    bridge_coredevice_usb_result result;
    assert(bridge_coredevice_usb_run(NULL,NULL,&result)==BRIDGE_E_ARGUMENT);
    for(unsigned ssl=0;ssl<2;ssl++) for(unsigned f=NONE;f<=STOP;f++) {
        if(!ssl && f==SERVICE_TLS)continue;
        memset(&sim,0,sizeof sim);sim.now=1;sim.fault=(enum fault)f;sim.service_ssl=ssl!=0;
        bridge_coredevice_usb_config config={"fixture-host","fixture-buid",&tls,10000,consume,&sim};
        bridge_status s=bridge_coredevice_usb_run((bridge_usb_host *)&sim.host_marker,&config,&result);
        if(f==NONE) {assert(s==BRIDGE_OK && result.phase==BRIDGE_COREDEVICE_PHASE_DONE && result.stop_session_confirmed && result.tunnel_negotiated && result.consumer_completed);assert(sim.consumer==1 && sim.aborts==2);}
        else {assert(s!=BRIDGE_OK && result.phase!=BRIDGE_COREDEVICE_PHASE_DONE && !result.stop_session_confirmed);}
        assert(sim.live==0 && sim.tls_open==sim.tls_destroy);
        if(f==SESSION_TLS || f==SERVICE_TLS)assert(result.tls_error==-123 && result.lockdown_failure==BRIDGE_LOCKDOWN_FAILURE_TLS);
        if(f==START)assert(result.peer_error==BRIDGE_LOCKDOWN_PEER_INVALID_HOST_ID);
        if(f<CONSUMER && f!=NONE)assert(sim.consumer==0);
    }
    memset(&sim,0,sizeof sim);bridge_coredevice_usb_config config={"fixture-host","fixture-buid",NULL,10000,consume,&sim};
    assert(bridge_coredevice_usb_run((bridge_usb_host *)&sim.host_marker,&config,&result)==BRIDGE_E_ARGUMENT);
    assert(!sim.opens && result.lockdown_failure==BRIDGE_LOCKDOWN_FAILURE_MISSING_IDENTITY);
    puts("PASS: USB/CoreDevice binding lifecycle and real plist/CDTunnel composition; 23 success/fault profiles, no leaked owned resources");
    puts("This test stubs USB and TLS API boundaries. Actual cryptography and raw USB protocol have separate tests; no iPhone hardware is implied.");
}
