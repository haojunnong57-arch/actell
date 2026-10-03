/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A synthetic packet peer, NOT a tcp_* mock. Every emitted TCP/UDP datagram is
 * parsed and checksum-checked independently. Every received packet traverses
 * the real CDTunnel stream parser, netif, IPv6 and TCP/UDP implementation. */
#include "bridge_lwip.h"
#include "lwip/tcpip.h"
#include "lwip/sys.h"
#include "lwip/priv/tcp_priv.h"
#include "lwip/stats.h"
#include "lwip/udp.h"
#include "lwip/priv/nd6_priv.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
#define PEER_CAPACITY 8u
#define WIRE_CAPACITY (512u * 1024u)
#define FLAG_FIN 0x01u
#define FLAG_SYN 0x02u
#define FLAG_RST 0x04u
#define FLAG_PSH 0x08u
#define FLAG_ACK 0x10u
static const uint8_t client_ip[16] = {0x20,1,0x0d,0xb8,0,1,0,0,0,0,0,0,0,0,0,2};
static const uint8_t server_ip[16] = {0x20,1,0x0d,0xb8,0,1,0,0,0,0,0,0,0,0,0,1};
static uint16_t read16(const uint8_t *p) { return (uint16_t)((unsigned)p[0] * 256u + p[1]); }
static uint32_t read32(const uint8_t *p) { return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]; }
static void put16(uint8_t *p, uint16_t n) { p[0]=(uint8_t)(n>>8); p[1]=(uint8_t)n; }
static void put32(uint8_t *p, uint32_t n) { p[0]=(uint8_t)(n>>24); p[1]=(uint8_t)(n>>16); p[2]=(uint8_t)(n>>8); p[3]=(uint8_t)n; }
static uint64_t clock_now(void) { struct timespec t; CHECK(clock_gettime(CLOCK_MONOTONIC, &t)==0); return (uint64_t)t.tv_sec*1000u+(uint64_t)t.tv_nsec/1000000u; }
static void sleep_ms(unsigned n) { struct timespec t={.tv_sec=n/1000u,.tv_nsec=(long)(n%1000u)*1000000L}; while(nanosleep(&t,&t)) {} }
static uint32_t sum16(uint32_t s,const uint8_t *p,size_t n) { while(n>1) {s+=read16(p);p+=2;n-=2;} if(n)s+=(unsigned)p[0]<<8; return s; }
static uint16_t transport_checksum(const uint8_t *packet,size_t n,size_t offset,uint8_t protocol) {
    CHECK(offset>=40 && n>=offset && n==40u+read16(packet+4));
    uint32_t s=sum16(0,packet+8,32); s+=(uint32_t)(n-offset);s+=protocol;s=sum16(s,packet+offset,n-offset);
    while(s>>16){s=(s&0xffffu)+(s>>16);}return (uint16_t)~s;
}

static uint16_t checksum(const uint8_t *packet,size_t n){return transport_checksum(packet,n,40,packet[6]);}

