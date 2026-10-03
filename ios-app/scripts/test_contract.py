#!/usr/bin/env python3
"""Independent wire-contract fixture tests. These do not execute Swift code."""
import base64, hashlib, json, pathlib, struct, unittest, zlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
MAX_FRAME = 65536

def frame(message):
    data = json.dumps(message, ensure_ascii=False, separators=(',', ':')).encode()
    if not 0 < len(data) <= MAX_FRAME: raise ValueError('frame limit')
    return struct.pack('>I', len(data)) + data

def receive(pieces):
    pending = bytearray(); messages = []
    for piece in pieces:
        pending.extend(piece)
        while len(pending) >= 4:
            count = int.from_bytes(pending[:4], 'big')
            if not 0 < count <= MAX_FRAME: raise ValueError('frame limit')
            if len(pending) < count + 4: break
            messages.append(json.loads(pending[4:4+count])); del pending[:4+count]
    if pending: raise ValueError('truncated')
    return messages

def png():
    def chunk(kind, data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+b'\x33\xaa\xcc'*2+b'\0'+b'\x33\xaa\xcc'*2))+chunk(b'IEND',b'')

def validate_image(messages):
    expected='tool_ack'; data=bytearray(); sequence=0; image_id=None; ended=False; committed=False
    for m in messages:
        if m['session_id']!='fixture-session' or m['request_id']!='fixture-request' or m['version']!=1: raise ValueError('ids')
        t,p=m['type'],m['payload']
        if expected=='tool_ack':
            if t!='tool_ack' or p.get('accepted') is not True: raise ValueError('ack')
            expected='image_begin'; continue
        if expected=='image_begin':
            if t!='image_begin' or p['mime_type']!='image/png' or not 0<p['max_bytes']<=15728640: raise ValueError('begin')
            image_id=p['image_id']; ceiling=p['max_bytes']; expected='image_chunk'; continue
        if t=='image_chunk':
            b=base64.b64decode(p['data_base64'],validate=True)
            if ended or p['image_id']!=image_id or p['sequence']!=sequence or p['offset']!=len(data) or not 0<len(b)<=16384 or len(data)+len(b)>ceiling: raise ValueError('chunk')
            data.extend(b); sequence+=1
        elif t=='image_end':
            if ended or p['image_id']!=image_id or p['total_bytes']!=len(data) or p['sha256']!=hashlib.sha256(data).hexdigest() or not data.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError('end')
            if not 1<p['width']<=8192 or not 1<p['height']<=8192 or p['width']*p['height']>24000000: raise ValueError('dimensions')
            ended=True
        elif t=='tool_result':
            if not ended or p['status']!='ok' or p['image_id']!=image_id or committed: raise ValueError('commit')
            committed=True
        else: raise ValueError('type')
    if not committed: raise ValueError('not committed')
    return bytes(data)

class ContractTests(unittest.TestCase):
    def setUp(self): self.messages=json.loads((ROOT/'fixtures/screenshot-transcript.json').read_text())
    def test_coalesced_and_bytewise_frames(self):
        raw=b''.join(map(frame,self.messages)); self.assertEqual(receive([raw]),self.messages); self.assertEqual(receive([bytes([b]) for b in raw]),self.messages)
    def test_zero_frame(self):
        with self.assertRaises(ValueError): receive([b'\0'*4])
    def test_oversize_frame(self):
        with self.assertRaises(ValueError): receive([struct.pack('>I',65537)])
    def test_truncation(self):
        with self.assertRaises(ValueError): receive([frame(self.messages[0])[:-1]])
    def test_commit_matches_fixture(self): self.assertEqual(validate_image(self.messages),png())
    def test_missing_commit(self):
        with self.assertRaises(ValueError): validate_image(self.messages[:-1])
    def test_wrong_request(self):
        self.messages[1]['request_id']='wrong'
        with self.assertRaises(ValueError): validate_image(self.messages)
    def test_duplicate_chunk(self):
        self.messages.insert(3,self.messages[2])
        with self.assertRaises(ValueError): validate_image(self.messages)
    def test_out_of_order_chunk(self):
        self.messages[2]['payload']['sequence']=1
        with self.assertRaises(ValueError): validate_image(self.messages)
    def test_corrupt_hash(self):
        self.messages[3]['payload']['sha256']='0'*64
        with self.assertRaises(ValueError): validate_image(self.messages)
    def test_error_result(self):
        self.messages[-1]['payload']['status']='error'
        with self.assertRaises(ValueError): validate_image(self.messages)
    def test_inclusive_coordinates(self):
        for size in (390,1179,2556):
            self.assertEqual(round(0/(size-1)*65535),0); self.assertEqual(round((size-1)/(size-1)*65535),65535)

if __name__=='__main__': unittest.main(verbosity=2)
