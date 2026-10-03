#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent plistlib/OpenSSL peer: actual framed lockdown + live TLS."""
import os
from pathlib import Path
import plistlib
import socket
import ssl
import struct
import subprocess
import sys
import threading

EXE = Path(sys.argv[1]).resolve()
DATA = Path(sys.argv[2]).resolve()
ENV = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=1")

def exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        b = s.recv(n - len(buf))
        if not b:
            raise EOFError()
        buf.extend(b)
    return bytes(buf)

def receive(s):
    size, = struct.unpack(">I", exact(s, 4))
    assert 0 < size <= 4096
    return plistlib.loads(exact(s, size))

def send(s, obj, fmt):
    data = plistlib.dumps(obj, fmt=fmt)
    wire = struct.pack(">I", len(data)) + data
    for i in range(0, len(wire), 37):
        s.sendall(wire[i:i+37])

def listen():
    s = socket.socket()
    s.bind(("127.0.0.1", 0)); s.listen(1); s.settimeout(10)
    return s

def wrap(conn, mismatch=False):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.minimum_version = c.maximum_version = ssl.TLSVersion.TLSv1_2
    # SECLEVEL=0 only allows the PUBLIC sha1-signed alternate server test
    # certificate. No production setting is weakened by this test peer.
    c.set_ciphers("ECDHE-RSA-AES128-GCM-SHA256:@SECLEVEL=0")
    c.load_cert_chain(DATA / ("server1.crt" if mismatch else "server2-sha256.crt"),
                      DATA / ("server1.key" if mismatch else "server2.key"))
    c.load_verify_locations(DATA / "test-ca-sha256.crt")
    c.verify_mode = ssl.CERT_REQUIRED
    tls = c.wrap_socket(conn, server_side=True)
    assert tls.version() == "TLSv1.2"
    assert tls.getpeercert(binary_form=True) == ssl.PEM_cert_to_DER_cert((DATA / "cli-rsa-sha256.crt").read_text())
    return tls

def run(mode):
    session_listener, service_listener = listen(), listen()
    encrypted = mode != "lockdown_plain_service"
    mismatch = mode == "lockdown_service_mismatch"
    fmt = plistlib.FMT_BINARY if encrypted else plistlib.FMT_XML
    errors, requests = [], []
    def service_peer():
        try:
            conn, _ = service_listener.accept(); conn.settimeout(10)
            with conn:
                if encrypted:
                    conn = wrap(conn, mismatch)
                with conn:
                    assert exact(conn, 4) == b"ping"
                    conn.sendall(b"pong")
                    assert conn.recv(1) == b""
        except (ssl.SSLError, ConnectionError, EOFError, OSError) as e:
            if not mismatch: errors.append(e)
        except BaseException as e:
            errors.append(e)
        finally:
            service_listener.close()
    def session_peer():
        try:
            conn, _ = session_listener.accept(); conn.settimeout(10)
            with conn:
                request = receive(conn); requests.append(request["Request"])
                assert request["Request"] == "StartSession"
                assert request["HostID"] == "SYNTHETIC-HOST"
                assert request["SystemBUID"] == "SYNTHETIC-BUID"
                send(conn, {"Request": "StartSession", "SessionID": "synthetic-session",
                            "EnableSessionSSL": True}, fmt)
                with wrap(conn) as tls:
                    request = receive(tls); requests.append(request["Request"])
                    assert request["Request"] == "StartService"
                    assert request["Service"] == "com.apple.internal.devicecompute.CoreDeviceProxy"
                    send(tls, {"Request": "StartService", "Port": service_listener.getsockname()[1],
                               "EnableServiceSSL": encrypted}, fmt)
                    if mismatch:
                        assert tls.recv(1) == b""
                        return
                    request = receive(tls); requests.append(request["Request"])
                    assert request["Request"] == "StopSession"
                    assert request["SessionID"] == "synthetic-session"
                    send(tls, {"Request": "StopSession", "Result": "Success"}, fmt)
                    assert tls.recv(1) == b""
        except BaseException as e:
            errors.append(e)
        finally:
            session_listener.close()
    threads = [threading.Thread(target=f) for f in (service_peer, session_peer)]
    for t in threads: t.start()
    result = subprocess.run([str(EXE), str(DATA), mode, str(session_listener.getsockname()[1])],
                            env=ENV, capture_output=True, text=True, timeout=20)
    for t in threads:
        t.join(12); assert not t.is_alive()
    assert result.returncode == 0, (mode, result.returncode, result.stdout, result.stderr, errors)
    assert not errors, (mode, errors)
    assert requests == (["StartSession", "StartService"] if mismatch else ["StartSession", "StartService", "StopSession"])
    print(result.stdout, end="", flush=True)

for mode in ("lockdown_plain_service", "lockdown_tls_service", "lockdown_service_mismatch"):
    run(mode)
print("PASS: actual core state machine + actual TLS, two live contexts, independent XML/binary plist peer")
