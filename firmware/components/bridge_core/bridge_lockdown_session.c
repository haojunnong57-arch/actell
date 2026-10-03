/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Independent bounded implementation, based on pinned pymobiledevice3
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1:
 * lockdown.py:563-579, 607-633, 841-897, 986-1056;
 * remote/tunnel_service.py:1364-1371. CoreDeviceProxy is a lockdown service;
 * untrusted.tunnelservice (1182+) is an RSD service and is NOT used here.
 * XML lexical validation follows this project's read-only lockdown probe.
 */
#include "bridge_lockdown_session.h"
#include "bridge_lockdown_probe.h"
#include "bridge_bplist.h"
#include <string.h>

#define TEXT_CAPACITY BRIDGE_LOCKDOWN_ID_CAPACITY
#define MAX_PAIRS 6u
#define MAX_OBJECTS (1u + 2u * MAX_PAIRS)

/* Volatile erasure covers caller workspace and every parser-owned ID copy. */
static void erase(void *ptr, size_t size) {
    volatile uint8_t *p = ptr;
    while (size--) *p++ = 0;
}

typedef struct {
    const uint8_t *data;
    size_t size, pos;
} xml_cursor;

static bool prefix(const xml_cursor *c, const char *text) {
    size_t n = strlen(text);
    return n <= c->size - c->pos && !memcmp(c->data + c->pos, text, n);
}
static bool consume(xml_cursor *c, const char *text) {
    if (!prefix(c, text)) return false;
    c->pos += strlen(text);
    return true;
}
static bool xml_space(uint8_t ch) {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
}
static bool spaces(xml_cursor *c) {
    size_t before = c->pos;
    while (c->pos < c->size && xml_space(c->data[c->pos])) ++c->pos;
    return c->pos != before;
}
static bool ascii_xml(uint8_t ch) {
    return (ch >= 0x20 && ch <= 0x7e) || xml_space(ch);
}
/* Only XML comments and whitespace between structural tokens are supported.
 * Comments cannot contribute keys or values and cannot contain invalid '--'. */
