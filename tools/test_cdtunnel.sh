#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/host_test_platform.sh
mkdir -p .build/cdtunnel-fixtures
"${PYTHON:-python3}" - <<'PY'
from pathlib import Path
import ast
import hashlib
import ipaddress
import json
import struct

out = Path('.build/cdtunnel-fixtures')
lines = ['/* Synthetic/public data only. Python stdlib wire and address oracle. */']
rows = []

def emit(name, data):
    lines.append('static const uint8_t ' + name + '[] = {' + ','.join(map(str, data)) + '};')

# Exact request expression and json.dumps byte behavior in pinned upstream:
# pymobiledevice3 cd895d17ce8a97d883c10f87b26c7356d5e0ccb1
# remote/tunnel_service.py:510 and :438-440; CDTunnelPacket :172-186.
# This expression is intentionally independent of the firmware serializer.
for mtu in (1280, 16000):
    body = json.dumps({'type': 'clientHandshakeRequest', 'mtu': mtu}).encode()
    emit(f'expected_request_{mtu}', b'CDTunnel' + struct.pack('>H', len(body)) + body)

# When the research checkout is present, check the actual pinned source/AST too.
# Offline packaged tests still compare the documented source expression above.
source = Path('research/pymobiledevice3/pymobiledevice3/remote/tunnel_service.py')
if source.exists():
    assert hashlib.sha256(source.read_bytes()).hexdigest() == 'ae788ece14718a59af73300578159d6642f15b24f75851d90c5c456d33000263', 'Pinned tunnel_service.py hash mismatch'
    tree = ast.parse(source.read_text())
    classes = {node.name: node for node in tree.body if isinstance(node, ast.ClassDef)}
    tcp = classes['RemotePairingTcpTunnel']
    assert any(isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'REQUESTED_MTU' for t in n.targets)
               and isinstance(n.value, ast.Constant) and n.value.value == 16000 for n in tcp.body)
    establish = next(n for n in tcp.body if isinstance(n, ast.AsyncFunctionDef) and n.name == 'request_tunnel_establish')
    expression = establish.body[0].value.args[0]
    assert ast.unparse(expression) == "{'type': 'clientHandshakeRequest', 'mtu': self.REQUESTED_MTU}"
    assert any(isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'CDTUNNEL_MAGIC' for t in n.targets)
               and isinstance(n.value, ast.Constant) and n.value.value == b'CDTunnel' for n in tree.body)
    packet = classes['CDTunnelPacketData']
    body_field = next(n for n in packet.body if isinstance(n, ast.AnnAssign) and n.target.id == 'body')
    assert ast.unparse(body_field.value) == 'csfield(Prefixed(Int16ub, GreedyBytes))'
    print('Verified request and framing expressions against local pinned upstream source')

base = {'clientParameters': {'address': '2001:db8:1::2', 'mtu': 1280, 'netmask': 'ffff:ffff:ffff:ffff::'},
        'serverAddress': '2001:db8:1::1', 'serverRSDPort': 56307, 'type': 'serverHandshakeResponse'}
def clone():
    return json.loads(json.dumps(base))
def add(value, expected='BRIDGE_OK', *, raw=False, requested=16000):
    body = value.encode() if raw else json.dumps(value).encode()
    name = f'response_{len(rows)}'
    emit(name, b'CDTunnel' + struct.pack('>H', len(body)) + body)
    mtu, port, mask, prefix = 0, 0, False, 0
    if expected == 'BRIDGE_OK':
        v = json.loads(body)
        mtu, port = v['clientParameters']['mtu'], v['serverRSDPort']
        mask = 'netmask' in v['clientParameters']
        prefix = int(ipaddress.IPv6Address(v['clientParameters'].get('netmask', '::'))).bit_count()
        client = ipaddress.IPv6Address(v['clientParameters']['address']).packed
        server = ipaddress.IPv6Address(v['serverAddress']).packed
    else:
        client = server = bytes(16)
    c = '{' + ','.join(map(str,client)) + '}'
    s = '{' + ','.join(map(str,server)) + '}'
    rows.append(f'{{{name}, sizeof {name}, {expected}, {requested}, {mtu}, {port}, {str(mask).lower()}, {prefix}, {c}, {s}}}')

add(base)
# Public schema example in misc/RemoteXPC.md:225, NOT a captured device reply.
v = clone(); v['clientParameters']['address'] = 'fd58:8c92:8961::2'; v['serverAddress'] = 'fd58:8c92:8961::1'; add(v)
for mtu in (1280, 16000):
    v = clone(); v['clientParameters']['mtu'] = mtu; add(v)
