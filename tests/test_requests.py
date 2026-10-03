#!/usr/bin/env python3
"""Synthetic byte-equivalence/streaming tests. Never connects to an iPhone."""
import ctypes as C
import importlib.util
import pathlib
import random
import struct
import sys
import uuid
import zlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
from reference_source import reference_file
spec = importlib.util.spec_from_file_location('pinned_xpc', reference_file('xpc_message.py'))
x = importlib.util.module_from_spec(spec); sys.modules[spec.name] = x; spec.loader.exec_module(x)
lib = C.CDLL(sys.argv[1]); u8 = C.c_uint8; P = C.POINTER(u8); SZ = C.c_size_t; U = x.XpcUInt64Type; I = x.XpcInt64Type
class Invocation(C.Structure):
    _fields_=[('device_identifier',C.c_char_p),('invocation_identifier',C.c_char_p),('message_id',C.c_uint64)]
did=b'11111111-1111-4111-8111-111111111111'; iid=b'22222222-2222-4222-8222-222222222222'; inv=Invocation(did,iid,9)
lib.bridge_request_screenshot.argtypes=[C.POINTER(Invocation),C.c_char_p,P,SZ,C.POINTER(SZ)]
lib.bridge_request_touch_report.argtypes=[C.c_uint64,C.c_uint64,P,P,SZ,C.POINTER(SZ)]
lib.bridge_request_home.argtypes=[C.c_uint64,C.c_uint32,P,SZ,C.POINTER(SZ)]
lib.bridge_request_media_start.argtypes=[C.POINTER(Invocation),P,C.c_char_p,C.c_uint16,C.c_char_p,P,SZ,P,SZ,C.POINTER(SZ)]
lib.bridge_request_media_stop.argtypes=[C.POINTER(Invocation),C.c_uint32,P,SZ,C.POINTER(SZ)]
def invoke(input_, feature, action):
    return {'CoreDevice.CoreDeviceDDIProtocolVersion':I(2), 'CoreDevice.coreDeviceVersion':{'components':[U(629),U(3)],'originalComponentsCount':I(2),'stringValue':'629.3'},'CoreDevice.deviceIdentifier':did.decode(),'CoreDevice.input':input_,'CoreDevice.invocationIdentifier':iid.decode(),'CoreDevice.featureIdentifier':feature,'CoreDevice.action':{},'CoreDevice.actionIdentifier':action}
def encoded(fn,args,expected,reply=False,mid=9):
    out=(u8*8192)(); n=SZ()
    assert fn(*args,out,len(out),C.byref(n))==0
    expected_bytes=x.create_xpc_wrapper(expected, message_id=mid, wanting_reply=reply)
    assert bytes(out[:n.value])==expected_bytes
    short=(u8*(n.value-1))(*([165]*(n.value-1))); bad_n=SZ(999)
    assert fn(*args,short,len(short),C.byref(bad_n))==5 and bad_n.value==0
    assert bytes(short)==bytes([165]*len(short))
    return bytes(out[:n.value])
encoded(lib.bridge_request_screenshot,[C.byref(inv),None],invoke({'displayUniqueID':None,'requestedFormat':'png'},'com.apple.coredevice.feature.capturescreenshot','com.apple.coredevice.action.capturescreenshot'),True)
report=bytes([9,1,5,194])+struct.pack('<HH',32768,53600)+bytes(32)+b'\2\0\0\0'+(123456789).to_bytes(6,'little')+bytes(8)
r=(u8*58).from_buffer_copy(report)
encoded(lib.bridge_request_touch_report,[9,257,r],{'featureIdentifier':'com.apple.coredevice.feature.remote.universalhidservice','messageType':'Request','payload':{'send':{'_0':report,'_1':U(257)}}})
for state in [1,2,3]:
    encoded(lib.bridge_request_home,[9,state],{'messageType':'IndigoButtonEvent','payload':{'state':U(state),'usagePage':U(12),'usageCode':U(64)},'featureIdentifier':'com.apple.coredevice.feature.remote.hid.button'})
uid=uuid.UUID('33333333-3333-4333-8333-333333333333'); ua=(u8*16).from_buffer_copy(uid.bytes)
# Deliberately only a bplist signature for envelope testing. NOT a usable offer.
offer=b'bplist00'; oa=(u8*8).from_buffer_copy(offer)
input_={'clientSupportedFeatures':U(140),'direction':'output','negotiatorOffer':offer,'options':{'AVCMediaStreamNegotiatorAccessNetworkType':{'int':I(1)},'AVCMediaStreamNegotiatorTransportProtocolType':{'int':I(2)},'CoreDeviceVideoDisplayMode':{'string':'DisplayByID'},'VideoStreamForDisplayID':{'int':I(1)},'avcMediaStreamOptionClientSessionID':{'uuid':uid}},'receiverIP':'fd00::1','receiverPort':U(12345),'senderIP':'fd00::2','timeout':U(20),'type':'video'}
encoded(lib.bridge_request_media_start,[C.byref(inv),ua,b'fd00::1',12345,b'fd00::2',oa,8],invoke(input_,'com.apple.coredevice.feature.startmediastream','com.apple.coredevice.action.mediastreamstart'),True)
encoded(lib.bridge_request_media_stop,[C.byref(inv),42],invoke({'stopAll':False,'identifiers':[U(42)]},'com.apple.coredevice.feature.stopmediastream','com.apple.coredevice.action.mediastreamstop'),True)

