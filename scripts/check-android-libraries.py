"""Reject ELF load segments that cannot be packaged for Android 16 KB pages."""
from pathlib import Path
import struct
import sys

def check(path):
    data = path.read_bytes()
    if data[:4] != b'\x7fELF': raise ValueError(f'{path}: not ELF')
    endian = '<' if data[5] == 1 else '>'
    wide = data[4] == 2
    offset = struct.unpack_from(endian + ('Q' if wide else 'I'), data, 32 if wide else 28)[0]
    size, count = struct.unpack_from(endian + 'HH', data, 54 if wide else 42)
    loads = 0
    for i in range(count):
        p = offset + i * size
        if struct.unpack_from(endian + 'I', data, p)[0] != 1: continue
        loads += 1
        alignment = struct.unpack_from(endian + ('Q' if wide else 'I'), data, p + (48 if wide else 28))[0]
        file_offset, address = struct.unpack_from(endian + ('QQ' if wide else 'II'), data, p + (8 if wide else 4))
        if alignment < 16384 or (address - file_offset) % 16384:
            raise ValueError(f'{path}: PT_LOAD is not 16 KB compatible')
    if not loads: raise ValueError(f'{path}: missing load segments')
    print(f'{path}: 16 KB ELF alignment verified')

if __name__ == '__main__':
    files = list(Path(sys.argv[1]).rglob('*.so'))
    if not files: raise SystemExit('No shared libraries found')
    for path in files: check(path)
