#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Configuration
SIGNING_IDENTITY="Developer ID Application: Doug Dowenr (J77629PP5S)"
KEYCHAIN_PROFILE="InfraProxy"
BUNDLE_ID="com.dynadobe.infraproxy"
ENTITLEMENTS="infraproxy.entitlements"
APP_VERSION="2.8.0"
APP_BUILD="11"
SPARKLE_FEED="https://github.com/netsecdevio/infravibe/releases/latest/download/appcast.xml"

# Parse arguments
NOTARIZE=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --notarize) NOTARIZE=true ;;
        --help)
            echo "Usage: ./build.sh [--notarize]"
            echo "  --notarize  Sign and notarize the app for distribution"
            exit 0
            ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

bash scripts/fetch-sparkle.sh
(cd Web && npm ci --ignore-scripts --no-fund && npm audit --omit=dev)
SPARKLE_PUBLIC_KEY=$(cat Resources/sparkle-public-key.txt)
echo "Building InfraProxy..."

# Clean previous builds
rm -rf InfraProxy.app

# Compile each supported architecture, then sign the combined Universal 2 binary.
BUILD_SLICES=$(mktemp -d)
trap 'rm -rf "$BUILD_SLICES"' EXIT
for ARCH in arm64 x86_64; do
swiftc -target "$ARCH-apple-macosx15.5" -o "$BUILD_SLICES/InfraProxy-$ARCH" \
    Sources/ProxyModels.swift \
    Sources/LaunchctlServiceManager.swift \
    Sources/InfraProxyManager.swift \
    Sources/InfraProxyActions.swift \
    Sources/Operations.swift \
    Sources/CloudOperations.swift \
    Sources/OperationsCommand.swift \
    Sources/MenuBarPanel.swift \
    Sources/RemoteAccess.swift \
    Sources/AppUpdater.swift \
    Sources/AppSettings.swift \
    Sources/BrowserKeys.swift Sources/AgentAccess.swift Sources/TerminalSession.swift Sources/BrowserServer.swift \
    Sources/BrowserDashboard.swift \
    Sources/main.swift \
    -framework Cocoa \
    -framework UserNotifications \
    -F Vendor/Sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
clang -target "$ARCH-apple-macosx15.5" -O2 -Wall -Wextra Sources/Helpers/TerminalHost.c -o "$BUILD_SLICES/TerminalHost-$ARCH"
done
lipo -create "$BUILD_SLICES/InfraProxy-arm64" "$BUILD_SLICES/InfraProxy-x86_64" -output InfraProxy


# Create app bundle
mkdir -p InfraProxy.app/Contents/MacOS
mkdir -p InfraProxy.app/Contents/Resources
mkdir -p InfraProxy.app/Contents/Frameworks
lipo -create "$BUILD_SLICES/TerminalHost-arm64" "$BUILD_SLICES/TerminalHost-x86_64" -output InfraProxy.app/Contents/MacOS/TerminalHost
mkdir -p InfraProxy.app/Contents/Resources/Web
cp Web/index.html Web/app.js Web/style.css InfraProxy.app/Contents/Resources/Web/
cp Web/node_modules/@xterm/xterm/lib/xterm.js Web/node_modules/@xterm/xterm/css/xterm.css InfraProxy.app/Contents/Resources/Web/
cp Web/node_modules/@xterm/addon-fit/lib/addon-fit.js InfraProxy.app/Contents/Resources/Web/fit.js
cp Web/node_modules/@xterm/xterm/LICENSE InfraProxy.app/Contents/Resources/xterm-LICENSE.txt
cp Web/node_modules/@xterm/addon-fit/LICENSE InfraProxy.app/Contents/Resources/xterm-fit-LICENSE.txt
ditto Vendor/Sparkle/Sparkle.framework InfraProxy.app/Contents/Frameworks/Sparkle.framework
cp Vendor/Sparkle/LICENSE InfraProxy.app/Contents/Resources/Sparkle-LICENSE.txt
cp Resources/VibeTunnel-LICENSE.txt InfraProxy.app/Contents/Resources/
cp Resources/terminal.sb InfraProxy.app/Contents/Resources/
cp THIRD_PARTY_NOTICES.md InfraProxy.app/Contents/Resources/

