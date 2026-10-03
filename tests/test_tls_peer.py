#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent OpenSSL TLS peer. ALL identities are upstream public test files.
No credentials generated, user files read, or hardware accessed. Loopback only.
"""
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time
import warnings

EXE = Path(sys.argv[1]).resolve()
DATA = Path(sys.argv[2]).resolve()
ENV = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=1")

def exact(sock, n):
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError()
        out.extend(chunk)
    return bytes(out)

def ctx(mode):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.minimum_version = c.maximum_version = ssl.TLSVersion.TLSv1_2
    c.set_ciphers("ECDHE-RSA-AES128-GCM-SHA256")
    c.load_cert_chain(DATA / "server2-sha256.crt", DATA / "server2.key")
    c.load_verify_locations(DATA / "test-ca-sha256.crt")
    c.verify_mode = ssl.CERT_REQUIRED  # independently proves host certificate/key
    if mode == "old_tls":
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            c.minimum_version = c.maximum_version = ssl.TLSVersion.TLSv1_1
        c.set_ciphers("AES128-SHA:@SECLEVEL=0")
    if mode == "tls13_only":
        c.minimum_version = c.maximum_version = ssl.TLSVersion.TLSv1_3
    return c

def run(mode):
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(10)
    port = server.getsockname()[1]
    errors = []
    expected_failure = mode in {"pin_mismatch", "expired_deadline", "callback_overrun",
                               "callback_overreport", "tls13_only", "old_tls", "slow_drip", "handshake_oom"}
    def peer():
        try:
            conn, _ = server.accept()
            conn.settimeout(10)
            with conn:
                if mode in {"expired_deadline", "callback_overrun", "callback_overreport"}:
                    while conn.recv(4096):
                        pass
                    return
                if mode == "slow_drip":
                    for b in b"\x16\x03\x03\x00\x20" + b"\x00" * 32:
                        conn.sendall(bytes([b]))
                        time.sleep(0.035)
                    return
                if mode == "handshake_timeout":
                    time.sleep(0.3)
                    return
                if mode == "eof":
                    header = exact(conn, 5)
                    exact(conn, int.from_bytes(header[3:], "big"))
                    conn.shutdown(socket.SHUT_WR)
                    time.sleep(0.05)
                    return
                if mode in {"fatal_alert", "plaintext", "oversize_record"}:
                    conn.recv(4096)
                    conn.sendall({"fatal_alert": b"\x15\x03\x03\x00\x02\x02\x28",
                                  "plaintext": b"HTTP/1.0 200 OK\r\n\r\n",
                                  "oversize_record": b"\x16\x03\x03\xff\xff"}[mode])
                    time.sleep(0.05)
                    return
                tls = ctx(mode).wrap_socket(conn, server_side=True)
                with tls:
                    assert tls.version() == "TLSv1.2"
                    got_cert = tls.getpeercert(binary_form=True)
                    expected_cert = ssl.PEM_cert_to_DER_cert((DATA / "cli-rsa-sha256.crt").read_text())
                    assert got_cert == expected_cert
                    if mode == "happy":
                        data = exact(tls, 10000)
                        assert data == bytes(i % 251 for i in range(10000))
                        for offset in range(0, len(data), 97):
                            tls.sendall(data[offset:offset+97])
                        assert tls.recv(1) == b""  # client close_notify observed
                    elif mode == "close_notify":
                        try:
                            tls.unwrap()
                        except (ssl.SSLError, OSError):
                            pass  # client exposes EOF and aborts raw after observation
                    elif mode in {"read_timeout", "write_timeout"}:
                        time.sleep(0.3)
                    elif mode == "record_corruption":
                        # Inject an unauthenticated TLS application record directly
                        # beneath OpenSSL after a valid completed handshake.
                        fd = tls.detach()
                        with socket.socket(fileno=fd) as raw:
                            raw.sendall(b"\x17\x03\x03\x00\x20" + b"\x00" * 32)
                            time.sleep(0.05)
        except (ssl.SSLError, ConnectionError, EOFError, OSError) as e:
            if not expected_failure:
                errors.append(e)
        except BaseException as e:
            errors.append(e)
        finally:
            server.close()
    thread = threading.Thread(target=peer)
    thread.start()
    result = subprocess.run([str(EXE), str(DATA), mode, str(port)], env=ENV,
                            capture_output=True, text=True, timeout=15)
    thread.join(12)
    assert not thread.is_alive(), f"hung peer: {mode}"
    if result.returncode:
        raise AssertionError(f"{mode}: client={result.returncode}\n{result.stdout}\n{result.stderr}\npeer={errors}")
    assert not errors, (mode, errors)
    print(result.stdout, end="", flush=True)

subprocess.run([str(EXE), str(DATA), "local", "0"], check=True, env=ENV)
for mode in ("happy", "pin_mismatch", "expired_deadline", "callback_overrun",
             "callback_overreport", "handshake_timeout", "eof", "fatal_alert",
             "plaintext", "oversize_record", "old_tls", "tls13_only", "slow_drip", "handshake_oom", "close_notify",
             "read_timeout", "write_timeout", "record_corruption"):
    run(mode)
print("PASS: real mbedTLS client ↔ independent OpenSSL TLS server; no stubbed crypto")