READ=C.CFUNCTYPE(C.c_ssize_t,C.c_void_p,P,SZ,C.c_uint32)
WRITE=C.CFUNCTYPE(C.c_ssize_t,C.c_void_p,P,SZ,C.c_uint32)
CLOCK=C.CFUNCTYPE(C.c_uint64,C.c_void_p)
SINK=C.CFUNCTYPE(C.c_int,C.c_void_p,P,SZ)
class IO(C.Structure): _fields_=[('context',C.c_void_p),('read',READ),('write',WRITE),('clock_ms',CLOCK)]
class PNGInfo(C.Structure): _fields_=[('image_bytes',C.c_uint32),('width',C.c_uint32),('height',C.c_uint32),('message_id',C.c_uint64)]
lib.bridge_xpc_extract_png.argtypes=[C.POINTER(IO),C.c_uint32,P,SZ,SINK,C.c_void_p,C.c_uint64,C.POINTER(PNGInfo)]
def png(width,height):
    def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b))
    rows=(b'\0'+bytes(width*3))*height
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows,level=0))+chunk(b'IEND',b'')
def stream(msg,expected=None,step=127,fail_sink=False,limit=None,deadline=10**12,slow_sink=False):
    pos=0; time=0; emitted=0; crc=0; max_chunk=0
    @READ
    def read(_,buf,n,timeout):
        nonlocal pos,time
        take=min(n,step,len(msg)-pos); time+=1
        if take: C.memmove(buf,msg[pos:pos+take],take)
        pos+=take; return take
    @CLOCK
    def clock(_): return time
    @SINK
    def sink(_,buf,n):
        nonlocal emitted,crc,max_chunk,time
        if fail_sink: return 2
        emitted+=n; crc=zlib.crc32(C.string_at(buf,n),crc); max_chunk=max(max_chunk,n)
        if slow_sink: time+=deadline
        return 0
    io=IO(None,read,WRITE(),clock); scratch=(u8*256)(); info=PNGInfo()
    result=lib.bridge_xpc_extract_png(C.byref(io),limit or 16*1024*1024,scratch,256,sink,None,deadline,C.byref(info))
    if result==0:
        assert pos==len(msg) and info.image_bytes==emitted and max_chunk<=256
        if expected is not None: assert emitted==len(expected) and crc==zlib.crc32(expected)
    else: assert info.image_bytes==0 and info.width==0
    return result,info,emitted
small=png(17,31)
msg=x.create_xpc_wrapper({'CoreDevice.output':{'image':small,'imageFormat':'png','displayUniqueID':'synthetic'}},message_id=88)
for step in [1,3,17,127,4096]:
    result,info,_=stream(msg,small,step); assert result==0 and info.width==17 and info.height==31 and info.message_id==88
for end in range(len(msg)):
    assert stream(msg[:end],step=100000)[0]!=0
assert stream(msg,limit=len(msg)-1)[0]==5
assert stream(msg,fail_sink=True)[0]==2
assert stream(msg,slow_sink=True)[0]==4
assert stream(msg,deadline=2)[0]==4
for obj in [
    {'CoreDevice.output':{'image':b'not a PNG'}},
    {'CoreDevice.output':{'image':small,'imageFormat':'jpeg'}},
    {'CoreDevice.output':{'image':small},'CoreDevice.error':{'code':I(1)}},
    {'CoreDevice.output':{'unrelated':small}},
    {'CoreDevice.output':{'image':'text'}},
]: assert stream(x.create_xpc_wrapper(obj))[0]!=0
# Deterministic target/path/container regressions, including errors after bytes emit.
wrong = x.create_xpc_wrapper({'CoreDevice.output':{'nested':{'image':small}}})
assert stream(wrong)[0] == 8 and stream(wrong)[2] == 0
nested = {'image':small}
for _ in range(18): nested = {'nested':nested}
post_image = x.create_xpc_wrapper({'CoreDevice.output':{'image':small},'after':nested})
status,info,emitted = stream(post_image)
assert status == 5 and emitted == len(small) and info.image_bytes == 0

def raw_dict(entries):
    body=struct.pack('<I',len(entries))
    for k,v in entries:
        key=k.encode()+b'\0'; body += key + bytes((-len(key)) % 4) + v
    return struct.pack('<II',0xf000,len(body))+body

def raw_data(b): return struct.pack('<II',0x8000,len(b))+b+bytes((-len(b))%4)
def wrapper(root):
    payload=struct.pack('<II',0x42133742,5)+root
    return struct.pack('<IIQQ',0x29b00b92,0x101,len(payload),77)+payload
for root in [
    raw_dict([('CoreDevice.output',raw_dict([('image',raw_data(small)),('image',raw_data(small))]))]),
    raw_dict([('CoreDevice.output',raw_dict([('image',raw_data(small))])),('CoreDevice.output',raw_dict([]))]),
]:
    status,info,emitted=stream(wrapper(root)); assert status==6 and emitted==len(small) and info.image_bytes==0
bad_count=bytearray(msg); struct.pack_into('<I',bad_count,40,1000000)
assert stream(bytes(bad_count))[0]==5
rng=random.Random(0x29b00b92)
for _ in range(5000):
    mutated=bytearray(msg)
    for _ in range(rng.randrange(1,6)): mutated[rng.randrange(len(mutated))]=rng.randrange(256)
    stream(bytes(mutated),step=4096)
# Valid synthetic RGB PNG is >8 MiB. Only 256-byte caller scratch is used by C;
# host generator holds the input, sink keeps CRC/count only, no image copy.
large=png(1024,3072); assert len(large)>8*1024*1024
large_msg=x.create_xpc_wrapper({'CoreDevice.output':{'image':large,'imageFormat':'png'}},message_id=99)
result,info,_=stream(large_msg,large,step=997)
assert result==0 and info.width==1024 and info.height==3072
print(f'PASS: 7 request envelopes match pinned XPC serialization; bounded PNG extraction streamed {len(large):,} synthetic PNG bytes with 256-byte scratch; malformed/truncation/deadline cases pass')
