#!/bin/bash
# Собирает ffmpeg, урезанный до одной задачи: достать звук из файла.
#
# Зачем свой, а не готовый: полный ffmpeg весит 52 МБ, потому что тащит
# кодировщики видео, сеть, плеер и x264. Нам нужно только прочитать чужой
# контейнер и записать WAV. С --disable-everything остаётся 2,3 МБ,
# зависимости только системные.
#
# Нужен он не всегда: mp4, mov, m4a, mp3, wav, flac система читает сама.
# Дыра в webm, ogg, opus и mkv — их AVFoundation не берёт вовсе.
#
# Лицензия: без --enable-gpl это LGPL 2.1. Кладём отдельным файлом,
# исходники не правим, строку configure сохраняем рядом — этого хватает.
#
# Запускать разово: результат лежит в vendor/ и переживает пересборки .app.
#   ./build-ffmpeg.sh              — под macOS
#   ./build-ffmpeg.sh --windows    — ещё и ffmpeg.exe, кросс-сборкой
set -e
cd "$(dirname "$0")"

VERSION="7.1.1"
WORK="${TMPDIR:-/tmp}/golos-ffmpeg-build"

WINDOWS=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --windows) WINDOWS=true ;;
        --force) FORCE=true ;;
    esac
done

TARGET="vendor/ffmpeg"
$WINDOWS && TARGET="vendor/ffmpeg.exe"

if [ -f "$TARGET" ] && ! $FORCE; then
    echo "Уже собран: $TARGET"
    echo "Пересобрать: ./build-ffmpeg.sh $* --force"
    exit 0
fi

# Ровно то, что нужно, чтобы вскрыть контейнер и достать дорожку.
# Видеодекодеров нет: видео отбрасывается на входе.
CONFIGURE=(
    --disable-everything --disable-autodetect --disable-doc --disable-network
    --disable-debug --enable-small
    --disable-programs --enable-ffmpeg
    --enable-demuxer=matroska,ogg,mov,mp3,wav,flac,aac,asf,avi,aiff,caf,w64,mpegts,flv,ac3,wv,ape
    --enable-decoder=opus,vorbis,aac,aac_latm,mp3,mp3float,flac,alac,ac3,eac3,mp2,wmav1,wmav2,wavpack,ape,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw
    --enable-parser=opus,vorbis,aac,aac_latm,mpegaudio,flac,ac3
    --enable-protocol=file,pipe
    --enable-filter=aresample,aformat,anull,atrim
    --enable-muxer=wav --enable-encoder=pcm_s16le
)

if $WINDOWS; then
    command -v x86_64-w64-mingw32-gcc >/dev/null \
        || { echo "Нужен кросс-компилятор: brew install mingw-w64" >&2; exit 1; }
    # Ассемблер нужен только под x86: на arm64 SIMD берётся из компилятора.
    command -v nasm >/dev/null \
        || { echo "Нужен ассемблер: brew install nasm" >&2; exit 1; }
    CONFIGURE+=(
        --enable-cross-compile --cross-prefix=x86_64-w64-mingw32-
        --arch=x86_64 --target-os=mingw32 --pkg-config=false
        --extra-ldflags=-static
    )
    BUILD_DIR="$WORK/build-win"
else
    BUILD_DIR="$WORK/build-mac"
fi

mkdir -p "$WORK"
if [ ! -d "$WORK/ffmpeg-$VERSION" ]; then
    echo "Забираю исходники ffmpeg $VERSION…"
    curl -sSL -o "$WORK/ff.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
    tar xf "$WORK/ff.tar.xz" -C "$WORK"
fi

echo "Собираю…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
"$WORK/ffmpeg-$VERSION/configure" "${CONFIGURE[@]}" > configure.log 2>&1 \
    || { tail -20 configure.log >&2; exit 1; }
make -j "$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -20 make.log >&2; exit 1; }
cd - > /dev/null

mkdir -p vendor
if $WINDOWS; then
    cp "$BUILD_DIR/ffmpeg.exe" vendor/ffmpeg.exe
else
    cp "$BUILD_DIR/ffmpeg" vendor/ffmpeg
    strip -x vendor/ffmpeg
    # Ссылки только на системные фреймворки — иначе на чужой машине не запустится.
    FOREIGN=$(otool -L vendor/ffmpeg | tail -n +2 | awk '{print $1}' \
        | grep -vE '^(/usr/lib|/System)' || true)
    if [ -n "$FOREIGN" ]; then
        echo "Остались посторонние зависимости:" >&2
        echo "$FOREIGN" >&2
        exit 1
    fi
fi

cp "$WORK/ffmpeg-$VERSION/COPYING.LGPLv2.1" vendor/ffmpeg-LICENSE
{
    echo "ffmpeg $VERSION, https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
    echo "Исходники не изменялись. Собрано строкой:"
    echo
    printf '%s \\\n' "${CONFIGURE[@]}" | sed 's/^/  /'
} > vendor/ffmpeg-SOURCE

echo "Готово: $TARGET ($(du -h "$TARGET" | cut -f1))"
