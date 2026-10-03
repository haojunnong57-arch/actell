#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/lockdown-session-fixtures
"${PYTHON:-python3}" - <<'PY'
from pathlib import Path
import plistlib
out=Path('.build/lockdown-session-fixtures')
rows=[]; lines=['/* Synthetic identities only; stdlib plistlib oracle. */']
def add(value, kind, status='BRIDGE_OK', peer='BRIDGE_LOCKDOWN_PEER_NONE', fmt=plistlib.FMT_BINARY):
    data=plistlib.dumps(value,fmt=fmt,sort_keys=False)
    assert plistlib.loads(data)==value
    name=f'fixture_{len(rows)}'
    lines.append(f'static const uint8_t {name}[]={{'+','.join(map(str,data))+'};')
    rows.append(f'{{{name},sizeof {name},BRIDGE_LOCKDOWN_REPLY_{kind},{status},{peer}}}')
for fmt in (plistlib.FMT_XML,plistlib.FMT_BINARY):
    for kind,req,success in (
        ('START_SESSION','StartSession',{'SessionID':'synthetic-session','EnableSessionSSL':True}),
        ('START_SERVICE','StartService',{'Port':65535,'EnableServiceSSL':True}),
        ('STOP_SESSION','StopSession',{'Result':'Success'})):
        base={'Request':req,**success}
        add(base,kind,fmt=fmt)
        if kind!='STOP_SESSION': add({**base,'Result':'Success'},kind,fmt=fmt)
        add({'Request':req,'Error':'InvalidHostID'},kind,'BRIDGE_E_TYPE','BRIDGE_LOCKDOWN_PEER_INVALID_HOST_ID',fmt)
        add({'Request':req,'Error':'SyntheticUnrecognizedError'},kind,'BRIDGE_E_TYPE','BRIDGE_LOCKDOWN_PEER_OTHER',fmt)
        add({'Request':req,'Result':'Failure'},kind,'BRIDGE_E_TYPE','BRIDGE_LOCKDOWN_PEER_OTHER',fmt)
        add({'Request':req},kind,'BRIDGE_E_NOT_FOUND',fmt=fmt)
        add(success,kind,'BRIDGE_E_NOT_FOUND',fmt=fmt)
        add({**base,'Request':'Pair'},kind,'BRIDGE_E_TYPE',fmt=fmt)
        add({**base,'Unknown':True},kind,'BRIDGE_E_UNSUPPORTED',fmt=fmt)
        add({**base,'Error':''},kind,'BRIDGE_E_FORMAT',fmt=fmt)
    for key in ('EnableSessionSSL',):
        for val in ((False,None,1,'true',b'yes',[],{}) if fmt==plistlib.FMT_BINARY else (False,1,'true',b'yes',[],{})):
            add({'Request':'StartSession','SessionID':'synthetic-session',key:val},'START_SESSION',
                'BRIDGE_OK' if val is False else 'BRIDGE_E_TYPE',fmt=fmt)
    add({'Request':'StartSession','SessionID':'synthetic-session'},'START_SESSION',fmt=fmt)
    add({'Request':'StartSession','SessionID':''},'START_SESSION','BRIDGE_E_FORMAT',fmt=fmt)
    add({'Request':'StartSession','SessionID':'x'*128},'START_SESSION','BRIDGE_E_LIMIT',fmt=fmt)
    add({'Request':'StartSession','SessionID':'fake<&>"\'session','EnableSessionSSL':True},'START_SESSION',fmt=fmt)
    for val,status in ((0,'BRIDGE_E_LIMIT'),(1,'BRIDGE_OK'),(65536,'BRIDGE_E_LIMIT'),(-1,'BRIDGE_E_TYPE'),
                       (True,'BRIDGE_E_TYPE'),('123','BRIDGE_E_TYPE'),(2**63-1,'BRIDGE_E_LIMIT')):
        add({'Request':'StartService','Port':val},'START_SERVICE',status,fmt=fmt)
    add({'Request':'StartService','Port':49152,'Service':'com.apple.internal.devicecompute.CoreDeviceProxy'},'START_SERVICE',fmt=fmt)
    add({'Request':'StartService','Port':49152,'Service':'com.apple.internal.dt.coredevice.untrusted.tunnelservice'},'START_SERVICE','BRIDGE_E_TYPE',fmt=fmt)
    add({'Request':'StartService','Port':49152,'EnableServiceSSL':False},'START_SERVICE',fmt=fmt)
