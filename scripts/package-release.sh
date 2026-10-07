#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh --notarize
APP=InfraProxy.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUTPUT="$PWD/dist/$VERSION"
SIGNING_IDENTITY="Developer ID Application: Doug Dowenr (J77629PP5S)"
RELEASE_URL="https://github.com/netsecdevio/infraproxy/releases/download/v$VERSION"
# Each feed must describe exactly the signed archive produced by this invocation.
if [[ -e "$OUTPUT" ]]; then
    echo "Release output already exists: $OUTPUT. Move it aside before rebuilding." >&2
    exit 1
fi
mkdir -p "$OUTPUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/InfraProxy.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUTPUT/InfraProxy-$VERSION.dmg"
hdiutil create -volname "InfraProxy $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile InfraProxy --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
hdiutil verify "$DMG"
python3 - "$OUTPUT/InfraProxy-$VERSION.html" <<'PY'
import html, pathlib, sys
notes = pathlib.Path('RELEASE_NOTES.md').read_text()
pathlib.Path(sys.argv[1]).write_text('<pre>' + html.escape(notes) + '</pre>')
PY
Vendor/Sparkle/bin/generate_appcast --account com.dynadobe.infraproxy \
    --maximum-deltas 0 --embed-release-notes --download-url-prefix "$RELEASE_URL/" \
    --link "https://github.com/netsecdevio/infraproxy/releases/tag/v$VERSION" "$OUTPUT"
Vendor/Sparkle/bin/sign_update --account com.dynadobe.infraproxy --verify "$OUTPUT/appcast.xml"
(cd "$OUTPUT" && shasum -a 256 "InfraProxy-$VERSION.dmg" > "InfraProxy-$VERSION.dmg.sha256")
echo "Ready to publish: $OUTPUT"
echo "Upload the DMG, checksum, and appcast.xml together; then mark the release latest."
