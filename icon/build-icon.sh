#!/bin/bash
# Рисует иконку и собирает AppIcon.icns.
#
# Исходник — не картинка, а код: draw.swift рисует через Core Graphics,
# поэтому иконку можно поправить и пересобрать, не открывая редактор.
# Мелкие размеры берутся из упрощённого рисунка: тонкие лучи в 16 пикселях
# сливаются в пятно.
set -e
cd "$(dirname "$0")"

echo "Рисую…"
swift draw.swift . > /dev/null
cp icon-full.png icon-1024.png

SET="AppIcon.iconset"
rm -rf "$SET"
mkdir -p "$SET"

emit() {  # размер, имя, исходник
    sips -z "$1" "$1" "$3" --out "$SET/icon_$2.png" > /dev/null
}

emit 16   "16x16"      icon-tiny.png
emit 32   "16x16@2x"   icon-tiny.png
emit 32   "32x32"      icon-small.png
emit 64   "32x32@2x"   icon-small.png
emit 128  "128x128"    icon-medium.png
emit 256  "128x128@2x" icon-medium.png
emit 256  "256x256"    icon-medium.png
emit 512  "256x256@2x" icon-full.png
emit 512  "512x512"    icon-full.png
emit 1024 "512x512@2x" icon-full.png

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "Готово: $(pwd)/AppIcon.icns ($(du -h AppIcon.icns | cut -f1))"
