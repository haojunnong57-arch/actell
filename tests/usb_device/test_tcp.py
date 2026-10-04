"""Production C server over localhost; no USB enumeration or real HID input."""
import hashlib, hmac, os, pathlib, signal, socket, subprocess, time, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
KEY = bytes(range(32))  # Public test vector; never used by device firmware.

def mac(text):
    return hmac.new(KEY, text.encode('ascii'), hashlib.sha256).hexdigest()

class TCPContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); cls.port=reservation.getsockname()[1]
        cls.server = subprocess.Popen([str(ROOT / '.build/usb-device-tests/server')], env={**os.environ, 'PA_TEST_HID':'1', 'PA_TEST_PORT':str(cls.port)})
        for _ in range(100):
            try:
                probe=socket.create_connection(('127.0.0.1',cls.port), timeout=.1)
                probe.recv(256); probe.close(); time.sleep(.1); return
            except ConnectionRefusedError:
                if cls.server.poll() is not None: break
                time.sleep(.05)
        cls.server.terminate(); cls.server.wait(timeout=2)
        raise RuntimeError('host test server failed to start')
    @classmethod
    def tearDownClass(cls):
        cls.server.terminate(); cls.server.wait(timeout=2)
    def setUp(self):
        time.sleep(.1)
        self.sock = socket.create_connection(('127.0.0.1',self.port), timeout=2)
        self.stream = self.sock.makefile('rb')
        self.addCleanup(self.sock.close)
        self.addCleanup(self.stream.close)
        self.nonce = self.stream.readline().decode().strip().split()[2]
        self.sock.sendall(f'PA1 AUTH {mac("auth|"+self.nonce)}\n'.encode())
        self.assertEqual(self.read_signed(), 'READY 1')
    def send(self, body):
        self.sock.sendall(f'{body} {mac("client|"+self.nonce+"|"+body)}\n'.encode())
    def read_signed(self):
        line=self.stream.readline().decode().strip()
        body, signature=line.rsplit(' ',1)
        self.assertTrue(hmac.compare_digest(mac('server|'+self.nonce+'|'+body),signature))
        return body
    def test_ping_tap_duplicate_and_conflicting_id(self):
        self.send('1 PING'); self.assertEqual(self.read_signed(),'1 executed')
        self.send('2 TAP 65535 0'); self.assertEqual(self.read_signed(),'2 received'); self.assertEqual(self.read_signed(),'2 executed')
        self.send('2 TAP 65535 0'); self.assertEqual(self.read_signed(),'2 executed')
        self.send('2 TAP 0 0'); self.assertEqual(self.stream.readline(),b'')
    def test_drag_ack_and_ping_multiplexing(self):
        self.send('1 PING'); self.assertEqual(self.read_signed(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 250'); self.assertEqual(self.read_signed(),'2 received')
        self.send('3 PING'); self.assertEqual(self.read_signed(),'3 executed')
        self.assertEqual(self.read_signed(),'2 executed')
    def test_missing_heartbeat_revokes_active_input(self):
        self.send('1 PING'); self.assertEqual(self.read_signed(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 2000'); self.assertEqual(self.read_signed(),'2 received')
        self.assertEqual(self.stream.readline(),b'')
    def test_stop_releases_and_closes_session(self):
        self.send('1 PING'); self.assertEqual(self.read_signed(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 2000'); self.assertEqual(self.read_signed(),'2 received')
        self.send('3 STOP'); self.assertEqual(self.read_signed(),'3 executed')
        self.assertEqual(self.stream.readline(),b'')
    def test_bus_epoch_change_revokes_session(self):
        self.send('1 PING'); self.assertEqual(self.read_signed(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 2000'); self.assertEqual(self.read_signed(),'2 received')
        self.server.send_signal(signal.SIGUSR1)
        self.assertEqual(self.stream.readline(),b'')
    def test_signature_tamper_never_accepted(self):
        self.sock.sendall(('1 TAP 0 0 '+'0'*64+'\n').encode())
        self.assertEqual(self.stream.readline(),b'')
    def test_oversized_line_closes(self):
        self.sock.sendall(b'A'*257+b'\n'); self.assertEqual(self.stream.readline(),b'')

class AuthenticationModes(unittest.TestCase):
    def start(self, locked=False):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
        env={**os.environ,'PA_TEST_PORT':str(port)}
        env.pop('PA_TEST_HID',None); env.pop('PA_TEST_LOCKED',None)
        if locked: env['PA_TEST_LOCKED']='1'
        server=subprocess.Popen([str(ROOT / '.build/usb-device-tests/server')],env=env)
        def cleanup():
            server.terminate(); server.wait(timeout=2)
        self.addCleanup(cleanup)
        for _ in range(100):
            try:
                conn=socket.create_connection(('127.0.0.1',port),timeout=2)
                self.addCleanup(conn.close)
                stream=conn.makefile('rb'); self.addCleanup(stream.close)
                return conn,stream
            except ConnectionRefusedError:
                if server.poll() is not None: break
                time.sleep(.05)
        self.fail('server did not start')
    def test_unprovisioned_device_is_locked(self):
        conn,stream=self.start(locked=True)
        self.assertEqual(stream.readline(),b'PA1 LOCKED\n')
        self.assertEqual(stream.readline(),b'')
    def test_ncm_only_authenticated_round_trip_rejects_input(self):
        conn,stream=self.start()
        nonce=stream.readline().decode().strip().split()[2]
        conn.sendall(f'PA1 AUTH {mac("auth|"+nonce)}\n'.encode())
        self.assertEqual(stream.readline().decode().strip(),f'READY 0 {mac("server|"+nonce+"|READY 0")}')
        for body in ['1 PING','2 TAP 0 0']:
            conn.sendall(f'{body} {mac("client|"+nonce+"|"+body)}\n'.encode())
            if body=='1 PING':
                self.assertEqual(stream.readline().decode().strip(),f'1 executed {mac("server|"+nonce+"|1 executed")}')
            else: self.assertEqual(stream.readline(),b'')
    def test_bad_authentication_closes_before_any_command(self):
        conn,stream=self.start(); self.assertTrue(stream.readline().startswith(b'PA1 CHALLENGE '))
        conn.sendall(('PA1 AUTH '+'0'*64+'\n').encode())
        self.assertEqual(stream.readline(),b'')

if __name__ == '__main__': unittest.main(verbosity=2)
