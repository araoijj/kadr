#!/bin/zsh
# Сборка Kadr.app: swift build → обёртка .app → ~/Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Kadr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Kadr "$APP/Contents/MacOS/Kadr"
# Иконка: Resources/AppIcon-1024.png (рисуется tools/make-icon.swift) → AppIcon.icns
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
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>100</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Готово: $PWD/$APP"
# Установка: та копия, что запускается из Launchpad/Spotlight. Запущенное приложение сперва закрыть.
if pgrep -x Kadr >/dev/null; then
  echo "«Кадр» запущен — закройте его и повторите, иначе в ~/Applications останется старая версия"
else
  mkdir -p ~/Applications && rm -rf ~/Applications/Kadr.app && ditto "$APP" ~/Applications/Kadr.app
  echo "Установлено: ~/Applications/Kadr.app"
fi
