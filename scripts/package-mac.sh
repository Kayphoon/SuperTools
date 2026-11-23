#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INSTALL=false
ZIP=false
for arg in "$@"; do
    case "$arg" in
        --install)
            INSTALL=true
            ;;
        --zip)
            ZIP=true
            ;;
        *)
            echo "Usage: $0 [--install] [--zip]" >&2
            exit 1
            ;;
    esac
done

RAW_VERSION="${SUPERTOOLS_VERSION:-0.1.0}"
VERSION="${RAW_VERSION#v}"

echo "==> Building SuperTools ${VERSION} (release)..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/SuperTools"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: Release binary not found at $BIN_PATH" >&2
    exit 1
fi

APP_DIR="$ROOT_DIR/dist/SuperTools.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/SuperTools"
chmod 755 "$MACOS_DIR/SuperTools"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/Resources/MenuBarIcon.png" "$RESOURCES_DIR/MenuBarIcon.png"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>SuperTools</string>
    <key>CFBundleExecutable</key>
    <string>SuperTools</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.supertools.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SuperTools</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>SuperTools 需要屏幕录制权限以截取您框选的屏幕区域。</string>
</dict>
</plist>
EOF

echo "==> Signing $APP_DIR (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

if [[ "$ZIP" == "true" ]]; then
    ARCH="$(uname -m)"
    ZIP_NAME="SuperTools-macos-${ARCH}.zip"
    ZIP_PATH="$ROOT_DIR/dist/$ZIP_NAME"
    echo "==> Packaging $ZIP_PATH..."
    rm -f "$ZIP_PATH" "${ZIP_PATH}.sha256"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
    (cd "$ROOT_DIR/dist" && shasum -a 256 "$ZIP_NAME" > "${ZIP_NAME}.sha256")
fi

if [[ "$INSTALL" == "true" ]]; then
    TARGET_DIR="$HOME/Applications"
    TARGET_APP="$TARGET_DIR/SuperTools.app"
    echo "==> Installing to $TARGET_APP..."
    mkdir -p "$TARGET_DIR"
    rm -rf "$TARGET_APP"
    cp -R "$APP_DIR" "$TARGET_APP"
    codesign --verify --deep --strict "$TARGET_APP"
fi

echo "==> Done: $APP_DIR"
