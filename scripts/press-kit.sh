#!/bin/sh
# Gera as imagens de divulgação em docs/screenshots e o GIF em docs/media (ver App/Sources/PressKit.swift).
# `--gif` refaz só os GIFs: demo-pt.gif (README.pt.md) e demo-en.gif (README.md).
# `--social` refaz só a imagem de prévia do repositório (docs/media/social-preview.png, 1280×640, em inglês),
# que se sobe à mão em Settings › Social preview.
set -eu
cd "$(dirname "$0")/.."
DD=.build/xcode-debug
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
APP="$DD/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar"

xcodegen generate --quiet
xcodebuild -project Quietbar.xcodeproj -scheme Quietbar -configuration Debug -derivedDataPath "$DD" build -quiet

mkdir -p docs/screenshots docs/media
if [ "${1:-}" = --social ]; then
  "$APP" --press-kit "$OUT" --social-preview -AppleAccentColor 4 -AppleLanguages "(en)"
  # A captura sai em 2x; o GitHub pede 1280×640.
  sips -z 640 1280 "$OUT/social-preview.png" --out docs/media/social-preview.png > /dev/null
  sips -g pixelWidth -g pixelHeight docs/media/social-preview.png
  exit
fi
if [ "${1:-}" != --gif ]; then
  "$APP" --press-kit "$OUT/pt" -AppleAccentColor 4 -AppleLanguages "(pt-BR)"
  mv "$OUT"/pt/*.png docs/screenshots/
fi

for lang in pt en; do
  locale=$lang; [ "$lang" = pt ] && locale=pt-BR
  gif=docs/media/demo-$lang.gif
  [ -f "$OUT/$lang/demo.mov" ] || "$APP" --press-kit "$OUT/$lang" --demo-only -AppleAccentColor 4 -AppleLanguages "($locale)"
  # Do popup do Sony ao fim do JBL; 10 fps e 256 cores mantêm o GIF abaixo de 4 MB.
  ffmpeg -y -loglevel error -ss 2 -t 14 -i "$OUT/$lang/demo.mov" \
    -vf "fps=10,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    "$gif"
  ls -lh "$gif"
done