# Copy executable
mv InfraProxy InfraProxy.app/Contents/MacOS/

# Create app icon (if icon.png exists)
if [ -f "icon.png" ]; then
    mkdir -p InfraProxy.app/Contents/Resources/AppIcon.iconset

    # Generate iconset from PNG
    sips -z 16 16     icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_16x16.png
    sips -z 32 32     icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_16x16@2x.png
    sips -z 32 32     icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_32x32.png
    sips -z 64 64     icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_32x32@2x.png
    sips -z 128 128   icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_128x128.png
    sips -z 256 256   icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_128x128@2x.png
    sips -z 256 256   icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_256x256.png
    sips -z 512 512   icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_256x256@2x.png
    sips -z 512 512   icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_512x512.png
    sips -z 1024 1024 icon.png --out InfraProxy.app/Contents/Resources/AppIcon.iconset/icon_512x512@2x.png

    # Convert to icns
    iconutil -c icns InfraProxy.app/Contents/Resources/AppIcon.iconset
    rm -rf InfraProxy.app/Contents/Resources/AppIcon.iconset

    ICON_LINE="
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
else
    ICON_LINE=""
fi

# Create Info.plist
cat > InfraProxy.app/Contents/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>InfraProxy</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>infravibe</string>
    <key>CFBundleDisplayName</key>
    <string>infravibe</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUEnableSystemProfiling</key>
    <false/>
    <key>LSMinimumSystemVersion</key>
    <string>15.5</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>InfraProxy opens Google Cloud SSH connections in Terminal.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>${ICON_LINE}
</dict>
</plist>
EOF

bash scripts/verify-architectures.sh InfraProxy.app
echo "✅ InfraProxy.app created successfully"

# Code signing and notarization
if [ "$NOTARIZE" = true ]; then
    echo ""
    echo "🔐 Signing app with hardened runtime..."

    # Sign nested Sparkle helpers inside-out, retaining their required entitlements.
    SPARKLE_ROOT="InfraProxy.app/Contents/Frameworks/Sparkle.framework/Versions/B"
    for component in "$SPARKLE_ROOT/XPCServices/Downloader.xpc" \
                     "$SPARKLE_ROOT/XPCServices/Installer.xpc" \
                     "$SPARKLE_ROOT/Autoupdate" "$SPARKLE_ROOT/Updater.app" \
                     "InfraProxy.app/Contents/Frameworks/Sparkle.framework"; do
        codesign --force --options runtime --preserve-metadata=identifier,entitlements \
            --sign "$SIGNING_IDENTITY" --timestamp "$component"
    done

    codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp InfraProxy.app/Contents/MacOS/TerminalHost

    # Sign the app with hardened runtime (required for notarization)
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        InfraProxy.app

    # Verify the signature
    echo "🔍 Verifying signature..."
    codesign --verify --deep --strict --verbose=2 InfraProxy.app

    # Create a zip for notarization
    echo "📦 Creating zip for notarization..."
    rm -f InfraProxy.zip
    ditto -c -k --keepParent InfraProxy.app InfraProxy.zip

    # Submit for notarization
    echo "📤 Submitting for notarization (this may take a few minutes)..."
    xcrun notarytool submit InfraProxy.zip \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    # Staple the notarization ticket
    echo "📎 Stapling notarization ticket..."
    xcrun stapler staple InfraProxy.app

    # Verify stapling
    echo "🔍 Verifying stapled app..."
    xcrun stapler validate InfraProxy.app

    # Clean up
    rm -f InfraProxy.zip

    echo ""
    echo "✅ InfraProxy.app is signed and notarized!"
    echo "📦 Ready for distribution"
else
    echo ""
    echo "💡 To sign and notarize for distribution, run:"
    echo "   ./build.sh --notarize"
    echo ""
    echo "📦 Ready for local testing"
fi