typedef struct { uint16_t local_port,remote_port,window,last_client_window;uint32_t local_next,remote_next;size_t syns,acks,resets,data_packets,duplicates,bytes;bool ack_data,drop_syn,synack_sent;uint8_t data[65536]; } peer_tcp;
typedef struct {
    bridge_cdtunnel tunnel;bridge_packet_link link;bridge_lwip_net *net;pthread_t owner;
    uint8_t incoming[WIRE_CAPACITY],outgoing[BRIDGE_CDTUNNEL_MAX_MTU+128u];
    size_t incoming_size,incoming_pos,outgoing_size,chunk,read_calls,write_calls,poll_calls,clock_calls,empty_reads;
    size_t udp_packets,udp_bytes,ipv6_packets,icmp6_packets;uint8_t udp_data[4096];uint16_t udp_source,udp_dest;
    uint16_t syn_window;unsigned drop_syns;bool no_syn_reply,handshake_done,callbacks_forbidden,fail_poll,truncate_read,fail_write,hold_readable;
    peer_tcp tcp[PEER_CAPACITY];size_t tcp_count;
} peer;
static void check_owner(peer *p) { CHECK(!p->callbacks_forbidden);CHECK(pthread_equal(pthread_self(),p->owner)); }
static void enqueue(peer *p,const uint8_t *bytes,size_t n) {
    if(p->incoming_pos==p->incoming_size)p->incoming_pos=p->incoming_size=0;
    CHECK(n<=sizeof p->incoming-p->incoming_size);memcpy(p->incoming+p->incoming_size,bytes,n);p->incoming_size+=n;
}
static size_t ip_packet(uint8_t *out,uint8_t protocol,size_t payload) {
    CHECK(payload<=UINT16_MAX);memset(out,0,40+payload);out[0]=0x60;put16(out+4,(uint16_t)payload);out[6]=protocol;out[7]=64;
    memcpy(out+8,server_ip,16);memcpy(out+24,client_ip,16);return payload+40;
}
static size_t tcp_packet(uint8_t *out,peer_tcp *t,uint32_t seq,uint32_t ack,uint8_t flags,uint16_t window,const void *bytes,size_t n) {
    size_t options=(flags&FLAG_SYN)?4u:0u;size_t size=ip_packet(out,6,20+options+n);uint8_t *q=out+40;
    put16(q,t->remote_port);put16(q+2,t->local_port);put32(q+4,seq);put32(q+8,ack);q[12]=(uint8_t)((20+options)/4u<<4);q[13]=flags;put16(q+14,window);
    if(options){q[20]=2;q[21]=4;put16(q+22,1220);}if(n)memcpy(q+20+options,bytes,n);put16(q+16,checksum(out,size));CHECK(checksum(out,size)==0);return size;
}
static void tcp_inject(peer *p,peer_tcp *t,uint32_t seq,uint8_t flags,const void *bytes,size_t n) {
    uint8_t packet[4096];size_t size=tcp_packet(packet,t,seq,t->local_next,flags,t->window,bytes,n);enqueue(p,packet,size);
}
static void udp_inject(peer *p,uint16_t source,uint16_t dest,const void *bytes,size_t n,bool corrupt) {
    uint8_t packet[BRIDGE_CDTUNNEL_MAX_MTU];size_t size=ip_packet(packet,17,8+n);memcpy(packet+8,p->tunnel.parameters.server_address,16);memcpy(packet+24,p->tunnel.parameters.client_address,16);put16(packet+40,source);put16(packet+42,dest);put16(packet+44,(uint16_t)(8+n));
    if(n){memcpy(packet+48,bytes,n);}uint16_t c=checksum(packet,size);put16(packet+46,c?c:0xffff);if(corrupt)packet[47]^=1;enqueue(p,packet,size);
}
static peer_tcp *find_peer(peer *p,uint16_t local,uint16_t remote,bool create) {
    for(size_t i=0;i<p->tcp_count;++i)if(p->tcp[i].local_port==local&&p->tcp[i].remote_port==remote)return &p->tcp[i];
    CHECK(create && p->tcp_count<PEER_CAPACITY);peer_tcp *t=&p->tcp[p->tcp_count++];memset(t,0,sizeof *t);t->local_port=local;t->remote_port=remote;t->window=p->syn_window;t->remote_next=100000u+(uint32_t)p->tcp_count*10000u;t->ack_data=true;return t;
}
static void peer_packet(peer *p,const uint8_t *packet,size_t size) {
    CHECK(size>=40 && size==40u+read16(packet+4));CHECK((packet[0]>>4)==6);CHECK(!memcmp(packet+8,p->tunnel.parameters.client_address,16));CHECK(!memcmp(packet+24,p->tunnel.parameters.server_address,16));
    CHECK(checksum(packet,size)==0);++p->ipv6_packets;
    if(packet[6]==17){CHECK(size>=48);CHECK(read16(packet+44)==size-40);++p->udp_packets;p->udp_source=read16(packet+40);p->udp_dest=read16(packet+42);p->udp_bytes=size-48;CHECK(p->udp_bytes<=sizeof p->udp_data);memcpy(p->udp_data,packet+48,p->udp_bytes);return;}
    if(packet[6]==58){CHECK(size>=48&&packet[40]==1&&packet[41]==4);++p->icmp6_packets;return;}CHECK(packet[6]==6 && size>=60);const uint8_t *q=packet+40;size_t header=(size_t)(q[12]>>4)*4u;CHECK(header>=20 && header<=size-40);
    uint8_t flags=q[13];uint32_t seq=read32(q+4);size_t bytes=size-40-header;peer_tcp *t=find_peer(p,read16(q),read16(q+2),(flags&FLAG_SYN)!=0);
    if(flags&FLAG_RST){++t->resets;return;}
    if(flags&FLAG_SYN){++t->syns;t->local_next=seq+1u;if(!p->no_syn_reply && !t->drop_syn && t->syns>p->drop_syns){tcp_inject(p,t,t->remote_next-(t->synack_sent?1u:0u),FLAG_SYN|FLAG_ACK,NULL,0);if(!t->synack_sent){++t->remote_next;t->synack_sent=true;}}return;}
    if(flags&FLAG_ACK){++t->acks;t->last_client_window=read16(q+14);}
    if(bytes){++t->data_packets;if(seq==t->local_next){CHECK(bytes<=sizeof t->data-t->bytes);memcpy(t->data+t->bytes,q+header,bytes);t->bytes+=bytes;t->local_next+=(uint32_t)bytes;}else{CHECK(seq<t->local_next);++t->duplicates;}
        if(t->ack_data)tcp_inject(p,t,t->remote_next,FLAG_ACK,NULL,0);}
    if(flags&FLAG_FIN){++t->local_next;tcp_inject(p,t,t->remote_next,FLAG_ACK,NULL,0);}
}
static ptrdiff_t stream_read(void *ctx,uint8_t *out,size_t n,uint32_t timeout) {
    peer *p=ctx;check_owner(p);CHECK(n&&timeout);++p->read_calls;size_t avail=p->incoming_size-p->incoming_pos;
    if(!avail){++p->empty_reads;return p->truncate_read?0:-BRIDGE_E_TIMEOUT;}
    if(n>avail){n=avail;}if(p->chunk&&n>p->chunk)n=p->chunk;memcpy(out,p->incoming+p->incoming_pos,n);p->incoming_pos+=n;return (ptrdiff_t)n;
}
static ptrdiff_t stream_write(void *ctx,const uint8_t *data,size_t n,uint32_t timeout) {
    peer *p=ctx;check_owner(p);CHECK(n&&timeout);++p->write_calls;if(p->fail_write)return -BRIDGE_E_IO;if(p->chunk&&n>p->chunk)n=p->chunk;
    CHECK(n<=sizeof p->outgoing-p->outgoing_size);memcpy(p->outgoing+p->outgoing_size,data,n);p->outgoing_size+=n;
    if(!p->handshake_done){if(p->outgoing_size>=10){CHECK(!memcmp(p->outgoing,"CDTunnel",8));size_t expected=10u+read16(p->outgoing+8);if(p->outgoing_size>=expected){CHECK(p->outgoing_size==expected);p->handshake_done=true;p->outgoing_size=0;}}}
    else if(p->outgoing_size>=40){size_t expected=40u+read16(p->outgoing+4);if(p->outgoing_size>=expected){CHECK(p->outgoing_size==expected);peer_packet(p,p->outgoing,expected);p->outgoing_size=0;}}
    return (ptrdiff_t)n;
}
static uint64_t stream_clock(void *ctx){peer*p=ctx;check_owner(p);++p->clock_calls;return clock_now();}
static bridge_status link_poll(void *ctx,uint64_t deadline){peer*p=ctx;check_owner(p);++p->poll_calls;if(deadline<=clock_now())return BRIDGE_E_TIMEOUT;if(p->fail_poll)return BRIDGE_E_IO;sleep_ms(1);return BRIDGE_OK;}
static bridge_status link_readable(void *ctx,bool *ready){peer*p=ctx;check_owner(p);*ready=!p->hold_readable&&p->incoming_pos<p->incoming_size;return BRIDGE_OK;}
static peer *open_peer_addresses(uint16_t mtu,const char*client,const char*server){
    peer *p=calloc(1,sizeof *p);CHECK(p);p->owner=pthread_self();p->syn_window=8192;p->chunk=7;
    char json[512];const char *format="{\"type\":\"serverHandshakeResponse\",\"clientParameters\":{\"address\":\"%s\",\"mtu\":%u,\"netmask\":\"ffff:ffff:ffff:ffff::\"},\"serverAddress\":\"%s\",\"serverRSDPort\":56307}";
    int count=snprintf(json,sizeof json,format,client,(unsigned)mtu,server);CHECK(count>0&&(size_t)count<sizeof json);size_t length=(size_t)count;
    uint8_t response[sizeof json+10];memcpy(response,"CDTunnel",8);put16(response+8,(uint16_t)length);memcpy(response+10,json,length);enqueue(p,response,length+10);
    bridge_io io={p,stream_read,stream_write,stream_clock};CHECK(bridge_cdtunnel_init(&p->tunnel,&io,mtu)==BRIDGE_OK);uint8_t scratch[1024];CHECK(bridge_cdtunnel_handshake(&p->tunnel,scratch,sizeof scratch,clock_now()+2000)==BRIDGE_OK);
    p->link=(bridge_packet_link){&p->tunnel,p,link_poll,link_readable};CHECK(bridge_lwip_create(&p->link,&p->net,clock_now()+2000)==BRIDGE_OK);CHECK(p->net);return p;
}
static peer *open_peer_mtu(uint16_t mtu){return open_peer_addresses(mtu,"2001:db8:1::2","2001:db8:1::1");}
static peer *open_peer(void){return open_peer_mtu(1280);}
static void destroy_peer(peer *p){
    size_t reads=p->read_calls,writes=p->write_calls,polls=p->poll_calls,clocks=p->clock_calls;p->callbacks_forbidden=true;
    bridge_status s=bridge_lwip_shutdown(p->net);CHECK(s==BRIDGE_OK||s==BRIDGE_E_LIMIT);uint64_t deadline=clock_now()+2000;
    do{s=bridge_lwip_destroy(p->net);if(s==BRIDGE_OK)break;CHECK(s==BRIDGE_E_TIMEOUT||s==BRIDGE_E_LIMIT);CHECK(clock_now()<deadline);sleep_ms(1);}while(1);
    CHECK(p->read_calls==reads&&p->write_calls==writes&&p->poll_calls==polls&&p->clock_calls==clocks);free(p);
}
static void pump(peer *p,unsigned count){for(unsigned i=0;i<count;++i)CHECK(bridge_lwip_poll(p->net,clock_now()+500)==BRIDGE_OK);}
static bridge_lwip_tcp connect_peer(peer *p,uint16_t port){bridge_lwip_tcp ch={0};CHECK(bridge_lwip_tcp_connect(p->net,port,clock_now()+2000,&ch)==BRIDGE_OK);pump(p,3);CHECK(p->tcp_count);CHECK(p->tcp[p->tcp_count-1].syns==1);CHECK(p->tcp[p->tcp_count-1].acks);return ch;}
static void start_done(void *arg){sys_sem_signal(arg);}
static void initialize_lwip(void){sys_sem_t done;CHECK(sys_sem_new(&done,0)==ERR_OK);tcpip_init(start_done,&done);CHECK(sys_arch_sem_wait(&done,5000)!=SYS_ARCH_TIMEOUT);sys_sem_free(&done);}

