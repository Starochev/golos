#!/bin/bash
# Собирает движок распознавания в один самодостаточный бинарник.
#
# Зачем не Homebrew: у сборки whisper-cpp из Homebrew бэкенды ggml лежат
# отдельными плагинами, а путь к ним вшит в библиотеку. На чужой машине,
# где Homebrew нет, они не находятся — и переменной GGML_BACKEND_PATH это
# не перебивается. Своя статическая сборка снимает вопрос: один файл,
# Metal внутри, зависимости только системные.
#
# Запускать разово: результат лежит в vendor/ и переживает пересборки .app.
set -e
cd "$(dirname "$0")"

VERSION="v1.9.2"
WORK="${TMPDIR:-/tmp}/golos-engine-build"

if [ -x vendor/whisper-server ] && [ "$1" != "--force" ]; then
    echo "Движок уже собран: vendor/whisper-server"
    echo "Пересобрать: ./build-engine.sh --force"
    exit 0
fi

command -v cmake >/dev/null || { echo "Нужен cmake: brew install cmake" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
echo "Забираю whisper.cpp $VERSION…"
git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp.git "$WORK/src" 2>&1 | tail -1

echo "Собираю…"
cmake -B "$WORK/build" -S "$WORK/src" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON > /dev/null

cmake --build "$WORK/build" --config Release -j "$(sysctl -n hw.ncpu)" \
    --target whisper-server 2>&1 | tail -2

mkdir -p vendor
cp "$WORK/build/bin/whisper-server" vendor/whisper-server
cp "$WORK/src/LICENSE" vendor/whisper.cpp-LICENSE

# Ссылки только на системные фреймворки — иначе на чужой машине не запустится.
FOREIGN=$(otool -L vendor/whisper-server | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib|/System)' || true)
if [ -n "$FOREIGN" ]; then
    echo "Остались посторонние зависимости:" >&2
    echo "$FOREIGN" >&2
    exit 1
fi

rm -rf "$WORK"
echo "Готово: vendor/whisper-server ($(du -h vendor/whisper-server | cut -f1))"
