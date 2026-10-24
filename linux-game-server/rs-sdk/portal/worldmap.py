#!/usr/bin/env python3
"""Render the game's own worldmap.jag into a static PNG plus label/geometry JSON.

A pure-stdlib port of the ground layer of the web client's MapView
(webclient/src/mapview/MapView.ts): blended underlay colours, overlays and
walls, on the same "unified" canvas (surface plus the underground bands the
client folds into it). The live map draws bot markers on top with the same
coordinate transform (live.map_point), so tiles and markers always agree.

    python3 worldmap.py --jag worldmap.jag --out assets/
"""
import argparse
import bz2
import json
from pathlib import Path
import struct
import zlib

# MapView.ts: mapsquare columns 29-56 and unified rows 42-91, with one padding square.
ORIGIN_X = 28 << 6
ORIGIN_Z = 41 << 6
WIDTH = 30 << 6
HEIGHT = 52 << 6
# (from, to, offset) mapsquare-z bands folded into the unified canvas.
MAP_BANDS = ((42, 62, 0), (142, 161, -79), (69, 77, 14))
SCALE = 2  # pixels per tile in the PNG


def unified_square_z(mz):
    for low, high, offset in MAP_BANDS:
        if low <= mz <= high:
            return mz + offset
    return -1


def jag_hash(name):
    value = 0
    for char in name.upper():
        value = (value * 61 + ord(char) - 32) & 0xffffffff
    return value - (1 << 32) if value & 0x80000000 else value


def bunzip(data):
    return bz2.decompress(b'BZh1' + bytes(data))


def read_jag(blob):
    unpacked, packed = int.from_bytes(blob[0:3], 'big'), int.from_bytes(blob[3:6], 'big')
    whole = unpacked != packed
    data = bunzip(blob[6:]) if whole else blob[6:]
    count = int.from_bytes(data[0:2], 'big')
    offset = 2 + count * 10
    files = {}
    for i in range(count):
        entry = data[2 + i * 10:12 + i * 10]
        name_hash = struct.unpack('>i', entry[0:4])[0]
        size = int.from_bytes(entry[7:10], 'big')
        chunk = data[offset:offset + size]
        files[name_hash] = chunk if whole else bunzip(chunk)
        offset += size
    return lambda name: files[jag_hash(name)]


def get_rgb(hue, saturation, lightness):
    r = g = b = lightness
    if saturation != 0.0:
        q = lightness * (saturation + 1.0) if lightness < 0.5 else lightness + saturation - lightness * saturation
        p = lightness * 2.0 - q

        def channel(t):
            if t * 6.0 < 1.0:
                return p + (q - p) * 6.0 * t
            if t * 2.0 < 1.0:
                return q
            if t * 3.0 < 2.0:
                return p + (q - p) * (0.6666666666666666 - t) * 6.0
            return p
        t = hue + 0.3333333333333333
        r = channel(t - 1 if t > 1.0 else t)
        g = channel(hue)
        d = hue - 0.3333333333333333
        b = channel(d + 1 if d < 0.0 else d)
    return (int(r * 256.0) << 16) + (int(g * 256.0) << 8) + int(b * 256.0)


def squares(data, per_tile):
    """Yield (map x, top row, tile reader) for each in-canvas 64x64 square, skipping others."""
    pos = 0
    while pos < len(data):
        mx = data[pos] * 64 - ORIGIN_X
        unified = unified_square_z(data[pos + 1])
        mz = -1 if unified == -1 else unified * 64 - ORIGIN_Z
        pos += 2
        inside = mx > 0 and mz > 0 and mx + 64 < WIDTH and mz + 64 < HEIGHT
        pos = per_tile(data, pos, mx, HEIGHT - mz - 1, inside)


