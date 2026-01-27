#!/bin/bash
set -e

# Configuration
SIGNING_IDENTITY="Developer ID Application: Doug Dowenr (J77629PP5S)"
KEYCHAIN_PROFILE="InfraProxy"
BUNDLE_ID="com.dynadobe.infraproxy"
ENTITLEMENTS="infraproxy.entitlements"

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

echo "Building InfraProxy..."

# Clean previous builds
rm -rf InfraProxy.app

# Compile Swift files directly
swiftc -o InfraProxy \
    Sources/ProxyModels.swift \
    Sources/LaunchctlServiceManager.swift \
    Sources/InfraProxyManager.swift \
    Sources/InfraProxyActions.swift \
    Sources/main.swift \
    -framework Cocoa \
    -framework UserNotifications

# Create app bundle
mkdir -p InfraProxy.app/Contents/MacOS
mkdir -p InfraProxy.app/Contents/Resources

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
    <key>CFBundleExecutable</key>
    <string>InfraProxy</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>InfraProxy</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.5</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>${ICON_LINE}
</dict>
</plist>
EOF

echo "✅ InfraProxy.app created successfully"

# Code signing and notarization
if [ "$NOTARIZE" = true ]; then
    echo ""
    echo "🔐 Signing app with hardened runtime..."

    # Sign the app with hardened runtime (required for notarization)
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        InfraProxy.app

    # Verify the signature
    echo "🔍 Verifying signature..."
    codesign --verify --verbose=2 InfraProxy.app

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
