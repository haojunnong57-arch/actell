/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 * Synthetic peer tests. Golden VERSION/SETUP/SYN bytes independently transcribed
 * from usbmuxd 3ded00c9985a5108cfc7591a309f9a23d57a8cba src/device.c.
 * Directional inbound magic independently checked against demuxusb commit
 * 778f8cd0ffd1558be857c0d170ab5d8eacd89ba3, ext/usbmux.h.
 * No physical-device captures, credentials, libusbmuxd, or host socket daemon.
 */
#include "bridge_usbmux.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define ACK 0x10u
#define SYNACK 0x12u
#define RST 0x04u
#define COUNT 64u
static bridge_usbmux mux;
static struct {
    uint8_t packets[COUNT][BRIDGE_USBMUX_TX_FRAME];
    size_t sizes[COUNT], count, calls;
    bridge_status result;
} usb;
static uint8_t peer[BRIDGE_USBMUX_MAX_FRAME * 2u];
static uint8_t data[BRIDGE_USBMUX_MAX_FRAME], output[BRIDGE_USBMUX_MAX_FRAME];
static unsigned assertions;
#define CHECK(x) do { ++assertions; assert(x); } while (0)
#define OK(x) CHECK((x) == BRIDGE_OK)

static uint16_t get16(const uint8_t *p)
{ return (uint16_t)(((uint16_t)p[0] << 8) | p[1]); }
static uint32_t get32(const uint8_t *p)
{ return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static void u16(uint8_t *p, uint16_t x)
{ p[0] = (uint8_t)(x >> 8); p[1] = (uint8_t)x; }
static void u32(uint8_t *p, uint32_t x)
{ p[0] = (uint8_t)(x >> 24); p[1] = (uint8_t)(x >> 16); p[2] = (uint8_t)(x >> 8); p[3] = (uint8_t)x; }
static bridge_status send_packet(void *context, const uint8_t *p, size_t n)
{
    CHECK(context == &usb); CHECK(n <= BRIDGE_USBMUX_TX_FRAME);
    ++usb.calls;
    if (usb.result != BRIDGE_OK) return usb.result;
    CHECK(usb.count < COUNT);
    memcpy(usb.packets[usb.count], p, n); usb.sizes[usb.count++] = n;
    return BRIDGE_OK;
}
static void empty_usb(void) { usb.count = 0; }
static const uint8_t *last_tcp(void)
{ CHECK(usb.count != 0u); return usb.packets[usb.count - 1u] + (mux.version == 2u ? 16u : 8u); }
static size_t packet(uint8_t *p, unsigned version, uint32_t protocol,
    uint16_t remote, uint16_t local, uint32_t seq, uint32_t ack,
    uint8_t flags, uint16_t window, const uint8_t *body, size_t n)
{
    size_t h = version == 2u ? 16u : 8u;
    size_t total = h + (protocol == 6u ? 20u : 0u) + n;
    memset(p, 0, h + (protocol == 6u ? 20u : 0u));
    u32(p, protocol); u32(p + 4, (uint32_t)total);
    if (version == 2u) { u32(p + 8, 0xfacefaceu); u16(p + 12, 0x5a5a); u16(p + 14, 0x1234); }
    if (protocol == 6u) {
        uint8_t *t = p + h;
        u16(t, remote); u16(t + 2, local); u32(t + 4, seq); u32(t + 8, ack);
        t[12] = 0x50; t[13] = flags; u16(t + 14, window);
        h += 20u;
    }
    if (n != 0u) memcpy(p + h, body, n);
    return total;
}
static void version_reply(unsigned version, uint64_t now, bool fragmented)
{
    static const uint8_t literal[] = {0,0,0,0, 0,0,0,20, 0,0,0,2, 0,0,0,0, 0,0,0,0};
    uint8_t reply[20]; memcpy(reply, literal, 20); reply[11] = (uint8_t)version;
    if (fragmented) for (size_t i = 0; i < 20u; ++i) OK(bridge_usbmux_feed(&mux, reply + i, 1, now));
    else OK(bridge_usbmux_feed(&mux, reply, 20, now));
}
static void init(void)
{
    memset(&usb, 0, sizeof(usb));
    OK(bridge_usbmux_init(&mux, send_packet, &usb));
}
static void ready(unsigned version)
{
    init(); OK(bridge_usbmux_start(&mux, 0)); version_reply(version, 1, false);
    CHECK(bridge_usbmux_get_state(&mux) == BRIDGE_USBMUX_READY);
    empty_usb();
}
static bridge_usbmux_channel_id open_channel(uint16_t remote, uint32_t peer_seq, uint16_t window)
{
    bridge_usbmux_channel_id id;
    OK(bridge_usbmux_open(&mux, remote, 2, &id));
    uint16_t local = get16(last_tcp());
    size_t n = packet(peer, mux.version, 6, remote, local, peer_seq, 1, SYNACK, window, NULL, 0);
    OK(bridge_usbmux_feed(&mux, peer, n, 3));
    bridge_usbmux_channel_state state; bridge_usbmux_reason reason;
    OK(bridge_usbmux_channel_status(&mux, id, &state, &reason));
    CHECK(state == BRIDGE_USBMUX_CH_OPEN); CHECK(reason == BRIDGE_USBMUX_REASON_NONE);
    return id;
}
static void expect_reason(bridge_usbmux_channel_id id, bridge_usbmux_reason expected)
{
    bridge_usbmux_channel_state state; bridge_usbmux_reason reason;
    OK(bridge_usbmux_channel_status(&mux, id, &state, &reason));
    CHECK(state == BRIDGE_USBMUX_CH_CLOSED); CHECK(reason == expected);
}
static void receive_tcp(uint16_t remote, uint16_t local, uint32_t seq, uint32_t ack,
    uint8_t flags, uint16_t window, const uint8_t *body, size_t length, uint64_t now)
{
    size_t n = packet(peer, mux.version, 6, remote, local, seq, ack, flags, window, body, length);
    OK(bridge_usbmux_feed(&mux, peer, n, now));
}
static void test_golden_handshake_and_send(void)
{
    static const uint8_t version_golden[] = {
        0,0,0,0, 0,0,0,20, 0,0,0,2, 0,0,0,0, 0,0,0,0};
    static const uint8_t setup_golden[] = {
        0,0,0,2, 0,0,0,17, 0xfe,0xed,0xfa,0xce, 0,0,0xff,0xff, 7};
    static const uint8_t syn_golden[] = {
        0,0,0,6, 0,0,0,36, 0xfe,0xed,0xfa,0xce, 0,1,0xff,0xff,
        0,1,0xf2,0x7e, 0,0,0,0, 0,0,0,0, 0x50,2,0,32, 0,0,0,0};
    init(); OK(bridge_usbmux_start(&mux, 0));
    CHECK(usb.count == 1u && usb.sizes[0] == sizeof(version_golden));
    CHECK(memcmp(usb.packets[0], version_golden, sizeof(version_golden)) == 0);
    version_reply(2, 1, true);
    CHECK(usb.count == 2u && usb.sizes[1] == sizeof(setup_golden));
    CHECK(memcmp(usb.packets[1], setup_golden, sizeof(setup_golden)) == 0);
    bridge_usbmux_channel_id id; OK(bridge_usbmux_open(&mux, 62078, 2, &id));
    CHECK(usb.sizes[2] == sizeof(syn_golden));
    CHECK(memcmp(usb.packets[2], syn_golden, sizeof(syn_golden)) == 0);
    receive_tcp(62078, 1, 0, 1, SYNACK, 2, NULL, 0, 3);
    const uint8_t *t = last_tcp();
    CHECK(get32(t + 4) == 1u && get32(t + 8) == 1u && t[13] == ACK);
    CHECK(get16(usb.packets[3] + 12) == 2u);
    CHECK(get16(usb.packets[3] + 14) == 0x1234u); /* echo rx, not tx */
    memset(data, 0xab, 1000);
    size_t n; OK(bridge_usbmux_write(&mux, id, data, 700, &n, 4)); CHECK(n == 512u);
    t = last_tcp(); CHECK(get32(t + 4) == 1u && t[13] == ACK);
    CHECK(memcmp(t + 20, data, n) == 0);
    size_t sent = usb.count;
    OK(bridge_usbmux_write(&mux, id, data, 700, &n, 5)); CHECK(n == 0u && usb.count == sent);
    receive_tcp(62078, 1, 1, 513, ACK, 1, NULL, 0, 6);
    CHECK(usb.count == sent); /* ACK-only is not ACKed back forever */
    OK(bridge_usbmux_write(&mux, id, data, 700, &n, 7)); CHECK(n == 256u);
    receive_tcp(62078, 1, 1, 769, ACK, 32, NULL, 0, 8);
    usb.result = BRIDGE_E_LIMIT;
    uint16_t mux_seq = mux.tx_seq;
    OK(bridge_usbmux_write(&mux, id, data, 100, &n, 9)); CHECK(n == 0u && mux.tx_seq == mux_seq);
    usb.result = BRIDGE_OK;
    OK(bridge_usbmux_write(&mux, id, data, 100, &n, 10)); CHECK(n == 100u);
    CHECK(get32(last_tcp() + 4) == 769u);
    OK(bridge_usbmux_close(&mux, id, 11)); CHECK(last_tcp()[13] == RST);
    expect_reason(id, BRIDGE_USBMUX_REASON_LOCAL_CLOSE);
    CHECK(bridge_usbmux_read(&mux, id, output, 1, &n) == BRIDGE_E_EOF);
    OK(bridge_usbmux_release(&mux, id));
    CHECK(bridge_usbmux_read(&mux, id, output, 1, &n) == BRIDGE_E_NOT_FOUND);
}
static void test_v1_and_coalescing(void)
{
    ready(1); bridge_usbmux_channel_id id = open_channel(1234, 100, 65535);
    CHECK(usb.sizes[0] == 28u && usb.sizes[1] == 28u);
    CHECK(get32(last_tcp() + 8) == 101u);
    size_t a = packet(peer, 1, 1, 0,0,0,0,0,0, (const uint8_t *)"\7hello", 6);
    size_t b = packet(peer + a, 1, 6, 1234,1,101,1,ACK,8,(const uint8_t *)"abc",3);
    size_t c = packet(peer + a + b, 1, 6, 1234,1,104,1,ACK,8,(const uint8_t *)"defg",4);
    OK(bridge_usbmux_feed(&mux, peer, a + b + c, 4));
    size_t n; OK(bridge_usbmux_read(&mux, id, output, sizeof(output), &n));
    CHECK(n == 7u && memcmp(output, "abcdefg", 7) == 0);
    memset(data, 0xd3, sizeof(data));
    OK(bridge_usbmux_write(&mux, id, data, sizeof(data), &n, 5)); CHECK(n == 2048u); /* window=8 */
    receive_tcp(1234,1,108,2049,ACK,65535,NULL,0,6);
    OK(bridge_usbmux_write(&mux, id, data, sizeof(data), &n, 7)); CHECK(n == BRIDGE_USBMUX_TX_PAYLOAD);
    CHECK(usb.sizes[usb.count-1u] == BRIDGE_USBMUX_TX_PAYLOAD + 28u);
}
static void test_version_optional_bytes_and_coalescing(void)
{
    init(); OK(bridge_usbmux_start(&mux,0));
    memset(peer,0,24); u32(peer+4,24); u32(peer+8,2); u32(peer+12,99);
    u32(peer+16,0x01020304u); u32(peer+20,0x05060708u);
    size_t n=packet(peer+24,2,1,0,0,0,0,0,0,NULL,0);
    OK(bridge_usbmux_feed(&mux,peer,24u+n,1));
    CHECK(mux.state==BRIDGE_USBMUX_READY && mux.version==2u && mux.minor==99u);
    CHECK(mux.rx_seq==0x1234u);
}
static void test_receive_window_wrap_and_duplicates(void)
{
    ready(2); uint32_t initial = UINT32_MAX - 3u;
    bridge_usbmux_channel_id id = open_channel(62078, initial, 8);
    empty_usb();
    for (size_t i = 0; i < BRIDGE_USBMUX_RX_CAPACITY; ++i) data[i] = (uint8_t)i;
    size_t p = packet(peer, 2,6,62078,1,initial+1u,1,ACK,8,data,BRIDGE_USBMUX_RX_CAPACITY);
    for (size_t off = 0; off < p;) {
        size_t step = (off % 31u) + 1u; if (step > p - off) step = p - off;
        OK(bridge_usbmux_feed(&mux, peer + off, step, 4)); off += step;
    }
    CHECK(get16(last_tcp() + 14) == 0u);
    CHECK(get32(last_tcp() + 8) == initial + 1u + BRIDGE_USBMUX_RX_CAPACITY);
    /* A duplicate fills neither memory nor receive sequence. */
    OK(bridge_usbmux_feed(&mux, peer, p, 5)); CHECK(mux.channels[0].rx_size == BRIDGE_USBMUX_RX_CAPACITY);
    size_t n; OK(bridge_usbmux_read(&mux, id, output, 100, &n)); CHECK(n == 100u);
    OK(bridge_usbmux_tick(&mux, 6)); CHECK(get16(last_tcp() + 14) == 0u);
    OK(bridge_usbmux_read(&mux, id, output + 100, 156, &n)); CHECK(n == 156u);
    OK(bridge_usbmux_tick(&mux, 7)); CHECK(get16(last_tcp() + 14) == 1u);
    CHECK(memcmp(output, data, 256) == 0);
    uint32_t seq = initial + 1u + BRIDGE_USBMUX_RX_CAPACITY;
    memset(data + BRIDGE_USBMUX_RX_CAPACITY, 0xef, 256);
    receive_tcp(62078,1,seq,1,ACK,8,data + BRIDGE_USBMUX_RX_CAPACITY,256,8);
    CHECK(get16(last_tcp() + 14) == 0u);
    OK(bridge_usbmux_read(&mux, id, output, sizeof(output), &n)); CHECK(n == BRIDGE_USBMUX_RX_CAPACITY);
    CHECK(memcmp(output, data + 256, BRIDGE_USBMUX_RX_CAPACITY - 256u) == 0);
    CHECK(memcmp(output + BRIDGE_USBMUX_RX_CAPACITY - 256u, data + BRIDGE_USBMUX_RX_CAPACITY,256) == 0);
    OK(bridge_usbmux_tick(&mux, 9)); CHECK(get16(last_tcp() + 14) == 32u);
    /* Partial retransmission overlap delivers only new suffix. */
    uint32_t next = seq + 256u;
    receive_tcp(62078,1,next,1,ACK,8,(const uint8_t *)"abcd",4,10);
    receive_tcp(62078,1,next+2u,1,ACK,8,(const uint8_t *)"cdef",4,11);
    OK(bridge_usbmux_read(&mux,id,output,20,&n)); CHECK(n == 6u && memcmp(output,"abcdef",6) == 0);
}
static void test_unaligned_inflight_window(void)
{
    /* Original 8192-byte grant remains valid while ACK window rounding falls
     * by 255 bytes. Both packets may already be queued on the peer's USB side. */
    for (unsigned busy=0;busy<2u;++busy) {
        ready(2); bridge_usbmux_channel_id id=open_channel(123,0,8);
        memset(data,0xc7,BRIDGE_USBMUX_RX_CAPACITY);
        if (busy!=0u) usb.result=BRIDGE_E_LIMIT;
        receive_tcp(123,1,1,1,ACK,8,data,1,4);
        receive_tcp(123,1,2,1,ACK,8,data+1,BRIDGE_USBMUX_RX_CAPACITY-1u,5);
        CHECK(mux.channels[0].state==BRIDGE_USBMUX_CH_OPEN);
        size_t n; OK(bridge_usbmux_read(&mux,id,output,sizeof(output),&n));
        CHECK(n==BRIDGE_USBMUX_RX_CAPACITY && memcmp(output,data,n)==0);
        usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,6));
        CHECK(get16(last_tcp()+14)==32u);
    }
}
static void test_multiple_channels_and_resets(void)
{
    ready(2); bridge_usbmux_channel_id ids[5];
    for (uint16_t i = 0; i < 4u; ++i) ids[i] = open_channel((uint16_t)(5000u+i),0,8);
    CHECK(bridge_usbmux_open(&mux,6000,4,&ids[4]) == BRIDGE_E_LIMIT && ids[4] == 0u);
    CHECK(bridge_usbmux_release(&mux, ids[0]) == BRIDGE_E_UNSUPPORTED);
    receive_tcp(5002,3,1,1,ACK,8,(const uint8_t *)"channel3",8,4);
    size_t n; OK(bridge_usbmux_read(&mux,ids[0],output,20,&n)); CHECK(n == 0u);
    receive_tcp(5002,3,9,1,RST,0,(const uint8_t *)"reset reason\n",13,5);
    expect_reason(ids[2],BRIDGE_USBMUX_REASON_RESET);
    OK(bridge_usbmux_read(&mux,ids[2],output,20,&n)); CHECK(n == 8u && memcmp(output,"channel3",8) == 0);
    CHECK(bridge_usbmux_read(&mux,ids[2],output,20,&n) == BRIDGE_E_IO);
    OK(bridge_usbmux_release(&mux,ids[2]));
    OK(bridge_usbmux_open(&mux,6000,6,&ids[4])); CHECK(ids[4] != ids[2]);
    CHECK(get16(last_tcp()) == 5u);
    receive_tcp(6000,5,0,0,RST,0,NULL,0,7);
    expect_reason(ids[4],BRIDGE_USBMUX_REASON_REFUSED);
    size_t prior = usb.count;
    receive_tcp(7777,2345,123,0,RST,0,NULL,0,8); CHECK(usb.count == prior);
    receive_tcp(7777,2345,123,0,ACK,0,NULL,0,9); CHECK(usb.count == prior+1u);
    const uint8_t *t = last_tcp(); CHECK(get16(t)==2345u && get16(t+2)==7777u);
    CHECK(t[13] == RST && get32(t+8)==123u);
    bridge_usbmux_disconnect(&mux); CHECK(mux.state == BRIDGE_USBMUX_DEAD);
    expect_reason(ids[0],BRIDGE_USBMUX_REASON_DISCONNECTED);
    expect_reason(ids[1],BRIDGE_USBMUX_REASON_DISCONNECTED);
    expect_reason(ids[3],BRIDGE_USBMUX_REASON_DISCONNECTED);
    CHECK(bridge_usbmux_feed(&mux,NULL,0,10) == BRIDGE_E_IO);
}
static void test_queue_backpressure(void)
{
    init(); usb.result = BRIDGE_E_LIMIT;
    OK(bridge_usbmux_start(&mux,0)); CHECK(mux.state == BRIDGE_USBMUX_VERSION_PENDING && usb.count == 0u);
    OK(bridge_usbmux_tick(&mux,1)); CHECK(usb.count == 0u);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,2)); CHECK(mux.state == BRIDGE_USBMUX_WAIT_VERSION);
    usb.result=BRIDGE_E_LIMIT; version_reply(2,3,false);
    CHECK(mux.state == BRIDGE_USBMUX_SETUP_PENDING && mux.tx_seq == 0u);
    OK(bridge_usbmux_tick(&mux,4)); CHECK(mux.tx_seq == 0u);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,5)); CHECK(mux.state == BRIDGE_USBMUX_READY && mux.tx_seq == 1u);
    usb.result=BRIDGE_E_LIMIT; bridge_usbmux_channel_id id;
    OK(bridge_usbmux_open(&mux,62078,6,&id)); CHECK(mux.channels[0].state == BRIDGE_USBMUX_CH_SYN_PENDING);
    CHECK(mux.channels[0].tx_next == 0u && mux.tx_seq == 1u);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,7)); CHECK(mux.channels[0].state == BRIDGE_USBMUX_CH_SYN_SENT);
    usb.result=BRIDGE_E_LIMIT; receive_tcp(62078,1,0,1,SYNACK,32,NULL,0,8);
    CHECK(mux.channels[0].state == BRIDGE_USBMUX_CH_ACK_PENDING);
    size_t n; OK(bridge_usbmux_write(&mux,id,data,1,&n,9)); CHECK(n == 0u);
    usb.result=BRIDGE_OK; receive_tcp(62078,1,0,1,SYNACK,32,NULL,0,10);
    CHECK(mux.channels[0].state == BRIDGE_USBMUX_CH_OPEN);
    CHECK(last_tcp()[13] == ACK);
    usb.result=BRIDGE_E_LIMIT; receive_tcp(62078,1,1,1,ACK,32,(const uint8_t *)"hi",2,11);
    CHECK(mux.channels[0].ack_pending && mux.channels[0].rx_size == 2u);
    uint16_t tx = mux.tx_seq;
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,12)); CHECK(mux.tx_seq == (uint16_t)(tx+1u));
    CHECK(get32(last_tcp()+8)==3u);
    usb.result=BRIDGE_E_LIMIT; OK(bridge_usbmux_close(&mux,id,13));
    CHECK(mux.channels[0].state == BRIDGE_USBMUX_CH_CLOSING);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,14)); expect_reason(id,BRIDGE_USBMUX_REASON_LOCAL_CLOSE);
    OK(bridge_usbmux_read(&mux,id,output,10,&n)); CHECK(n==2u && memcmp(output,"hi",2)==0);
    CHECK(bridge_usbmux_read(&mux,id,output,10,&n)==BRIDGE_E_EOF);
    /* Unknown connection resets are bounded to one pending record. */
    usb.result=BRIDGE_E_LIMIT; receive_tcp(999,98,7,0,ACK,0,NULL,0,15);
    CHECK(mux.anonymous_reset_pending);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,16)); CHECK(!mux.anonymous_reset_pending);
}
static void test_duplicate_synack_after_progress(void)
{
    ready(2); bridge_usbmux_channel_id id=open_channel(123,99,32); size_t n;
    OK(bridge_usbmux_write(&mux,id,(const uint8_t *)"test",4,&n,4));
    receive_tcp(123,1,100,5,ACK,1,(const uint8_t *)"data",4,5);
    usb.result=BRIDGE_E_LIMIT;
    receive_tcp(123,1,99,1,SYNACK,65535,NULL,0,6);
    CHECK(mux.channels[0].state==BRIDGE_USBMUX_CH_OPEN && mux.channels[0].ack_pending);
    CHECK(mux.channels[0].tx_acked==5u && mux.channels[0].peer_window==256u);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,7));
    CHECK(get32(last_tcp()+4)==5u && get32(last_tcp()+8)==104u && last_tcp()[13]==ACK);
}
static void test_timeouts_and_transfer_errors(void)
{
    init(); OK(bridge_usbmux_start(&mux,0)); OK(bridge_usbmux_tick(&mux,4999));
    CHECK(bridge_usbmux_tick(&mux,5000)==BRIDGE_E_TIMEOUT);
    init(); usb.result=BRIDGE_E_LIMIT; OK(bridge_usbmux_start(&mux,0));
    CHECK(bridge_usbmux_tick(&mux,5000)==BRIDGE_E_TIMEOUT);
    ready(2); OK(bridge_usbmux_feed(&mux,(const uint8_t *)"\0",1,4));
    CHECK(bridge_usbmux_tick(&mux,5004)==BRIDGE_E_TIMEOUT);
    ready(2); bridge_usbmux_channel_id id; OK(bridge_usbmux_open(&mux,123,2,&id));
    OK(bridge_usbmux_tick(&mux,5002)); expect_reason(id,BRIDGE_USBMUX_REASON_TIMEOUT);
    CHECK(last_tcp()[13]==RST);
    ready(2); usb.result=BRIDGE_E_LIMIT; OK(bridge_usbmux_open(&mux,123,2,&id));
    OK(bridge_usbmux_tick(&mux,5002)); expect_reason(id,BRIDGE_USBMUX_REASON_TIMEOUT);
    ready(2); OK(bridge_usbmux_open(&mux,123,2,&id));
    usb.result=BRIDGE_E_LIMIT; receive_tcp(123,1,0,1,SYNACK,8,NULL,0,3);
    CHECK(mux.channels[0].state==BRIDGE_USBMUX_CH_ACK_PENDING);
    usb.result=BRIDGE_OK; OK(bridge_usbmux_tick(&mux,5002));
    expect_reason(id,BRIDGE_USBMUX_REASON_TIMEOUT);
    CHECK(last_tcp()[13]==RST);
    ready(2); id=open_channel(123,0,8); size_t n;
    OK(bridge_usbmux_write(&mux,id,(const uint8_t *)"abc",3,&n,4)); CHECK(n==3u);
    receive_tcp(123,1,1,2,ACK,8,NULL,0,4000); /* Partial ACK resets progress timer. */
    OK(bridge_usbmux_tick(&mux,8999)); CHECK(mux.channels[0].state==BRIDGE_USBMUX_CH_OPEN);
    OK(bridge_usbmux_tick(&mux,9000)); expect_reason(id,BRIDGE_USBMUX_REASON_TIMEOUT);
    ready(2); id=open_channel(123,0,0); empty_usb();
    OK(bridge_usbmux_write(&mux,id,data,10,&n,4)); CHECK(n==0u);
    OK(bridge_usbmux_tick(&mux,999999)); CHECK(mux.channels[0].state==BRIDGE_USBMUX_CH_OPEN);
    usb.result=BRIDGE_E_LIMIT; OK(bridge_usbmux_close(&mux,id,1000000));
    OK(bridge_usbmux_tick(&mux,1005000)); expect_reason(id,BRIDGE_USBMUX_REASON_TIMEOUT);
    init(); usb.result=BRIDGE_E_IO; CHECK(bridge_usbmux_start(&mux,0)==BRIDGE_E_IO);
    CHECK(bridge_usbmux_get_state(&mux)==BRIDGE_USBMUX_DEAD && bridge_usbmux_get_error(&mux)==BRIDGE_E_IO);
    ready(2); id=open_channel(123,0,8); usb.result=BRIDGE_E_IO;
    CHECK(bridge_usbmux_write(&mux,id,data,10,&n,4)==BRIDGE_E_IO && n==0u);
    expect_reason(id,BRIDGE_USBMUX_REASON_IO);
}
static void test_malformed_frames(void)
{
    const uint32_t lengths[] = {0,1,7,15,65537,UINT32_MAX};
    for (size_t i=0;i<sizeof(lengths)/sizeof(lengths[0]);++i) {
        ready(2); memset(peer,0,8); u32(peer+4,lengths[i]);
        bridge_status expected=lengths[i]>BRIDGE_USBMUX_MAX_FRAME?BRIDGE_E_LIMIT:BRIDGE_E_FORMAT;
        CHECK(bridge_usbmux_feed(&mux,peer,8,2)==expected); CHECK(mux.state==BRIDGE_USBMUX_DEAD);
    }
    ready(2); size_t n=packet(peer,2,1,0,0,0,0,0,0,NULL,0); peer[8]^=1;
    CHECK(bridge_usbmux_feed(&mux,peer,n,2)==BRIDGE_E_FORMAT);
    ready(2); n=packet(peer,2,1,0,0,0,0,0,0,NULL,0); u32(peer+8,0xfeedfaceu);
    CHECK(bridge_usbmux_feed(&mux,peer,n,2)==BRIDGE_E_FORMAT); /* wrong direction */
    ready(2); n=packet(peer,2,99,0,0,0,0,0,0,NULL,0);
    CHECK(bridge_usbmux_feed(&mux,peer,n,2)==BRIDGE_E_UNSUPPORTED);
    ready(2); n=packet(peer,2,2,0,0,0,0,0,0,(const uint8_t *)"\7",1);
    CHECK(bridge_usbmux_feed(&mux,peer,n,2)==BRIDGE_E_UNSUPPORTED);
    init(); OK(bridge_usbmux_start(&mux,0));
    memset(peer,0,20); u32(peer+4,20); u32(peer+8,3);
    CHECK(bridge_usbmux_feed(&mux,peer,20,1)==BRIDGE_E_UNSUPPORTED);
    init(); OK(bridge_usbmux_start(&mux,0)); u32(peer+8,2); u32(peer+4,19);
    CHECK(bridge_usbmux_feed(&mux,peer,19,1)==BRIDGE_E_FORMAT);
    init(); OK(bridge_usbmux_start(&mux,0));
    n=packet(peer,1,6,1,1,0,0,ACK,1,NULL,0);
    CHECK(bridge_usbmux_feed(&mux,peer,n,1)==BRIDGE_E_FORMAT);
    init(); OK(bridge_usbmux_start(&mux,0));
    memset(peer,0,20); u32(peer+4,20); u32(peer+8,1);
    CHECK(bridge_usbmux_feed(&mux,peer,20,5000)==BRIDGE_E_TIMEOUT); /* late reply */
    for (unsigned off=0;off<3u;++off) {
        ready(2); (void)open_channel(123,0,8);
        n=packet(peer,2,6,123,1,1,1,ACK,8,NULL,0);
        peer[28]=(uint8_t)(off==0u?0x40u:off==1u?0x60u:0x51u);
        CHECK(bridge_usbmux_feed(&mux,peer,n,4)==BRIDGE_E_FORMAT);
    }
    ready(2); n=packet(peer,2,6,123,1,1,1,ACK,8,NULL,0); u32(peer+4,35);
    CHECK(bridge_usbmux_feed(&mux,peer,35,4)==BRIDGE_E_FORMAT);
    /* Exactly 64 KiB diagnostic frame, arbitrary fragmentation, then next frame. */
    ready(2); memset(data,0xa5,sizeof(data));
    n=packet(peer,2,1,0,0,0,0,0,0,data,BRIDGE_USBMUX_MAX_FRAME-16u);
    CHECK(n==BRIDGE_USBMUX_MAX_FRAME);
    OK(bridge_usbmux_feed(&mux,peer,12345,2));
    OK(bridge_usbmux_feed(&mux,peer+12345,n-12345,3)); CHECK(mux.state==BRIDGE_USBMUX_READY);
    /* Full-size TCP input cannot overrun a channel's 8 KiB advertised capacity. */
    bridge_usbmux_channel_id id=open_channel(123,0,8);
    receive_tcp(123,1,1,1,ACK,8,data,BRIDGE_USBMUX_MAX_FRAME-36u,4);
    expect_reason(id,BRIDGE_USBMUX_REASON_OVERFLOW);
}
static void test_bad_channel_states(void)
{
    for (unsigned which=0;which<4u;++which) {
        ready(2); bridge_usbmux_channel_id id=open_channel(123,0,8);
        receive_tcp(123,1,which==0u?2u:which==3u?99u:1u,which==1u?2u:1u,
            (uint8_t)(which==2u?0x11u:which==3u?SYNACK:ACK),8,NULL,0,4);
        expect_reason(id,BRIDGE_USBMUX_REASON_PROTOCOL);
    }
    for (unsigned which=0;which<3u;++which) {
        ready(2); bridge_usbmux_channel_id id; OK(bridge_usbmux_open(&mux,123,2,&id));
        receive_tcp(123,1,0,which==0u?0u:1u,(uint8_t)(which==1u?ACK:SYNACK),8,
            which==2u?(const uint8_t *)"x":NULL,which==2u?1u:0u,3);
        expect_reason(id,BRIDGE_USBMUX_REASON_PROTOCOL);
    }
    ready(2); bridge_usbmux_channel_id id=open_channel(123,0,8);
    receive_tcp(123,1,1,1,ACK,8,data,BRIDGE_USBMUX_RX_CAPACITY,4);
    receive_tcp(123,1,1u+BRIDGE_USBMUX_RX_CAPACITY,1,ACK,8,data,1,5);
    expect_reason(id,BRIDGE_USBMUX_REASON_OVERFLOW);
    /* Reordered old ACK must not regress the bytes acknowledged or window. */
    ready(2); id=open_channel(123,0,8); size_t n;
    OK(bridge_usbmux_write(&mux,id,data,100,&n,4));
    receive_tcp(123,1,1,101,ACK,1,NULL,0,5);
    receive_tcp(123,1,1,1,ACK,65535,NULL,0,6);
    CHECK(mux.channels[0].tx_acked==101u && mux.channels[0].peer_window==256u);
    /* Explicit white-box boundary: 32-bit send sequence wrap. */
    mux.channels[0].tx_next=UINT32_MAX-1u; mux.channels[0].tx_acked=UINT32_MAX-1u;
    OK(bridge_usbmux_write(&mux,id,data,4,&n,7)); CHECK(n==4u && mux.channels[0].tx_next==2u);
    receive_tcp(123,1,1,2,ACK,8,NULL,0,8); CHECK(mux.channels[0].tx_acked==2u);
    /* Explicit white-box boundary: 16-bit mux sequence wraps on successful TX. */
    mux.tx_seq=UINT16_MAX; OK(bridge_usbmux_write(&mux,id,data,1,&n,9)); CHECK(mux.tx_seq==0u);
}
static void test_arguments_and_limits(void)
{
    size_t n=123; bridge_usbmux_channel_id id=99;
    CHECK(bridge_usbmux_init(NULL,send_packet,&usb)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_usbmux_init(&mux,NULL,&usb)==BRIDGE_E_ARGUMENT);
    init(); CHECK(bridge_usbmux_feed(&mux,NULL,0,0)==BRIDGE_E_UNSUPPORTED);
    CHECK(bridge_usbmux_open(&mux,123,0,&id)==BRIDGE_E_UNSUPPORTED && id==0u);
    CHECK(bridge_usbmux_open(&mux,0,0,&id)==BRIDGE_E_ARGUMENT);
    OK(bridge_usbmux_start(&mux,0)); CHECK(bridge_usbmux_start(&mux,0)==BRIDGE_E_UNSUPPORTED);
    CHECK(bridge_usbmux_feed(&mux,NULL,1,0)==BRIDGE_E_ARGUMENT);
    OK(bridge_usbmux_feed(&mux,NULL,0,0));
    version_reply(2,1,false); id=open_channel(123,0,8);
    CHECK(bridge_usbmux_write(&mux,id,NULL,1,&n,4)==BRIDGE_E_ARGUMENT && n==0u);
    CHECK(bridge_usbmux_read(&mux,id,NULL,1,&n)==BRIDGE_E_ARGUMENT && n==0u);
    OK(bridge_usbmux_read(&mux,id,NULL,0,&n)); CHECK(n==0u);
    OK(bridge_usbmux_write(&mux,id,NULL,0,&n,4)); CHECK(n==0u);
    CHECK(bridge_usbmux_close(&mux,0,4)==BRIDGE_E_NOT_FOUND);
    CHECK(bridge_usbmux_release(&mux,999)==BRIDGE_E_NOT_FOUND);
    CHECK(bridge_usbmux_channel_status(&mux,id,NULL,NULL)==BRIDGE_E_ARGUMENT);
    /* Exhaustion must not silently reuse a port from a released connection. */
    mux.next_port=UINT16_MAX; bridge_usbmux_channel_id second;
    OK(bridge_usbmux_open(&mux,456,4,&second)); CHECK(get16(last_tcp())==UINT16_MAX);
    CHECK(bridge_usbmux_open(&mux,789,4,&id)==BRIDGE_E_LIMIT);
}
static uint32_t random_word(uint32_t *state)
{
    *state ^= *state << 13; *state ^= *state >> 17; *state ^= *state << 5;
    return *state;
}
static void test_seeded_malformed_input(void)
{
    uint32_t rng=0x46ae2d73u;
    /* Many bounded, reproducible malformed frames/fragment splits under ASAN. */
    for (size_t iteration=0;iteration<1500u;++iteration) {
        ready(2); (void)open_channel(123,0,32); empty_usb();
        size_t n=36u+(random_word(&rng)%129u);
        for (size_t i=0;i<n;++i) peer[i]=(uint8_t)random_word(&rng);
        u32(peer+4,(uint32_t)n);
        if (iteration%2u==0u) {u32(peer,6);u32(peer+8,0xfacefaceu);}
        if (iteration%3u==0u) {u16(peer+16,123);u16(peer+18,1);peer[28]=0x50;}
        size_t off=0;
        while(off<n) {
            size_t step=1u+(random_word(&rng)%23u); if(step>n-off)step=n-off;
            bridge_status result=bridge_usbmux_feed(&mux,peer+off,step,4);
            if(result!=BRIDGE_OK) {CHECK(mux.state==BRIDGE_USBMUX_DEAD);break;}
            off+=step;
        }
    }
}
int main(void)
{
    test_golden_handshake_and_send();
    test_v1_and_coalescing();
    test_version_optional_bytes_and_coalescing();
    test_receive_window_wrap_and_duplicates();
    test_unaligned_inflight_window();
    test_multiple_channels_and_resets();
    test_queue_backpressure();
    test_duplicate_synack_after_progress();
    test_timeouts_and_transfer_errors();
    test_malformed_frames();
    test_bad_channel_states();
    test_arguments_and_limits();
    test_seeded_malformed_input();
    printf("usbmux: %u checks passed; context=%zu bytes; synthetic peer only\n",assertions,sizeof(bridge_usbmux));
    return 0;
}