def render(read):
    floorcol = read('floorcol.dat')
    count = int.from_bytes(floorcol[0:2], 'big')
    col1, col2 = [0] * (count + 1), [0] * (count + 1)
    for i in range(count):
        col1[i + 1], col2[i + 1] = struct.unpack('>ii', floorcol[2 + i * 8:10 + i * 8])

    under = [bytearray(HEIGHT) for _ in range(WIDTH)]
    over = [[0] * HEIGHT for _ in range(WIDTH)]
    walls = [bytearray(HEIGHT) for _ in range(WIDTH)]

    def underlay(data, pos, mx, top, inside):
        if inside:
            for x in range(64):
                column = under[mx + x]
                for z in range(64):
                    column[top - z] = data[pos]
                    pos += 1
            return pos
        return pos + 4096

    def overlay(data, pos, mx, top, inside):
        for x in range(64):
            for z in range(64):
                opcode = data[pos]
                pos += 1
                if opcode:
                    pos += 1  # shape/rotation; a 2 px tile is drawn whole like the client's small zooms
                    if inside:
                        over[mx + x][top - z] = col2[opcode]
        return pos

    def locs(data, pos, mx, top, inside):
        for x in range(64):
            for z in range(64):
                while True:
                    opcode = data[pos]
                    pos += 1
                    if opcode == 0:
                        break
                    if inside and opcode < 29:
                        walls[mx + x][top - z] = opcode
        return pos

    squares(read('underlay.dat'), underlay)
    squares(read('overlay.dat'), overlay)
    squares(read('loc.dat'), locs)

    # MapView.getBlendedGroundColour: an 11x11 box blur of packed HSL underlay colours.
    blended = [[0] * HEIGHT for _ in range(WIDTH)]
    average = [0] * HEIGHT
    for x in range(5, WIDTH - 5):
        east, west = under[x + 5], under[x - 5]
        for z in range(HEIGHT):
            average[z] += col1[east[z]] - col1[west[z]]
        if 10 < x < WIDTH - 10:
            r = g = b = 0
            out = blended[x]
            for z in range(5, HEIGHT - 5):
                north, south = average[z + 5], average[z - 5]
                r += (north >> 20) - (south >> 20)
                g += ((north >> 10) & 0x3ff) - ((south >> 10) & 0x3ff)
                b += (north & 0x3ff) - (south & 0x3ff)
                if b > 0:
                    out[z] = get_rgb(r / 8533.0, g / 8533.0, b / 8533.0)

    width, height = WIDTH * SCALE, HEIGHT * SCALE
    pixels = [bytearray(width * 3) for _ in range(height)]

    def put(px, py, rgb):
        row = pixels[py]
        row[px * 3:px * 3 + 3] = bytes(((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff))

    for x in range(WIDTH):
        for z in range(HEIGHT):
            rgb = over[x][z] or blended[x][z]
            if rgb:
                for dx in range(SCALE):
                    for dz in range(SCALE):
                        put(x * SCALE + dx, z * SCALE + dz, rgb)
    edge = SCALE - 1
    for x in range(WIDTH):
        for z in range(HEIGHT):
            wall = walls[x][z]
            if not wall:
                continue
            rgb = 0xcccccc
            if 5 <= wall <= 8 or 13 <= wall <= 16 or 21 <= wall <= 24:
                rgb, wall = 0xcc0000, wall - 4
            if wall in (27, 28):
                rgb, wall = 0xcc0000, wall - 2
            sx, sz = x * SCALE, z * SCALE
            lines = {1: [('v', 0)], 2: [('h', 0)], 3: [('v', edge)], 4: [('h', edge)],
                     9: [('v', 0), ('h', 0)], 10: [('v', edge), ('h', 0)],
                     11: [('v', edge), ('h', edge)], 12: [('v', 0), ('h', edge)]}.get(wall)
            if lines:
                for kind, at in lines:
                    for i in range(SCALE):
                        put(sx + at, sz + i, rgb) if kind == 'v' else put(sx + i, sz + at, rgb)
            else:  # corners and diagonals: a single dot keeps the outline readable
                put(sx, sz, rgb)
    return width, height, pixels


def png(width, height, rows):
    raw = b''.join(b'\x00' + bytes(row) for row in rows)

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def labels(read):
    data = read('labels.dat')
    count = int.from_bytes(data[0:2], 'big')
    pos, out = 2, []
    for _ in range(count):
        end = data.index(b'\n', pos)
        text = data[pos:end].decode('latin-1')
        pos = end + 1
        x, y, size = int.from_bytes(data[pos:pos + 2], 'big'), int.from_bytes(data[pos + 2:pos + 4], 'big'), data[pos + 4]
        pos += 5
        # MapView draws labels at (x - originX, originZ + height - y) on its unified canvas.
        out.append({'text': text.replace('\\n', '\n'), 'x': x - ORIGIN_X, 'y': ORIGIN_Z + HEIGHT - y, 'size': size})
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jag', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    read = read_jag(args.jag.read_bytes())
    width, height, rows = render(read)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'worldmap.png.part').write_bytes(png(width, height, rows))
    (args.out / 'worldmap.png.part').replace(args.out / 'worldmap.png')
    meta = {'originX': ORIGIN_X, 'originZ': ORIGIN_Z, 'width': WIDTH, 'height': HEIGHT, 'scale': SCALE,
            'bands': [list(band) for band in MAP_BANDS], 'labels': labels(read)}
    (args.out / 'worldmap.json.part').write_text(json.dumps(meta, separators=(',', ':')))
    (args.out / 'worldmap.json.part').replace(args.out / 'worldmap.json')
    print(f'Rendered {width}x{height} world map and {len(meta["labels"])} labels into {args.out}')


if __name__ == '__main__':
    main()
