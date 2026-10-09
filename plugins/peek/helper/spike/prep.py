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