static bridge_status misc(xml_cursor *c) {
    for (;;) {
        (void)spaces(c);
        if (!consume(c, "<!--")) return BRIDGE_OK;
        for (;;) {
            if (consume(c, "-->")) break;
            if (c->pos == c->size || prefix(c, "--") || !ascii_xml(c->data[c->pos]))
                return BRIDGE_E_FORMAT;
            ++c->pos;
        }
    }
}
static bridge_status quoted_literal(xml_cursor *c, char *out, size_t cap) {
    if (c->pos == c->size || (c->data[c->pos] != '\'' && c->data[c->pos] != '"'))
        return BRIDGE_E_FORMAT;
    uint8_t quote = c->data[c->pos++];
    size_t n = 0;
    while (c->pos < c->size && c->data[c->pos] != quote) {
        uint8_t ch = c->data[c->pos++];
        if (!ascii_xml(ch) || ch == '<' || ch == '&') return BRIDGE_E_FORMAT;
        if (n == cap - 1u) return BRIDGE_E_LIMIT;
        out[n++] = (char)ch;
    }
    if (c->pos == c->size) return BRIDGE_E_FORMAT;
    ++c->pos;
    out[n] = '\0';
    return BRIDGE_OK;
}
static bridge_status attribute(xml_cursor *c, const char *name,
    char *value, size_t cap) {
    if (!consume(c, name)) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    if (!consume(c, "=")) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    return quoted_literal(c, value, cap);
}
static bridge_status declaration(xml_cursor *c) {
    if (!consume(c, "<?xml")) return BRIDGE_OK;
    char value[TEXT_CAPACITY];
    if (!spaces(c)) return BRIDGE_E_FORMAT;
    bridge_status s = attribute(c, "version", value, sizeof value);
    if (s != BRIDGE_OK) return s;
    if (strcmp(value, "1.0")) return BRIDGE_E_UNSUPPORTED;
    bool gap = spaces(c);
    if (prefix(c, "encoding")) {
        if (!gap) return BRIDGE_E_FORMAT;
        s = attribute(c, "encoding", value, sizeof value);
        if (s != BRIDGE_OK) return s;
        if (strcmp(value, "UTF-8") && strcmp(value, "utf-8")) return BRIDGE_E_UNSUPPORTED;
        gap = spaces(c);
    }
    if (prefix(c, "standalone")) {
        if (!gap) return BRIDGE_E_FORMAT;
        s = attribute(c, "standalone", value, sizeof value);
        if (s != BRIDGE_OK) return s;
        if (strcmp(value, "yes") && strcmp(value, "no")) return BRIDGE_E_FORMAT;
        (void)spaces(c);
    }
    return consume(c, "?>") ? BRIDGE_OK : BRIDGE_E_FORMAT;
}
static bridge_status doctype(xml_cursor *c) {
    if (!consume(c, "<!DOCTYPE")) return BRIDGE_OK;
    /* Recognize the normal plist declaration as inert syntax. No DTD parser,
     * internal subset, other public/system ID, entity expansion or network. */
    if (!spaces(c) || !consume(c, "plist") || !spaces(c) ||
        !consume(c, "PUBLIC") || !spaces(c)) return BRIDGE_E_UNSUPPORTED;
    char value[TEXT_CAPACITY];
    bridge_status s = quoted_literal(c, value, sizeof value);
    if (s != BRIDGE_OK) return s;
    if (strcmp(value, "-//Apple//DTD PLIST 1.0//EN")) return BRIDGE_E_UNSUPPORTED;
    if (!spaces(c)) return BRIDGE_E_FORMAT;
    s = quoted_literal(c, value, sizeof value);
    if (s != BRIDGE_OK) return s;
    if (strcmp(value, "http://www.apple.com/DTDs/PropertyList-1.0.dtd"))
        return BRIDGE_E_UNSUPPORTED;
    (void)spaces(c);
    return consume(c, ">") ? BRIDGE_OK : BRIDGE_E_UNSUPPORTED;
}
static bridge_status element_start(xml_cursor *c, const char *name, bool *empty) {
    if (!consume(c, "<") || !consume(c, name)) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    if (consume(c, "/>")) { *empty = true; return BRIDGE_OK; }
    if (!consume(c, ">")) return BRIDGE_E_FORMAT;
    *empty = false;
    return BRIDGE_OK;
}
static bridge_status element_end(xml_cursor *c, const char *name) {
    if (!consume(c, "</") || !consume(c, name)) return BRIDGE_E_FORMAT;
    (void)spaces(c);
    return consume(c, ">") ? BRIDGE_OK : BRIDGE_E_FORMAT;
}
static bridge_status entity(xml_cursor *c, uint8_t *out) {
    static const struct { const char *name; uint8_t ch; } builtins[] = {
        {"amp;", '&'}, {"lt;", '<'}, {"gt;", '>'}, {"quot;", '"'}, {"apos;", '\''}
    };
    if (!consume(c, "&")) return BRIDGE_E_FORMAT;
    if (consume(c, "#")) {
        unsigned radix = consume(c, "x") ? 16u : 10u;
        unsigned n = 0, digits = 0;
        while (c->pos < c->size && c->data[c->pos] != ';') {
            uint8_t ch = c->data[c->pos++];
            unsigned d;
            if (ch >= '0' && ch <= '9') d = (unsigned)(ch - '0');
            else if (radix == 16 && ch >= 'a' && ch <= 'f') d = (unsigned)(ch - 'a') + 10u;
            else if (radix == 16 && ch >= 'A' && ch <= 'F') d = (unsigned)(ch - 'A') + 10u;
            else return BRIDGE_E_FORMAT;
            if (d >= radix || n > (127u - d) / radix) return BRIDGE_E_UNSUPPORTED;
            n = n * radix + d;
            ++digits;
        }
        if (!digits || !consume(c, ";") || !ascii_xml((uint8_t)n)) return BRIDGE_E_FORMAT;
        *out = (uint8_t)n;
        return BRIDGE_OK;
    }
    for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; ++i) {
        if (consume(c, builtins[i].name)) { *out = builtins[i].ch; return BRIDGE_OK; }
    }
    return BRIDGE_E_UNSUPPORTED;
}
static bridge_status text_element(xml_cursor *c, const char *name,
    char *out, size_t cap) {
    bool empty;
    bridge_status s = element_start(c, name, &empty);
    if (s != BRIDGE_OK) return s;
    size_t n = 0;
    if (!empty) {
        while (c->pos < c->size && c->data[c->pos] != '<') {
            uint8_t ch = c->data[c->pos];
            if (ch == '&') {
                s = entity(c, &ch);
                if (s != BRIDGE_OK) return s;
            } else {
                if (!ascii_xml(ch) || prefix(c, "]]>")) return BRIDGE_E_FORMAT;
                ++c->pos;
            }
            if (n == cap - 1u) return BRIDGE_E_LIMIT;
            out[n++] = (char)ch;
        }
        s = element_end(c, name);
        if (s != BRIDGE_OK) return s;
    }
    out[n] = '\0';
    return BRIDGE_OK;
}

typedef enum { VALUE_TEXT, VALUE_BOOLEAN, VALUE_INTEGER } value_kind;
typedef struct {
    value_kind kind;
    char text[TEXT_CAPACITY];
    uint64_t integer;
    bool boolean;
} scalar;
enum { F_REQUEST = 1u, F_RESULT = 2u, F_ERROR = 4u, F_SESSION = 8u,
       F_SSL = 16u, F_PORT = 32u, F_SERVICE = 64u };
