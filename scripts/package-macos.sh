#!/bin/bash
set -euo pipefail

# Local testing package; no Apple distribution credentials are required.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repo_root/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="${SWAR_BUILD_DIR:-${TMPDIR:-/tmp}/swar-distribution-build}"
version="${SWAR_VERSION:-1.0.0}"
build_number="${SWAR_BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "Building Swar $version ($build_number) for Apple Silicon and Intel…"
if ! xcodebuild -project "$repo_root/swar.xcodeproj" -scheme swar \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_dir" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    INFOPLIST_KEY_CFBundleDisplayName=Swar CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES \
    build > "$output_dir/build.log" 2>&1; then
    tail -80 "$output_dir/build.log" >&2
    exit 1
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/swar-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$build_dir/Build/Products/Release/swar.app" "$staging/Swar.app"
codesign --verify --deep --strict "$staging/Swar.app"
lipo "$staging/Swar.app/Contents/MacOS/swar" -verify_arch arm64 x86_64
for codec in "$staging/Swar.app/Contents/Frameworks/"*.dylib; do
    lipo "$codec" -verify_arch arm64 x86_64
done
test -s "$staging/Swar.app/Contents/Resources/AppIcon.icns"
test -s "$staging/Swar.app/Contents/Resources/FFmpeg-LGPL.txt"

ln -s /Applications "$staging/Applications"
cat > "$staging/Install Swar.txt" <<EOF
Swar $version ($build_number) · macOS 14 or later

Drag Swar into Applications, eject this disk image, and open Swar from Applications.
Add music through Settings → Files → Add Folder. Your music stays in place.
Quit Swar before replacing it with a later build; your library and queue are retained.

This is a locally signed test build, not a notarized public release.
EOF

artifact="$output_dir/Swar-$version-build$build_number"
hdiutil create -volname Swar -srcfolder "$staging" -format UDZO -ov "$artifact.dmg"
ditto -c -k --sequesterRsrc --keepParent "$staging/Swar.app" "$artifact.zip"
# Keep a standalone app beside the installer for local installation and debugging.
if [[ -e "$output_dir/Swar.app" ]]; then
    backup="$output_dir/Swar-previous-$(date +%Y%m%d-%H%M%S).app"
    mv "$output_dir/Swar.app" "$backup"
fi
ditto "$staging/Swar.app" "$output_dir/Swar.app"
shasum -a 256 "$artifact.dmg" "$artifact.zip" > "$artifact.sha256"
echo "Ready: $artifact.dmg"
