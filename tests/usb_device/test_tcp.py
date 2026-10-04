"""Production C server over localhost; no USB enumeration or real HID input."""
import os, pathlib, signal, socket, subprocess, time, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]

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
        self.assertEqual(self.stream.readline(), b'PA2 READY 1\n')
    def send(self, body):
        self.sock.sendall(f'{body}\n'.encode('ascii'))
    def read_ack(self):
        line = self.stream.readline()
        self.assertTrue(line.endswith(b'\n'))
        return line[:-1].decode('ascii')
    def test_ping_tap_duplicate_and_conflicting_id(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 TAP 65535 0'); self.assertEqual(self.read_ack(),'2 received'); self.assertEqual(self.read_ack(),'2 executed')
        self.send('2 TAP 65535 0'); self.assertEqual(self.read_ack(),'2 executed')
        self.send('2 TAP 0 0'); self.assertEqual(self.stream.readline(),b'')
    def test_drag_ack_and_ping_multiplexing(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 250'); self.assertEqual(self.read_ack(),'2 received')
        self.send('3 PING'); self.assertEqual(self.read_ack(),'3 executed')
        self.assertEqual(self.read_ack(),'2 executed')
    def test_missing_heartbeat_revokes_active_input(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.assertEqual(self.stream.readline(),b'')
    def test_stop_releases_and_closes_session(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.send('3 STOP'); self.assertEqual(self.read_ack(),'3 executed')
        self.assertEqual(self.stream.readline(),b'')
    def test_bus_epoch_change_revokes_session(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.server.send_signal(signal.SIGUSR1)
        self.assertEqual(self.stream.readline(),b'')
    def test_old_signed_command_never_accepted(self):
        self.sock.sendall(('1 TAP 0 0 '+'0'*64+'\n').encode())
        self.assertEqual(self.stream.readline(),b'')
    def test_oversized_line_closes(self):
        self.sock.sendall(b'A'*257+b'\n'); self.assertEqual(self.stream.readline(),b'')
    def test_input_requires_ping_on_each_connection(self):
        self.send('1 TAP 0 0'); self.assertEqual(self.stream.readline(), b'')
    def test_fragmented_and_coalesced_lines(self):
        self.sock.sendall(b'1 PI'); self.sock.sendall(b'NG\n2 PING\n')
        self.assertEqual(self.read_ack(), '1 executed'); self.assertEqual(self.read_ack(), '2 executed')
    def test_retired_id_does_not_reexecute(self):
        for command_id in range(1, 35):
            self.send(f'{command_id} PING'); self.assertEqual(self.read_ack(), f'{command_id} executed')
        self.send('1 PING'); self.assertEqual(self.stream.readline(), b'')

class NCMOnly(unittest.TestCase):
    def start(self):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
        env={**os.environ,'PA_TEST_PORT':str(port)}
        env.pop('PA_TEST_HID',None)
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
    def test_no_credentials_needed_for_ping_and_stop(self):
        conn,stream=self.start()
        self.assertEqual(stream.readline(), b'PA2 READY 0\n')
        conn.sendall(b'1 PING\n'); self.assertEqual(stream.readline(), b'1 executed\n')
        conn.sendall(b'2 STOP\n'); self.assertEqual(stream.readline(), b'2 executed\n')
        self.assertEqual(stream.readline(),b'')
    def test_ncm_only_rejects_input_after_ping(self):
        conn,stream=self.start()
        self.assertEqual(stream.readline(), b'PA2 READY 0\n')
        conn.sendall(b'1 PING\n'); self.assertEqual(stream.readline(), b'1 executed\n')
        conn.sendall(b'2 TAP 0 0\n'); self.assertEqual(stream.readline(), b'')
    def test_old_authentication_request_is_rejected(self):
        conn,stream=self.start(); self.assertEqual(stream.readline(), b'PA2 READY 0\n')
        conn.sendall(('PA1 AUTH '+'0'*64+'\n').encode())
        self.assertEqual(stream.readline(),b'')
    def test_malformed_lines_close_session(self):
        for line in [b'01 PING\n', b'1 PING \n', b'1 PING\r\n', b'1\tPING\n', b'1 PING\x00\n']:
            with self.subTest(line=line):
                conn,stream=self.start(); self.assertEqual(stream.readline(), b'PA2 READY 0\n')
                conn.sendall(line); self.assertEqual(stream.readline(), b'')

if __name__ == '__main__': unittest.main(verbosity=2)