typedef struct {
    bridge_lockdown_reply_kind kind;
    unsigned seen;
    bool result_failure;
    bridge_lockdown_reply value;
} parsed_reply;
static const char *request_name(bridge_lockdown_reply_kind kind) {
    switch (kind) {
    case BRIDGE_LOCKDOWN_REPLY_START_SESSION: return "StartSession";
    case BRIDGE_LOCKDOWN_REPLY_START_SERVICE: return "StartService";
    case BRIDGE_LOCKDOWN_REPLY_STOP_SESSION: return "StopSession";
    }
    return NULL;
}
static bridge_lockdown_peer_error error_category(const char *error) {
    if (!strcmp(error, "InvalidHostID")) return BRIDGE_LOCKDOWN_PEER_INVALID_HOST_ID;
    if (!strcmp(error, "InvalidConnection")) return BRIDGE_LOCKDOWN_PEER_INVALID_CONNECTION;
    if (!strcmp(error, "SessionInactive")) return BRIDGE_LOCKDOWN_PEER_SESSION_INACTIVE;
    if (!strcmp(error, "PasswordProtected")) return BRIDGE_LOCKDOWN_PEER_PASSWORD_PROTECTED;
    if (!strcmp(error, "InvalidService")) return BRIDGE_LOCKDOWN_PEER_INVALID_SERVICE;
    if (!strcmp(error, "ServiceProhibited")) return BRIDGE_LOCKDOWN_PEER_SERVICE_PROHIBITED;
    return BRIDGE_LOCKDOWN_PEER_OTHER;
}
static bool printable_text(const char *text) {
    for (size_t i = 0; text[i]; ++i)
        if ((unsigned char)text[i] < 0x20u || (unsigned char)text[i] > 0x7eu) return false;
    return true;
}
static bridge_status accept_pair(parsed_reply *p, const char *key, const scalar *v) {
    unsigned bit;
    value_kind kind = VALUE_TEXT;
    if (!strcmp(key, "Request")) bit = F_REQUEST;
    else if (!strcmp(key, "Result")) bit = F_RESULT;
    else if (!strcmp(key, "Error")) bit = F_ERROR;
    else if (p->kind == BRIDGE_LOCKDOWN_REPLY_START_SESSION && !strcmp(key, "SessionID")) bit = F_SESSION;
    else if (p->kind == BRIDGE_LOCKDOWN_REPLY_START_SESSION && !strcmp(key, "EnableSessionSSL")) {
        bit = F_SSL; kind = VALUE_BOOLEAN;
    } else if (p->kind == BRIDGE_LOCKDOWN_REPLY_START_SERVICE && !strcmp(key, "EnableServiceSSL")) {
        bit = F_SSL; kind = VALUE_BOOLEAN;
    } else if (p->kind == BRIDGE_LOCKDOWN_REPLY_START_SERVICE && !strcmp(key, "Port")) {
        bit = F_PORT; kind = VALUE_INTEGER;
    } else if (p->kind == BRIDGE_LOCKDOWN_REPLY_START_SERVICE && !strcmp(key, "Service")) bit = F_SERVICE;
    else return BRIDGE_E_UNSUPPORTED;
    if (p->seen & bit) return BRIDGE_E_FORMAT;
    p->seen |= bit;
    if (v->kind != kind) return BRIDGE_E_TYPE;
    if (kind == VALUE_TEXT && !printable_text(v->text)) return BRIDGE_E_FORMAT;
    switch (bit) {
    case F_REQUEST: return strcmp(v->text, request_name(p->kind)) ? BRIDGE_E_TYPE : BRIDGE_OK;
    case F_RESULT:
        if (!strcmp(v->text, "Failure")) p->result_failure = true;
        else if (strcmp(v->text, "Success")) return BRIDGE_E_TYPE;
        return BRIDGE_OK;
    case F_ERROR:
        if (!v->text[0]) return BRIDGE_E_FORMAT;
        p->value.peer_error = error_category(v->text);
        return BRIDGE_OK;
    case F_SESSION:
        if (!v->text[0]) return BRIDGE_E_FORMAT;
        memcpy(p->value.session_id, v->text, sizeof p->value.session_id);
        return BRIDGE_OK;
    case F_SSL: p->value.enable_ssl = v->boolean; return BRIDGE_OK;
    case F_PORT:
        if (!v->integer || v->integer > UINT16_MAX) return BRIDGE_E_LIMIT;
        p->value.port = (uint16_t)v->integer;
        return BRIDGE_OK;
    case F_SERVICE: return strcmp(v->text, BRIDGE_LOCKDOWN_COREDEVICE_PROXY) ? BRIDGE_E_TYPE : BRIDGE_OK;
    default: return BRIDGE_E_FORMAT;
    }
}
static bridge_status xml_scalar(xml_cursor *c, scalar *out) {
    memset(out, 0, sizeof *out);
    if (prefix(c, "<string")) {
        out->kind = VALUE_TEXT;
        return text_element(c, "string", out->text, sizeof out->text);
    }
    if (prefix(c, "<true") || prefix(c, "<false")) {
        out->kind = VALUE_BOOLEAN;
        out->boolean = prefix(c, "<true");
        const char *name = out->boolean ? "true" : "false";
        bool empty;
        bridge_status s = element_start(c, name, &empty);
        if (s != BRIDGE_OK || empty) return s;
        /* Paired boolean tags are legal XML plist syntax, no content allowed. */
        (void)spaces(c);
        return element_end(c, name);
    }
    if (prefix(c, "<integer")) {
        out->kind = VALUE_INTEGER;
        char number[32];
        bridge_status s = text_element(c, "integer", number, sizeof number);
        if (s != BRIDGE_OK) return s;
        size_t i = 0;
        while (xml_space((uint8_t)number[i])) ++i;
        if (number[i] == '+') ++i;
        if (number[i] < '0' || number[i] > '9') return BRIDGE_E_TYPE;
        uint64_t n = 0;
        while (number[i] >= '0' && number[i] <= '9') {
            unsigned d = (unsigned)(number[i++] - '0');
            if (n > (UINT64_MAX - d) / 10u) return BRIDGE_E_LIMIT;
            n = n * 10u + d;
        }
        while (xml_space((uint8_t)number[i])) ++i;
        if (number[i]) return BRIDGE_E_FORMAT;
        out->integer = n;
        return BRIDGE_OK;
    }
    return BRIDGE_E_TYPE;
}
static bridge_status xml_pair(xml_cursor *c, parsed_reply *p) {
    char key[TEXT_CAPACITY] = {0};
    scalar value = {0};
    bridge_status s = text_element(c, "key", key, sizeof key);
    if (s == BRIDGE_OK) s = misc(c);
    if (s == BRIDGE_OK) s = xml_scalar(c, &value);
    if (s == BRIDGE_OK) s = accept_pair(p, key, &value);
    /* A malformed scalar can already contain part or all of a SessionID. */
    erase(&value, sizeof value);
    erase(key, sizeof key);
    return s;
}
static bridge_status parse_xml(const uint8_t *data, size_t size, parsed_reply *p) {
    xml_cursor c = {data, size, 0};
    if (size >= 3 && !memcmp(data, "\xef\xbb\xbf", 3)) c.pos = 3;
    bridge_status s = declaration(&c);
    if (s != BRIDGE_OK || (s = misc(&c)) != BRIDGE_OK ||
        (s = doctype(&c)) != BRIDGE_OK || (s = misc(&c)) != BRIDGE_OK) return s;
    if (!consume(&c, "<plist") || !spaces(&c)) return BRIDGE_E_FORMAT;
    char version[TEXT_CAPACITY];
    s = attribute(&c, "version", version, sizeof version);
    if (s != BRIDGE_OK) return s;
    if (strcmp(version, "1.0")) return BRIDGE_E_UNSUPPORTED;
    (void)spaces(&c);
    if (!consume(&c, ">")) return BRIDGE_E_FORMAT;
    if ((s = misc(&c)) != BRIDGE_OK) return s;
    bool empty;
    s = element_start(&c, "dict", &empty);
    if (s != BRIDGE_OK) return s;
    unsigned pairs = 0;
    if (!empty) {
        for (;;) {
            if ((s = misc(&c)) != BRIDGE_OK) return s;
            if (prefix(&c, "</dict")) break;
            if (++pairs > MAX_PAIRS) return BRIDGE_E_LIMIT;
            if ((s = xml_pair(&c, p)) != BRIDGE_OK) return s;
        }
        if ((s = element_end(&c, "dict")) != BRIDGE_OK) return s;
    }
    if ((s = misc(&c)) != BRIDGE_OK || (s = element_end(&c, "plist")) != BRIDGE_OK ||
        (s = misc(&c)) != BRIDGE_OK) return s;
    return c.pos == c.size ? BRIDGE_OK : BRIDGE_E_FORMAT;
}
static uint64_t read_be(const uint8_t *data, uint8_t width) {
    uint64_t value = 0;
    while (width--) value = value << 8 | *data++;
    return value;
}
static bridge_status bplist_text(const bridge_bplist_value *v, char *out) {
    if (v->type != 5 && v->type != 6) return BRIDGE_E_TYPE;
    if (v->length >= TEXT_CAPACITY) return BRIDGE_E_LIMIT;
    for (size_t i = 0; i < v->length; ++i) {
        uint8_t ch;
        if (v->type == 6) {
            if (v->payload[i * 2]) return BRIDGE_E_UNSUPPORTED;
            ch = v->payload[i * 2 + 1];
        } else ch = v->payload[i];
        if (!ascii_xml(ch)) return BRIDGE_E_FORMAT;
        out[i] = (char)ch;
    }
    out[v->length] = '\0';
    return BRIDGE_OK;
}
static bridge_status bplist_scalar(const bridge_bplist_value *v, scalar *out) {
    memset(out, 0, sizeof *out);
    if (v->type == 5 || v->type == 6) {
        out->kind = VALUE_TEXT;
        return bplist_text(v, out->text);
    }
    if (v->type == 0 && (v->subtype == 8 || v->subtype == 9)) {
        out->kind = VALUE_BOOLEAN;
        out->boolean = v->subtype == 9;
        return BRIDGE_OK;
    }
    if (v->type == 1) {
        /* Python plistlib encodes nonnegative ports as one/two/four bytes;
         * negative plist integers use 8 bytes with the high bit set. */
        if (v->length == 8 && (v->payload[0] & 0x80u)) return BRIDGE_E_TYPE;
        out->kind = VALUE_INTEGER;
        out->integer = read_be(v->payload, (uint8_t)v->length);
        return BRIDGE_OK;
    }
    return BRIDGE_E_TYPE;
}
static bridge_status parse_binary(const uint8_t *data, size_t size, parsed_reply *reply) {
    bridge_bplist p;
    bridge_status s = bridge_bplist_open(&p, data, size);
    if (s != BRIDGE_OK) return s;
    if (p.count > MAX_OBJECTS) return BRIDGE_E_LIMIT;
    if (p.table + (size_t)p.count * p.offset_width != size - 32u) return BRIDGE_E_FORMAT;
    for (size_t i = size - 32u; i < size - 26u; ++i)
        if (data[i]) return BRIDGE_E_FORMAT;
    bridge_bplist_value values[MAX_OBJECTS];
    size_t starts[MAX_OBJECTS], ends[MAX_OBJECTS];
    bool used[MAX_OBJECTS] = {false};
    for (uint64_t i = 0; i < p.count; ++i) {
        if ((s = bridge_bplist_get(&p, i, &values[i])) != BRIDGE_OK) return s;
        bridge_bplist_value *v = &values[i];
        size_t bytes = v->length;
        if (i == p.root) {
            if (v->type != 13) return BRIDGE_E_TYPE;
            if (v->length > MAX_PAIRS) return BRIDGE_E_LIMIT;
            bytes *= 2u * p.ref_width;
        } else {
            scalar checked = {0};
            s = bplist_scalar(v, &checked);
            erase(&checked, sizeof checked);
            if (s != BRIDGE_OK) return s;
            if (v->type == 6) bytes *= 2u;
        }
        starts[i] = (size_t)read_be(data + p.table + (size_t)i * p.offset_width, p.offset_width);
        ends[i] = (size_t)(v->payload - data) + bytes;
        for (uint64_t j = 0; j < i; ++j)
            if (starts[i] < ends[j] && starts[j] < ends[i]) return BRIDGE_E_FORMAT;
    }
    size_t position = 8u;
    for (uint64_t n = 0; n < p.count; ++n) {
        bool found = false;
        for (uint64_t i = 0; i < p.count; ++i) {
            if (starts[i] == position) { position = ends[i]; found = true; break; }
        }
        if (!found) return BRIDGE_E_FORMAT;
    }
    if (position != p.table) return BRIDGE_E_FORMAT;
    used[p.root] = true;
    const bridge_bplist_value *dict = &values[p.root];
    for (size_t i = 0; i < dict->length; ++i) {
        uint64_t kr = read_be(dict->payload + i * p.ref_width, p.ref_width);
        uint64_t vr = read_be(dict->payload + (dict->length + i) * p.ref_width, p.ref_width);
        char key[TEXT_CAPACITY] = {0};
        scalar value = {0};
        s = bplist_text(&values[kr], key);
        if (s == BRIDGE_OK) s = bplist_scalar(&values[vr], &value);
        if (s == BRIDGE_OK) s = accept_pair(reply, key, &value);
        erase(&value, sizeof value);
        erase(key, sizeof key);
        if (s != BRIDGE_OK) return s;
        used[kr] = used[vr] = true;
    }
    for (uint64_t i = 0; i < p.count; ++i)
        if (!used[i]) return BRIDGE_E_FORMAT;
    return BRIDGE_OK;
}
bridge_status bridge_lockdown_session_parse_reply(const uint8_t *data, size_t size,
    bridge_lockdown_reply_kind kind, bridge_lockdown_reply *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof *out);
    if (!data || !request_name(kind)) return BRIDGE_E_ARGUMENT;
    if (!size) return BRIDGE_E_FORMAT;
    if (size > BRIDGE_LOCKDOWN_SESSION_MAX_WORKSPACE) return BRIDGE_E_LIMIT;
    parsed_reply parsed;
    memset(&parsed, 0, sizeof parsed);
    parsed.kind = kind;
    bridge_status s = size >= 8 && !memcmp(data, "bplist00", 8) ?
        parse_binary(data, size, &parsed) : parse_xml(data, size, &parsed);
    if (s != BRIDGE_OK) goto done;
    if (!(parsed.seen & F_REQUEST)) { s = BRIDGE_E_NOT_FOUND; goto done; }
    if ((parsed.seen & F_ERROR) || parsed.result_failure) {
        out->peer_error = parsed.value.peer_error ? parsed.value.peer_error : BRIDGE_LOCKDOWN_PEER_OTHER;
        s = BRIDGE_E_TYPE;
        goto done;
    }
    unsigned required = kind == BRIDGE_LOCKDOWN_REPLY_START_SESSION ? F_SESSION :
        (kind == BRIDGE_LOCKDOWN_REPLY_START_SERVICE ? F_PORT : F_RESULT);
    if (!(parsed.seen & required)) { s = BRIDGE_E_NOT_FOUND; goto done; }
    *out = parsed.value;
