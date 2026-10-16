#!/usr/bin/env python3
"""Rebuild Swar's unmodified, decoder-only LGPL FFmpeg libraries for macOS 14+."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

VERSION = "9.0.2"
SHA256 = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
URL = f"https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz"
ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Packages/SwarKit/Vendor/FFmpeg"
parser = argparse.ArgumentParser()
parser.add_argument("--work-directory", type=Path, default=Path("/tmp/swar-ffmpeg-source"))
args = parser.parse_args()
work = args.work_directory.resolve()
work.mkdir(parents=True, exist_ok=True)
archive = work / f"ffmpeg-{VERSION}.tar.xz"
if not archive.exists():
    urllib.request.urlretrieve(URL, archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
    raise SystemExit("FFmpeg source checksum mismatch")
source = work / f"ffmpeg-{VERSION}"
if not source.exists():
    with tarfile.open(archive) as tar:
        tar.extractall(work, filter="data")
flags = [
    "--disable-everything", "--disable-autodetect", "--disable-network",
    "--disable-programs", "--disable-doc", "--disable-debug", "--disable-asm",
    "--disable-static", "--enable-shared", "--disable-gpl", "--disable-nonfree",
    "--disable-version3", "--disable-avdevice", "--disable-avfilter",
    "--disable-swscale", "--enable-swresample", "--enable-protocol=file",
    "--enable-demuxer=aac,aiff,ape,asf,caf,flac,mov,mp3,ogg,wav,wv",
    "--enable-parser=aac,flac,mpegaudio,opus,vorbis",
    "--enable-decoder=aac,alac,flac,mp3,opus,vorbis,wavpack,ape,wmav1,wmav2,wmapro,wmalossless,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_u8",
    "--target-os=darwin", "--enable-cross-compile", "--cc=/usr/bin/clang",
    "--install-name-dir=@rpath",
]
installs = []
for arch in ["arm64", "x86_64"]:
    build = work / f"build-{arch}"
    build.mkdir(exist_ok=True)
    install = work / f"install-{arch}"
    config = [str(source / "configure"), *flags, f"--arch={arch}", f"--prefix={install}",
              f"--extra-cflags=-arch {arch} -mmacosx-version-min=14.0",
              f"--extra-ldflags=-arch {arch} -mmacosx-version-min=14.0"]
    subprocess.run(config, cwd=build, check=True)
    subprocess.run(["make", "-j6"], cwd=build, check=True)
    subprocess.run(["make", "install"], cwd=build, check=True)
    installs.append(install)
VENDOR.mkdir(parents=True, exist_ok=True)
shutil.copytree(installs[0] / "include", VENDOR / "include", dirs_exist_ok=True)
lib = VENDOR / "lib"
lib.mkdir(exist_ok=True)
names = ["libavformat.63.dylib", "libavcodec.63.dylib", "libavutil.61.dylib", "libswresample.7.dylib"]
for name in names:
    dest = lib / name
    subprocess.run(["lipo", "-create", *(str(p / "lib" / name) for p in installs), "-output", str(dest)], check=True)
    subprocess.run(["install_name_tool", "-id", f"@rpath/{name}", str(dest)], check=True)
    for dependency in names:
        if dependency != name:
            subprocess.run(["install_name_tool", "-change", f"@rpath/{dependency}", f"@loader_path/{dependency}", str(dest)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(dest)], check=True)
shutil.copy2(source / "COPYING.LGPLv2.1", VENDOR / "COPYING.LGPLv2.1")
shutil.copy2(source / "LICENSE.md", VENDOR / "LICENSE.md")
(VENDOR / "BUILD.txt").write_text(f"FFmpeg {VERSION}\nSource: {URL}\nSHA256: {SHA256}\nArchitectures: arm64 x86_64\nMinimum macOS: 14.0\n\n" + "\n".join(flags) + "\n")
notices = ROOT / "swar/Resources/ThirdParty"
notices.mkdir(parents=True, exist_ok=True)
for origin, name in [(VENDOR / "BUILD.txt", "FFmpeg-Build.txt"),
                     (VENDOR / "COPYING.LGPLv2.1", "FFmpeg-LGPL.txt"),
                     (VENDOR / "LICENSE.md", "FFmpeg-LICENSE.md"),
                     (archive, f"FFmpeg-{VERSION}.tar.xz")]:
    shutil.copy2(origin, notices / name)
print(f"Built universal LGPL codec libraries in {lib}")
