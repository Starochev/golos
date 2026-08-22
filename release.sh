#!/bin/bash
# Собирает релиз: .app → .dmg → подпись → appcast.xml → релиз на GitHub.
#
# Приватный ключ EdDSA лежит в связке ключей (создан ./setup-signing.sh
# и generate_keys) и в репозиторий не попадает: без него подделать
# обновление нельзя.
#
#   ./release.sh 1.1.0            собрать и выложить
#   ./release.sh 1.1.0 --dry-run  собрать, но на GitHub не выкладывать
set -e
cd "$(dirname "$0")"

VERSION="$1"
DRY_RUN=""
[ "$2" = "--dry-run" ] && DRY_RUN=1

if [ -z "$VERSION" ]; then
    echo "Использование: ./release.sh ВЕРСИЯ [--dry-run]" >&2
    echo "Текущая версия: $(cat VERSION)" >&2
    exit 1
fi

REPO="Starochev/golos"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
DIST="dist"
STAGING="$DIST/staging"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "Нет инструментов Sparkle — сначала: swift build -c release" >&2
    exit 1
fi

echo "$VERSION" > VERSION

echo "── Сборка"
./build.sh > /dev/null
echo "   Golos.app $VERSION"

echo "── DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST"
cp -R Golos.app "$STAGING/Голос.app"
ln -s /Applications "$STAGING/Applications"

DMG="$DIST/Golos-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Голос" -srcfolder "$STAGING" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGING"
echo "   $DMG ($(du -h "$DMG" | cut -f1))"

echo "── Подпись обновления и appcast"
# generate_appcast сам подписывает каждый файл в папке и собирает список версий.
# Prefix нужен, чтобы Sparkle качал из релиза, а не искал файл рядом с appcast.
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    "$DIST" 2>&1 | grep -v "^$" || true

if [ ! -f "$DIST/appcast.xml" ]; then
    echo "appcast.xml не собрался" >&2
    exit 1
fi
echo "   appcast.xml готов"

if [ -n "$DRY_RUN" ]; then
    echo
    echo "Пробный прогон: на GitHub ничего не отправлено."
    echo "Файлы в $DIST/"
    exit 0
fi

echo "── Релиз на GitHub"
command -v gh >/dev/null || { echo "Нужен gh: brew install gh" >&2; exit 1; }

git add -A
git commit -m "Версия $VERSION" > /dev/null 2>&1 || true
git tag -f "v$VERSION" > /dev/null
git push origin HEAD --tags --force > /dev/null

gh release create "v$VERSION" \
    "$DMG" "$DIST/appcast.xml" \
    --repo "$REPO" \
    --title "Голос $VERSION" \
    --notes "Обновление $VERSION" \
    || gh release upload "v$VERSION" "$DMG" "$DIST/appcast.xml" --repo "$REPO" --clobber

echo
echo "Готово. Установленные копии увидят обновление в течение суток"
echo "или сразу по пункту меню «Проверить обновления…»."
