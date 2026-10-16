#!/usr/bin/env python3
"""Create original short tones and reference hashes for every encodable format.
FFmpeg is a development-only fixture generator, never a playback subprocess.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import wave

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)
manifest = []

def encode(source, filename, options):
    path = args.directory / filename
    subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), *options, str(path)], check=True)
    return path

for bits, rate in [(16, 44100), (24, 96000), (24, 192000)]:
    stem = f"{rate}-{bits}"
    raw = bytearray()
    for frame in range(rate // 5):
        # Quiet signal with nonzero low bits; positive and negative 24-bit values.
        for channel in range(2):
            value = round(math.sin(2 * math.pi * (440 + channel * 220) * frame / rate) * ((1 << (bits - 1)) - 1) * .02)
            value += (frame % 13) - 6
            raw.extend((value & ((1 << bits) - 1)).to_bytes(bits // 8, 'little'))
    original = args.directory / f"{stem}.wav"
    with wave.open(str(original), 'wb') as f:
        f.setnchannels(2); f.setsampwidth(bits // 8); f.setframerate(rate); f.writeframes(raw)
    reference = f"{stem}.pcm"
    (args.directory / reference).write_bytes(raw)
    digest = hashlib.sha256(raw).hexdigest()
    entries = [(original.name, 'PCM', True)]
    for extension, codec, options in [
        ('m4a', 'ALAC', ['-c:a', 'alac']),
        ('flac', 'FLAC', ['-c:a', 'flac']),
        ('aiff', 'PCM', ['-c:a', f'pcm_s{bits}be']),
        ('caf', 'PCM', ['-c:a', f'pcm_s{bits}le']),
        ('wv', 'WavPack', ['-c:a', 'wavpack', '-bits_per_raw_sample', str(bits)]),
    ]:
        path = encode(original, f"{stem}.{extension}", options)
        entries.append((path.name, codec, extension != 'wv'))
    for name, codec, native in entries:
        manifest.append(dict(file=name, codec=codec, rate=rate, bits=bits, channels=2, lossless=True,
                             native=native, reference=reference, sha256=digest))
    if bits == 16:
        for extension, codec, options, native, output_rate in [
            ('aac.m4a', 'AAC', ['-c:a', 'aac', '-b:a', '128k'], True, rate),
            ('aac', 'AAC', ['-c:a', 'aac', '-b:a', '128k'], True, rate),
            ('mp3', 'MP3', ['-c:a', 'libmp3lame', '-b:a', '128k'], True, rate),
            ('ogg', 'Vorbis', ['-c:a', 'vorbis', '-strict', '-2'], False, rate),
            ('opus', 'Opus', ['-c:a', 'libopus', '-b:a', '128k', '-ar', '48000'], False, 48000),
            ('wma', 'WMA', ['-c:a', 'wmav2', '-b:a', '128k'], False, rate),
        ]:
            path = encode(original, f"{stem}.{extension}", options)
            manifest.append(dict(file=path.name, codec=codec, rate=output_rate, bits=None,
                                 channels=2, lossless=False, native=native, reference=None, sha256=None))
# Float PCM is verified against independently calculated IEEE-754 samples.
integer24 = (args.directory / '96000-24.pcm').read_bytes()
float_pcm = b''.join(struct.pack('<f', int.from_bytes(integer24[i:i+3], 'little', signed=True) / 8388608)
                     for i in range(0, len(integer24), 3))
(args.directory / '96000-float.pcm').write_bytes(float_pcm)
for ext, encoding in [('wav', 'pcm_f32le'), ('aifc', 'pcm_f32be'), ('caf', 'pcm_f32le')]:
    filename = f'96000-float.{ext}'
    encode(args.directory / '96000-24.wav', filename, ['-c:a', encoding, '-f', 'aiff' if ext == 'aifc' else ext])
    manifest.append(dict(file=filename, codec='PCM', rate=96000, bits=32, channels=2,
                         lossless=True, native=True, reference='96000-float.pcm',
                         sha256=hashlib.sha256(float_pcm).hexdigest()))
encode(args.directory / '96000-float.wav', '96000-float.wv', ['-c:a', 'wavpack'])
manifest.append(dict(file='96000-float.wv', codec='WavPack', rate=96000, bits=32, channels=2,
                     lossless=True, native=False, reference='96000-float.pcm',
                     sha256=hashlib.sha256(float_pcm).hexdigest()))
manifest_path = args.directory / 'manifest.json'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
print(f"Generated {len(manifest)} codec fixtures and reference hashes in {args.directory}")
