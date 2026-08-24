#!/bin/bash
# Собирает Golos.app из SwiftPM-таргета. Xcode-проект не нужен.
set -e
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
REPO="Starochev/golos"

if [ ! -x vendor/whisper-server ]; then
    echo "Нет vendor/whisper-server — сначала ./build-engine.sh" >&2
    exit 1
fi

swift build -c release

APP="Golos.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Frameworks" "$APP/Contents/Helpers"

cp .build/release/Golos "$APP/Contents/MacOS/Golos"

# Движок распознавания — внутрь бандла: на чужой машине Homebrew нет.
cp vendor/whisper-server "$APP/Contents/Helpers/whisper-server"
cp vendor/whisper.cpp-LICENSE "$APP/Contents/Resources/whisper.cpp-LICENSE"

# Урезанный ffmpeg — для webm, mkv, ogg и opus, которые система не читает.
# Не обязателен: без него эти форматы просто не откроются, остальное работает.
if [ -x vendor/ffmpeg ]; then
    cp vendor/ffmpeg "$APP/Contents/Helpers/ffmpeg"
    cp vendor/ffmpeg-LICENSE "$APP/Contents/Resources/ffmpeg-LICENSE"
    cp vendor/ffmpeg-SOURCE "$APP/Contents/Resources/ffmpeg-SOURCE"
else
    echo "Нет vendor/ffmpeg — webm и ogg открываться не будут. Лечится: ./build-ffmpeg.sh"
fi

# Иконка. Пересобрать после правки рисунка: ./icon/build-icon.sh
if [ -f icon/AppIcon.icns ]; then
    cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sparkle SwiftPM не встраивает сам — копируем и указываем, где её искать.
cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/Golos" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Голос</string>
    <key>CFBundleDisplayName</key><string>Голос</string>
    <key>CFBundleIdentifier</key><string>local.golos</string>
    <key>CFBundleExecutable</key><string>Golos</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSMicrophoneUsageDescription</key><string>Нужен, чтобы записывать надиктованное</string>
    <key>NSAppleEventsUsageDescription</key><string>Нужен, чтобы вставлять текст в активное поле</string>
    <key>SUFeedURL</key><string>https://github.com/${REPO}/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>7xxAujJ6o2ytGJ8dM0G5vtUlSoMDAOfjC93bXFK0n38=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Подписываем изнутри наружу: вложенный код должен быть подписан раньше бандла.
IDENTITY="Golos Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGN="$IDENTITY"
    echo "Подпись: сертификат «$IDENTITY»"
else
    SIGN="-"
    echo "Подпись: ad-hoc. Разрешения будут слетать при пересборке —"
    echo "лечится один раз: ./setup-signing.sh"
fi

codesign --force --sign "$SIGN" "$APP/Contents/Helpers/whisper-server"
if [ -f "$APP/Contents/Helpers/ffmpeg" ]; then
    codesign --force --sign "$SIGN" "$APP/Contents/Helpers/ffmpeg"
fi
find "$APP/Contents/Frameworks/Sparkle.framework" -type f -perm +111 -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --sign "$SIGN" {} 2>/dev/null || true
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN" --identifier local.golos "$APP"

echo "Готово: $(pwd)/$APP — версия $VERSION (сборка $BUILD)"
du -sh "$APP" | awk '{print "Размер:", $1}'
