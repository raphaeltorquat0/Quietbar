#!/bin/sh
# Gera as imagens de divulgação em docs/screenshots e o GIF em docs/media (ver App/Sources/PressKit.swift).
set -eu
cd "$(dirname "$0")/.."
DD=.build/xcode-debug
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

xcodegen generate --quiet
xcodebuild -project Quietbar.xcodeproj -scheme Quietbar -configuration Debug -derivedDataPath "$DD" build -quiet
"$DD/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar" --press-kit "$OUT" -AppleAccentColor 4

mkdir -p docs/screenshots docs/media
mv "$OUT"/*.png docs/screenshots/
# 8 s a partir da entrada do popup; 12 fps e 256 cores mantêm o GIF abaixo de 4 MB.
ffmpeg -y -loglevel error -ss 2 -t 8 -i "$OUT/demo.mov" \
  -vf "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  docs/media/demo.gif
ls -lh docs/media/demo.gif
