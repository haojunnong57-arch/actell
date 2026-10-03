/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_lockdown_session.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *data;
    size_t size;
    bridge_lockdown_reply_kind kind;
    bridge_status status;
    bridge_lockdown_peer_error peer;
} fixture;
#include "fixtures.h"
#define WRAP(s) "<plist version=\"1.0\"><dict>" s "</dict></plist>"
#define START "<key>Request</key><string>StartSession</string>"
#define SESSION "<key>SessionID</key><string>synthetic-session</string>"
#define SSL "<key>EnableSessionSSL</key><true/>"
#define SERVICE "<key>Request</key><string>StartService</string>"
#define PORT "<key>Port</key><integer>12345</integer>"
#define STOP "<key>Request</key><string>StopSession</string>"
#define RESULT "<key>Result</key><string>Success</string>"
static const char start_reply[] = WRAP(START SESSION SSL);
static const char service_reply[] = WRAP(SERVICE PORT "<key>EnableServiceSSL</key><false/>");
static const char stop_reply[] = WRAP(STOP RESULT);
static size_t assertions;
#define CHECK(e) do { ++assertions; if (!(e)) { fprintf(stderr,"check failed line %d: %s\n",__LINE__,#e); abort(); } } while (0)
static void zero_result(const bridge_lockdown_reply *r) {
    CHECK(r->port == 0 && !r->enable_ssl);
    for (size_t i = 0; i < sizeof r->session_id; ++i) CHECK(r->session_id[i] == 0);
}
static bridge_status parse(const uint8_t *data, size_t size, bridge_lockdown_reply_kind kind,
    bridge_status expected, bridge_lockdown_peer_error peer) {
    bridge_lockdown_reply r;
    memset(&r, 0x55, sizeof r);
    bridge_status got = bridge_lockdown_session_parse_reply(data, size, kind, &r);
    if (got != expected) { fprintf(stderr,"parse wanted %s got %s len %zu\n",bridge_status_name(expected),bridge_status_name(got),size);abort(); }
    CHECK(r.peer_error == peer);
    if (got != BRIDGE_OK) zero_result(&r);
    return got;
}
static void xml(const char *text, bridge_status expected) {
    (void)parse((const uint8_t *)text, strlen(text), BRIDGE_LOCKDOWN_REPLY_START_SESSION, expected, BRIDGE_LOCKDOWN_PEER_NONE);
}
static void test_parser(void) {
    for (size_t i = 0; i < sizeof fixtures / sizeof fixtures[0]; ++i) {
        const fixture *f=&fixtures[i];
        (void)parse(f->data,f->size,f->kind,f->status,f->peer);
    }
    xml(WRAP(START SESSION SSL),BRIDGE_OK);
    xml("\xef\xbb\xbf<?xml version='1.0' encoding='utf-8' standalone='yes'?>" WRAP(START SESSION SSL),BRIDGE_OK);
    xml(WRAP(START SESSION "<key>EnableSessionSSL</key><true></true>"),BRIDGE_OK);
    xml(WRAP(START SESSION "<key>EnableSessionSSL</key><false> </false>"),BRIDGE_OK);
    xml(WRAP(START "<key>SessionID</key><string>fake&amp;&lt;&gt;&quot;&apos;&#65;&#x42;</string>" SSL),BRIDGE_OK);
    xml(WRAP(START SESSION SESSION SSL),BRIDGE_E_FORMAT);
    xml(WRAP(START SESSION "<key>EnableSessionSSL</key><true>yes</true>"),BRIDGE_E_FORMAT);
    xml(WRAP(START SESSION "<key>EnableSessionSSL</key><truefalse/>"),BRIDGE_E_FORMAT);
    xml(WRAP(START SESSION "<key>EnableSessionSSL</key><string>true</string>"),BRIDGE_E_TYPE);
    xml(WRAP(START SESSION "<key>EnableSessionSSL</key><integer>1</integer>"),BRIDGE_E_TYPE);
    xml(WRAP(START SESSION SSL) "<plist/>",BRIDGE_E_FORMAT);
    xml("<!DOCTYPE plist [<!ENTITY bad SYSTEM 'file:///synthetic'>]>" WRAP(START SESSION SSL),BRIDGE_E_UNSUPPORTED);
    xml(WRAP(START "<key>SessionID</key><string>&bogus;</string>" SSL),BRIDGE_E_UNSUPPORTED);
    xml(WRAP(START "<key>SessionID</key><string>&#0;</string>" SSL),BRIDGE_E_FORMAT);
    xml(WRAP(START "<key>SessionID</key><string>fake\nidentifier</string>" SSL),BRIDGE_E_FORMAT);
    xml(WRAP(START "<key>SessionID</key><string><![CDATA[synthetic-session]]></string>" SSL),BRIDGE_E_FORMAT);
    xml(WRAP(START SESSION "<!-- invalid -- comment -->" SSL),BRIDGE_E_FORMAT);
    xml(WRAP(START SESSION "<!-- safe -->" SSL),BRIDGE_OK);
    xml(WRAP(START "<key>SessionID</key><dict/>" SSL),BRIDGE_E_TYPE);
    xml(WRAP(START "<key>SessionID</key><string>]]></string>" SSL),BRIDGE_E_FORMAT);
    xml("<plist version='1.1'><dict/></plist>",BRIDGE_E_UNSUPPORTED);
    xml("<plist version='1.0'><dict/></plist>",BRIDGE_E_NOT_FOUND);
    bridge_lockdown_reply r;
    CHECK(bridge_lockdown_session_parse_reply(NULL,0,BRIDGE_LOCKDOWN_REPLY_START_SESSION,&r)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_parse_reply((const uint8_t *)start_reply,0,BRIDGE_LOCKDOWN_REPLY_START_SESSION,&r)==BRIDGE_E_FORMAT);
    CHECK(bridge_lockdown_session_parse_reply((const uint8_t *)start_reply,sizeof start_reply,(bridge_lockdown_reply_kind)99,&r)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_parse_reply((const uint8_t *)start_reply,4097,BRIDGE_LOCKDOWN_REPLY_START_SESSION,&r)==BRIDGE_E_LIMIT);
    CHECK(bridge_lockdown_session_parse_reply((const uint8_t *)start_reply,1,BRIDGE_LOCKDOWN_REPLY_START_SESSION,NULL)==BRIDGE_E_ARGUMENT);
    /* Every truncation is rejected; random mutations are checked for bounded,
     * internally consistent outputs. A mutation can legitimately remain valid. */
    for (size_t i = 0; i < sizeof fixtures/sizeof fixtures[0]; ++i) {
        const fixture *f=&fixtures[i];
        if (f->status != BRIDGE_OK) continue;
        for (size_t n=0;n<f->size;++n) {
            bridge_status s=bridge_lockdown_session_parse_reply(f->data,n,f->kind,&r);
            if (s == BRIDGE_OK) {
                /* Removing final XML whitespace does not truncate the document. */
                for (size_t k=n;k<f->size;++k)
                    CHECK(f->data[k]==' ' || f->data[k]=='\n' || f->data[k]=='\t' || f->data[k]=='\r');
            } else zero_result(&r);
        }
    }
    uint8_t mutated[4096]; uint32_t rng=0x81f3462du;
    for (size_t i=0;i<50000;++i) {
        rng=rng*1664525u+1013904223u;
        const fixture *f=&fixtures[rng%(sizeof fixtures/sizeof fixtures[0])];
        CHECK(f->size<=sizeof mutated);
        memcpy(mutated,f->data,f->size);
        rng=rng*1664525u+1013904223u;
        size_t pos=rng%f->size;
        rng=rng*1664525u+1013904223u;
        mutated[pos]=(uint8_t)(rng>>24);
        bridge_status s=bridge_lockdown_session_parse_reply(mutated,f->size,f->kind,&r);
        if (s!=BRIDGE_OK) zero_result(&r);
        else {
            CHECK(r.peer_error==BRIDGE_LOCKDOWN_PEER_NONE);
            if(f->kind==BRIDGE_LOCKDOWN_REPLY_START_SESSION) CHECK(r.session_id[0]!=0);
            if(f->kind==BRIDGE_LOCKDOWN_REPLY_START_SERVICE) CHECK(r.port>0);
        }
    }
}

