"""OM FBD1 transport, derived from frozen OL framing. No serial device is opened by this module.

The persistent allocator reserves sequence ranges before transmitting. Reconnect
never restarts at one. A disconnected connection never implies DDR residency.
"""
from pathlib import Path
import hashlib
import json
import math
import os
import struct
import time
import zlib

MAGIC = b'FBD1'
HEADER = struct.Struct('<4sBBBBIIII')
HELLO, READ, WRITE, START, STATUS, RESULT, SESSION, REARM = range(1, 9)
BOARD_BUILD = 0x26102420
SUMMARY_ACK = 13
VIDEO_ARM, VIDEO_STATUS, VIDEO_STOP, VIDEO_RECOVER = range(9,13)
CPU_BUILD = 0x261007a1
MAX_PAYLOAD = 512


class ProtocolError(ValueError):
    pass


class IndeterminateTransportError(RuntimeError):
    """An incomplete outbound frame must not be replayed into the RX parser."""
    pass


class BoardError(RuntimeError):
    def __init__(self, status):
        self.status = status
        names = ['OK', 'BAD_CRC', 'BAD_FORMAT', 'BAD_RANGE', 'BUSY',
                 'MEMORY_ERROR', 'NOT_READY', 'SEQUENCE_ERROR']
        super().__init__(names[status] if status < len(names) else str(status))


def encode(op, seq, address=0, length=0, payload=b'', status=0):
    expected = length if op in (WRITE, VIDEO_ARM) or op & 0x80 else 0
    if len(payload) != expected or length > MAX_PAYLOAD:
        raise ProtocolError('Payload extent')
    prefix = HEADER.pack(MAGIC, 1, op, status, 0, seq, address, length, 0)[:20]
    crc = zlib.crc32(prefix + payload) & 0xffffffff
    return prefix + struct.pack('<I', crc) + payload


def decode(packet):
    if len(packet) < HEADER.size:
        raise ProtocolError('Short header')
    magic, version, op, status, flags, seq, address, length, crc = HEADER.unpack(packet[:24])
    if magic != MAGIC or version != 1 or flags or length > MAX_PAYLOAD:
        raise ProtocolError('Header identity')
    extent = length if op in (WRITE, VIDEO_ARM) or op & 0x80 else 0
    if len(packet) != 24 + extent:
        raise ProtocolError('Packet extent')
    payload = packet[24:]
    if zlib.crc32(packet[:20] + payload) & 0xffffffff != crc:
        raise ProtocolError('CRC')
    return dict(op=op, status=status, seq=seq, address=address, length=length, payload=payload)


