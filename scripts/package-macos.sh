#!/bin/bash
set -euo pipefail

# Ad-hoc testing package (local or CI); no Apple distribution credentials required.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repo_root/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="${SWAR_BUILD_DIR:-${TMPDIR:-/tmp}/swar-distribution-build}"
version="${SWAR_VERSION:-1.0.0}"
build_number="${SWAR_BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Ad-hoc signatures have no Apple Team ID, so Hardened Runtime cannot match
# the app to its bundled dylibs. Scope this exception to this local-only packager;
# normal certificate-signed Xcode/production builds keep library validation.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/swar-package.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
local_entitlements="$work_dir/local-testing.entitlements"
cp "$repo_root/swar/swar.entitlements" "$local_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$local_entitlements"

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

staging="$work_dir/staging"
mkdir -p "$staging"
ditto "$build_dir/Build/Products/Release/swar.app" "$staging/Swar.app"
# Sign only the packaged app with the explicit local entitlements. This also
# strips Xcode's injected get-task-allow entitlement from the Release package.
codesign --force --sign - --options runtime --entitlements "$local_entitlements" "$staging/Swar.app"
codesign -d --entitlements :- "$staging/Swar.app" > "$work_dir/signed-entitlements.plist" 2>/dev/null
for entitlement in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.cs.disable-library-validation; do
    test "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$work_dir/signed-entitlements.plist")" = true
done
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$work_dir/signed-entitlements.plist" >/dev/null 2>&1; then
    echo "Release package unexpectedly permits debugger access" >&2
    exit 1
fi
codesign --verify --deep --strict "$staging/Swar.app"
lipo "$staging/Swar.app/Contents/MacOS/swar" -verify_arch arm64 x86_64
for codec in "$staging/Swar.app/Contents/Frameworks/"*.dylib; do
    lipo "$codec" -verify_arch arm64 x86_64
done
test -s "$staging/Swar.app/Contents/Resources/AppIcon.icns"
test -s "$staging/Swar.app/Contents/Resources/FFmpeg-LGPL.txt"
# Signature verification alone cannot detect a runtime Team-ID mismatch. Execute
# the actual signed app with its bundled libraries, without starting the UI/library.
"$staging/Swar.app/Contents/MacOS/swar" --verify-bundled-codecs

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
# Portable names allow checksums to be verified after downloading CI artifacts.
(cd "$output_dir" && shasum -a 256 "$(basename "$artifact").dmg" "$(basename "$artifact").zip") > "$artifact.sha256"
echo "Ready: $artifact.dmg"