done:
    erase(&parsed, sizeof parsed);
    return s;
}
static bool valid_io(const bridge_io *io) { return io && io->read && io->write && io->clock_ms; }
static void teardown(bridge_lockdown_session *s) {
    if (s->owns_service) {
        s->owns_service = false;
        s->ops.close(s->ops.context, BRIDGE_LOCKDOWN_CHANNEL_SERVICE, &s->service_io);
    }
    if (s->owns_session) {
        s->owns_session = false;
        s->ops.close(s->ops.context, BRIDGE_LOCKDOWN_CHANNEL_SESSION, &s->session_io);
    }
    memset(&s->session_io, 0, sizeof s->session_io);
    memset(&s->service_io, 0, sizeof s->service_io);
    erase(s->session_id, sizeof s->session_id);
    if (s->workspace) erase(s->workspace, s->workspace_capacity);
    memset(&s->identity, 0, sizeof s->identity);
    s->session_ssl = s->service_ssl = false;
    s->service_port = 0;
}
static bridge_status fail(bridge_lockdown_session *s, bridge_status status, bridge_lockdown_failure failure) {
    s->state = BRIDGE_LOCKDOWN_FAILED;
    s->status = status;
    s->failure = failure;
    teardown(s);
    return status;
}
static bridge_status require_state(bridge_lockdown_session *s, bridge_lockdown_session_state state) {
    if (!s) return BRIDGE_E_ARGUMENT;
    if (s->state == BRIDGE_LOCKDOWN_FAILED) return s->status;
    if (s->state != state || !s->owns_session || !valid_io(&s->session_io))
        return fail(s, BRIDGE_E_ARGUMENT, BRIDGE_LOCKDOWN_FAILURE_STATE);
    return BRIDGE_OK;
}
static bridge_status before_deadline(bridge_lockdown_session *s, uint64_t deadline) {
    if (s->session_io.clock_ms(s->session_io.context) >= deadline)
        return fail(s, BRIDGE_E_TIMEOUT, BRIDGE_LOCKDOWN_FAILURE_TRANSPORT);
    return BRIDGE_OK;
}
static bool valid_id(const char *id) {
    if (!id || !id[0]) return false;
    for (size_t i = 0; i < BRIDGE_LOCKDOWN_ID_CAPACITY; ++i) {
        unsigned char ch = (unsigned char)id[i];
        if (!ch) return true;
        if (ch < 0x20u || ch > 0x7eu) return false;
    }
    return false;
}
bridge_status bridge_lockdown_session_init(bridge_lockdown_session *s, const bridge_io *io,
    const bridge_lockdown_session_ops *ops, const bridge_lockdown_pair_identity *identity,
    uint8_t *workspace, size_t capacity) {
    if (!s) return BRIDGE_E_ARGUMENT;
    memset(s, 0, sizeof *s);
    s->state = BRIDGE_LOCKDOWN_FAILED;
    if (!valid_io(io) || !ops || !ops->open_service || !ops->start_tls || !ops->close ||
        !workspace || capacity < BRIDGE_LOCKDOWN_SESSION_MIN_WORKSPACE ||
        capacity > BRIDGE_LOCKDOWN_SESSION_MAX_WORKSPACE) {
        s->status = BRIDGE_E_ARGUMENT; s->failure = BRIDGE_LOCKDOWN_FAILURE_ARGUMENT;
        return s->status;
    }
    if (!identity || !valid_id(identity->host_id) || !valid_id(identity->system_buid) || !identity->tls_identity) {
        s->status = BRIDGE_E_NOT_FOUND; s->failure = BRIDGE_LOCKDOWN_FAILURE_MISSING_IDENTITY;
        return s->status;
    }
    s->session_io = *io; s->ops = *ops; s->identity = *identity;
    s->workspace = workspace; s->workspace_capacity = capacity;
    erase(workspace, capacity);
    s->owns_session = true;
    s->state = BRIDGE_LOCKDOWN_NEW;
    return BRIDGE_OK;
}
typedef struct { uint8_t *data; size_t size, capacity; } buffer;
static bridge_status append(buffer *b, const char *text) {
    if (!text) return BRIDGE_E_ARGUMENT;
    size_t n = strlen(text);
    if (n > b->capacity - b->size) return BRIDGE_E_LIMIT;
    memcpy(b->data + b->size, text, n); b->size += n;
    return BRIDGE_OK;
}
static bridge_status append_string(buffer *b, const char *key, const char *text) {
    if (!key || !text) return BRIDGE_E_ARGUMENT;
    bridge_status r;
    if ((r = append(b, "<key>")) != BRIDGE_OK || (r = append(b, key)) != BRIDGE_OK ||
        (r = append(b, "</key><string>")) != BRIDGE_OK) return r;
    for (size_t i = 0; text[i]; ++i) {
        const char *entity_text = NULL;
        switch (text[i]) {
        case '&': entity_text = "&amp;"; break;
        case '<': entity_text = "&lt;"; break;
        case '>': entity_text = "&gt;"; break;
        case '"': entity_text = "&quot;"; break;
        case '\'': entity_text = "&apos;"; break;
        default: break;
        }
        char single[2] = {text[i], 0};
        if ((r = append(b, entity_text ? entity_text : single)) != BRIDGE_OK) return r;
    }
    return append(b, "</string>");
}
static bridge_status make_request(bridge_lockdown_session *s, bridge_lockdown_reply_kind kind, size_t *size) {
    buffer b = {s->workspace, 0, s->workspace_capacity};
    bridge_status r;
    if ((r = append(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>")) != BRIDGE_OK ||
        (r = append_string(&b, "Label", BRIDGE_LOCKDOWN_PROBE_LABEL)) != BRIDGE_OK ||
        (r = append_string(&b, "Request", request_name(kind))) != BRIDGE_OK) return r;
    if (kind == BRIDGE_LOCKDOWN_REPLY_START_SESSION) {
        if ((r = append_string(&b, "HostID", s->identity.host_id)) != BRIDGE_OK ||
            (r = append_string(&b, "SystemBUID", s->identity.system_buid)) != BRIDGE_OK) return r;
    } else if (kind == BRIDGE_LOCKDOWN_REPLY_START_SERVICE) {
        if ((r = append_string(&b, "Service", BRIDGE_LOCKDOWN_COREDEVICE_PROXY)) != BRIDGE_OK) return r;
    } else if ((r = append_string(&b, "SessionID", s->session_id)) != BRIDGE_OK) return r;
    if ((r = append(&b, "</dict></plist>\n")) != BRIDGE_OK) return r;
    *size = b.size;
    return BRIDGE_OK;
}
static bridge_status collect(void *context, const uint8_t *data, size_t size) {
    buffer *b = context;
    if (size > b->capacity - b->size) return BRIDGE_E_LIMIT;
    memcpy(b->data + b->size, data, size); b->size += size;
    return BRIDGE_OK;
}
static bridge_status exchange(bridge_lockdown_session *s, bridge_lockdown_reply_kind kind,
    uint64_t deadline, bridge_lockdown_reply *reply) {
    size_t request_size = 0;
    bridge_status r = make_request(s, kind, &request_size);
    if (r != BRIDGE_OK) return fail(s, r, BRIDGE_LOCKDOWN_FAILURE_PROTOCOL);
    r = bridge_plist_send(&s->session_io, s->workspace, request_size, (uint32_t)s->workspace_capacity, deadline);
    erase(s->workspace, s->workspace_capacity);
    if (r != BRIDGE_OK) return fail(s, r, BRIDGE_LOCKDOWN_FAILURE_TRANSPORT);
    buffer b = {s->workspace, 0, s->workspace_capacity};
    uint8_t scratch[128];
    uint32_t received;
    r = bridge_plist_recv(&s->session_io, (uint32_t)s->workspace_capacity, scratch, sizeof scratch,
        collect, &b, deadline, &received);
    erase(scratch, sizeof scratch);
    if (r != BRIDGE_OK) return fail(s, r, BRIDGE_LOCKDOWN_FAILURE_TRANSPORT);
    r = bridge_lockdown_session_parse_reply(s->workspace, received, kind, reply);
    erase(s->workspace, s->workspace_capacity);
    if (r != BRIDGE_OK) {
        s->peer_error = reply->peer_error;
        return fail(s, r, reply->peer_error ? BRIDGE_LOCKDOWN_FAILURE_PEER : BRIDGE_LOCKDOWN_FAILURE_PROTOCOL);
    }
    return before_deadline(s, deadline);
}
static bridge_status upgrade(bridge_lockdown_session *s, bridge_lockdown_channel channel, uint64_t deadline) {
    bridge_io *io = channel == BRIDGE_LOCKDOWN_CHANNEL_SESSION ? &s->session_io : &s->service_io;
    bridge_status r = before_deadline(s, deadline);
    if (r != BRIDGE_OK) return r;
    r = s->ops.start_tls(s->ops.context, channel, io, s->identity.tls_identity, deadline);
    if (r != BRIDGE_OK) return fail(s, r, BRIDGE_LOCKDOWN_FAILURE_TLS);
    if (!valid_io(io)) return fail(s, BRIDGE_E_IO, BRIDGE_LOCKDOWN_FAILURE_TLS);
    /* Check both clocks; all transport/TLS IO must share a monotonic domain. */
    if (io->clock_ms(io->context) >= deadline)
        return fail(s, BRIDGE_E_TIMEOUT, BRIDGE_LOCKDOWN_FAILURE_TLS);
    return before_deadline(s, deadline);
}
bridge_status bridge_lockdown_session_start(bridge_lockdown_session *s, uint64_t deadline) {
    bridge_status r = require_state(s, BRIDGE_LOCKDOWN_NEW);
    if (r != BRIDGE_OK) return r;
    s->state = BRIDGE_LOCKDOWN_STARTING;
    bridge_lockdown_reply reply = {0};
    r = exchange(s, BRIDGE_LOCKDOWN_REPLY_START_SESSION, deadline, &reply);
    if (r == BRIDGE_OK) memcpy(s->session_id, reply.session_id, sizeof s->session_id);
    bool enable_ssl = reply.enable_ssl;
    /* exchange may fail its final deadline check after parsing a full reply. */
    erase(&reply, sizeof reply);
    if (r != BRIDGE_OK) return r;
    /* This modern CoreDevice path deliberately refuses cleartext sessions.
     * Older source-compatible false/absent replies remain parser-supported. */
    if (!enable_ssl) return fail(s, BRIDGE_E_UNSUPPORTED, BRIDGE_LOCKDOWN_FAILURE_TLS);
    if ((r = upgrade(s, BRIDGE_LOCKDOWN_CHANNEL_SESSION, deadline)) != BRIDGE_OK) return r;
    s->session_ssl = true;
    s->state = BRIDGE_LOCKDOWN_ACTIVE;
    return BRIDGE_OK;
}
bridge_status bridge_lockdown_session_start_coredevice_proxy(bridge_lockdown_session *s, uint64_t deadline) {
    bridge_status r = require_state(s, BRIDGE_LOCKDOWN_ACTIVE);
    if (r != BRIDGE_OK) return r;
    if (!s->session_ssl) return fail(s, BRIDGE_E_UNSUPPORTED, BRIDGE_LOCKDOWN_FAILURE_TLS);
    s->state = BRIDGE_LOCKDOWN_STARTING_SERVICE;
    bridge_lockdown_reply reply = {0};
    r = exchange(s, BRIDGE_LOCKDOWN_REPLY_START_SERVICE, deadline, &reply);
    if (r == BRIDGE_OK) s->service_port = reply.port;
    bool enable_ssl = reply.enable_ssl;
    erase(&reply, sizeof reply);
    if (r != BRIDGE_OK) return r;
    s->owns_service = true; /* close must release even a partial failed open */
    r = s->ops.open_service(s->ops.context, s->service_port, &s->service_io, deadline);
    if (r != BRIDGE_OK) return fail(s, r, BRIDGE_LOCKDOWN_FAILURE_TRANSPORT);
    if (!valid_io(&s->service_io)) return fail(s, BRIDGE_E_IO, BRIDGE_LOCKDOWN_FAILURE_TRANSPORT);
    if (s->service_io.clock_ms(s->service_io.context) >= deadline)
        return fail(s, BRIDGE_E_TIMEOUT, BRIDGE_LOCKDOWN_FAILURE_TRANSPORT);
    if ((r = before_deadline(s, deadline)) != BRIDGE_OK) return r;
    if (enable_ssl && (r = upgrade(s, BRIDGE_LOCKDOWN_CHANNEL_SERVICE, deadline)) != BRIDGE_OK) return r;
    s->service_ssl = enable_ssl;
    s->state = BRIDGE_LOCKDOWN_SERVICE_READY;
    return BRIDGE_OK;
}
bridge_status bridge_lockdown_session_stop(bridge_lockdown_session *s, uint64_t deadline) {
    if (!s) return BRIDGE_E_ARGUMENT;
    if (s->state == BRIDGE_LOCKDOWN_FAILED) return s->status;
    if (s->state != BRIDGE_LOCKDOWN_ACTIVE && s->state != BRIDGE_LOCKDOWN_SERVICE_READY)
        return fail(s, BRIDGE_E_ARGUMENT, BRIDGE_LOCKDOWN_FAILURE_STATE);
    s->state = BRIDGE_LOCKDOWN_STOPPING;
    bridge_lockdown_reply reply = {0};
    bridge_status r = exchange(s, BRIDGE_LOCKDOWN_REPLY_STOP_SESSION, deadline, &reply);
    erase(&reply, sizeof reply);
    if (r != BRIDGE_OK) return r;
    s->state = BRIDGE_LOCKDOWN_CLOSED;
    teardown(s);
    return BRIDGE_OK;
}
void bridge_lockdown_session_close(bridge_lockdown_session *s) {
    if (!s) return;
    if (s->state != BRIDGE_LOCKDOWN_FAILED) s->state = BRIDGE_LOCKDOWN_CLOSED;
    teardown(s);
}
bridge_io *bridge_lockdown_session_service_io(bridge_lockdown_session *s) {
    return s && s->state == BRIDGE_LOCKDOWN_SERVICE_READY ? &s->service_io : NULL;
}
