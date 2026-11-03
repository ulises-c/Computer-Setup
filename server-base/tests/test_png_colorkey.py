"""png_colorkey.py: magenta-keyed sprites become alpha-transparent PNGs."""
import importlib.util
from pathlib import Path
import struct
import unittest
import zlib

HERE = Path(__file__).resolve().parents[1] / 'homepage'
SPEC = importlib.util.spec_from_file_location('png_colorkey', HERE / 'png_colorkey.py')
png_colorkey = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(png_colorkey)


def png(width, height, colour, rows, filters):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    raw = b''.join(bytes([kind]) + row for kind, row in zip(filters, rows))
    return (png_colorkey.SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, colour, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def pixels(data):
    header, idat = None, b''
    for kind, body in png_colorkey.chunks(data):
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    width, height = header[:2]
    rows = png_colorkey.unfilter(zlib.decompress(idat), width, height, 4)
    return [tuple(row[i:i + 4]) for row in rows for i in range(0, len(row), 4)]


class ColorkeyTests(unittest.TestCase):
    def test_rgb_magenta_becomes_transparent_and_other_pixels_stay_opaque(self):
        data = png(2, 1, 2, [bytes([255, 0, 255, 200, 10, 10])], [0])
        self.assertEqual(pixels(png_colorkey.colorkey(data)), [(255, 0, 255, 0), (200, 10, 10, 255)])

    def test_filtered_rgba_rows_are_decoded_before_keying(self):
        # Row 2 uses the Up filter: deltas of zero repeat row 1 exactly.
        first = bytes([255, 0, 255, 255, 1, 2, 3, 128])
        data = png(2, 2, 6, [first, bytes(8)], [0, 2])
        self.assertEqual(pixels(png_colorkey.colorkey(data)),
                         [(255, 0, 255, 0), (1, 2, 3, 128), (255, 0, 255, 0), (1, 2, 3, 128)])

    def test_unsupported_images_are_refused(self):
        with self.assertRaises(ValueError):
            png_colorkey.colorkey(b'GIF89a')
        indexed = png(1, 1, 3, [bytes([0])], [0])
        with self.assertRaises(ValueError):
            png_colorkey.colorkey(indexed)


if __name__ == '__main__':
    unittest.main()
