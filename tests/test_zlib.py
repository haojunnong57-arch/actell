#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Vendored firmware compressor against Python zlib and pinned media offers."""
import ctypes as C
import hashlib
import json
import pathlib
import plistlib
import random
import runpy
import unittest
import uuid
import zlib
from reference_source import reference_file

ROOT = pathlib.Path(__file__).resolve().parents[1]
U8, SIZE = C.c_uint8, C.c_size_t
PTR = C.POINTER(U8)
COMPRESS = C.CFUNCTYPE(C.c_int, C.c_void_p, PTR, SIZE, PTR, SIZE, C.POINTER(SIZE))


class VendoredZlibTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = C.CDLL(str(ROOT / '.build/zlib/libbridge_zlib.so'))
        cls.lib.bridge_zlib_compress.argtypes = [C.c_void_p, PTR, SIZE, PTR, SIZE, C.POINTER(SIZE)]
        cls.lib.bridge_zlib_compress.restype = C.c_int
        cls.callback = COMPRESS(('bridge_zlib_compress', cls.lib))
        cls.lib.bridge_media_video_offer.argtypes = [C.c_uint32, PTR, COMPRESS, C.c_void_p, PTR, SIZE, C.POINTER(SIZE)]
        cls.lib.bridge_media_video_offer.restype = C.c_int
        cls.upstream = runpy.run_path(str(reference_file('media_stream_offer.py')))

    def test_source_hashes(self):
        vendor = ROOT / 'firmware/components/bridge_zlib/vendor'
        manifest = json.loads((vendor / 'SOURCE_MANIFEST.json').read_text())
        self.assertEqual(manifest['version'], '1.3.2')
        for name, expected in manifest['files'].items():
            data = (vendor / 'zlib' / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected['sha256'], name)
            self.assertEqual(len(data), expected['bytes'])
        self.assertEqual(set(p.name for p in (vendor / 'zlib').iterdir()), set(manifest['files']))

    def test_all_input_lengths_exact_python_zlib9(self):
        rng = random.Random(0x5A11B)
        for n in range(385):
            for source in (rng.randbytes(n), b'\x00' * n, (b'abcabcabc0123' * 33)[:n]):
                src = (U8 * max(1, n))()
                C.memmove(src, source, n)
                dst = (U8 * 600)(*([0xA5] * 600)); size = SIZE(999)
                self.assertEqual(self.lib.bridge_zlib_compress(None, src, n, dst, len(dst), C.byref(size)), 0)
                encoded = bytes(dst[:size.value])
                self.assertEqual(encoded, zlib.compress(source, 9))
                self.assertEqual(zlib.decompress(encoded), source)
                self.assertEqual(bytes(dst[512:]), b'\xa5' * 88)

    def test_265_full_offers_exact_pinned_upstream(self):
        rng = random.Random(0xB17D6E)
        sessions = [0, 1, 127, 128, 16383, 16384, 0x7fffffff, 0x80000000, 0xffffffff]
        sessions += [rng.getrandbits(32) for _ in range(256)]
        for sid in sessions:
            call = uuid.UUID(int=rng.getrandbits(128))
            uid = (U8 * 16).from_buffer_copy(call.bytes)
            out = (U8 * 1025)(*([0xA5] * 1025)); size = SIZE(999)
            self.assertEqual(self.lib.bridge_media_video_offer(sid, uid, self.callback, None, out, 1024, C.byref(size)), 0)
            actual = bytes(out[:size.value])
            expected = self.upstream['build_negotiator_offer_video'](str(call).upper(), sid)
            self.assertEqual(actual, expected)
            self.assertEqual(out[1024], 0xA5)
            compressed = plistlib.loads(actual)['avcMediaStreamNegotiatorMediaBlob']
            self.assertEqual(compressed[:2], b'\x78\xda')
            self.assertEqual(zlib.decompress(compressed), self.upstream['build_media_blob_video'](sid))


if __name__ == '__main__':
    print(f'Independent Python zlib runtime: {zlib.ZLIB_RUNTIME_VERSION}', flush=True)
    unittest.main(verbosity=2)
