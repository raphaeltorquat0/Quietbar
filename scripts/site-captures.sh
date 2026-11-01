#!/bin/sh
# Gera as imagens da página do site em ~/Documents/MacKit/site-captures (ver App/Sources/SiteCaptures.swift).
# Preferências num HOME temporário: nada do usuário entra nas imagens, e nada do simulador fica nas preferências dele.
set -eu
cd "$(dirname "$0")/.."
DD=.build/xcode-debug
OUT=${1:-$HOME/Documents/MacKit/site-captures}
HOME_TMP=$(mktemp -d)
trap 'rm -rf "$HOME_TMP"' EXIT
mkdir -p "$HOME_TMP/Library/Preferences" "$OUT"

xcodegen generate --quiet
xcodebuild -project Quietbar.xcodeproj -scheme Quietbar -configuration Debug -derivedDataPath "$DD" build -quiet
CFFIXED_USER_HOME="$HOME_TMP" "$DD/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar" \
  --site-captures "$OUT" --simulate WH-1000XM5 -AppleLanguages "(en)" -AppleLocale en_US -AppleAccentColor 4
python3 scripts/site_captures.py "$OUT"
