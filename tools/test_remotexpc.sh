#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/remotexpc-fixtures
# Requires construct==2.10.70 and hyperframe==6.1.0, never a device/account.
"${XPC_PYTHON:-python3}" - <<'PY'
import ast, asyncio, hashlib, importlib.util, struct, sys, zlib
from pathlib import Path
import construct, hyperframe
from hyperframe.frame import DataFrame, HeadersFrame, SettingsFrame, WindowUpdateFrame, PingFrame
assert construct.__version__ == '2.10.70'
assert hyperframe.__version__ == '6.1.0'
sys.path.insert(0, str(Path('tests').resolve()))
from reference_source import reference_file
spec = importlib.util.spec_from_file_location('reference_xpc', reference_file('xpc_message.py'))
xpc = importlib.util.module_from_spec(spec); sys.modules[spec.name] = xpc; spec.loader.exec_module(xpc)
source = Path('tests/upstream_reference/remotexpc.py')
if not source.exists(): source = Path('research/pymobiledevice3/pymobiledevice3/remote/remotexpc.py')
assert hashlib.sha256(source.read_bytes()).hexdigest() == '315c118a6846807de1125d3fe61829792b5c07edb8814d0a7d142f610ff37ad8'
tree = ast.parse(source.read_text())
cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'RemoteXPCConnection')
handshake = next(n for n in cls.body if isinstance(n, ast.AsyncFunctionDef) and n.name == '_do_handshake')
module = ast.Module(body=[handshake], type_ignores=[])
globals_ = dict(asyncio=asyncio, SettingsFrame=SettingsFrame, HeadersFrame=HeadersFrame,
    WindowUpdateFrame=WindowUpdateFrame, DataFrame=DataFrame, XpcWrapper=xpc.XpcWrapper,
    XpcFlags=xpc.XpcFlags, HTTP2_MAGIC=b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n',
    DEFAULT_SETTINGS_MAX_CONCURRENT_STREAMS=100, DEFAULT_SETTINGS_INITIAL_WINDOW_SIZE=16*1024*1024,
    DEFAULT_WIN_SIZE_INCR=16*1024*1024-65535, ROOT_CHANNEL=1, REPLY_CHANNEL=3,
    FIRST_REPLY_TIMEOUT=3, ProtocolError=RuntimeError)
exec(compile(module, str(source), 'exec'), globals_)
class Writer:
    def __init__(self): self.data=bytearray()
    def write(self, data): self.data.extend(data)
    async def drain(self): pass
class Peer:
    def __init__(self): self.writer=Writer(); self.frames=[]; self.next_message_id={1:0,3:0}
    async def _send_frame(self, frame): self.frames.append(frame); self.writer.write(frame.serialize())
    async def send_request(self, obj):
        await self._send_frame(DataFrame(stream_id=1, data=xpc.create_xpc_wrapper(obj, message_id=self.next_message_id[1])))
        self.next_message_id[1]+=1
    async def _receive_frame(self): return SettingsFrame()
    def _apply_flow_control_frame(self, frame): return True
peer=Peer(); asyncio.run(globals_['_do_handshake'](peer))
assert [(f.type,f.stream_id) for f in peer.frames] == [(4,0),(8,0),(1,1),(0,1),(1,3),(0,1),(0,3),(4,0)]
# Deliberate bounded-flow-control variation only; preserve source frame sequence
# and every XPC byte. No initial WINDOW_UPDATE since connection stays at 65535.
peer.frames[0].settings[SettingsFrame.INITIAL_WINDOW_SIZE]=16384
expected=globals_['HTTP2_MAGIC']+b''.join(f.serialize() for i,f in enumerate(peer.frames) if i != 1)
out=Path('.build/remotexpc-fixtures')
(out/'handshake.bin').write_bytes(expected)

def h2(data, stream=3, flags=()): return DataFrame(stream_id=stream,data=data,flags=flags).serialize()
def wrapper(value, mid=42, flags=0x20101):
    return xpc.XpcWrapper.build({'flags':flags,'message':{'message_id':mid,'payload':{'obj':xpc._build_xpc_object(value)}}})
small=wrapper({'answer': xpc.XpcUInt64Type(7)})
(out/'response.bin').write_bytes(small)
# >9MiB valid PNG with CRC-correct chunks and uncompressed zlib RGB rows.
# Synthetic pixels only; no device data. The extractor still only checks IHDR.
def png_chunk(kind, body):
    return struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body))
width,height=1170,2700
png=b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))
png+=png_chunk(b'IDAT',zlib.compress((b'\0'+bytes(width*3))*height,level=0))+png_chunk(b'IEND',b'')
large=wrapper({'CoreDevice.output':{'image':png,'imageFormat':'png'}})
small_other=wrapper({'note':'interleaved'},mid=900,flags=0x101)
with (out/'stream.bin').open('wb') as f:
    f.write(SettingsFrame(settings={SettingsFrame.INITIAL_WINDOW_SIZE:65535}).serialize())
    f.write(SettingsFrame(flags=['ACK']).serialize())
    # Both wrapper headers split across DATA frames, other stream mid-wrapper.
    f.write(h2(large[:7])); f.write(h2(small_other[:11],1)); f.write(h2(large[7:19]))
    f.write(h2(small_other[11:],1)); f.write(h2(large[19:24]))
    pos=24; idx=0
    while pos<len(large):
        n=min(997 if idx%7==0 else 8192,len(large)-pos)
        f.write(h2(large[pos:pos+n])); pos+=n; idx+=1
        if idx%67==0: f.write(PingFrame(opaque_data=b'bounded!').serialize())
lines=['#define FIXTURE_PNG_SIZE %du'%len(png),'#define FIXTURE_WRAPPER_SIZE %du'%len(large)]
lines += ['#define FIXTURE_WIDTH %du'%width,'#define FIXTURE_HEIGHT %du'%height]
png_hash=0
for value in png: png_hash=(png_hash*33+value)&0xffffffff
lines += ['#define FIXTURE_PNG_HASH UINT32_C(%d)'%png_hash]
for name,data in [('fixture_response',small),('fixture_handshake',expected)]:
    lines.append('static const uint8_t %s[]={%s};'%(name,','.join(str(b) for b in data)))
(out/'remotexpc_fixtures.h').write_text('\n'.join(lines)+'\n')
print('RemoteXPC: pinned upstream handshake AST + hyperframe 6.1.0 / construct 2.10.70 synthetic fixtures')
PY
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I firmware/components/bridge_core/include -I .build/remotexpc-fixtures \
  firmware/components/bridge_core/bridge_io.c firmware/components/bridge_core/bridge_xpc.c \
  firmware/components/bridge_core/bridge_remotexpc.c \
  firmware/components/bridge_core/bridge_screenshot_stream.c \
  tests/test_remotexpc.c -o .build/test_remotexpc
ASAN_OPTIONS=detect_leaks=0 .build/test_remotexpc
