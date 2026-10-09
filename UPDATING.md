# Maintaining signed releases

InfraProxy uses Sparkle 2.10.0. `scripts/fetch-sparkle.sh` downloads the official distribution and verifies its pinned SHA-256 before use. The SDK stays outside Git; its license is included in the app bundle.

The public Ed25519 key is committed in `Resources/sparkle-public-key.txt`. The private key stays in the macOS login Keychain under Sparkle's signing-key service, account `com.dynadobe.infraproxy`. Do not commit or print the private key. Preserve that Keychain item when moving release machines; do not generate a replacement key for routine releases. Follow Sparkle's documented key-rotation process if a key must change.

For a release:

1. Increase `APP_VERSION` and the monotonically increasing `APP_BUILD` in `build.sh`. Update `RELEASE_NOTES.md`.
2. Run `bash Tests/run.sh`.
3. Run `bash scripts/package-release.sh`. This requires the Developer ID certificate, the `InfraProxy` notarization profile, and the existing Sparkle signing key in Keychain.
4. Inspect `dist/<version>/appcast.xml`. Test update detection and installation with a lower-build local fixture before publishing where practical.
5. Commit and tag the release. Create a GitHub **draft** release and upload the DMG, its SHA-256 file, and `appcast.xml` from that same output directory. Publish it as the latest release only after all assets are uploaded.
6. Verify that the public stable feed URL serves the signed XML and its enclosure matches the release archive. Never edit signed XML or the archive after signing.

Feed: `https://github.com/netsecdevio/infravibe/releases/latest/download/appcast.xml`

Each release carries its own signed feed. Marking the release latest advances the stable feed URL. Future releases must include `appcast.xml`; otherwise existing installations will be unable to check for updates. Older versions before 2.6.0 require one manual installation.

Official reference: https://sparkle-project.org/documentation/publishing/
