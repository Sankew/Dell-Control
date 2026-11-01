# Builds the three Custom Color profiles from the base G2.2 profile, each with a 'vcgt' white-balance curve.
# macOS loads vcgt into the GPU's output table, which works at high precision and dithers. The Dell's own RGB
# gains don't: lowering them in the monitor throws away levels and causes banding. So the gains stay at 100
# and the white balance lives here instead.
#
# python3 Tools/make-profiles.py R G B   (the gains you'd otherwise set on the Dell, e.g. 98 96 87)
import struct, sys

gains = [float(x) for x in sys.argv[1:4]] if len(sys.argv) == 4 else [98, 96, 87]
# Measured with the camera: the Dell's light changes with about the 2.65th power of a gain, the panel's
# response to its input with about the 2.25th. A GPU scale of gain^(2.65/2.25) gives the same light.
scales = [(g / 100) ** (2.65 / 2.25) for g in gains]

base = open('Profiles/Dell S2725QC Custom Color D65 G2.2.icc', 'rb').read()
count = struct.unpack('>I', base[128:132])[0]
tags = []
for i in range(count):
    sig, off, size = struct.unpack('>4sII', base[132 + 12 * i:144 + 12 * i])
    tags.append([sig, base[off:off + size]])
tags = [t for t in tags if t[0] != b'vcgt']

def s15(v): return struct.pack('>i', round(v * 65536))

def build(gamma_declared, name):
    vcgt = b'vcgt' + b'\0' * 4 + struct.pack('>I', 1) + b''.join(s15(1) + s15(0) + s15(s) for s in scales)
    para = b'para' + b'\0' * 4 + struct.pack('>H', 0) + b'\0\0' + s15(gamma_declared)
    out_tags = []
    for sig, data in tags:
        if sig in (b'rTRC', b'gTRC', b'bTRC'): data = para
        if sig == b'desc':
            text = name.encode('utf-16-be')
            data = b'mluc' + b'\0' * 4 + struct.pack('>II', 1, 12) + b'enUS' + struct.pack('>II', len(text), 28) + text
        out_tags.append((sig, data))
    out_tags.append((b'vcgt', vcgt))
    table = bytearray(struct.pack('>I', len(out_tags)))
    body = bytearray()
    offset = 128 + 4 + 12 * len(out_tags)
    shared = {}
    for sig, data in out_tags:
        if data in shared:  # the three TRC tags share one copy, as in the base profile
            table += struct.pack('>4sII', sig, shared[data], len(data)); continue
        while (offset + len(body)) % 4: body += b'\0'
        shared[data] = offset + len(body)
        table += struct.pack('>4sII', sig, shared[data], len(data))
        body += data
    p = bytearray(base[:128]) + table + body
    struct.pack_into('>I', p, 0, len(p))
    p[84:100] = b'\0' * 16  # no profile ID: allowed, and avoids a stale checksum
    open(f'Profiles/{name.replace(" - ", " ")}.icc', 'wb').write(p)
    print(name, len(p), 'bytes, vcgt scales', [round(s, 4) for s in scales])

# ColorSync encodes for the gamma it's told; the panel really answers at ~2.2, so declared < 2.2 = steeper picture.
build(2.2, 'Dell S2725QC - Custom Color D65 G2.2')
build(2.2 * 2.2 / 2.3, 'Dell S2725QC - Custom Color D65 E2.3')
build(2.2 * 2.2 / 2.4, 'Dell S2725QC - Custom Color D65 E2.4')
