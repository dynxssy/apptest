"""Draws the app icon (a screen with a phone-shaped cursor) as PNGs with no dependencies."""
import struct, sys, zlib, math, os

def png(path, w, h, px):
    raw = b''.join(b'\x00' + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

def inside_round_rect(x, y, x0, y0, x1, y1, r):
    cx, cy = min(max(x, x0 + r), x1 - r), min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

def draw(size):
    px = bytearray(size * size * 4)
    S = 4  # supersampling
    for y in range(size):
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(S):
                for sx in range(S):
                    u, v = (x + (sx + .5) / S) / size, (y + (sy + .5) / S) / size
                    # background gradient, full bleed (iOS rounds the corners itself)
                    t = (u + v) / 2
                    c = (int(20 + 30 * t), int(70 + 60 * (1 - t)), int(200 + 40 * (1 - t)), 255)
                    # monitor body
                    if inside_round_rect(u, v, .17, .22, .83, .66, .04):
                        c = (245, 247, 250, 255)
                        if inside_round_rect(u, v, .21, .26, .79, .62, .015):
                            c = (16, 22, 34, 255)
                    # stand
                    if .44 <= u <= .56 and .66 <= v <= .74: c = (235, 238, 242, 255)
                    if inside_round_rect(u, v, .34, .73, .66, .77, .02): c = (235, 238, 242, 255)
                    # pointer arrow on the screen
                    ax, ay = u - .46, v - .33
                    if ax >= 0 and ay >= 0 and ay <= .22 and ax <= ay * .62 and not (ay > .15 and ax < (ay - .15) * 1.2):
                        c = (76, 141, 255, 255)
                    for i in range(4): acc[i] += c[i]
            o = (y * size + x) * 4
            for i in range(4): px[o + i] = acc[i] // (S * S)
    return px

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for s in (180, 192, 512):
    png(os.path.join(out, f'icon-{s}.png'), s, s, draw(s))
print('icons written to', out)