v = clone(); del v['clientParameters']['netmask']; add(v)
for mask in ('::', 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', 'ffff:ffff:ffff:ffff:8000::'):
    v = clone(); v['clientParameters']['netmask'] = mask; add(v)
for address in ('2001:0DB8:0001:0000:0000:0000:0000:0002', '2001:db8::192.0.2.2', '1:2:3:4:5:6:7:8', '2::', '::2'):
    v = clone(); v['clientParameters']['address'] = address; add(v)
add(json.dumps(base).replace('"type"', '"ty\\u0070e"').replace('2001:db8:1::2', '2001:db8:1::\\u0032'), raw=True)
add(' \n\t' + json.dumps(base, separators=(',',':')) + '\r\n ', raw=True)
# Reordered object keys and correctly escaped keys remain accepted.
v = dict(reversed(list(base.items()))); add(v)
add(base, requested=1280)
for mtu in (0, 40, 1279, 16001, 65535, 4294967295, 4294967296):
    v = clone(); v['clientParameters']['mtu'] = mtu; add(v, 'BRIDGE_E_LIMIT')
v = clone(); v['clientParameters']['mtu'] = 1281; add(v, 'BRIDGE_E_LIMIT', requested=1280)
for mtu in (-1, 1280.0, True, None, '1280', [], {}):
    v = clone(); v['clientParameters']['mtu'] = mtu; add(v, 'BRIDGE_E_FORMAT')
for port in (0, 65536, 4294967295, 4294967296):
    v = clone(); v['serverRSDPort'] = port; add(v, 'BRIDGE_E_LIMIT')
for port in (1, 65535):
    v = clone(); v['serverRSDPort'] = port; add(v)
for port in (-1, 56307.5, '56307', True, None):
    v = clone(); v['serverRSDPort'] = port; add(v, 'BRIDGE_E_FORMAT')
for field in base:
    v = clone(); del v[field]; add(v, 'BRIDGE_E_NOT_FOUND')
for field in ('address','mtu'):
    v = clone(); del v['clientParameters'][field]; add(v, 'BRIDGE_E_NOT_FOUND')
for key in ('extra', 'Error'):
    v = clone(); v[key] = {'deep': ['value']}; add(v, 'BRIDGE_E_UNSUPPORTED')
v = clone(); v['clientParameters']['extra'] = 1; add(v, 'BRIDGE_E_UNSUPPORTED')
for key, value in base.items():
    raw = json.dumps(base)[:-1] + ',' + json.dumps(key) + ':' + json.dumps(value) + '}'
    add(raw, 'BRIDGE_E_FORMAT', raw=True)
for field in ('address','mtu','netmask'):
    raw = json.dumps(base).replace('"clientParameters": {', '"clientParameters": {' + json.dumps(field) + ':' + json.dumps(base['clientParameters'][field]) + ',')
    add(raw, 'BRIDGE_E_FORMAT', raw=True)
add(json.dumps(base)[:-1] + ',"ty\\u0070e":"serverHandshakeResponse"}', 'BRIDGE_E_FORMAT', raw=True)
for value in ('clientHandshakeRequest', '', 'serverHandshakeResponseX'):
    v = clone(); v['type'] = value; add(v, 'BRIDGE_E_TYPE')
for address in ('', '2001:db8:::2', '2001::db8::2', '2001:db8:1:2:3:4:5:6:7', '2001:db8:1:2:3:4:5',
                '2001:db8:1:2:3:4:5:6::', ':2001:db8::2', '2001:db8::2:', '2001:db8::xyz',
                '2001:db8::12345', '2001:db8::1%en0', '[2001:db8::1]', '192.0.2.2',
                '2001:db8::192.0.2.999', '2001:db8::192.0.2', '2001:db8::192.0.2.02',
                '2001:db8::192.0.2.2:1', '::', '::1', 'ff02::1', '::ffff:192.0.2.2',
                '2001:db8:1::1', '2001:db8::2\x00evil'):
    v = clone(); v['clientParameters']['address'] = address; add(v, 'BRIDGE_E_FORMAT')
v = clone(); v['serverAddress'] = 'bogus'; add(v, 'BRIDGE_E_FORMAT')
v = clone(); v['clientParameters']['netmask'] = 'ffff:ffff:fffe:ffff::'; add(v, 'BRIDGE_E_FORMAT')
for needle, replacement in [('1280','01280'), ('1280','1280e0'), ('1280','+1280'),
                            ('56307','56307e0'), ('"type"','"ty\\x70e"'),
                            ('"type"','"ty\\uD800pe"'), ('"type"','"ty\\u0000pe"'),
                            ('"type"','"ty\\u007pe"'), ('"type"','"ty\\u0070')]:
    add(json.dumps(base).replace(needle, replacement), 'BRIDGE_E_FORMAT', raw=True)
for raw in ('[]', 'null', '{', json.dumps(base) + '{}', json.dumps(base)[:-1] + ',}', json.dumps(base).replace('1280,','1280,,',1)):
    add(raw, 'BRIDGE_E_FORMAT', raw=True)
add({}, 'BRIDGE_E_NOT_FOUND')
v = clone(); v['clientParameters'] = {}; add(v, 'BRIDGE_E_NOT_FOUND')
lines.append('static const fixture fixtures[] = {' + ',\n'.join(rows) + '};')
(out / 'cdtunnel_fixtures.h').write_text('\n'.join(lines))
print(f'Generated {len(rows)} CDTunnel schema fixtures')
PY
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer "${host_no_pie[@]}" \
  -I firmware/components/bridge_core/include -I .build/cdtunnel-fixtures \
  firmware/components/bridge_core/bridge_io.c \
  firmware/components/bridge_core/bridge_cdtunnel.c \
  tests/test_cdtunnel.c -o .build/test_cdtunnel
ASAN_OPTIONS=detect_leaks=0 .build/test_cdtunnel