static void test_stream_and_checksums(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,56307);bridge_io io=bridge_lwip_tcp_io(&ch);peer_tcp*t=&p->tcp[0];
    const char outbound[]="real lwIP writes through real CDTunnel";CHECK(io.write(io.context,(const uint8_t*)outbound,sizeof outbound,500)==sizeof outbound);pump(p,6);CHECK(t->bytes==sizeof outbound&&!memcmp(t->data,outbound,sizeof outbound));CHECK(bridge_lwip_tcp_drain(&ch,clock_now()+500)==BRIDGE_OK);
    const char inbound[]="peer packet reached TCP receive callback";tcp_inject(p,t,t->remote_next,FLAG_PSH|FLAG_ACK,inbound,sizeof inbound);uint8_t result[128];ptrdiff_t n=io.read(io.context,result,7,500);CHECK(n==7);n=io.read(io.context,result+7,sizeof result-7,500);CHECK(n==(ptrdiff_t)sizeof inbound-7);CHECK(!memcmp(result,inbound,sizeof inbound));size_t pending=99;CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_OK&&pending==0);t->remote_next+=(uint32_t)sizeof inbound;
    /* Bad transport checksum cannot reach the bridge receive ring. */
    uint8_t corrupt[128];size_t size=tcp_packet(corrupt,t,t->remote_next,t->local_next,FLAG_ACK|FLAG_PSH,t->window,"bad",3);corrupt[size-1]^=1;enqueue(p,corrupt,size);pump(p,4);
    tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_PSH,"good",4);CHECK(io.read(io.context,result,sizeof result,500)==4);CHECK(!memcmp(result,"good",4));t->remote_next+=4;
    CHECK(!p->empty_reads);bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.tx_packets>=3&&stats.rx_packets>=4&&stats.allocation_bytes>0);printf("Fixed bridge context: %zu bytes (host ABI; lwIP pools excluded)\n",stats.allocation_bytes);
    CHECK(bridge_lwip_tcp_close(&ch,clock_now()+500)==BRIDGE_OK);destroy_peer(p);puts("PASS TCP SYN/ACK, checksums, fragmented stream, bidirectional data and core ownership");
}
static void test_reassembly_duplicates_and_eof(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,10001);bridge_io io=bridge_lwip_tcp_io(&ch);peer_tcp*t=&p->tcp[0];uint32_t seq=t->remote_next;
    tcp_inject(p,t,seq+5,FLAG_ACK|FLAG_PSH,"world",5);tcp_inject(p,t,seq,FLAG_ACK|FLAG_PSH,"hello",5);tcp_inject(p,t,seq,FLAG_ACK|FLAG_PSH,"hello",5);uint8_t out[32];
    size_t total=0;while(total<10){ptrdiff_t n=io.read(io.context,out+total,sizeof out-total,500);CHECK(n>0);total+=(size_t)n;}CHECK(total==10&&!memcmp(out,"helloworld",10));t->remote_next+=10;
    tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_FIN,NULL,0);CHECK(io.read(io.context,out,sizeof out,500)==0);size_t pending=99;CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_E_EOF&&pending==0);++t->remote_next;CHECK(io.write(io.context,(const uint8_t*)"after FIN",9,500)==9);CHECK(bridge_lwip_tcp_drain(&ch,clock_now()+500)==BRIDGE_OK);CHECK(t->bytes==9&&!memcmp(t->data,"after FIN",9));CHECK(!p->empty_reads);destroy_peer(p);puts("PASS actual TCP reassembly, duplicates, FIN EOF and half-close writes");
}
static void test_reset_and_deadline(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,10002);bridge_io io=bridge_lwip_tcp_io(&ch);uint8_t out[32];uint64_t start=clock_now();
    CHECK(io.read(io.context,out,sizeof out,45)==-BRIDGE_E_TIMEOUT);CHECK(clock_now()-start<250);CHECK(!p->empty_reads);
    peer_tcp*t=&p->tcp[0];tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_RST,NULL,0);CHECK(io.read(io.context,out,sizeof out,500)<0);destroy_peer(p);
    p=open_peer();p->no_syn_reply=true;start=clock_now();CHECK(bridge_lwip_tcp_connect(p->net,10003,clock_now()+45,&ch)==BRIDGE_E_TIMEOUT);CHECK(clock_now()-start<250);CHECK(p->tcp_count==1&&p->tcp[0].syns==1);CHECK(!p->empty_reads);destroy_peer(p);puts("PASS TCP read/connect deadlines and peer RST");
}
static void test_udp(void){
    peer*p=open_peer();bridge_lwip_udp u={0};CHECK(bridge_lwip_udp_open(p->net,5555,4444,clock_now()+500,&u)==BRIDGE_OK);
    const uint8_t data[]={0,1,2,3,4,5,255};CHECK(bridge_lwip_udp_send(&u,4444,data,sizeof data,clock_now()+500)==BRIDGE_OK);pump(p,3);CHECK(p->udp_packets==1&&p->udp_source==5555&&p->udp_dest==4444&&p->udp_bytes==sizeof data&&!memcmp(p->udp_data,data,sizeof data));
    udp_inject(p,4444,5555,data,sizeof data,true);udp_inject(p,9999,5555,"wrong",5,false);udp_inject(p,4444,5555,data,sizeof data,false);uint8_t out[64];size_t n=99;uint16_t port=0;
    CHECK(bridge_lwip_udp_receive(&u,out,2,&n,&port,clock_now()+500)==BRIDGE_E_LIMIT);CHECK(n==0);CHECK(bridge_lwip_udp_receive(&u,out,sizeof out,&n,&port,clock_now()+500)==BRIDGE_OK);CHECK(n==sizeof data&&port==4444&&!memcmp(out,data,n));
    udp_inject(p,4444,5555,NULL,0,false);CHECK(bridge_lwip_udp_receive(&u,out,sizeof out,&n,&port,clock_now()+500)==BRIDGE_OK);CHECK(n==0&&port==4444);
    for(unsigned i=0;i<BRIDGE_LWIP_UDP_PACKETS+3u;++i){udp_inject(p,4444,5555,data,sizeof data,false);}pump(p,20);bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.udp_dropped>=3);
    CHECK(bridge_lwip_udp_close(&u,clock_now()+500)==BRIDGE_OK);destroy_peer(p);puts("PASS real UDP checksum, source-port filter, datagram preservation, empty and bounded queue");
}
static void test_udp_size_bounds(void){
    peer*p=open_peer_mtu(16000);bridge_lwip_udp u={0};CHECK(bridge_lwip_udp_open(p->net,5555,4444,clock_now()+500,&u)==BRIDGE_OK);
    uint8_t data[BRIDGE_LWIP_UDP_CAPACITY+1u],out[BRIDGE_LWIP_UDP_CAPACITY];memset(data,0xa7,sizeof data);
    CHECK(bridge_lwip_udp_send(&u,4444,data,sizeof data,clock_now()+500)==BRIDGE_E_LIMIT);
    CHECK(bridge_lwip_udp_send(&u,4444,data,sizeof out,clock_now()+500)==BRIDGE_OK);pump(p,3);
    CHECK(p->udp_bytes==sizeof out&&!memcmp(p->udp_data,data,sizeof out));
    udp_inject(p,4444,5555,data,sizeof data,false);udp_inject(p,4444,5555,data,sizeof out,false);size_t n=0;uint16_t port=0;
    CHECK(bridge_lwip_udp_receive(&u,out,sizeof out,&n,&port,clock_now()+500)==BRIDGE_OK);CHECK(n==sizeof out&&!memcmp(out,data,n));
    bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.udp_dropped==1);destroy_peer(p);
    puts("PASS negotiated maximum MTU and exact UDP capacity/oversize boundaries");
}
static void test_slots_and_stale_handles(void){
    peer*p=open_peer();bridge_lwip_tcp tcp[BRIDGE_LWIP_TCP_SLOTS];for(unsigned i=0;i<BRIDGE_LWIP_TCP_SLOTS;++i)tcp[i]=connect_peer(p,(uint16_t)(11000+i));bridge_lwip_tcp extra={0};CHECK(bridge_lwip_tcp_connect(p->net,12000,clock_now()+500,&extra)==BRIDGE_E_LIMIT);
    bridge_lwip_tcp stale=tcp[0];CHECK(bridge_lwip_tcp_close(&tcp[0],clock_now()+500)==BRIDGE_OK);extra=connect_peer(p,12001);bridge_io old=bridge_lwip_tcp_io(&stale);uint8_t out=0;CHECK(old.read(old.context,&out,1,100)<0);
    bridge_lwip_udp udp[BRIDGE_LWIP_UDP_SLOTS],u={0};for(unsigned i=0;i<BRIDGE_LWIP_UDP_SLOTS;++i)CHECK(bridge_lwip_udp_open(p->net,(uint16_t)(13000+i),0,clock_now()+500,&udp[i])==BRIDGE_OK);CHECK(bridge_lwip_udp_open(p->net,14000,0,clock_now()+500,&u)==BRIDGE_E_LIMIT);
    bridge_lwip_udp stale_udp=udp[0];CHECK(bridge_lwip_udp_close(&udp[0],clock_now()+500)==BRIDGE_OK);CHECK(bridge_lwip_udp_open(p->net,14001,0,clock_now()+500,&u)==BRIDGE_OK);CHECK(bridge_lwip_udp_send(&stale_udp,4444,&out,1,clock_now()+100)==BRIDGE_E_ARGUMENT);destroy_peer(p);puts("PASS four TCP/UDP slots, slot reuse and stale-handle rejection");
}
static void test_retransmission_and_zero_window(void){
    peer*p=open_peer();p->drop_syns=1;bridge_lwip_tcp ch={0};
    CHECK(bridge_lwip_tcp_connect(p->net,15000,clock_now()+7000,&ch)==BRIDGE_OK);
    CHECK(p->tcp[0].syns>=2);peer_tcp*t=&p->tcp[0];t->ack_data=false;
    bridge_io io=bridge_lwip_tcp_io(&ch);const uint8_t message[]={9,8,7,6};
    CHECK(io.write(io.context,message,sizeof message,500)==sizeof message);
    uint64_t deadline=clock_now()+7000;
    while(!t->duplicates){CHECK(clock_now()<deadline);pump(p,1);}
    CHECK(t->bytes==sizeof message&&!memcmp(t->data,message,sizeof message));
    t->ack_data=true;tcp_inject(p,t,t->remote_next,FLAG_ACK,NULL,0);pump(p,5);destroy_peer(p);
    p=open_peer();p->syn_window=0;ch=connect_peer(p,15001);io=bridge_lwip_tcp_io(&ch);t=&p->tcp[0];
    CHECK(io.write(io.context,message,sizeof message,500)==sizeof message);pump(p,10);CHECK(t->bytes==0);CHECK(bridge_lwip_tcp_drain(&ch,clock_now()+40)==BRIDGE_E_TIMEOUT);
    t->window=8192;tcp_inject(p,t,t->remote_next,FLAG_ACK,NULL,0);deadline=clock_now()+2000;
    while(t->bytes<sizeof message){CHECK(clock_now()<deadline);pump(p,1);}
    CHECK(t->bytes==sizeof message&&!memcmp(t->data,message,sizeof message));CHECK(bridge_lwip_tcp_drain(&ch,clock_now()+500)==BRIDGE_OK);destroy_peer(p);
    puts("PASS real timer-driven SYN/data retransmission and zero-window reopening");
}
static void test_transport_failure(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,16000);(void)ch;p->fail_poll=true;
    CHECK(bridge_lwip_poll(p->net,clock_now()+100)==BRIDGE_E_IO);destroy_peer(p);
    p=open_peer();uint8_t partial[60];memset(partial,0,sizeof partial);partial[0]=0x60;put16(partial+4,20);partial[6]=6;
    enqueue(p,partial,30);p->truncate_read=true;CHECK(bridge_lwip_poll(p->net,clock_now()+100)==BRIDGE_E_EOF);
    CHECK(p->tunnel.state==BRIDGE_CDTUNNEL_FAILED);destroy_peer(p);
    puts("PASS USB poll failure and partial CDTunnel packet fail closed");
}
typedef struct{sys_sem_t entered,release;} core_barrier;
static void block_core(void *ctx){core_barrier*b=ctx;sys_sem_signal(&b->entered);sys_sem_wait(&b->release);}
static void test_shutdown_pending_core(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,17000);(void)ch;core_barrier b;
    CHECK(sys_sem_new(&b.entered,0)==ERR_OK&&sys_sem_new(&b.release,0)==ERR_OK);
    CHECK(tcpip_callback(block_core,&b)==ERR_OK);CHECK(sys_arch_sem_wait(&b.entered,1000)!=SYS_ARCH_TIMEOUT);
    p->callbacks_forbidden=true;uint64_t start=clock_now();CHECK(bridge_lwip_shutdown(p->net)==BRIDGE_OK);
    CHECK(clock_now()-start<100);CHECK(!bridge_lwip_cleanup_complete(p->net));CHECK(bridge_lwip_destroy(p->net)==BRIDGE_E_TIMEOUT);
    sys_sem_signal(&b.release);uint64_t deadline=clock_now()+2000;
    while(!bridge_lwip_cleanup_complete(p->net)){CHECK(clock_now()<deadline);sleep_ms(1);}
    CHECK(bridge_lwip_destroy(p->net)==BRIDGE_OK);sys_sem_free(&b.entered);sys_sem_free(&b.release);free(p);
    puts("PASS nonblocking shutdown retains context until real core cleanup acknowledgment");
}
static void test_create_timeout_and_full_mailbox(void){
    peer*p=open_peer();bridge_lwip_net*first=p->net;core_barrier b;
    CHECK(sys_sem_new(&b.entered,0)==ERR_OK&&sys_sem_new(&b.release,0)==ERR_OK);
    CHECK(tcpip_callback(block_core,&b)==ERR_OK);CHECK(sys_arch_sem_wait(&b.entered,1000)!=SYS_ARCH_TIMEOUT);
    bridge_lwip_net*pending=NULL;uint64_t start=clock_now();
    CHECK(bridge_lwip_create(&p->link,&pending,clock_now()+40)==BRIDGE_E_TIMEOUT);
    CHECK(pending&&clock_now()-start<250);CHECK(!bridge_lwip_cleanup_complete(pending));
    p->callbacks_forbidden=true;CHECK(bridge_lwip_destroy(pending)==BRIDGE_E_TIMEOUT);sys_sem_signal(&b.release);
    bridge_status status=bridge_lwip_shutdown(first);CHECK(status==BRIDGE_OK||status==BRIDGE_E_LIMIT);
    p->net=pending;destroy_peer(p); /* Both nets stopped borrowing before transport free. */
    uint64_t deadline=clock_now()+2000;
    do{status=bridge_lwip_destroy(first);if(status==BRIDGE_OK)break;CHECK(status==BRIDGE_E_TIMEOUT||status==BRIDGE_E_LIMIT);CHECK(clock_now()<deadline);sleep_ms(1);}while(1);
    sys_sem_free(&b.entered);sys_sem_free(&b.release);
    puts("PASS timed-out create preserves context until deferred cleanup acknowledgment");
}
static void test_posted_write_timeout_cleanup(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,19000);bridge_io io=bridge_lwip_tcp_io(&ch);core_barrier b;
    CHECK(sys_sem_new(&b.entered,0)==ERR_OK&&sys_sem_new(&b.release,0)==ERR_OK);
    CHECK(tcpip_callback(block_core,&b)==ERR_OK);CHECK(sys_arch_sem_wait(&b.entered,1000)!=SYS_ARCH_TIMEOUT);
    CHECK(io.write(io.context,(const uint8_t*)"pending",7,40)==-BRIDGE_E_TIMEOUT);p->callbacks_forbidden=true;
    CHECK(!bridge_lwip_cleanup_complete(p->net));sys_sem_signal(&b.release);uint64_t deadline=clock_now()+2000;
    while(!bridge_lwip_cleanup_complete(p->net)){CHECK(clock_now()<deadline);sleep_ms(1);}
    CHECK(p->tcp[0].bytes==0);destroy_peer(p);sys_sem_free(&b.entered);sys_sem_free(&b.release);
    puts("PASS posted write acknowledgment timeout cancels deferred work before teardown");
}
static void no_op_core(void *ctx){(void)ctx;}
static void test_full_mailbox_shutdown(void){
    peer*p=open_peer();core_barrier b;CHECK(sys_sem_new(&b.entered,0)==ERR_OK&&sys_sem_new(&b.release,0)==ERR_OK);
    CHECK(tcpip_callback(block_core,&b)==ERR_OK);CHECK(sys_arch_sem_wait(&b.entered,1000)!=SYS_ARCH_TIMEOUT);
    unsigned count=0;while(tcpip_try_callback(no_op_core,NULL)==ERR_OK){CHECK(++count<1000);}
    CHECK(count>0);p->callbacks_forbidden=true;CHECK(bridge_lwip_shutdown(p->net)==BRIDGE_E_LIMIT);
    CHECK(bridge_lwip_destroy(p->net)==BRIDGE_E_LIMIT);CHECK(!bridge_lwip_cleanup_complete(p->net));sys_sem_signal(&b.release);
    destroy_peer(p);sys_sem_free(&b.entered);sys_sem_free(&b.release);
    puts("PASS full real tcpip callback mailbox cleanup retry without borrowed I/O");
}
typedef struct{sys_sem_t done;unsigned sent,limited;} tx_burst;
static void send_core_burst(void *ctx){
    tx_burst*b=ctx;ip_addr_t local,remote;CHECK(ipaddr_aton("2001:db8:1::2",&local));CHECK(ipaddr_aton("2001:db8:1::1",&remote));
    struct netif*n=netif_list;while(n&&!ip6_addr_cmp(netif_ip6_addr(n,0),ip_2_ip6(&local)))n=n->next;CHECK(n);
    struct udp_pcb*pcb=udp_new_ip_type(IPADDR_TYPE_V6);CHECK(pcb);CHECK(udp_bind(pcb,&local,21000)==ERR_OK);
    for(unsigned i=0;i<BRIDGE_LWIP_TX_PACKETS+4u;++i){
        struct pbuf*p=pbuf_alloc(PBUF_TRANSPORT,1,PBUF_RAM);CHECK(p);((uint8_t*)p->payload)[0]=(uint8_t)i;
        err_t e=udp_sendto_if_src(pcb,p,&remote,21001,n,&local);if(e==ERR_OK)++b->sent;else{CHECK(e==ERR_MEM);++b->limited;}pbuf_free(p);
    }
    udp_remove(pcb);sys_sem_signal(&b->done);
}
static void test_tx_backpressure(void){
    peer*p=open_peer();tx_burst burst={0};CHECK(sys_sem_new(&burst.done,0)==ERR_OK);
    CHECK(tcpip_callback(send_core_burst,&burst)==ERR_OK);CHECK(sys_arch_sem_wait(&burst.done,1000)!=SYS_ARCH_TIMEOUT);
    CHECK(burst.sent==BRIDGE_LWIP_TX_PACKETS&&burst.limited==4);CHECK(p->udp_packets==0);
    bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.tx_backpressure==4);pump(p,3);
    CHECK(p->udp_packets==BRIDGE_LWIP_TX_PACKETS);sys_sem_free(&burst.done);destroy_peer(p);
    puts("PASS bounded netif TX ring returns actual lwIP ERR_MEM under core packet burst");
}
static void test_receive_window_and_ring_wrap(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,22000);bridge_io io=bridge_lwip_tcp_io(&ch);peer_tcp*t=&p->tcp[0];
    uint8_t payload[1220],result[TCP_WND+8];for(size_t i=0;i<sizeof payload;++i)payload[i]=(uint8_t)i;
    size_t offset=0;while(offset<TCP_WND){size_t n=TCP_WND-offset;if(n>sizeof payload)n=sizeof payload;tcp_inject(p,t,t->remote_next+(uint32_t)offset,FLAG_ACK|FLAG_PSH,payload,n);offset+=n;}
    t->remote_next+=TCP_WND;uint64_t deadline=clock_now()+1000;size_t pending=0;
    do{pump(p,1);CHECK(clock_now()<deadline);CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_OK);}while(pending<TCP_WND||t->last_client_window!=0);
    tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_PSH,"Z",1);pump(p,5);CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_OK&&pending==TCP_WND);
    CHECK(io.read(io.context,result,TCP_WND/2,500)==TCP_WND/2);pump(p,5);CHECK(t->last_client_window>0);
    tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_PSH,"Z",1);++t->remote_next;pump(p,5);
    size_t got=TCP_WND/2;while(got<TCP_WND+1u){ptrdiff_t n=io.read(io.context,result+got,sizeof result-got,500);CHECK(n>0);got+=(size_t)n;}
    CHECK(got==TCP_WND+1u&&result[TCP_WND]=='Z');for(size_t i=0;i<TCP_WND;++i)CHECK(result[i]==payload[i%sizeof payload]);
    for(unsigned i=0;i<20;++i){tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_PSH,payload,sizeof payload);t->remote_next+=(uint32_t)sizeof payload;size_t total=0;while(total<sizeof payload){ptrdiff_t n=io.read(io.context,result+total,317,500);CHECK(n>0);total+=(size_t)n;}CHECK(total==sizeof payload&&!memcmp(result,payload,sizeof payload));}
    destroy_peer(p);puts("PASS real TCP zero receive window, credit reopening and receive-ring wraparound");
}
typedef struct{uint64_t heap,pools[MEMP_MAX];size_t netifs;struct netif*default_netif;} memory_snapshot;
static memory_snapshot snapshot_memory(void){
    memory_snapshot s={0};LOCK_TCPIP_CORE();s.heap=lwip_stats.mem.used;
    for(unsigned i=0;i<MEMP_MAX;++i)if(lwip_stats.memp[i])s.pools[i]=lwip_stats.memp[i]->used;
    for(struct netif*n=netif_list;n;n=n->next){++s.netifs;}s.default_netif=netif_default;
    UNLOCK_TCPIP_CORE();return s;
}
static void test_pool_cleanup(memory_snapshot before){
    /* Allow real periodic timers to retire their last TCP timeout entry. */
    sleep_ms(1100);memory_snapshot after=snapshot_memory();CHECK(after.heap==before.heap);
    CHECK(after.netifs==before.netifs&&after.default_netif==before.default_netif);
    for(unsigned i=0;i<MEMP_MAX;++i){if(before.pools[i]!=after.pools[i])fprintf(stderr,"pool %u before=%llu after=%llu\n",i,(unsigned long long)before.pools[i],(unsigned long long)after.pools[i]);CHECK(before.pools[i]==after.pools[i]);}
    printf("PASS lwIP heap/pool/netif baseline restored (%llu heap bytes)\n",(unsigned long long)after.heap);
}
static void test_policy_and_pending(void){
    peer*p=open_peer();bridge_lwip_tcp ch=connect_peer(p,18000);peer_tcp*t=&p->tcp[0];uint8_t packet[128];
    size_t n=tcp_packet(packet,t,t->remote_next,t->local_next,FLAG_ACK|FLAG_PSH,t->window,"evil",4);
    packet[23]^=8;put16(packet+56,0);put16(packet+56,checksum(packet,n));enqueue(p,packet,n);
    n=tcp_packet(packet,t,t->remote_next,t->local_next,FLAG_ACK|FLAG_PSH,t->window,"evil",4);
    packet[39]^=8;put16(packet+56,0);put16(packet+56,checksum(packet,n));enqueue(p,packet,n);pump(p,8);
    bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.rx_rejected==2);size_t pending=99;
    CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_OK&&pending==0);
    tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_PSH,"kept",4);t->remote_next+=4;
    tcp_inject(p,t,t->remote_next,FLAG_ACK|FLAG_FIN,NULL,0);pump(p,8);
    size_t reads=p->read_calls,polls=p->poll_calls,clocks=p->clock_calls;
    CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_OK&&pending==4);
    CHECK(p->read_calls==reads&&p->poll_calls==polls&&p->clock_calls==clocks);
    bridge_io io=bridge_lwip_tcp_io(&ch);CHECK(io.read(io.context,packet,sizeof packet,200)==4);CHECK(!memcmp(packet,"kept",4));
    CHECK(bridge_lwip_tcp_pending(&ch,&pending)==BRIDGE_E_EOF&&pending==0);destroy_peer(p);
    puts("PASS negotiated IPv6 source/destination policy and pending-before-EOF observation");
}
static void enqueue_udp_fragment(peer*p,unsigned part,int extension){
    uint8_t full[64];size_t full_size=ip_packet(full,17,24);put16(full+40,4444);put16(full+42,5555);put16(full+44,24);
    for(unsigned i=0;i<16;++i){full[48+i]=(uint8_t)('A'+i);}put16(full+46,checksum(full,full_size));
    size_t skip=part==1?16u:0u;size_t bytes=part==0?16u:part==1?8u:24u;
    size_t extension_size=extension<0?0u:extension==51?12u:8u;uint8_t packet[128];
    size_t size=ip_packet(packet,extension<0?44u:(uint8_t)extension,extension_size+8+bytes);
    size_t offset=40;if(extension>=0){packet[offset]=44;packet[offset+1]=(uint8_t)(extension==51?1:0);offset+=extension_size;}
    packet[offset]=17;put16(packet+offset+2,part==0?1u:part==1?16u:0u);put32(packet+offset+4,0x12345678u);
    memcpy(packet+offset+8,full+40+skip,bytes);enqueue(p,packet,size);
}
static void test_fragment_lifecycle_isolation(void){
    peer*p=open_peer();bridge_lwip_udp u={0};CHECK(bridge_lwip_udp_open(p->net,5555,4444,clock_now()+500,&u)==BRIDGE_OK);
    memory_snapshot before=snapshot_memory();enqueue_udp_fragment(p,0,-1);enqueue_udp_fragment(p,2,-1);
    const int extensions[]={0,43,60,51};for(size_t i=0;i<sizeof extensions/sizeof extensions[0];++i)enqueue_udp_fragment(p,0,extensions[i]);
    pump(p,16);bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.rx_rejected==6&&stats.udp_received==0);
    memory_snapshot after=snapshot_memory();CHECK(before.pools[MEMP_IP6_REASSDATA]==after.pools[MEMP_IP6_REASSDATA]);CHECK(before.pools[MEMP_PBUF_POOL]==after.pools[MEMP_PBUF_POOL]);
    uint8_t oversized[1233]={0};CHECK(bridge_lwip_udp_send(&u,4444,oversized,sizeof oversized,clock_now()+500)==BRIDGE_E_LIMIT);
    destroy_peer(p);p=open_peer();CHECK(bridge_lwip_udp_open(p->net,5555,4444,clock_now()+500,&u)==BRIDGE_OK);
    enqueue_udp_fragment(p,1,-1);enqueue_udp_fragment(p,1,0);uint8_t out[64];size_t n=0;uint16_t port=0;
    CHECK(bridge_lwip_udp_receive(&u,out,sizeof out,&n,&port,clock_now()+45)==BRIDGE_E_TIMEOUT);
    bridge_lwip_get_stats(p->net,&stats);CHECK(stats.rx_rejected==2&&stats.udp_received==0);
    udp_inject(p,4444,5555,"fresh",5,false);CHECK(bridge_lwip_udp_receive(&u,out,sizeof out,&n,&port,clock_now()+500)==BRIDGE_OK);CHECK(n==5&&!memcmp(out,"fresh",5));
    destroy_peer(p);puts("PASS fragment/atomic-fragment filtering, extension chains and cross-session reassembly isolation");
}
typedef struct{
    struct nd6_router_list_entry routers[LWIP_ND6_NUM_ROUTERS];
    uint32_t reachable,retrans;
} nd6_snapshot;
static nd6_snapshot snapshot_nd6(void){
    nd6_snapshot s={0};LOCK_TCPIP_CORE();memcpy(s.routers,default_router_list,sizeof s.routers);
    s.reachable=reachable_time;s.retrans=retrans_timer;UNLOCK_TCPIP_CORE();return s;
}
static void inject_neighbor_discovery(peer*p,uint8_t type,bool extension){
    const size_t sizes[]={8,16,24,24,40};CHECK(type>=133&&type<=137);size_t body=sizes[type-133];
    uint8_t packet[128];size_t offset=extension?48u:40u;size_t size=ip_packet(packet,extension?0u:58u,offset-40u+body);
    packet[7]=255;memcpy(packet+8,p->tunnel.parameters.server_address,16);memcpy(packet+24,p->tunnel.parameters.client_address,16);
    if(extension){packet[40]=58;packet[41]=0;}
    uint8_t*q=packet+offset;q[0]=type;
    if(type==134){q[4]=64;put16(q+6,1800);put32(q+8,43210);put32(q+12,1234);}
    if(type==135||type==136){memcpy(q+8,p->tunnel.parameters.server_address,16);if(type==136)put32(q+4,0x60000000u);}
    if(type==137){memcpy(q+8,p->tunnel.parameters.server_address,16);memcpy(q+24,p->tunnel.parameters.client_address,16);}
    put16(q+2,transport_checksum(packet,size,offset,58));CHECK(transport_checksum(packet,size,offset,58)==0);enqueue(p,packet,size);
}
static void test_link_local_router_isolation(void){
    nd6_snapshot original=snapshot_nd6();peer*p=open_peer_addresses(1280,"fe80::2","fe80::1");nd6_snapshot before=snapshot_nd6();
    CHECK(p->tunnel.parameters.client_address[0]==0xfe&&p->tunnel.parameters.client_address[1]==0x80);
    for(uint8_t type=133;type<=137;++type){inject_neighbor_discovery(p,type,false);inject_neighbor_discovery(p,type,true);}
    pump(p,24);nd6_snapshot after=snapshot_nd6();
    CHECK(before.reachable==after.reachable&&before.retrans==after.retrans);CHECK(!memcmp(before.routers,after.routers,sizeof before.routers));
    bridge_lwip_stats stats;bridge_lwip_get_stats(p->net,&stats);CHECK(stats.rx_rejected==10&&stats.rx_packets==0);
    /* Link-local addressing itself remains operational after rejecting ND6. */
    bridge_lwip_udp u={0};CHECK(bridge_lwip_udp_open(p->net,5555,4444,clock_now()+500,&u)==BRIDGE_OK);
    CHECK(bridge_lwip_udp_send(&u,4444,(const uint8_t*)"live",4,clock_now()+500)==BRIDGE_OK);pump(p,4);CHECK(p->udp_packets==1&&p->udp_bytes==4&&!memcmp(p->udp_data,"live",4));
    udp_inject(p,4444,5555,"safe",4,false);uint8_t out[8];size_t n=0;uint16_t port=0;CHECK(bridge_lwip_udp_receive(&u,out,sizeof out,&n,&port,clock_now()+500)==BRIDGE_OK);CHECK(n==4&&!memcmp(out,"safe",4));
    destroy_peer(p);after=snapshot_nd6();CHECK(original.reachable==after.reachable&&original.retrans==after.retrans);CHECK(!memcmp(original.routers,after.routers,sizeof original.routers));
    puts("PASS valid link-local RA/ND6 filtering preserves global routers/timers, including Hop headers");
}
int main(void){
    setvbuf(stdout,NULL,_IONBF,0);initialize_lwip();memory_snapshot baseline=snapshot_memory();test_stream_and_checksums();test_reassembly_duplicates_and_eof();
    test_reset_and_deadline();test_udp();test_udp_size_bounds();test_slots_and_stale_handles();
    test_retransmission_and_zero_window();test_transport_failure();test_shutdown_pending_core();test_policy_and_pending();test_create_timeout_and_full_mailbox();test_posted_write_timeout_cleanup();test_full_mailbox_shutdown();test_tx_backpressure();test_receive_window_and_ring_wrap();test_fragment_lifecycle_isolation();test_link_local_router_isolation();test_pool_cleanup(baseline);
    puts("Real lwIP packet tests passed");return 0;
}
