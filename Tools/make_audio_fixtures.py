#!/usr/bin/env python3
"""Generate quiet, original test tones; no downloads or licensed music required."""
import argparse
import math
from pathlib import Path
import subprocess
import wave

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)

for bits, rate, name in [(24, 96000, "quiet-24bit-96k"), (16, 44100, "quiet-16bit-44k")]:
    wav = args.directory / (name + ".wav")
    width = bits // 8
    data = bytearray()
    for frame in range(rate * 4):
        # -40 dBFS, stereo, four seconds. Keep hardware test playback quiet.
        sample = round(math.sin(2 * math.pi * 440 * frame / rate) * ((1 << (bits - 1)) - 1) * 0.01)
        data.extend((sample & ((1 << bits) - 1)).to_bytes(width, "little") * 2)
    with wave.open(str(wav), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(width)
        output.setframerate(rate)
        output.writeframes(data)
    alac = args.directory / (name + ".m4a")
    subprocess.run(["/usr/bin/afconvert", str(wav), str(alac), "-d", "alac", "-f", "m4af"], check=True)
    print(alac)

(args.directory / "corrupt.flac").write_bytes(b"not a valid audio file")
