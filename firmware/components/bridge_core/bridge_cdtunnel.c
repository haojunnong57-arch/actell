/* SPDX-License-Identifier: GPL-3.0-or-later
 * Independently implemented from pymobiledevice3 at
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1: remote/tunnel_service.py
 * CDTunnelPacket, RemotePairingTcpTunnel, CoreDeviceTunnelProxy; and the public
 * schema in misc/RemoteXPC.md. No authentication or IP stack is implemented.
 */
#include "bridge_cdtunnel.h"
#include <string.h>

#define TRY(expression) do { bridge_status status_ = (expression); \
    if (status_ != BRIDGE_OK) return status_; } while (0)
static const uint8_t magic[8] = {'C','D','T','u','n','n','e','l'};
typedef struct { const uint8_t *bytes; size_t size, pos; } json_cursor;

static void whitespace(json_cursor *c) {
    while (c->pos < c->size) {
        uint8_t ch = c->bytes[c->pos];
        if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') break;
        ++c->pos;
    }
}
static bool consume(json_cursor *c, uint8_t ch) {
    whitespace(c);
    if (c->pos == c->size || c->bytes[c->pos] != ch) return false;
    ++c->pos;
    return true;
}
static int hex_digit(uint8_t ch) {
    if (ch >= '0' && ch <= '9') return (int)(ch - '0');
    if (ch >= 'a' && ch <= 'f') return (int)(ch - 'a') + 10;
    if (ch >= 'A' && ch <= 'F') return (int)(ch - 'A') + 10;
    return -1;
}
/* The entire supported schema is ASCII. Decode escapes BEFORE matching keys,
 * so alternate escaped spellings cannot evade duplicate detection. Embedded
 * NUL/control/non-ASCII characters cannot belong to any accepted schema value.
 */
static bridge_status string_value(json_cursor *c, char *out, size_t capacity) {
    if (!consume(c, '"')) return BRIDGE_E_FORMAT;
    size_t used = 0;
    while (c->pos < c->size) {
        uint8_t ch = c->bytes[c->pos++];
        if (ch == '"') { out[used] = '\0'; return BRIDGE_OK; }
        if (ch == '\\') {
            if (c->pos == c->size) return BRIDGE_E_FORMAT;
            ch = c->bytes[c->pos++];
            if (ch == 'u') {
                if (c->size - c->pos < 4) return BRIDGE_E_FORMAT;
                unsigned value = 0;
                for (unsigned i = 0; i < 4; ++i) {
                    int digit = hex_digit(c->bytes[c->pos++]);
                    if (digit < 0) return BRIDGE_E_FORMAT;
                    value = (value << 4) | (unsigned)digit;
                }
                if (value < 0x20u || value > 0x7eu) return BRIDGE_E_FORMAT;
                ch = (uint8_t)value;
            } else if (ch != '"' && ch != '\\' && ch != '/') return BRIDGE_E_FORMAT;
        }
        if (ch < 0x20u || ch > 0x7eu) return BRIDGE_E_FORMAT;
        if (used == capacity - 1u) return BRIDGE_E_LIMIT;
        out[used++] = (char)ch;
    }
    return BRIDGE_E_FORMAT;
}
static bridge_status integer_value(json_cursor *c, uint32_t *out) {
    whitespace(c);
    if (c->pos == c->size || c->bytes[c->pos] < '0' || c->bytes[c->pos] > '9')
        return BRIDGE_E_FORMAT;
    size_t start = c->pos;
    uint32_t value = 0;
    while (c->pos < c->size && c->bytes[c->pos] >= '0' && c->bytes[c->pos] <= '9') {
        uint32_t digit = (uint32_t)(c->bytes[c->pos++] - '0');
        if (value > (UINT32_MAX - digit) / 10u) return BRIDGE_E_LIMIT;
        value = value * 10u + digit;
    }
    if (c->pos - start > 1u && c->bytes[start] == '0') return BRIDGE_E_FORMAT;
    *out = value;
    return BRIDGE_OK;
}
static bridge_status ipv4_tail(const char *text, size_t size, uint8_t out[4]) {
    size_t pos = 0;
    for (size_t i = 0; i < 4; ++i) {
        size_t start = pos;
        unsigned value = 0;
        while (pos < size && text[pos] >= '0' && text[pos] <= '9') {
            value = value * 10u + (unsigned)(text[pos++] - '0');
            if (value > 255u || pos - start > 3u) return BRIDGE_E_FORMAT;
        }
        if (pos == start || (pos - start > 1u && text[start] == '0')) return BRIDGE_E_FORMAT;
        out[i] = (uint8_t)value;
        if (i < 3u && (pos == size || text[pos++] != '.')) return BRIDGE_E_FORMAT;
    }
    return pos == size ? BRIDGE_OK : BRIDGE_E_FORMAT;
}
/* Bounded inet_pton-like parser without OS/lwIP dependencies. Accepts one ::,
 * 1..4-digit groups, and a final dotted IPv4 tail. No DNS, brackets, or zone IDs.
 */
