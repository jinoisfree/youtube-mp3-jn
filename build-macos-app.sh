#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/dist/My MP3.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/module-cache"
ICON_SOURCE="$PROJECT_DIR/assets/app-icon-1024.png"
ICONSET_DIR="/private/tmp/MyMP3-AppIcon.iconset"

if [[ ! -x "$PROJECT_DIR/.venv/bin/python" ]]; then
  echo "오류: .venv가 없습니다. README의 설치 명령을 먼저 실행해 주세요."
  exit 1
fi

SITE_PACKAGES="$($PROJECT_DIR/.venv/bin/python -c 'import site; print(site.getsitepackages()[0])')"
if [[ ! -d "$SITE_PACKAGES/yt_dlp" ]]; then
  echo "오류: yt-dlp가 설치되지 않았습니다."
  exit 1
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "오류: assets/app-icon-1024.png가 없습니다."
  exit 1
fi
if [[ ! -f "$PROJECT_DIR/config/remote-token.txt" ]]; then
  mkdir -p "$PROJECT_DIR/config"
  /usr/bin/openssl rand -hex 32 > "$PROJECT_DIR/config/remote-token.txt"
  /bin/chmod 600 "$PROJECT_DIR/config/remote-token.txt"
fi

if [[ -d "$APP_DIR" ]]; then
  /usr/bin/xattr -cr "$APP_DIR"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/static" "$MODULE_CACHE_DIR" "$ICONSET_DIR"
/usr/bin/sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
/usr/bin/xcrun swiftc \
  -O \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Cocoa \
  -framework WebKit \
  "$PROJECT_DIR/macos/main.swift" \
  -o "$MACOS_DIR/MyMP3"

/usr/bin/ditto "$PROJECT_DIR/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/ditto "$PROJECT_DIR/app.py" "$RESOURCES_DIR/app.py"
/usr/bin/ditto "$PROJECT_DIR/static" "$RESOURCES_DIR/static"
/usr/bin/ditto "$PROJECT_DIR/config/remote-token.txt" "$RESOURCES_DIR/remote-token.txt"
/usr/bin/ditto "$SITE_PACKAGES/yt_dlp" "$RESOURCES_DIR/yt_dlp"
if [[ -x "$PROJECT_DIR/vendor/yt-dlp_macos" ]]; then
  /usr/bin/ditto "$PROJECT_DIR/vendor/yt-dlp_macos" "$RESOURCES_DIR/yt-dlp_macos"
/bin/chmod +x "$RESOURCES_DIR/yt-dlp_macos"
fi
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
