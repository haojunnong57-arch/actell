#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/operations-fixtures
"${PYTHON:-python3}" - <<'PY'
import importlib.util,sys,struct,zlib
from pathlib import Path
sys.path.insert(0,str(Path('tests').resolve()))
from reference_source import reference_file
s=importlib.util.spec_from_file_location('operations_xpc',reference_file('xpc_message.py'));m=importlib.util.module_from_spec(s);sys.modules[s.name]=m;s.loader.exec_module(m)
def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b))
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,3,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes(6))*3))+chunk(b'IEND',b'')
body=m.create_xpc_wrapper({'CoreDevice.output':{'image':png,'imageFormat':'png'}},message_id=1)
def decl(name,data):return 'static const uint8_t '+name+'[]={'+','.join(map(str,data))+'};\n'
Path('.build/operations-fixtures/operations_fixtures.h').write_text(decl('png_bytes',png)+decl('capture_reply',body))
PY
${CC:-gcc} -std=c11 -g -O1 -Wall -Wextra -Werror -Wconversion -Wshadow \
 -fsanitize=address,undefined -fno-omit-frame-pointer -fno-pie -no-pie \
 -I firmware/components/bridge_core/include -I .build/operations-fixtures \
 tests/test_operations.c firmware/components/bridge_core/{bridge_io,bridge_xpc,bridge_hid,bridge_requests,bridge_screenshot_stream,bridge_remotexpc,bridge_operations}.c \
 -o .build/test_operations
ASAN_OPTIONS=detect_leaks=0 .build/test_operations
