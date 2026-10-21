#!/bin/zsh
# Builds Kadr.app: swift build → .app bundle → ~/Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Kadr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Kadr "$APP/Contents/MacOS/Kadr"
# MediaPipe face mesh (Apache 2.0) goes inside the app so AI culling works without a separate install.
# The models are not in the repo: the archive is fetched from the models-1 release and cached in .build.
MODELS_ZIP=.build/models/kadr-facemesh-1.zip
if [ ! -s "$MODELS_ZIP" ]; then
  mkdir -p .build/models
  curl -fsSL --max-time 120 -o "$MODELS_ZIP.part" https://github.com/araoijj/kadr/releases/download/models-1/kadr-facemesh-1.zip \
    && mv "$MODELS_ZIP.part" "$MODELS_ZIP" || { rm -f "$MODELS_ZIP.part"; echo "Модели сетки лица не скачались — сборка без них"; }
fi
if [ -s "$MODELS_ZIP" ]; then
  ditto -x -k "$MODELS_ZIP" .build/models/x && rm -rf "$APP/Contents/Resources/FaceMesh" \
    && mv .build/models/x/kadr-facemesh-1 "$APP/Contents/Resources/FaceMesh" && rm -rf .build/models/x
fi
# Icon: Resources/AppIcon-1024.png (drawn by tools/make-icon.swift) → AppIcon.icns
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Кадр</string>
  <key>CFBundleDisplayName</key><string>Кадр</string>
  <key>CFBundleIdentifier</key><string>ru.kozlov.kadr</string>
  <key>CFBundleExecutable</key><string>Kadr</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.4.5</string>
  <key>CFBundleVersion</key><string>145</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Готово: $PWD/$APP"
# Install: the copy launched from Launchpad/Spotlight. Quit the running app first.
if pgrep -x Kadr >/dev/null; then
  echo "«Кадр» запущен — закройте его и повторите, иначе в ~/Applications останется старая версия"
else
  mkdir -p ~/Applications && rm -rf ~/Applications/Kadr.app && ditto "$APP" ~/Applications/Kadr.app
  echo "Установлено: ~/Applications/Kadr.app"
fi
