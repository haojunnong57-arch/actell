#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Host-only conformance. Uses the pinned Python source and system/Python zlib.

Passing proves serializer equivalence, not live device acceptance. Firmware
still needs a bounded level-9 zlib callback and media-session integration.
"""
import ctypes as C
import pathlib
import plistlib
import random
import runpy
import sys
import unittest
import uuid
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build" / "media_offer"
U8 = C.c_uint8
PTR = C.POINTER(U8)
SIZE = C.c_size_t
COMPRESS = C.CFUNCTYPE(C.c_int, C.c_void_p, PTR, SIZE, PTR, SIZE, C.POINTER(SIZE))
OK, ARGUMENT, IO, LIMIT, FORMAT = 0, 1, 2, 5, 6


def pinned_source():
    from reference_source import reference_file
    return runpy.run_path(str(reference_file("media_stream_offer.py")))


@COMPRESS
def zlib9(_context, source, size, destination, capacity, out_size):
    out_size[0] = 0
    encoded = zlib.compress(C.string_at(source, size), level=9)
    if len(encoded) > capacity:
        return LIMIT
    C.memmove(destination, encoded, len(encoded))
    out_size[0] = len(encoded)
    return OK


class MediaOfferTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = pinned_source()
        cls.lib = C.CDLL(str(BUILD / "libmedia_offer.so"))
        cls.lib.bridge_media_video_protobuf.argtypes = [C.c_uint32, PTR, SIZE, C.POINTER(SIZE)]
        cls.lib.bridge_media_video_protobuf.restype = C.c_int
        cls.lib.bridge_media_video_offer.argtypes = [C.c_uint32, PTR, COMPRESS, C.c_void_p, PTR, SIZE, C.POINTER(SIZE)]
        cls.lib.bridge_media_video_offer.restype = C.c_int

    def offer(self, session, call, capacity=1024, compressor=zlib9):
        buffer = (U8 * 1100)(*([0xA5] * 1100))
        call_bytes = (U8 * 16).from_buffer_copy(call.bytes)
        size = SIZE(999)
        status = self.lib.bridge_media_video_offer(session, call_bytes, compressor, None, buffer, capacity, C.byref(size))
        self.assertEqual(bytes(buffer)[capacity:], b"\xA5" * (1100 - capacity))
        return status, bytes(buffer)[:size.value], size.value

    def test_exact_upstream_equivalence(self):
        rng = random.Random(0xB17D6E)
        sessions = [0, 1, 127, 128, 16383, 16384, 0x7fffffff, 0x80000000, 0xffffffff]
        sessions += [rng.getrandbits(32) for _ in range(256)]
        for session in sessions:
            with self.subTest(session=session):
                call = uuid.UUID(int=rng.getrandbits(128))
                expected = self.upstream["build_negotiator_offer_video"](str(call).upper(), session)
                status, actual, _ = self.offer(session, call)
                self.assertEqual(status, OK)
                decoded = plistlib.loads(actual)
                reference = plistlib.loads(expected)
                self.assertEqual(decoded, reference)
                self.assertEqual(actual, expected)  # Full bplist, not merely semantic equivalence.
                endpoint = self.upstream["build_remote_endpoint_info"]("Mac15,9", "2205.3.1", "25F80")
                self.assertEqual(decoded["avcMediaStreamOptionRemoteEndpointInfo"], endpoint)
                blob = zlib.decompress(decoded["avcMediaStreamNegotiatorMediaBlob"])
                self.assertEqual(blob, self.upstream["build_media_blob_video"](session))
                self.assertEqual(decoded["avcMediaStreamOptionCallID"], str(call).upper())
                self.assertEqual(decoded["avcMediaStreamNegotiatorMode"], 5)

    def test_every_output_capacity(self):
        call = uuid.UUID("01234567-89ab-cdef-0123-456789abcdef")
        status, expected, size = self.offer(0x89abcdef, call)
        self.assertEqual(status, OK)
        for cap in range(size):
            with self.subTest(cap=cap):
                status, actual, length = self.offer(0x89abcdef, call, cap)
                self.assertEqual((status, length, actual), (LIMIT, 0, b""))
        self.assertEqual(self.offer(0x89abcdef, call, size), (OK, expected, size))

    def test_protobuf_boundaries(self):
        expected = self.upstream["build_media_blob_video"](0xffffffff)
        for cap in range(len(expected) + 1):
            buffer = (U8 * 400)(*([0xAA] * 400))
            length = SIZE(999)
            status = self.lib.bridge_media_video_protobuf(0xffffffff, buffer, cap, C.byref(length))
            self.assertEqual(bytes(buffer)[cap:], b"\xAA" * (400 - cap))
            if cap < len(expected):
                self.assertEqual((status, length.value), (LIMIT, 0))
            else:
                self.assertEqual(status, OK)
                self.assertEqual(bytes(buffer)[:length.value], expected)

    def test_callback_failures(self):
        call = uuid.UUID(int=0)
        @COMPRESS
        def failed(_ctx, _src, _size, _dst, _cap, out_size):
            out_size[0] = 123
            return IO
        @COMPRESS
        def oversize(_ctx, _src, _size, _dst, cap, out_size):
            out_size[0] = cap + 1
            return OK
        @COMPRESS
        def empty(_ctx, _src, _size, _dst, _cap, out_size):
            out_size[0] = 0
            return OK
        @COMPRESS
        def level6(_ctx, src, size, dst, _cap, out_size):
            encoded = zlib.compress(C.string_at(src, size), level=6)
            C.memmove(dst, encoded, len(encoded)); out_size[0] = len(encoded)
            return OK
        for callback, wanted in ((failed, IO), (oversize, LIMIT), (empty, FORMAT), (level6, FORMAT)):
            self.assertEqual(self.offer(0, call, compressor=callback), (wanted, b"", 0))

    def test_missing_arguments(self):
        buf = (U8 * 1024)()
        uid = (U8 * 16)()
        size = SIZE(999)
        fn = self.lib.bridge_media_video_offer
        self.assertEqual(fn(0, None, zlib9, None, buf, 1024, C.byref(size)), ARGUMENT)
        self.assertEqual(size.value, 0)
        self.assertEqual(fn(0, uid, COMPRESS(), None, buf, 1024, C.byref(size)), ARGUMENT)
        self.assertEqual(fn(0, uid, zlib9, None, None, 0, C.byref(size)), ARGUMENT)
        self.assertEqual(fn(0, uid, zlib9, None, buf, 1024, None), ARGUMENT)
        self.assertEqual(self.lib.bridge_media_video_protobuf(0, None, 0, C.byref(size)), ARGUMENT)
        self.assertEqual(self.lib.bridge_media_video_protobuf(0, buf, 1024, None), ARGUMENT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