class PersistentSequence:
    """One locked high-water file per host; crash-safe gaps are intentional.

    If another client used a larger sequence, fail closed on SEQUENCE_ERROR.
    The console cannot query the board high-water or infer a cold reset. Keep
    this state file; resolve other clients/confirmed reconfiguration explicitly.
    Never delete state to work around a live-board sequence rejection.
    """
    def __init__(self, path, block=256):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.block = block
        self.next_value = self.limit = 0
        self.lock = self.path.with_suffix('.lock').open('a+b')
        self.lock.seek(0, 2)
        if not self.lock.tell():
            self.lock.write(b'0'); self.lock.flush()
        self.lock.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(self.lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            self.lock.close()
            raise RuntimeError('Sequence state already owned by another client')

    def take(self):
        if self.next_value == self.limit:
            previous = 0
            if self.path.exists():
                state = json.loads(self.path.read_text(encoding='utf-8'))
                if state.get('schema') != 'OL_SEQUENCE_V1':
                    raise RuntimeError('Unrecognized sequence state; cannot safely reset')
                previous = state['reserved_through']
                if type(previous) is not int or not 0 <= previous <= 0xfffffffe:
                    raise RuntimeError('Invalid sequence state')
            end = min(previous + self.block, 0xfffffffe)
            if end <= previous:
                raise RuntimeError('Sequence exhausted; explicit new board session required')
            temporary = self.path.with_suffix('.new')
            with temporary.open('w', encoding='utf-8') as stream:
                json.dump(dict(schema='OL_SEQUENCE_V1', reserved_through=end), stream)
                stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            self.next_value, self.limit = previous + 1, end + 1
        value = self.next_value
        self.next_value += 1
        return value

    def close(self):
        if self.lock is not None:
            self.lock.seek(0)
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(self.lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.lock.close(); self.lock = None


class Client:
    def __init__(self, serial, sequences, timeout=3, attempts=2):
        self.serial, self.sequences = serial, sequences
        self.timeout, self.attempts = timeout, attempts

    def _exact(self, length, deadline):
        data = bytearray()
        while len(data) < length:
            if time.monotonic() >= deadline:
                raise TimeoutError('Serial response deadline')
            data.extend(self.serial.read(length - len(data)))
        return bytes(data)

    def _receive(self):
        deadline = time.monotonic() + self.timeout
        header = self._exact(24, deadline)
        while header[:4] != MAGIC:
            header = header[1:] + self._exact(1, deadline)
        length = HEADER.unpack(header)[7]
        if length > MAX_PAYLOAD:
            raise ProtocolError('Reply too large')
        return decode(header + self._exact(length, deadline))

    def request(self, op, address=0, length=0, payload=b''):
        began=time.perf_counter()
        seq = self.sequences.take()
        packet = encode(op, seq, address, length, payload)
        expected = length if op == READ else 64 if op in (HELLO, STATUS, RESULT, SESSION, VIDEO_STATUS) else 0
        for attempt in range(self.attempts):
            # Only a completely submitted request can use the endpoint's
            # exact-packet replay cache. A short/failed write is indeterminate.
            try:
                written=self.serial.write(packet)
                if written != len(packet):
                    raise IndeterminateTransportError('Partial serial write; disconnect before recovery')
                self.serial.flush()
            except IndeterminateTransportError:
                raise
            except Exception as error:
                raise IndeterminateTransportError('Serial submission failed; disconnect before recovery') from error
            try:
                for _ in range(8):
                    reply = self._receive()
                    if reply['seq'] == seq:
                        break
                else:
                    raise ProtocolError('Too many stale responses')
                if reply['op'] != op | 0x80 or reply['address'] != address:
                    raise ProtocolError('Reply identity')
                if reply['status']:
                    raise BoardError(reply['status'])
                if reply['length'] != expected:
                    raise ProtocolError('Reply extent')
                recorder=getattr(self.serial,'record_transaction',None)
                if recorder:recorder(dict(op=op,seq=seq,address=address,request_bytes=len(packet),reply_bytes=24+reply['length'],attempt=attempt,seconds=time.perf_counter()-began))
                return reply['payload']
            except (TimeoutError, ProtocolError):
                if attempt + 1 == self.attempts:
                    raise
                # Exact duplicate seq/header/payload: RTL replays cached ACK.
            except BoardError as error:
                if error.status != 1 or attempt + 1 == self.attempts:
                    raise
                # CRC-rejected requests have no effect; retry unchanged bytes.

    def snapshot(self):
        return parse_status(self.request(STATUS))

    def session(self):
        return parse_session(self.request(SESSION))

    def result_page(self, page):
        if not 0 <= page <= 32:
            raise ValueError('Result page outside 0..32')
        return self.request(RESULT, address=page)

    def start(self, generation):
        return self.request(START, address=generation)

    def rearm(self, generation):
        before = self.session()
        return self.rearm_checked(generation,before)

    def rearm_checked(self,generation,before):
        if before['generation'] != generation or not all(before[k] for k in
                ('rearm_allowed', 'memory_drained', 'results_acknowledged')):
            raise RuntimeError('REARM requires matching generation, acknowledged result and real drain')
        self.request(REARM, address=generation)
        after = self.session()
        if after['generation'] != generation + 1 or not after['start_allowed'] or after['pages_seen']:
            raise ProtocolError('REARM ACK not followed by clean next-generation BOOT')
        return after

    def collect(self, generation, include_embedding=True):
        return self._collect(generation,include_embedding)

    def collect_from_video(self,generation,observation,include_embedding=True):
        # The immediately preceding VIDEO_STATUS already carries this generation.
        # No persistent cache: qualified source belongs to this serial-owner call.
        if not observation.get('result_ready') or observation.get('result_source_id')!=1 or any(
                observation.get(k)!=generation for k in ('session_generation','held_session_generation','result_session_generation')):
            raise ProtocolError('Result/video generation not qualified')
        return self._collect(generation,include_embedding,qualified_video=True)

    def _collect(self, generation, include_embedding,qualified_video=False):
        self.last_collect_session=None
        if not qualified_video:
            before = self.session()
            if before['generation'] != generation:
                raise ProtocolError('Result generation changed')
        result = parse_result(self.result_page(0))
        embedding = b''.join(self.result_page(p) for p in range(1, 33)) if result['has_face'] and include_embedding else b''
        if result['has_face'] and not include_embedding:
            self.request(SUMMARY_ACK, address=generation)
        after = self.session()
        if after['generation'] != generation or not after['results_acknowledged']:
            raise ProtocolError('Result page ACK/generation incomplete')
        if after['has_face'] != result['has_face']:
            raise ProtocolError('Result/session has_face mismatch')
        if embedding:
            values = struct.unpack('<512f', embedding)
            if not all(math.isfinite(v) for v in values):
                raise ProtocolError('Nonfinite embedding')
            result.update(embedding_sha256=hashlib.sha256(embedding).hexdigest(), embedding_words=512)
        result.update(generation=generation, result_page_mask=after['pages_seen'], export_mode='feature' if embedding else 'summary')
        self.last_collect_session=dict(after)
        return result, embedding


def parse_session(data):
    words = list(struct.unpack('<16I', data))
    if words[:2] != [0x31534553, 1] or words[7] != 32 or any(words[8:]) or words[3] & ~15 or words[4] & ~1 or words[6] & ~1:
        raise ProtocolError('SESSION ABI')
    flags = words[3]
    return dict(raw=words, generation=words[2], start_allowed=bool(flags & 1),
                rearm_allowed=bool(flags & 2), memory_drained=bool(flags & 4),
                results_acknowledged=bool(flags & 8), pages_seen=words[5] | (words[4] << 32),
                has_face=bool(words[6]), embedding_pages=words[7])


def parse_status(data):
    words = list(struct.unpack('<16I', data))
    if words[:2] != [0x31444246, 1]:
        raise ProtocolError('Status ABI')
    t, flags = words[8], words[3]
    result = dict(raw=words, build_id=f'{words[2]:08x}', supported=words[2] == BOARD_BUILD,
        temp_valid=bool(t & 1), temp_fault=(t >> 1) & 7, over_temp=bool(t & 16),
        temperature_C=round(words[7] * .1219 - 273.15, 2) if t & 1 else None,
        temperature_scope='ADC estimate; not independently calibrated')
    if words[2] in (BOARD_BUILD, 0x261006f1):
        result.update(kind='QL HDMI Retina+MBF' if result['supported'] else 'Legacy face build; read-only',
            face_program=True, phase=flags & 7, ddr_ready=bool(flags & 64),
            safety_ready=bool(flags & 256), fault=bool(flags & 512), done=bool(flags & 1024),
            result_committed=bool(flags & 2048), cpu_Hz=words[4], npu_Hz=words[5],
            ui_Hz=words[6], cpu_status=words[9], cpu_phase=words[10], task=words[11],
              read_bytes=words[12], write_bytes=words[13],
              fault_detail=words[15],transport_fault=bool(words[15]&0x100),
              core_fault=bool(words[15]&0x200),client_fault=bool(words[15]&0x400),
              result_fault=bool(words[15]&0x800),ddr_bridge_fault_code=words[15]&255)
    else:
        result.update(kind='Unsupported build; read-only', face_program=False)
    return result


def parse_result(data):
    words = list(struct.unpack('<16I', data))
    if words[:3] != [0x31445246, 1, CPU_BUILD]:
        raise ProtocolError('CPU FRD1 ABI/build')
    score = struct.unpack('<f', struct.pack('<I', words[8]))[0]
    threshold = struct.unpack('<f', struct.pack('<I', words[10]))[0]
    if not all(math.isfinite(v) and -1 <= v <= 1 for v in (score, threshold)):
        raise ProtocolError('CPU cosine/threshold')
    signed = lambda value: value if value < 0x80000000 else value - 0x100000000
    center = [signed(v) / 65536 for v in words[12:16]]
    cx, cy, width, height = center
    has_face = bool(words[3] & 1)
    if has_face and (width < 0 or height < 0):
        raise ProtocolError('Negative face extent')
    return dict(source='FPGA original CPU committed result', has_face=has_face,
        accepted=bool(words[3] & 2), has_match=bool(words[3] & 4),
        selected_anchor=words[4], candidates=words[5], kept=words[6], identity=words[7],
        cosine=score, gallery_count=words[9], gallery_revision=words[11], threshold=threshold,
        box_center_wh_pixels=center,
        box_xyxy=[cx-width/2, cy-height/2, cx+width/2, cy+height/2] if has_face else None,
        box_semantics='FRD1 signed Q16 center x/y, width/height converted to pixel xyxy', raw=words)
