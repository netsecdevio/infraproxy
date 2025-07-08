#!/bin/bash
set -e

echo "Building InfraProxy..."

# Clean previous builds
rm -rf InfraProxy.app

# Compile Swift files directly
swiftc -o InfraProxy \
    Sources/ProxyModels.swift \
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
    
    ICON_LINE="    <key>CFBundleIconFile</key>
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
    <string>com.InfraProxy.app</string>
    <key>CFBundleName</key>
    <string>InfraProxy</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.5</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>$ICON_LINE
</dict>
</plist>
EOF

echo "✅ InfraProxy.app created successfully"
echo "📦 Ready for distribution"