static bridge_status ipv6_address(const char *text, uint8_t out[16]) {
    size_t length = strlen(text), pos = 0, count = 0, compressed = 9;
    uint16_t groups[8] = {0};
    if (!length || length >= BRIDGE_CDTUNNEL_ADDRESS_CAPACITY) return BRIDGE_E_FORMAT;
    if (text[0] == ':') {
        if (length < 2 || text[1] != ':') return BRIDGE_E_FORMAT;
        compressed = 0; pos = 2;
    }
    while (pos < length) {
        size_t start = pos;
        bool dotted = false;
        while (pos < length && text[pos] != ':') {
            if (text[pos] == '.') dotted = true;
            ++pos;
        }
        size_t size = pos - start;
        if (!size || count == 8u) return BRIDGE_E_FORMAT;
        if (dotted) {
            if (pos != length || count > 6u) return BRIDGE_E_FORMAT;
            uint8_t tail[4];
            TRY(ipv4_tail(text + start, size, tail));
            groups[count++] = (uint16_t)((uint16_t)tail[0] << 8 | tail[1]);
            groups[count++] = (uint16_t)((uint16_t)tail[2] << 8 | tail[3]);
        } else {
            if (size > 4u) return BRIDGE_E_FORMAT;
            unsigned value = 0;
            for (size_t i = start; i < pos; ++i) {
                int digit = hex_digit((uint8_t)text[i]);
                if (digit < 0) return BRIDGE_E_FORMAT;
                value = (value << 4) | (unsigned)digit;
            }
            groups[count++] = (uint16_t)value;
        }
        if (pos < length) {
            ++pos;
            if (pos == length) return BRIDGE_E_FORMAT;
            if (text[pos] == ':') {
                if (compressed != 9u) return BRIDGE_E_FORMAT;
                compressed = count; ++pos;
            }
        }
    }
    if (compressed == 9u) {
        if (count != 8u) return BRIDGE_E_FORMAT;
    } else {
        if (count >= 8u) return BRIDGE_E_FORMAT;
        size_t gap = 8u - count;
        for (size_t i = count; i > compressed; --i) groups[i - 1u + gap] = groups[i - 1u];
        for (size_t i = compressed; i < compressed + gap; ++i) groups[i] = 0;
    }
    for (size_t i = 0; i < 8; ++i) {
        out[i * 2u] = (uint8_t)(groups[i] >> 8);
        out[i * 2u + 1u] = (uint8_t)groups[i];
    }
    return BRIDGE_OK;
}
static bool unicast_address(const uint8_t address[16]) {
    bool any = false;
    for (size_t i = 0; i < 16; ++i) any = any || address[i] != 0;
    /* Loopback and IPv4-mapped endpoints cannot identify a remote IPv6 tunnel. */
    bool prefix_zero = true;
    for (size_t i = 0; i < 10; ++i) prefix_zero = prefix_zero && address[i] == 0;
    bool mapped = prefix_zero && address[10] == 0xffu && address[11] == 0xffu;
    bool loopback = prefix_zero && address[10] == 0 && address[11] == 0 &&
        address[12] == 0 && address[13] == 0 && address[14] == 0 && address[15] == 1;
    return any && address[0] != 0xffu && !mapped && !loopback;
}
static bridge_status mask_prefix(const uint8_t mask[16], uint8_t *prefix) {
    bool zero_seen = false;
    unsigned count = 0;
    for (size_t i = 0; i < 16; ++i) {
        for (unsigned bit = 0; bit < 8; ++bit) {
            bool one = (mask[i] & (uint8_t)(0x80u >> bit)) != 0;
            if (one && zero_seen) return BRIDGE_E_FORMAT;
            if (one) ++count; else zero_seen = true;
        }
    }
    *prefix = (uint8_t)count;
    return BRIDGE_OK;
}
/* Schema-only object parsing means no recursion, dynamic tokens, unknown values,
 * or arbitrary nested objects. Maximum two objects and seven members total.
 */