# End-to-end binary reply stream uses deliberately fake IDs and a host-order port.
for name,value in (
    ('binary_start',{'Request':'StartSession','SessionID':'synthetic-session','EnableSessionSSL':True}),
    ('binary_service',{'Request':'StartService','Port':12345,'EnableServiceSSL':True}),
    ('binary_stop',{'Request':'StopSession','Result':'Success'})):
    data=plistlib.dumps(value,fmt=plistlib.FMT_BINARY,sort_keys=False)
    lines.append(f'static const uint8_t {name}[]={{'+','.join(map(str,data))+'};')
# Hand-built binary: duplicate fields, reference cycles, hidden objects, offsets.
def binary(objects,root=0):
    data=bytearray(b'bplist00'); offsets=[]
    for o in objects: offsets.append(len(data));data.extend(o)
    table=len(data); width=1 if table<256 else 2
    data.extend(b''.join(x.to_bytes(width,'big') for x in offsets))
    data.extend(b'\0'*6+bytes([width,1])+len(objects).to_bytes(8,'big')+root.to_bytes(8,'big')+table.to_bytes(8,'big'))
    return data
def string(s):
    return bytes([0x50|min(len(s),15)])+(bytes([0x10,len(s)]) if len(s)>=15 else b'')+s.encode()
def custom(data,status):
    name=f'fixture_{len(rows)}';lines.append(f'static const uint8_t {name}[]={{'+','.join(map(str,data))+'};')
    rows.append(f'{{{name},sizeof {name},BRIDGE_LOCKDOWN_REPLY_START_SESSION,{status},BRIDGE_LOCKDOWN_PEER_NONE}}')
base=binary([b'\xd2\x01\x03\x02\x04',string('Request'),string('StartSession'),string('SessionID'),string('synthetic-session')])
assert plistlib.loads(base)=={'Request':'StartSession','SessionID':'synthetic-session'}
custom(base,'BRIDGE_OK')
custom(binary([b'\xd3\x01\x03\x03\x02\x04\x04',string('Request'),string('StartSession'),string('SessionID'),string('synthetic-session')]),'BRIDGE_E_FORMAT')
custom(binary([b'\xd2\x01\x03\x02\x00',string('Request'),string('StartSession'),string('SessionID')]),'BRIDGE_E_TYPE')
custom(binary([b'\xd2\x01\x03\x02\x04',string('Request'),string('StartSession'),string('SessionID'),string('synthetic-session'),string('hidden')]),'BRIDGE_E_FORMAT')
custom(binary([b'\xd1\x01\xff',string('Request')]),'BRIDGE_E_FORMAT')
for i in range(6):
    c=bytearray(base);c[-32+i]=1;custom(c,'BRIDGE_E_FORMAT')
custom(base[:-32]+b'\0'+base[-32:],'BRIDGE_E_FORMAT')
lines.append('static const fixture fixtures[]={'+',\n'.join(rows)+'};')
(out/'fixtures.h').write_text('\n'.join(lines))
print(f'Generated {len(rows)} synthetic session reply fixtures')
PY
"${CC:-gcc}" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
 -fsanitize=address,undefined -fno-omit-frame-pointer \
 -I firmware/components/bridge_core/include -I .build/lockdown-session-fixtures \
 firmware/components/bridge_core/bridge_io.c firmware/components/bridge_core/bridge_bplist.c \
 firmware/components/bridge_core/bridge_lockdown_session.c tests/test_lockdown_session.c \
 -o .build/test_lockdown_session
ASAN_OPTIONS=detect_leaks=0 .build/test_lockdown_session
"${PYTHON:-python3}" - <<'PY'
from pathlib import Path
import plistlib, struct
wire=Path('.build/lockdown-session-fixtures/requests.bin').read_bytes()
requests=[]
while wire:
    n=struct.unpack('>I',wire[:4])[0]
    assert len(wire)>=n+4
    requests.append(plistlib.loads(wire[4:4+n]));wire=wire[4+n:]
assert requests==[
 {'Label':'esp32-iphone-bridge','Request':'StartSession','HostID':'fake-host<&>"\'','SystemBUID':'fake-system<&>"\''},
 {'Label':'esp32-iphone-bridge','Request':'StartService','Service':'com.apple.internal.devicecompute.CoreDeviceProxy'},
 {'Label':'esp32-iphone-bridge','Request':'StopSession','SessionID':'synthetic-session'},
]
print('PASS: exact StartSession/CoreDeviceProxy/StopSession requests independently decoded by plistlib')
PY
