"""What the boot pictures need of two formats: a PNG's rows read back (rsvg-convert's), and the
BMP U-Boot draws."""

import struct
import zlib


def png_rows(png: bytes) -> tuple[int, int, list[bytes]]:
    """An 8-bit RGB or RGBA PNG's rows as RGB bytes (the five PNG filters undone)."""
    w, h, depth, colour = struct.unpack(">IIBB", png[16:26])
    if depth != 8 or colour not in (2, 6):
        raise SystemExit("logo: an 8-bit RGB(A) PNG expected")
    bpp = 3 if colour == 2 else 4
    data, i = b"", 8
    while i < len(png):
        n, kind = struct.unpack(">I4s", png[i : i + 8])
        if kind == b"IDAT":
            data += png[i + 8 : i + 8 + n]
        i += 12 + n
    raw, stride, prev, rows = zlib.decompress(data), w * bpp, bytearray(w * bpp), []
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)])
        for x in range(stride):
            a, b = line[x - bpp] if x >= bpp else 0, prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 0xFF
            elif f == 2:
                line[x] = (line[x] + b) & 0xFF
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        prev = line
        rows.append(bytes(line) if bpp == 3 else bytes(v for k, v in enumerate(line) if k % 4 != 3))
    return w, h, rows


def bmp24(w: int, h: int, rows: list[bytes]) -> bytes:
    """The 24-bit bottom-up BMP U-Boot reads (BGR, rows padded to 4 bytes)."""
    pad = b"\0" * (-(w * 3) % 4)
    pixels = b"".join(bytes(r[i + 2 - 2 * (i % 3)] for i in range(len(r))) + pad for r in reversed(rows))
    header = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 3780, 3780, 0, 0)
    return header + info + pixels
