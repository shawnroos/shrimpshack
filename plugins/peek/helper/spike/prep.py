# Throwaway U1 spike prep: writes test pictures in three forms for /peek-spike.
import base64, os, struct, zlib
from multiprocessing import shared_memory

W, H = 160, 80
os.makedirs('/tmp/claude-peek', exist_ok=True)

def pixels(r, g, b):
    return bytes([r, g, b, 255]) * (W * H)

def png_bytes(r, g, b):
    raw = b''.join(b'\x00' + bytes([r, g, b]) * W for _ in range(H))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

for name, color in (('a', (215, 153, 33)), ('b', (131, 165, 152))):
    open(f'/tmp/claude-peek/spike-{name}.rgba', 'wb').write(pixels(*color))
    open(f'/tmp/claude-peek/spike-{name}.png.b64', 'w').write(base64.b64encode(png_bytes(*color)).decode())

for i in range(40):
    try:
        shared_memory.SharedMemory(name=f'pkspk{i}', track=False).unlink()
    except FileNotFoundError:
        pass
    shm = shared_memory.SharedMemory(name=f'pkspk{i}', create=True, size=W * H * 4, track=False)
    data = pixels(184, 187, 38) if i % 2 else pixels(211, 134, 155)
    shm.buf[:len(data)] = data
    shm.close()
print('ok')

# Full-pane stream frames: a bar sweeping left to right with the frame number, as PNG and raw rgba files.
SW, SH, N = 1200, 800, 30
FONT = {'0': '111101101101111', '1': '010110010010111', '2': '111001111100111', '3': '111001111001111', '4': '101101111001001',
        '5': '111100111001111', '6': '111100111101111', '7': '111001001001001', '8': '111101111101111', '9': '111101111001111'}

def stream_frame(n):
    rows = [bytearray(b'\x28\x28\x28' * SW) for _ in range(SH)]
    for y in range(0, 140):
        rows[y][:] = os.urandom(SW * 3)
    x0 = int(n * (SW - 120) / (N - 1))
    for y in range(600, 700):
        rows[y][x0 * 3:(x0 + 120) * 3] = b'\xd7\x99\x21' * 120
    for d, ch in enumerate(f'{n:02d}'):
        bits = FONT[ch]
        for r in range(5):
            for c in range(3):
                if bits[r * 3 + c] == '1':
                    for y in range(100 + r * 80, 180 + r * 80):
                        x = 420 + d * 300 + c * 80
                        rows[y][x * 3:(x + 80) * 3] = b'\xeb\xdb\xb2' * 80
    return rows

def png_of_size(rows, w, h):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 1)) + chunk(b'IEND', b'')

def png_of(rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SW, SH, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 1)) + chunk(b'IEND', b'')

for n in range(N):
    rows = stream_frame(n)
    open(f'/tmp/claude-peek/stream-{n}.png', 'wb').write(png_of(rows))
    open(f'/tmp/claude-peek/stream-{n}.rgb', 'wb').write(b''.join(bytes(r) for r in rows))
    half = [bytearray(b''.join(bytes(r[x * 3:x * 3 + 3]) for x in range(0, SW, 2))) for r in rows[::2]]
    open(f'/tmp/claude-peek/stream-half-{n}.png', 'wb').write(png_of_size(half, SW // 2, SH // 2))
print('stream ok')
