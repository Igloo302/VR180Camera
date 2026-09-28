#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "==> Building VR180Camera in Release mode..."
swift build -c release

APP_NAME="VR180Camera.app"
CONTENTS="$APP_NAME/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"

echo "==> Creating $APP_NAME bundle structure..."
mkdir -p "$MACOS" "$FRAMEWORKS"

cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VR180 Camera</string>
    <key>CFBundleDisplayName</key><string>VR180 相机</string>
    <key>CFBundleIdentifier</key><string>com.vr180.camera</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key><string>VR180Camera</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>用于发现、配对并控制 VR180 相机。</string>
    <key>NSBluetoothPeripheralUsageDescription</key><string>用于连接 VR180 相机。</string>
    <key>NSLocalNetworkUsageDescription</key><string>用于与 VR180 相机建立 P2P WebRTC 实时双目取景流与高速媒体文件传输。</string>
</dict>
</plist>
EOF

echo "==> Copying binaries and frameworks..."
cp .build/release/VR180Camera "$MACOS/VR180Camera"
cp -R .build/arm64-apple-macosx/release/WebRTC.framework "$FRAMEWORKS/"
if [ -f .build/release/libVR180Protocol.dylib ]; then
    cp .build/release/libVR180Protocol.dylib "$FRAMEWORKS/"
fi

echo "==> Setting rpath and signing app bundle..."
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/VR180Camera" 2>/dev/null || true
xattr -cr "$APP_NAME"
codesign --force --deep --sign - "$APP_NAME"

echo "==> Build & Packaging Complete! Successfully generated $APP_NAME"
