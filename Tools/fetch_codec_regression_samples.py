#!/usr/bin/env python3
"""Optional FFmpeg regression media, kept outside the repository and application.
Requires a development-only ffmpeg executable for independent PCM references.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg')
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)
samples = [
    ('sample.ape', 'https://samples.ffmpeg.org/A-codecs/lossless/luckynight.ape',
     '6a7b79a6d530e9847c18119d627bd43c8d27dcefb3ec7ec979b9b6306e34ac15'),
    ('sample.wma', 'https://samples.ffmpeg.org/A-codecs/lossless/luckynight.wma',
     '37fe6efab1231f07f46ed8d8bec212c0b97e1535f4931ba02d92138a32f2b6ee'),
    ('hybrid.wv', 'https://fate-suite.ffmpeg.org/wavpack/lossy/4.0_16-bit.wv',
     '63a362a501d4e9a26a1de96dec3d34eb94cbf477977925cc1c53c05208c1dd83'),
]
for name, url, expected in samples:
    target = args.directory / name
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        download = target.with_suffix(target.suffix + '.download')
        urllib.request.urlretrieve(url, download)
        if hashlib.sha256(download.read_bytes()).hexdigest() != expected:
            raise SystemExit(f'Checksum mismatch: {url}')
        download.replace(target)
    if name.endswith(('.ape', '.wma')):
        extension = target.suffix[1:]
        reference = args.directory / f'sample-{extension}.pcm'
        # Packet timestamps in the WMA reference can be non-monotonic. The PCM
        # checksum below validates samples independently of those timestamps.
        result = subprocess.run([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(target),
                                 '-f', 's16le', '-c:a', 'pcm_s16le', str(reference)], stderr=subprocess.PIPE)
        if result.returncode:
            raise SystemExit(result.stderr.decode(errors='replace'))
        if hashlib.sha256(reference.read_bytes()).hexdigest() != 'f678c00511d6952504f00468aba1ac323693d896ea868df701d42c9ddda8ec1b':
            raise SystemExit(f'Unexpected PCM reference: {name}')
    print(target)
