"""Packs the finished PNGs into app.ico and app.res, the Windows executable's icon. app.res is what the Windows SDK's
`rc /nologo /fo app.res app.rc` makes from app.ico, written here directly so that no resource compiler is needed."""
import struct

def png_size(png):
    return struct.unpack('>II', png[16:24])

def ico(pngs):
    """An .ico holding each PNG as it is, smallest first."""
    pngs = sorted(pngs, key=png_size)
    out = struct.pack('<HHH', 0, 1, len(pngs))
    at = 6 + 16 * len(pngs)
    for p in pngs:
        w, h = png_size(p)
        out += struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 0, 32, len(p), at)
        at += len(p)
    return out + b''.join(pngs)

def res(ico_bytes):
    """The compiled resource for `1 ICON "app.ico"`: each image as an RT_ICON, then the RT_GROUP_ICON that lists them."""
    def entry(kind, name, flags, data, language=0x0409):
        head = struct.pack('<IIHHHHIHHII', len(data), 32, 0xffff, kind, 0xffff, name, 0, flags, language, 0, 0)
        return head + data + b'\0' * (-len(data) % 4)
    count = struct.unpack('<H', ico_bytes[4:6])[0]
    out = entry(0, 0, 0, b'', 0)  # the empty resource every .res file starts with
    group = struct.pack('<HHH', 0, 1, count)
    for i in range(count):
        w, h, colors, reserved, planes, bits, size, at = struct.unpack('<BBBBHHII', ico_bytes[6 + 16 * i:22 + 16 * i])
        out += entry(3, i + 1, 0x1010, ico_bytes[at:at + size])
        group += struct.pack('<BBBBHHIH', w, h, colors, reserved, 1, bits, size, i + 1)
    return out + entry(14, 1, 0x1030, group)