typedef struct fake fake;
typedef struct { fake *f; bool service,tls; } endpoint;
struct fake {
    uint8_t input[16384], output[16384];
    size_t input_size, input_pos, output_size, chunk;
    uint64_t now;
    size_t calls, error_call, expire_call;
    ptrdiff_t injected;
    bridge_status tls_error, open_error;
    bool expire_tls, expire_open, broken_tls_io, broken_service_io;
    bool expire_after_parse, parsed_deadline_observed;
    unsigned tls_session, tls_service, opened, closed_session, closed_service;
    bool session_upgraded, service_upgraded;
    endpoint raw_session, secure_session, raw_service, secure_service;
    bridge_lockdown_session session;
    uint8_t workspace[BRIDGE_LOCKDOWN_SESSION_MAX_WORKSPACE];
};
static uint64_t now_ms(void *context) {
    endpoint *e=context;fake *f=e->f;
    if(f->expire_after_parse && f->input_size && f->input_pos==f->input_size) {
        bool empty=true;
        for(size_t i=0;i<sizeof f->workspace;++i)empty=empty && f->workspace[i]==0;
        /* Only exchange's final deadline check sees a fully consumed reply
         * with its plaintext workspace already erased. Expire at that point. */
        if(empty) {f->parsed_deadline_observed=true;f->now=1000;}
    }
    return f->now;
}
static ptrdiff_t maybe_error(fake *f) {
    ++f->calls;
    if (f->calls==f->expire_call) f->now=1000;
    if (f->calls==f->error_call) return f->injected;
    return 1;
}
static ptrdiff_t read_data(void *context,uint8_t *data,size_t n,uint32_t timeout) {
    endpoint *e=context;fake *f=e->f;
    CHECK(!e->service && timeout>0 && n>0);
    CHECK(e->tls==f->session_upgraded);
    ptrdiff_t injected=maybe_error(f);
    if(injected!=1)return injected;
    if(f->input_pos==f->input_size)return 0;
    if(n>f->chunk)n=f->chunk;
    if(n>f->input_size-f->input_pos)n=f->input_size-f->input_pos;
    memcpy(data,f->input+f->input_pos,n);f->input_pos+=n;
    return (ptrdiff_t)n;
}
static ptrdiff_t write_data(void *context,const uint8_t *data,size_t n,uint32_t timeout) {
    endpoint *e=context;fake *f=e->f;
    CHECK(!e->service && timeout>0 && n>0);
    CHECK(e->tls==f->session_upgraded);
    ptrdiff_t injected=maybe_error(f);
    if(injected!=1)return injected;
    if(n>f->chunk)n=f->chunk;
    CHECK(n<=sizeof f->output-f->output_size);
    memcpy(f->output+f->output_size,data,n);f->output_size+=n;
    return (ptrdiff_t)n;
}
static bridge_io io_for(endpoint *e) { return (bridge_io){e,read_data,write_data,now_ms}; }
static bridge_status open_service(void *context,uint16_t port,bridge_io *out,uint64_t deadline) {
    fake *f=context;
    CHECK(f->session.state==BRIDGE_LOCKDOWN_STARTING_SERVICE && f->session_upgraded);
    CHECK(!bridge_lockdown_session_service_io(&f->session));
    CHECK(port==12345 && f->now<deadline);
    ++f->opened;
    *out=io_for(&f->raw_service);
    if(f->expire_open)f->now=deadline;
    if(f->broken_service_io)out->read=NULL;
    return f->open_error;
}
static bridge_status start_tls(void *context,bridge_lockdown_channel channel,bridge_io *io,
    const void *identity,uint64_t deadline) {
    fake *f=context;
    CHECK(identity==f && f->now<deadline);
    CHECK(!bridge_lockdown_session_service_io(&f->session));
    if(channel==BRIDGE_LOCKDOWN_CHANNEL_SESSION) {
        CHECK(f->session.state==BRIDGE_LOCKDOWN_STARTING && !f->opened);
        ++f->tls_session;
        *io=io_for(&f->secure_session);f->session_upgraded=true;
    } else {
        CHECK(f->session.state==BRIDGE_LOCKDOWN_STARTING_SERVICE && f->opened==1);
        ++f->tls_service;
        *io=io_for(&f->secure_service);f->service_upgraded=true;
    }
    if(f->expire_tls)f->now=deadline;
    if(f->broken_tls_io)io->read=NULL;
    return f->tls_error;
}
static void close_channel(void *context,bridge_lockdown_channel channel,bridge_io *io) {
    fake *f=context;(void)io;
    CHECK(!bridge_lockdown_session_service_io(&f->session));
    if(channel==BRIDGE_LOCKDOWN_CHANNEL_SESSION)++f->closed_session;else ++f->closed_service;
    CHECK(f->closed_session<=1 && f->closed_service<=1);
}
static void input(fake *f,const uint8_t *data,size_t n) {
    CHECK(n<=sizeof f->input-f->input_size-4);
    uint8_t *p=f->input+f->input_size;
    p[0]=(uint8_t)(n>>24);p[1]=(uint8_t)(n>>16);p[2]=(uint8_t)(n>>8);p[3]=(uint8_t)n;
    memcpy(p+4,data,n);f->input_size+=n+4;
}
static void input_xml(fake *f,const char *text) { input(f,(const uint8_t *)text,strlen(text)); }
static void prepare(fake *f,size_t chunk) {
    memset(f,0,sizeof *f);f->chunk=chunk;f->now=10;
    f->raw_session=(endpoint){f,false,false};f->secure_session=(endpoint){f,false,true};
    f->raw_service=(endpoint){f,true,false};f->secure_service=(endpoint){f,true,true};
    bridge_io io=io_for(&f->raw_session);
    bridge_lockdown_session_ops ops={f,open_service,start_tls,close_channel};
    bridge_lockdown_pair_identity identity={"fake-host<&>\"'","fake-system<&>\"'",f};
    CHECK(bridge_lockdown_session_init(&f->session,&io,&ops,&identity,f->workspace,sizeof f->workspace)==BRIDGE_OK);
}
static void erased(const fake *f) {
    for(size_t i=0;i<sizeof f->workspace;++i)CHECK(f->workspace[i]==0);
    for(size_t i=0;i<sizeof f->session.session_id;++i)CHECK(f->session.session_id[i]==0);
    CHECK(!f->session.identity.tls_identity && !f->session.identity.host_id);
    CHECK(!bridge_lockdown_session_service_io((bridge_lockdown_session *)&f->session));
}
static void terminal(fake *f,bridge_lockdown_failure why,bridge_status status) {
    CHECK(f->session.state==BRIDGE_LOCKDOWN_FAILED && f->session.failure==why && f->session.status==status);
    CHECK(f->closed_session==1);erased(f);
    size_t before=f->calls;
    CHECK(bridge_lockdown_session_start(&f->session,1000)==status);
    CHECK(bridge_lockdown_session_start_coredevice_proxy(&f->session,1000)==status);
    CHECK(bridge_lockdown_session_stop(&f->session,1000)==status);
    bridge_lockdown_session_close(&f->session);
    CHECK(f->calls==before && f->closed_session==1);
}
static void happy(size_t chunk,bool tls_service,bool capture) {
    fake f;prepare(&f,chunk);
    input_xml(&f,start_reply);
    input_xml(&f,tls_service?WRAP(SERVICE PORT "<key>EnableServiceSSL</key><true/>"):service_reply);
    input_xml(&f,stop_reply);
    CHECK(!bridge_lockdown_session_service_io(&f.session));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
    CHECK(f.session.state==BRIDGE_LOCKDOWN_ACTIVE && f.tls_session==1);
    CHECK(!bridge_lockdown_session_service_io(&f.session));
    CHECK(bridge_lockdown_session_start_coredevice_proxy(&f.session,1000)==BRIDGE_OK);
    CHECK(f.session.state==BRIDGE_LOCKDOWN_SERVICE_READY && f.opened==1);
    CHECK(f.tls_service==(tls_service?1u:0u) && f.session.service_ssl==tls_service);
    bridge_io *service=bridge_lockdown_session_service_io(&f.session);
    CHECK(service && service->context==(tls_service?(void *)&f.secure_service:(void *)&f.raw_service));
    CHECK(bridge_lockdown_session_stop(&f.session,1000)==BRIDGE_OK);
    CHECK(f.session.state==BRIDGE_LOCKDOWN_CLOSED && f.closed_session==1 && f.closed_service==1);
    CHECK(f.input_pos==f.input_size);erased(&f);
    bridge_lockdown_session_close(&f.session);
    if(capture) {
        FILE *out=fopen(".build/lockdown-session-fixtures/requests.bin","wb");CHECK(out);
        CHECK(fwrite(f.output,1,f.output_size,out)==f.output_size);CHECK(fclose(out)==0);
    }
}
static void binary_sessions(void) {
    for(size_t chunk=1;chunk<=64;++chunk) {
        fake f;prepare(&f,chunk);
        input(&f,binary_start,sizeof binary_start);
        input(&f,binary_service,sizeof binary_service);
        input(&f,binary_stop,sizeof binary_stop);
        CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
        CHECK(bridge_lockdown_session_start_coredevice_proxy(&f.session,1000)==BRIDGE_OK);
        CHECK(bridge_lockdown_session_service_io(&f.session));
        CHECK(f.tls_session==1 && f.tls_service==1);
        CHECK(bridge_lockdown_session_stop(&f.session,1000)==BRIDGE_OK);
        CHECK(f.closed_session==1 && f.closed_service==1 && f.input_pos==f.input_size);
        erased(&f);
    }
}
static void test_failures(void) {
    fake f;
    prepare(&f,7);CHECK(bridge_lockdown_session_start_coredevice_proxy(&f.session,1000)==BRIDGE_E_ARGUMENT);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_STATE,BRIDGE_E_ARGUMENT);CHECK(!f.calls);
    prepare(&f,7);CHECK(bridge_lockdown_session_stop(&f.session,1000)==BRIDGE_E_ARGUMENT);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_STATE,BRIDGE_E_ARGUMENT);
    prepare(&f,7);input_xml(&f,start_reply);CHECK(bridge_lockdown_session_start(&f.session,10)==BRIDGE_E_TIMEOUT);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TRANSPORT,BRIDGE_E_TIMEOUT);CHECK(!f.calls);
    prepare(&f,7);input_xml(&f,WRAP(START SESSION "<key>EnableSessionSSL</key><false/>"));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_UNSUPPORTED);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TLS,BRIDGE_E_UNSUPPORTED);CHECK(!f.tls_session);
    prepare(&f,7);input_xml(&f,WRAP(START SESSION));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_UNSUPPORTED);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TLS,BRIDGE_E_UNSUPPORTED);
    prepare(&f,7);input_xml(&f,WRAP(START "<key>Error</key><string>InvalidHostID</string>"));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_TYPE);
    CHECK(f.session.peer_error==BRIDGE_LOCKDOWN_PEER_INVALID_HOST_ID);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_PEER,BRIDGE_E_TYPE);CHECK(!f.tls_session);
    prepare(&f,7);input_xml(&f,WRAP(START SSL));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_NOT_FOUND);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_PROTOCOL,BRIDGE_E_NOT_FOUND);
    for(unsigned mode=0;mode<3;++mode) {
        prepare(&f,7);input_xml(&f,start_reply);
        if(mode==0)f.tls_error=BRIDGE_E_IO;
        if(mode==1)f.expire_tls=true;
        if(mode==2)f.broken_tls_io=true;
        bridge_status want=mode==1?BRIDGE_E_TIMEOUT:BRIDGE_E_IO;
        CHECK(bridge_lockdown_session_start(&f.session,1000)==want);
        terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TLS,want);CHECK(!f.opened);
    }
    for(unsigned mode=0;mode<6;++mode) {
        prepare(&f,7);input_xml(&f,start_reply);input_xml(&f,WRAP(SERVICE PORT "<key>EnableServiceSSL</key><true/>"));
        CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
        if(mode==0)f.open_error=BRIDGE_E_IO;
        if(mode==1)f.expire_open=true;
        if(mode==2)f.broken_service_io=true;
        if(mode==3)f.tls_error=BRIDGE_E_IO;
        if(mode==4)f.expire_tls=true;
        if(mode==5)f.broken_tls_io=true;
        bridge_status want=mode==1||mode==4?BRIDGE_E_TIMEOUT:BRIDGE_E_IO;
        CHECK(bridge_lockdown_session_start_coredevice_proxy(&f.session,1000)==want);
        terminal(&f,mode<3?BRIDGE_LOCKDOWN_FAILURE_TRANSPORT:BRIDGE_LOCKDOWN_FAILURE_TLS,want);
        CHECK(f.closed_service==1);
    }
    prepare(&f,7);input_xml(&f,start_reply);input_xml(&f,WRAP(SERVICE "<key>Error</key><string>PasswordProtected</string>"));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
    CHECK(bridge_lockdown_session_start_coredevice_proxy(&f.session,1000)==BRIDGE_E_TYPE);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_PEER,BRIDGE_E_TYPE);CHECK(!f.opened);
    prepare(&f,7);input_xml(&f,start_reply);input_xml(&f,WRAP(STOP));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
    CHECK(bridge_lockdown_session_stop(&f.session,1000)==BRIDGE_E_NOT_FOUND);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_PROTOCOL,BRIDGE_E_NOT_FOUND);
    prepare(&f,7);input_xml(&f,start_reply);
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_ARGUMENT);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_STATE,BRIDGE_E_ARGUMENT);
    /* Oversize/zero/truncated frames never retry or read a second frame. */
    for(unsigned mode=0;mode<3;++mode) {
        prepare(&f,7);
        if(mode==0){f.input[2]=0x10;f.input[3]=1;f.input_size=4;}
        if(mode==1)f.input_size=4;
        if(mode==2){input_xml(&f,start_reply);--f.input_size;}
        bridge_status want=mode==0?BRIDGE_E_LIMIT:mode==1?BRIDGE_E_FORMAT:BRIDGE_E_EOF;
        CHECK(bridge_lockdown_session_start(&f.session,1000)==want);
        terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TRANSPORT,want);
    }
    /* Inject timeout, EOF, overreported lengths and IO errors at every callback
     * boundary of the plain StartSession transaction with 7-byte fragments. */
    prepare(&f,7);input_xml(&f,start_reply);
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);size_t total=f.calls;
    bridge_lockdown_session_close(&f.session);
    const ptrdiff_t errors[]={0,-(ptrdiff_t)BRIDGE_E_IO,-(ptrdiff_t)BRIDGE_E_TIMEOUT,100000};
    for(size_t k=0;k<sizeof errors/sizeof errors[0];++k)
        for(size_t i=1;i<=total;++i) {
            prepare(&f,7);input_xml(&f,start_reply);f.error_call=i;f.injected=errors[k];
            bridge_status want=k==0?BRIDGE_E_EOF:k==2?BRIDGE_E_TIMEOUT:BRIDGE_E_IO;
            CHECK(bridge_lockdown_session_start(&f.session,1000)==want);
            terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TRANSPORT,want);
        }
}
static void test_reply_cleanup_paths(void) {
    fake f;
    /* SessionID has been parsed successfully before the final deadline failure.
     * The returned state/workspace are observable; stack scratch erasure is
     * enforced by the production parser's unconditional volatile cleanup. */
    for(unsigned binary=0;binary<2;++binary) {
        prepare(&f,13);
        if(binary)input(&f,binary_start,sizeof binary_start);else input_xml(&f,start_reply);
        f.expire_after_parse=true;
        CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_TIMEOUT);
        CHECK(f.parsed_deadline_observed && !f.tls_session && f.input_pos==f.input_size);
        terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TRANSPORT,BRIDGE_E_TIMEOUT);
    }
    /* Parse failure after copying a full or partial ID still closes the stream
     * and erases caller-visible storage; no retry or TLS callback is permitted. */
    const char *bad[]={WRAP(START SESSION SSL) "junk",
        WRAP(START SESSION "<key>Unexpected</key><string>x</string>"),
        WRAP(START "<key>SessionID</key><string>synthetic-session&bogus;</string>" SSL)};
    const bridge_status expected[]={BRIDGE_E_FORMAT,BRIDGE_E_UNSUPPORTED,BRIDGE_E_UNSUPPORTED};
    for(size_t i=0;i<sizeof bad/sizeof bad[0];++i) {
        prepare(&f,13);input_xml(&f,bad[i]);
        CHECK(bridge_lockdown_session_start(&f.session,1000)==expected[i]);
        CHECK(!f.tls_session);
        terminal(&f,BRIDGE_LOCKDOWN_FAILURE_PROTOCOL,expected[i]);
    }
    prepare(&f,13);input_xml(&f,WRAP(START SESSION "<key>Error</key><string>InvalidHostID</string>"));
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_E_TYPE);
    CHECK(f.session.peer_error==BRIDGE_LOCKDOWN_PEER_INVALID_HOST_ID && !f.tls_session);
    terminal(&f,BRIDGE_LOCKDOWN_FAILURE_PEER,BRIDGE_E_TYPE);
}
static void test_init(void) {
    fake f;prepare(&f,7);bridge_lockdown_session_close(&f.session);
    bridge_io io=io_for(&f.raw_session);
    bridge_lockdown_session_ops ops={&f,open_service,start_tls,close_channel};
    bridge_lockdown_pair_identity identity={"synthetic-host","synthetic-buid",&f};
    bridge_lockdown_session s;
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,NULL,f.workspace,sizeof f.workspace)==BRIDGE_E_NOT_FOUND);
    CHECK(s.failure==BRIDGE_LOCKDOWN_FAILURE_MISSING_IDENTITY);
    identity.tls_identity=NULL;
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_NOT_FOUND);
    identity.tls_identity=&f;identity.host_id="";
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_NOT_FOUND);
    identity.host_id="synthetic\nwrong";
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_NOT_FOUND);
    char oversized[129];memset(oversized,'x',sizeof oversized);oversized[128]=0;identity.host_id=oversized;
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_NOT_FOUND);
    identity.host_id="synthetic-host";
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,&identity,f.workspace,1024)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_init(&s,NULL,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_init(NULL,&io,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_ARGUMENT);
    ops.start_tls=NULL;
    CHECK(bridge_lockdown_session_init(&s,&io,&ops,&identity,f.workspace,sizeof f.workspace)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_start(NULL,1000)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_start_coredevice_proxy(NULL,1000)==BRIDGE_E_ARGUMENT);
    CHECK(bridge_lockdown_session_stop(NULL,1000)==BRIDGE_E_ARGUMENT);
    CHECK(!bridge_lockdown_session_service_io(NULL));bridge_lockdown_session_close(NULL);
    memset(&s,0,sizeof s);
    CHECK(bridge_lockdown_session_start(&s,1000)==BRIDGE_E_ARGUMENT);
    CHECK(s.state==BRIDGE_LOCKDOWN_FAILED);
    CHECK(f.closed_session==1); /* init failures never took ownership */
}
static bridge_status run_all(fake *f) {
    bridge_status status=bridge_lockdown_session_start(&f->session,1000);
    if(status==BRIDGE_OK)status=bridge_lockdown_session_start_coredevice_proxy(&f->session,1000);
    if(status==BRIDGE_OK)status=bridge_lockdown_session_stop(&f->session,1000);
    return status;
}
static void prepare_all(fake *f) {
    prepare(f,13);input_xml(f,start_reply);input_xml(f,service_reply);input_xml(f,stop_reply);
}
static void maximum_identity(void) {
    fake f;prepare(&f,31);bridge_lockdown_session_close(&f.session);
    f.closed_session=0;
    bridge_io io=io_for(&f.raw_session);
    bridge_lockdown_session_ops ops={&f,open_service,start_tls,close_channel};
    char host[BRIDGE_LOCKDOWN_ID_CAPACITY],buid[BRIDGE_LOCKDOWN_ID_CAPACITY];
    memset(host,'"',sizeof host);memset(buid,'\'',sizeof buid);
    host[sizeof host-1]=0;buid[sizeof buid-1]=0;
    bridge_lockdown_pair_identity identity={host,buid,&f};
    CHECK(bridge_lockdown_session_init(&f.session,&io,&ops,&identity,f.workspace,BRIDGE_LOCKDOWN_SESSION_MIN_WORKSPACE)==BRIDGE_OK);
    input_xml(&f,start_reply);input_xml(&f,stop_reply);
    CHECK(bridge_lockdown_session_start(&f.session,1000)==BRIDGE_OK);
    CHECK(bridge_lockdown_session_stop(&f.session,1000)==BRIDGE_OK);
    CHECK(f.output_size<BRIDGE_LOCKDOWN_SESSION_MIN_WORKSPACE+512);
    erased(&f);
}
static void all_boundaries(void) {
    fake f;prepare_all(&f);CHECK(run_all(&f)==BRIDGE_OK);size_t total=f.calls;
    const ptrdiff_t errors[]={0,-(ptrdiff_t)BRIDGE_E_IO,-(ptrdiff_t)BRIDGE_E_TIMEOUT,100000};
    for(size_t k=0;k<sizeof errors/sizeof errors[0];++k)
        for(size_t i=1;i<=total;++i) {
            prepare_all(&f);f.error_call=i;f.injected=errors[k];
            bridge_status want=k==0?BRIDGE_E_EOF:k==2?BRIDGE_E_TIMEOUT:BRIDGE_E_IO;
            CHECK(run_all(&f)==want);
            terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TRANSPORT,want);
            CHECK(f.closed_service==f.opened);
        }
    for(size_t i=1;i<=total;++i) {
        prepare_all(&f);f.expire_call=i;
        CHECK(run_all(&f)==BRIDGE_E_TIMEOUT);
        terminal(&f,BRIDGE_LOCKDOWN_FAILURE_TRANSPORT,BRIDGE_E_TIMEOUT);
        CHECK(f.closed_service==f.opened);
    }
}
int main(void) {
    test_parser();test_init();
    for(size_t chunk=1;chunk<=64;++chunk){happy(chunk,false,chunk==64);happy(chunk,true,false);}
    binary_sessions();test_failures();test_reply_cleanup_paths();all_boundaries();maximum_identity();
    printf("PASS: lockdown session %zu assertions; %zu XML/binary fixtures; 50,000 mutations; 192 fragmented XML/binary full sessions; terminal lifecycle faults\n",assertions,sizeof fixtures/sizeof fixtures[0]);
    return 0;
}
