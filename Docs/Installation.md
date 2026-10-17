# Install Swar for regular testing

Swar runs on macOS 14 or later. Local test packages include Apple Silicon and Intel
executables, bundled codecs, licenses, and the स्व app icon. Xcode and Homebrew are
not needed to run the packaged app.

1. Open the generated `dist/Swar-<version>-build<number>.dmg`.
2. Drag **Swar** onto **Applications**.
3. Eject the disk image and open **Swar** from Applications.
4. Add music with **Settings → Files → Add Folder**.

For updates, quit Swar and replace the app in Applications with the newer build.
The bundle identifier remains `catto.swar`, preserving the existing sandboxed
library, preferences, folder bookmarks, and listening session. The package never
copies, moves, or deletes your music. Avoid running an Xcode copy alongside the
installed copy, since both use the same library.

## Produce another package

With Xcode installed:

```sh
./scripts/package-macos.sh
```

Outputs are written to the ignored `dist/` folder: a DMG, ZIP, standalone `Swar.app`,
SHA-256 checksums, and a build log. The build number defaults to Git's commit count.
Optional environment variables are `SWAR_VERSION`, `SWAR_BUILD_NUMBER`,
`SWAR_BUILD_DIR`, and `DEVELOPER_DIR`; an optional first argument selects the output
directory. Previous standalone app outputs are retained with a timestamp.

The packaging command verifies code signatures, both executable architectures,
bundled codec architectures, the icon, and license resources. It also launches the
signed app with `--verify-bundled-codecs`, forces the bundled FFmpeg backend to
decode known PCM samples, checks EOF and seeks back to compare samples. This runs
without opening the UI, library database or audio device. A loading/decoding failure
stops packaging before a DMG is produced. It uses local ad-hoc
signing for testing on this Mac. It does not notarize or publish a release. Sharing
downloads with other people requires a separate Developer ID signing and Apple
notarization workflow; Gatekeeper acceptance on another Mac is not established by
the local signature checks.

## Local codec signing

Hardened Runtime library validation requires an Apple/platform signature or a
matching Apple Team ID. Ad-hoc signatures have no Team ID, so an ad-hoc Release
app cannot load its ad-hoc codecs under that policy even when signature verification
passes. For this local test packager only, the script copies the normal sandbox
entitlements into a temporary file and adds
`com.apple.security.cs.disable-library-validation`. The staged app is re-signed with exactly those entitlements, removing Xcode’s
injected debugger entitlement. Packaging checks these entitlements before testing.
The app remains sandboxed,
with read-only user-selected file access and Hardened Runtime enabled. This exception
relaxes library signature matching inside this app; it is not a system-wide change.
The base `swar/swar.entitlements` and certificate-signed Xcode builds retain library
validation. A public release should sign the app and every codec with the same Apple
team instead of using this local exception.

Files previously marked unreadable due to codec loading are retried on launch or
Settings → Files → Rescan Now, even if their size and modification date are unchanged.
Music files and metadata edits are preserved.
