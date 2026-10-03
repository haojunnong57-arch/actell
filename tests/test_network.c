/* SPDX-License-Identifier: GPL-3.0-or-later
 * Binding/lifetime tests only: lwIP and RSD API boundaries are controlled fakes.
 * The actual lwIP wire stack and actual RSD protocol each have separate suites.
 */
#include "bridge_network.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
struct bridge_lwip_net {bool stopped;};
static struct {struct bridge_lwip_net net;uint64_t now;unsigned clocks,polls,shutdowns,destroy_calls,dials,closes,drains,rsd_pumps;bool create_fail,dial_fail,close_fail,rsd_fail,readable,no_borrowed;unsigned pending_cleanup;} sim;
static uint64_t clock_ms(void *context) {(void)context;assert(!sim.no_borrowed);sim.clocks++;return sim.now;}
static ptrdiff_t rd(void *c,uint8_t *b,size_t n,uint32_t t) {(void)c;(void)b;(void)n;(void)t;return -BRIDGE_E_TIMEOUT;}
static ptrdiff_t wr(void *c,const uint8_t *b,size_t n,uint32_t t) {(void)c;(void)b;(void)t;return (ptrdiff_t)n;}
void sys_msleep(unsigned int ms) {sim.now+=ms;}
bridge_status bridge_lwip_create(const bridge_packet_link *link,bridge_lwip_net **out,uint64_t deadline) {(void)link;assert(deadline>sim.now);*out=&sim.net;return sim.create_fail?BRIDGE_E_TIMEOUT:BRIDGE_OK;}
bridge_status bridge_lwip_poll(bridge_lwip_net *n,uint64_t d) {assert(n==&sim.net && !n->stopped && d>sim.now);sim.polls++;sim.now++;return BRIDGE_OK;}
bridge_status bridge_lwip_tcp_connect(bridge_lwip_net *n,uint16_t port,uint64_t d,bridge_lwip_tcp *out) {assert(port && d>sim.now && !n->stopped);sim.dials++;*out=(bridge_lwip_tcp){n,sim.dials,sim.dials-1};return sim.dial_fail?BRIDGE_E_IO:BRIDGE_OK;}
bridge_io bridge_lwip_tcp_io(bridge_lwip_tcp *t) {return (bridge_io){t,rd,wr,clock_ms};}
bridge_status bridge_lwip_tcp_close(bridge_lwip_tcp *t,uint64_t d) {assert(d>sim.now && !sim.net.stopped);sim.closes++;if(sim.close_fail)return BRIDGE_E_TIMEOUT;t->net=NULL;return BRIDGE_OK;}
bridge_status bridge_lwip_tcp_pending(const bridge_lwip_tcp *t,size_t *bytes) {assert(t->net && !sim.net.stopped);*bytes=sim.readable?9u:0u;return BRIDGE_OK;}
bridge_status bridge_lwip_tcp_drain(bridge_lwip_tcp *t,uint64_t d) {assert(t->net && d>sim.now);sim.drains++;return BRIDGE_OK;}
bridge_status bridge_lwip_shutdown(bridge_lwip_net *n) {assert(n==&sim.net);n->stopped=true;sim.shutdowns++;sim.no_borrowed=true;return BRIDGE_OK;}
bridge_status bridge_lwip_destroy(bridge_lwip_net *n) {assert(n==&sim.net && n->stopped);sim.destroy_calls++;if(sim.pending_cleanup) {sim.pending_cleanup--;return BRIDGE_E_TIMEOUT;}return BRIDGE_OK;}
bridge_status bridge_rsd_init(bridge_rsd *r,const bridge_rsd_dialer *d,const uint8_t address[16],uint16_t port) {memset(r,0,sizeof *r);r->dialer=*d;memcpy(r->server_ipv6,address,16);r->rsd_port=port;return BRIDGE_OK;}
bridge_status bridge_rsd_connect(bridge_rsd *r,const uint8_t uuid[16],uint8_t *scratch,size_t capacity,uint64_t deadline) {(void)uuid;(void)scratch;(void)capacity;bridge_status s=r->dialer.dial(r->dialer.context,r->server_ipv6,r->rsd_port,deadline,&r->control_io);if(s!=BRIDGE_OK)return s;r->control_open=true;r->state=BRIDGE_RSD_READY;return sim.rsd_fail?BRIDGE_E_FORMAT:BRIDGE_OK;}
void bridge_rsd_close(bridge_rsd *r) {if(r->control_open)r->dialer.close(r->dialer.context,&r->control_io);r->control_open=false;r->state=BRIDGE_RSD_CLOSED;}
bridge_status bridge_rsd_pump(bridge_rsd *r,uint64_t deadline) {assert(r->control_open && deadline>sim.now);sim.rsd_pumps++;sim.readable=false;return BRIDGE_OK;}
int main(void) {
    uint8_t uuid[16]={1},scratch[64];bridge_cdtunnel tunnel={0};tunnel.parameters.server_address[0]=0xfd;tunnel.parameters.server_rsd_port=1234;bridge_packet_link link={.tunnel=&tunnel};
    for(unsigned scenario=0;scenario<5;scenario++) {
        memset(&sim,0,sizeof sim);sim.now=1;sim.pending_cleanup=2;
        sim.create_fail=scenario==1;sim.dial_fail=scenario==2;sim.rsd_fail=scenario==3;sim.close_fail=scenario==4;
        bridge_network network={0};bridge_status s=bridge_network_start(&network,&link,uuid,scratch,sizeof scratch,10000);
        bridge_lwip_net *saved=network.net;
        assert(bridge_network_start(&network,&link,uuid,scratch,sizeof scratch,10000)==BRIDGE_E_ARGUMENT && network.net==saved);
        if(scenario==0 || scenario==4) {
            assert(s==BRIDGE_OK && network.ready);
            assert(bridge_network_poll(&network,10000)==BRIDGE_OK && !sim.rsd_pumps);
            sim.readable=true;assert(bridge_network_poll(&network,10000)==BRIDGE_OK && sim.rsd_pumps==1);
            unsigned control_pumps=sim.rsd_pumps;sim.readable=true;
            uint64_t before=sim.now;assert(bridge_network_wait(&network,50,10000)==BRIDGE_OK && sim.now-before>=50);
            assert(sim.rsd_pumps==control_pumps); /* partial control data cannot prolong Home hold */
            bridge_io service={0};assert(network.rsd.dialer.dial(network.rsd.dialer.context,network.server_address,2345,10000,&service)==BRIDGE_OK);
            assert(network.rsd.dialer.drain(network.rsd.dialer.context,&service,10000)==BRIDGE_OK && sim.drains==1);
            network.rsd.dialer.close(network.rsd.dialer.context,&service);
            if(scenario==4)assert(network.stopping && network.failure==BRIDGE_E_TIMEOUT);
            uint8_t wrong[16]={1};assert(network.rsd.dialer.dial(network.rsd.dialer.context,wrong,1,10000,&service)==BRIDGE_E_ARGUMENT);
        } else assert(s!=BRIDGE_OK && network.stopping && !network.ready);
        unsigned clocks=sim.clocks,polls=sim.polls;
        assert(bridge_network_close(&network)==BRIDGE_E_TIMEOUT);
        assert(bridge_network_start(&network,&link,uuid,scratch,sizeof scratch,10000)==BRIDGE_E_ARGUMENT && network.net==saved);
        assert(bridge_network_close(&network)==BRIDGE_E_TIMEOUT);
        assert(bridge_network_close(&network)==BRIDGE_OK && !network.net);
        assert(bridge_network_close(&network)==BRIDGE_OK);
        assert(sim.clocks==clocks && sim.polls==polls && !network.rsd.control_open);
    }
    puts("PASS: real network binding ownership/mapping, pending-only RSD pump, ACK-drain forwarding, partial create/dial/close faults and repeated deferred cleanup without borrowed callbacks");
    puts("This suite uses synthetic API boundaries; separate suites execute actual lwIP and RSD protocols.");
}