static bridge_status client_parameters(json_cursor *c, uint16_t requested,
    bridge_cdtunnel_parameters *result) {
    if (!consume(c, '{')) return BRIDGE_E_FORMAT;
    unsigned seen = 0;
    if (consume(c, '}')) return BRIDGE_E_NOT_FOUND;
    for (;;) {
        char key[24];
        TRY(string_value(c, key, sizeof key));
        if (!consume(c, ':')) return BRIDGE_E_FORMAT;
        unsigned bit;
        if (!strcmp(key, "address")) bit = 1u;
        else if (!strcmp(key, "mtu")) bit = 2u;
        else if (!strcmp(key, "netmask")) bit = 4u;
        else return BRIDGE_E_UNSUPPORTED;
        if (seen & bit) return BRIDGE_E_FORMAT;
        seen |= bit;
        if (bit == 1u) {
            TRY(string_value(c, result->client_address_text, sizeof result->client_address_text));
            TRY(ipv6_address(result->client_address_text, result->client_address));
            if (!unicast_address(result->client_address)) return BRIDGE_E_FORMAT;
        } else if (bit == 2u) {
            uint32_t value;
            TRY(integer_value(c, &value));
            if (value < BRIDGE_CDTUNNEL_MIN_MTU || value > requested) return BRIDGE_E_LIMIT;
            result->mtu = (uint16_t)value;
        } else {
            char text[BRIDGE_CDTUNNEL_ADDRESS_CAPACITY];
            TRY(string_value(c, text, sizeof text));
            TRY(ipv6_address(text, result->netmask));
            TRY(mask_prefix(result->netmask, &result->prefix_length));
            result->has_netmask = true;
        }
        if (consume(c, '}')) break;
        if (!consume(c, ',')) return BRIDGE_E_FORMAT;
    }
    return (seen & 3u) == 3u ? BRIDGE_OK : BRIDGE_E_NOT_FOUND;
}
static bridge_status response_parameters(const uint8_t *bytes, size_t size,
    uint16_t requested, bridge_cdtunnel_parameters *result) {
    json_cursor c = {.bytes = bytes, .size = size};
    if (!consume(&c, '{')) return BRIDGE_E_FORMAT;
    unsigned seen = 0;
    if (consume(&c, '}')) return BRIDGE_E_NOT_FOUND;
    for (;;) {
        char key[24];
        TRY(string_value(&c, key, sizeof key));
        if (!consume(&c, ':')) return BRIDGE_E_FORMAT;
        unsigned bit;
        if (!strcmp(key, "clientParameters")) bit = 1u;
        else if (!strcmp(key, "serverAddress")) bit = 2u;
        else if (!strcmp(key, "serverRSDPort")) bit = 4u;
        else if (!strcmp(key, "type")) bit = 8u;
        else return BRIDGE_E_UNSUPPORTED;
        if (seen & bit) return BRIDGE_E_FORMAT;
        seen |= bit;
        if (bit == 1u) TRY(client_parameters(&c, requested, result));
        else if (bit == 2u) {
            TRY(string_value(&c, result->server_address_text, sizeof result->server_address_text));
            TRY(ipv6_address(result->server_address_text, result->server_address));
            if (!unicast_address(result->server_address)) return BRIDGE_E_FORMAT;
        } else if (bit == 4u) {
            uint32_t value;
            TRY(integer_value(&c, &value));
            if (!value || value > UINT16_MAX) return BRIDGE_E_LIMIT;
            result->server_rsd_port = (uint16_t)value;
        } else {
            char value[32];
            TRY(string_value(&c, value, sizeof value));
            if (strcmp(value, "serverHandshakeResponse")) return BRIDGE_E_TYPE;
        }
        if (consume(&c, '}')) break;
        if (!consume(&c, ',')) return BRIDGE_E_FORMAT;
    }
    whitespace(&c);
    if (c.pos != c.size) return BRIDGE_E_FORMAT;
    if (seen != 15u) return BRIDGE_E_NOT_FOUND;
    if (!memcmp(result->client_address, result->server_address, 16)) return BRIDGE_E_FORMAT;
    return BRIDGE_OK;
}
static bridge_status fail(bridge_cdtunnel *t, bridge_status status) {
    t->state = BRIDGE_CDTUNNEL_FAILED;
    t->error = status;
    memset(&t->parameters, 0, sizeof t->parameters);
    return status;
}
static bridge_status ready(const bridge_cdtunnel *t) {
    if (!t) return BRIDGE_E_ARGUMENT;
    if (t->state == BRIDGE_CDTUNNEL_FAILED) return t->error;
    return t->state == BRIDGE_CDTUNNEL_READY ? BRIDGE_OK : BRIDGE_E_ARGUMENT;
}
bridge_status bridge_cdtunnel_init(bridge_cdtunnel *t, const bridge_io *io, uint16_t mtu) {
    if (!t || !io || !io->read || !io->write || !io->clock_ms ||
        mtu < BRIDGE_CDTUNNEL_MIN_MTU || mtu > BRIDGE_CDTUNNEL_MAX_MTU) return BRIDGE_E_ARGUMENT;
    /* Copy before clearing, permitting init(&context, &context.io, mtu) only on a
     * newly opened underlying stream, as with any other reinitialization. */
    bridge_io copy = *io;
    memset(t, 0, sizeof *t);
    t->io = copy; t->requested_mtu = mtu; t->state = BRIDGE_CDTUNNEL_NEW;
    return BRIDGE_OK;
}
static size_t request(uint8_t out[80], uint16_t mtu) {
    /* Match Python json.dumps({"type": "clientHandshakeRequest", "mtu": mtu}). */
    static const char prefix[] = "{\"type\": \"clientHandshakeRequest\", \"mtu\": ";
    memcpy(out, magic, sizeof magic);
    memcpy(out + 10, prefix, sizeof prefix - 1u);
    size_t length = 10u + sizeof prefix - 1u;
    char digits[5]; size_t count = 0;
    do { digits[count++] = (char)('0' + mtu % 10u); mtu = (uint16_t)(mtu / 10u); } while (mtu);
    while (count) out[length++] = (uint8_t)digits[--count];
    out[length++] = '}';
    size_t body = length - 10u;
    out[8] = (uint8_t)(body >> 8); out[9] = (uint8_t)body;
    return length;
}
bridge_status bridge_cdtunnel_handshake(bridge_cdtunnel *t, uint8_t *scratch,
    size_t capacity, uint64_t deadline) {
    if (!t) return BRIDGE_E_ARGUMENT;
    if (t->state == BRIDGE_CDTUNNEL_FAILED) return t->error;
    if (t->state != BRIDGE_CDTUNNEL_NEW || !scratch || !capacity) return BRIDGE_E_ARGUMENT;
    uint8_t wire[80];
    size_t wire_size = request(wire, t->requested_mtu);
    t->state = BRIDGE_CDTUNNEL_HANDSHAKING;
    bridge_status status = bridge_write_exact(&t->io, wire, wire_size, deadline);
    if (status != BRIDGE_OK) return fail(t, status);
    status = bridge_read_exact(&t->io, wire, 10, deadline);
    if (status != BRIDGE_OK) return fail(t, status);
    if (memcmp(wire, magic, sizeof magic)) return fail(t, BRIDGE_E_FORMAT);
    size_t size = (size_t)wire[8] << 8 | wire[9];
    if (!size) return fail(t, BRIDGE_E_FORMAT);
    if (size > capacity || size > BRIDGE_CDTUNNEL_MAX_JSON) return fail(t, BRIDGE_E_LIMIT);
    status = bridge_read_exact(&t->io, scratch, size, deadline);
    if (status != BRIDGE_OK) return fail(t, status);
    bridge_cdtunnel_parameters parameters = {0};
    status = response_parameters(scratch, size, t->requested_mtu, &parameters);
    if (status != BRIDGE_OK) return fail(t, status);
    if (t->io.clock_ms(t->io.context) >= deadline) return fail(t, BRIDGE_E_TIMEOUT);
    t->parameters = parameters;
    t->state = BRIDGE_CDTUNNEL_READY;
    return BRIDGE_OK;
}
static bridge_status packet_header(const uint8_t *packet, uint16_t mtu, size_t *size) {
    if (packet[0] >> 4 != 6u) return BRIDGE_E_FORMAT;
    size_t payload = (size_t)packet[4] << 8 | packet[5];
    if (!payload && packet[6] != 59u) return BRIDGE_E_UNSUPPORTED;
    *size = BRIDGE_CDTUNNEL_IPV6_HEADER_SIZE + payload;
    return *size <= mtu ? BRIDGE_OK : BRIDGE_E_LIMIT;
}
bridge_status bridge_cdtunnel_send_ipv6(bridge_cdtunnel *t, const uint8_t *packet,
    size_t size, uint64_t deadline) {
    TRY(ready(t));
    if (!packet || size < BRIDGE_CDTUNNEL_IPV6_HEADER_SIZE) return BRIDGE_E_ARGUMENT;
    size_t expected;
    TRY(packet_header(packet, t->parameters.mtu, &expected));
    if (size != expected) return BRIDGE_E_FORMAT;
    bridge_status status = bridge_write_exact(&t->io, packet, size, deadline);
    return status == BRIDGE_OK ? status : fail(t, status);
}
bridge_status bridge_cdtunnel_recv_ipv6(bridge_cdtunnel *t, uint8_t *packet,
    size_t capacity, size_t *size, uint64_t deadline) {
    if (!size) return BRIDGE_E_ARGUMENT;
    *size = 0;
    TRY(ready(t));
    if (!packet) return BRIDGE_E_ARGUMENT;
    if (capacity < t->parameters.mtu) return BRIDGE_E_LIMIT;
    bridge_status status = bridge_read_exact(&t->io, packet, BRIDGE_CDTUNNEL_IPV6_HEADER_SIZE, deadline);
    if (status != BRIDGE_OK) return fail(t, status);
    size_t expected;
    status = packet_header(packet, t->parameters.mtu, &expected);
    if (status != BRIDGE_OK) return fail(t, status);
    status = bridge_read_exact(&t->io, packet + BRIDGE_CDTUNNEL_IPV6_HEADER_SIZE,
        expected - BRIDGE_CDTUNNEL_IPV6_HEADER_SIZE, deadline);
    if (status != BRIDGE_OK) return fail(t, status);
    if (t->io.clock_ms(t->io.context) >= deadline) return fail(t, BRIDGE_E_TIMEOUT);
    *size = expected;
    return BRIDGE_OK;
}
