#!/usr/bin/env python3
"""Original tagged test audio and a tiny original PNG; no downloaded music."""
import binascii
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

root = Path(__file__).resolve().parents[1]
inputs = root / 'Packages/SwarKit/Tests/DecodingTests/Fixtures'
out = root / 'Packages/SwarKit/Tests/LibraryTests/Fixtures'
out.mkdir(parents=True, exist_ok=True)
def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', binascii.crc32(kind + value) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress((b'\0' + bytes([60, 120, 220, 255]) * 2) * 2)) + chunk(b'IEND', b'')
cover = out / 'front.png'
cover.write_bytes(png)
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
tags = dict(title='Morning Light', artist='Björk', album_artist='Ensemble', album='Test Album', genre='Classical',
            composer='Test Composer', comment='Original fixture', lyrics='A quiet original tone', date='2024',
            track='2/9', disc='2/3', replaygain_track_gain='-3.00 dB', replaygain_album_gain='-2.00 dB')
for filename in ['96000-24.flac', '96000-24.m4a', '44100-16.mp3', '44100-16.opus', '96000-24.wv']:
    cmd = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(inputs / filename)]
    if filename.endswith('.mp3'):
        cmd += ['-i', str(cover), '-map', '0:a:0', '-map', '1:v:0', '-c', 'copy', '-disposition:v:0', 'attached_pic', '-id3v2_version', '3']
    else:
        cmd += ['-map', '0:a:0', '-c:a', 'copy']
    for name, value in tags.items(): cmd += ['-metadata', f'{name}={value}']
    subprocess.run(cmd + [str(out / filename)], check=True)
print(out)
