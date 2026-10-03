#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/xpc-fixtures
# Requires only construct==2.10.70 in this interpreter. Install in an isolated
# venv if needed, then set XPC_PYTHON to that venv's Python. No device is used.
"${XPC_PYTHON:-python3}" - <<'PY'
import importlib.util
from pathlib import Path
import random
import subprocess
import sys
import uuid
import construct

assert construct.__version__ == "2.10.70", "Use construct==2.10.70 for pinned differential tests"
sys.path.insert(0, str(Path("tests").resolve()))
from reference_source import reference_file
spec = importlib.util.spec_from_file_location("xpc_wire_reference", reference_file("xpc_message.py"))
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
rng = random.Random(0x42133742)
lines = ["/* Synthetic fixtures serialized by pinned upstream; no device data. */"]
counter = 0

def cbytes(value):
    return ",".join(f"0x{b:02x}" for b in value) or "0"

def cstr(value):
    # Fixed-width octal escapes cannot consume subsequent numeric characters.
    return '"' + ''.join(f"\\{b:03o}" for b in value.encode("utf8")) + '"'

def object_c(value):
    global counter
    counter += 1
    name = f"obj_{counter}"
    if value is None:
        init = ".type=BRIDGE_XPC_NULL"
    elif isinstance(value, bool):
        init = f".type=BRIDGE_XPC_BOOL,.value.boolean={'true' if value else 'false'}"
    elif isinstance(value, module.XpcInt64Type):
        number = str(value)
        expr = "(-INT64_C(9223372036854775807)-1)" if value == -(1 << 63) else f"INT64_C({number})"
        init = f".type=BRIDGE_XPC_INT64,.value.int64={expr}"
    elif isinstance(value, module.XpcUInt64Type):
        init = f".type=BRIDGE_XPC_UINT64,.value.uint64=UINT64_C({value})"
    elif isinstance(value, str):
        init = f".type=BRIDGE_XPC_STRING,.value.string={cstr(value)}"
    elif isinstance(value, bytes):
        lines.append(f"static const uint8_t {name}_bytes[]={{ {cbytes(value)} }};")
        init = f".type=BRIDGE_XPC_DATA,.value.bytes={{ {name}_bytes,{len(value)} }}"
    elif isinstance(value, uuid.UUID):
        init = f".type=BRIDGE_XPC_UUID,.value.uuid={{ {cbytes(value.bytes)} }}"
    elif isinstance(value, list):
        names = [object_c(v) for v in value]
        # Array members are values, so initialize this array in the test function.
        if names:
            lines.append(f"static bridge_xpc_object {name}_array[{len(names)}];")
            assignments.extend(f"{name}_array[{i}]={child};" for i, child in enumerate(names))
        init = f".type=BRIDGE_XPC_ARRAY,.value.array={{ {name+'_array' if names else 'NULL'},{len(names)} }}"
    elif isinstance(value, dict):
        names = [(k, object_c(v)) for k, v in value.items()]
        if names:
            entries = ",".join(f"{{{cstr(k)},&{child}}}" for k, child in names)
            lines.append(f"static const bridge_xpc_entry {name}_entries[]={{ {entries} }};")
        init = f".type=BRIDGE_XPC_DICTIONARY,.value.dictionary={{ {name+'_entries' if names else 'NULL'},{len(names)} }}"
    else:
        raise TypeError(type(value))
    lines.append(f"static const bridge_xpc_object {name}={{ {init} }};")
    return name

assignments = []
rows = []

def add(value, flags=0x101, message_id=0, absent=False):
    name = None if absent else object_c(value)
    msg = {"message_id": message_id}
    if not absent:
        msg["payload"] = {"obj": module._build_xpc_object(value)}
    encoded = module.XpcWrapper.build({"flags": flags, "message": msg})
    data_name = f"wire_{len(rows)}"
    lines.append(f"static const uint8_t {data_name}[]={{ {cbytes(encoded)} }};")
    rows.append(f"{{{('&'+name) if name else 'NULL'},{flags}u,UINT64_C({message_id}),{data_name},sizeof({data_name})}}")

add(None, flags=0x400001, message_id=(1 << 64)-1, absent=True)
add({}, flags=1)
add(None)
add({"CoreDevice.output": {"image": b"\x89PNG\r\n\x1a\nsynthetic-only", "format": "public.png"}},
    flags=0x20101, message_id=42)
atoms = [None, False, True, module.XpcInt64Type(-(1 << 63)), module.XpcInt64Type((1 << 63)-1),
         module.XpcInt64Type(-1), module.XpcInt64Type(0), module.XpcUInt64Type(0),
         module.XpcUInt64Type((1 << 64)-1), "", "a", "ab", "abc", "abcd", "hé😀",
         uuid.UUID("00112233-4455-6677-8899-aabbccddeeff"), {}, []]
atoms += [bytes(range(n)) for n in range(9)]
add({"all-types": atoms, "empty-key-dict": {"": None}, "utf8-key": {"中文😀": "héllo"}},
    flags=0x10101, message_id=0x0102030405060708)
for value in atoms:
    add(value, flags=rng.getrandbits(32), message_id=rng.getrandbits(64))

def random_value(depth=0):
    choice = rng.randrange(10 if depth < 4 else 8)
    if choice == 0: return None
    if choice == 1: return bool(rng.randrange(2))
    if choice == 2: return module.XpcInt64Type(rng.randrange(-(1 << 63), 1 << 63))
    if choice == 3: return module.XpcUInt64Type(rng.getrandbits(64))
    if choice == 4: return ''.join(rng.choice("ab中😀é123") for _ in range(rng.randrange(32)))
    if choice == 5: return bytes(rng.getrandbits(8) for _ in range(rng.randrange(80)))
    if choice == 6: return uuid.UUID(int=rng.getrandbits(128))
    if choice == 7: return rng.choice(atoms)
    if choice == 8: return [random_value(depth+1) for _ in range(rng.randrange(6))]
    return {f"key-{i}😀": random_value(depth+1) for i in range(rng.randrange(6))}

for _ in range(100):
    add(random_value(), flags=rng.getrandbits(32), message_id=rng.getrandbits(64))
lines.append("static const fixture fixtures[]={" + ",\n".join(rows) + "};")
lines.append("static void init_fixtures(void) {" + "\n".join(assignments) + "}")
Path(".build/xpc-fixtures/xpc_fixtures.h").write_text("\n".join(lines))
print(f"Generated {len(rows)} differential fixtures from pinned upstream cd895d17ce8a97d883c10f87b26c7356d5e0ccb1")
PY
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I firmware/components/bridge_core/include -I .build/xpc-fixtures \
  firmware/components/bridge_core/bridge_xpc.c tests/test_xpc.c -o .build/test_xpc
ASAN_OPTIONS=detect_leaks=0 .build/test_xpc
