#!/usr/bin/env python3
"""Make one RGB colour transparent in an 8-bit PNG (stdlib only).

The 2004-era game sprites mark transparency with magenta (#ff00ff) rather than
an alpha channel; fetch-assets.sh keys it out so the logo sits on the card art.

    python3 png_colorkey.py <in.png> <out.png> [rrggbb]
"""
import struct
import sys
import zlib

SIGNATURE = b'\x89PNG\r\n\x1a\n'


def chunks(data):
    if not data.startswith(SIGNATURE):
        raise ValueError('not a PNG')
    offset = len(SIGNATURE)
    while offset < len(data):
        length, = struct.unpack('>I', data[offset:offset + 4])
        kind = data[offset + 4:offset + 8]
        yield kind, data[offset + 8:offset + 8 + length]
        offset += 12 + length


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def unfilter(raw, width, height, bpp):
    stride = width * bpp
    rows, previous, offset = [], bytearray(stride), 0
    for _ in range(height):
        kind, line = raw[offset], bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        for i in range(stride):
            left = line[i - bpp] if i >= bpp else 0
            up = previous[i]
            corner = previous[i - bpp] if i >= bpp else 0
            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                line[i] = (line[i] + paeth(left, up, corner)) & 0xFF
            elif kind != 0:
                raise ValueError(f'bad filter type {kind}')
        rows.append(line)
        previous = line
    return rows


def colorkey(data, key=(0xFF, 0x00, 0xFF)):
    header, idat = None, b''
    for kind, body in chunks(data):
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    if header is None:
        raise ValueError('missing IHDR')
    width, height, depth, colour, _, _, interlace = header
    if depth != 8 or colour not in (2, 6) or interlace:
        raise ValueError('only 8-bit, non-interlaced RGB/RGBA PNGs are supported')
    bpp = 3 if colour == 2 else 4
    out = bytearray()
    for line in unfilter(zlib.decompress(idat), width, height, bpp):
        out.append(0)
        for i in range(0, len(line), bpp):
            rgb = tuple(line[i:i + 3])
            alpha = line[i + 3] if bpp == 4 else 0xFF
            out += bytes(rgb) + bytes([0 if rgb == key else alpha])

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    return (SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(out), 9)) + chunk(b'IEND', b''))


def main():
    if len(sys.argv) not in (3, 4):
        print('usage: python3 png_colorkey.py <in.png> <out.png> [rrggbb]', file=sys.stderr)
        sys.exit(2)
    key = bytes.fromhex(sys.argv[3]) if len(sys.argv) == 4 else b'\xff\x00\xff'
    with open(sys.argv[1], 'rb') as source:
        result = colorkey(source.read(), tuple(key))
    with open(sys.argv[2], 'wb') as target:
        target.write(result)


if __name__ == '__main__':
    main()
