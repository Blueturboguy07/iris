#!/usr/bin/env python3
"""Draws the four seed catalog icons (Kneecap, Nut AI, FreeHarmony, Lunara) as
small original PNGs with no third-party marks. Pure standard library
(zlib, struct), 4x supersampled for smooth edges. Deterministic: the same
script always writes the same bytes, so the icon hashes in the seed catalog
stay stable.

Usage: python3 draw-icons.py <output-dir>
"""
import math
import struct
import sys
import zlib

SIZE = 128
SS = 4  # supersampling factor


def png_bytes(pixels, size):
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter: none
        for x in range(size):
            raw.extend(pixels[y * size + x])
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)  # 8-bit RGB
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def render(shade):
    """shade(x, y) -> (r, g, b) at supersampled coordinates in [0, SIZE)."""
    out = []
    for y in range(SIZE):
        for x in range(SIZE):
            acc = [0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    r, g, b = shade(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)
                    acc[0] += r; acc[1] += g; acc[2] += b
            n = SS * SS
            out.append((round(acc[0] / n), round(acc[1] / n), round(acc[2] / n)))
    return out


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def in_triangle(px, py, a, b, c):
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
    d1, d2, d3 = sign((px, py), a, b), sign((px, py), b, c), sign((px, py), c, a)
    neg = d1 < 0 or d2 < 0 or d3 < 0
    pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)


def in_round_rect(px, py, x0, y0, x1, y1, r):
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r and x0 <= px <= x1 and y0 <= py <= y1


def kneecap(x, y):
    # Video editing: a film frame with a play mark on Kneecap's green.
    t = (x + y) / (2 * SIZE)
    color = mix((35, 77, 40), (21, 51, 47), t)
    outer = in_round_rect(x, y, 22, 30, 106, 98, 12)
    inner = in_round_rect(x, y, 29, 37, 99, 91, 7)
    if outer and not inner:
        color = (255, 255, 255)
    if in_triangle(x, y, (55, 49), (55, 79), (81, 64)):
        color = (46, 204, 113)
    # Timeline strip under the frame.
    if 104 <= y <= 110 and 22 <= x <= 106:
        color = (255, 255, 255) if x < 70 else (120, 170, 130)
    return color


def nut_ai(x, y):
    # Nutrition: a daily ring, like the app's own "calories left" ring.
    color = (255, 255, 255)
    dx, dy = x - 64, y - 66
    dist = math.hypot(dx, dy)
    angle = (math.degrees(math.atan2(dx, -dy)) + 360) % 360  # 0 at top, clockwise
    if 34 <= dist <= 46:
        color = (22, 22, 26) if angle <= 250 else (232, 232, 238)
    if math.hypot(x - 64, y - 26) <= 8:
        color = (22, 22, 26)
    # A small leaf in the middle.
    lx, ly = x - 64, y - 66
    if (lx / 11) ** 2 + (ly / 17) ** 2 <= 1 and abs(lx - ly * 0.35) < 11:
        color = (46, 160, 90)
    return color


def freeharmony(x, y):
    # Face proportions: a gold face outline with landmark points.
    color = (12, 12, 12)
    gold = (217, 183, 126)
    ex = (x - 64) / 34
    ey = (y - 64) / 44
    d = ex * ex + ey * ey
    if 0.86 <= d <= 1.0:
        color = gold
    for (cx, cy) in ((50, 56), (78, 56), (64, 74), (64, 90)):
        if math.hypot(x - cx, y - cy) <= 4.2:
            color = gold
    # Thin measurement lines between the landmarks.
    if abs(y - 56) <= 0.9 and 50 <= x <= 78:
        color = gold
    if abs(x - 64) <= 0.9 and 56 <= y <= 90:
        color = mix((12, 12, 12), gold, 0.55)
    return color


def lunara(x, y):
    # Health and body: a crescent moon inside a cycle ring, on soft plum.
    t = (x + y) / (2 * SIZE)
    color = mix((94, 53, 96), (58, 33, 79), t)
    dx, dy = x - 64, y - 64
    dist = math.hypot(dx, dy)
    if 44 <= dist <= 50:
        color = (244, 214, 226)
    # Crescent: a pale disc with a second disc cut out of it.
    if math.hypot(x - 60, y - 64) <= 26 and math.hypot(x - 72, y - 58) > 22:
        color = (255, 240, 246)
    # A small dot on the ring, like today's marker on a cycle.
    if math.hypot(x - 64, y - 14) <= 5:
        color = (255, 158, 190)
    return color


def main():
    out_dir = sys.argv[1]
    for name, shade in (("kneecap", kneecap), ("nut-ai", nut_ai), ("freeharmony", freeharmony), ("lunara", lunara)):
        data = png_bytes(render(shade), SIZE)
        with open(f"{out_dir}/{name}.png", "wb") as handle:
            handle.write(data)
        print(name, len(data))


if __name__ == "__main__":
    main()
