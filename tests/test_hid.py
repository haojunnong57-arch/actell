#!/usr/bin/env python3
"""Differential wire-report test only. No iPhone access or input delivery."""
import ast
import ctypes as C
import pathlib
import random
import struct
import sys
from typing import Iterable, Optional
root = pathlib.Path(__file__).resolve().parents[1]
from reference_source import reference_file
upstream = reference_file('hid_service.py')
# Compile only pure upstream report builders plus their literal constants.
# No import of the device package or execution of service/session code.
tree = ast.parse(upstream.read_text())
wanted = {'build_touchscreen_report', 'build_keyboard_report'}
selected = []
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        selected.append(node)
    elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        if node.targets[0].id in {'TOUCHSCREEN_REPORT_ID', 'KEYBOARD_REPORT_ID'}:
            selected.append(node)
ns = {'struct': struct, 'Optional': Optional, 'Iterable': Iterable}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(upstream), 'exec'), ns)
lib = C.CDLL(sys.argv[1])
u8p = C.POINTER(C.c_uint8)
lib.bridge_hid_touch.argtypes = [u8p, C.c_size_t, C.c_uint8, C.c_uint32, C.c_uint32, C.c_uint64]
lib.bridge_hid_keyboard.argtypes = [u8p, C.c_size_t, C.POINTER(C.c_uint16), C.c_size_t, C.c_uint64]
lib.bridge_hid_normalize.argtypes = [C.c_uint32, C.c_uint32, C.POINTER(C.c_uint16)]
rng = random.Random(27)
for _ in range(1000):
    x, y, t = rng.randrange(65536), rng.randrange(65536), rng.randrange(1 << 48)
    state = rng.choice([0xc2, 2]); out = (C.c_uint8 * 58)()
    assert lib.bridge_hid_touch(out, 58, state, x, y, t) == 0
    assert bytes(out) == ns['build_touchscreen_report'](state, x, y, t)
    usages = [rng.randrange(240) for _ in range(rng.randrange(32))]
    a = (C.c_uint16 * len(usages))(*usages); out = (C.c_uint8 * 39)()
    assert lib.bridge_hid_keyboard(out, 39, a, len(a), t) == 0
    assert bytes(out) == ns['build_keyboard_report'](usages, t)
out = (C.c_uint8 * 58)(*([0xa5] * 58))
assert lib.bridge_hid_touch(out, 57, 2, 0, 0, 0) == 5
assert lib.bridge_hid_touch(out, 58, 2, 65536, 0, 0) == 1
assert lib.bridge_hid_touch(out, 58, 0, 0, 0, 0) == 1
assert lib.bridge_hid_touch(out, 58, 2, 0, 0, 1 << 48) == 1
assert bytes(out) == bytes([0xa5] * 58)
invalid = (C.c_uint16 * 1)(240)
assert lib.bridge_hid_keyboard(out, 58, invalid, 1, 0) == 1
assert bytes(out) == bytes([0xa5] * 58)
assert lib.bridge_hid_keyboard(out, 58, None, 0, 0) == 0
assert bytes(out[:39]) == bytes([1] + [0] * 38)
v = C.c_uint16()
for extent in [2, 1179, 2556, 2**32 - 1]:
    assert lib.bridge_hid_normalize(0, extent, C.byref(v)) == 0 and v.value == 0
    assert lib.bridge_hid_normalize(extent-1, extent, C.byref(v)) == 0 and v.value == 65535
assert lib.bridge_hid_normalize(2, 2, C.byref(v)) == 1
assert lib.bridge_hid_normalize(0, 1, C.byref(v)) == 1
print('PASS: 2000 HID reports byte-identical to pinned upstream; bounds/release/coordinate mapping checked; device behavior NOT tested')
