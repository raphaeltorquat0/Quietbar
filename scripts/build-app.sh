#!/bin/sh
# Compila o Quietbar.app em Release (universal) e assina. Saída: dist/Quietbar.app
#   SIGN_IDENTITY  identidade do codesign (padrão "-" = ad-hoc)
#   SANDBOX=0      assina sem App Sandbox (padrão: com sandbox)
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS=App/Support/Quietbar-Sandbox.entitlements
[ "${SANDBOX:-1}" = 0 ] && ENTITLEMENTS=App/Support/Quietbar.entitlements
BUILD=.build/release-app

command -v xcodegen >/dev/null && xcodegen generate --quiet

xcodebuild -project Quietbar.xcodeproj -scheme Quietbar -configuration Release \
  -derivedDataPath "$BUILD" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" QUIETBAR_APP_ENTITLEMENTS="$ENTITLEMENTS" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" build -quiet 2>&1 | grep -v 'IDERunDestination\|appintentsmetadataprocessor' || true

APP="$BUILD/Build/Products/Release/Quietbar.app"
[ -d "$APP" ] || { echo "build falhou" >&2; exit 1; }
rm -rf dist/Quietbar.app && mkdir -p dist
cp -R "$APP" dist/
APP=dist/Quietbar.app

if [ "$SIGN_IDENTITY" != "-" ]; then
  # De dentro para fora: a extensão primeiro, com os entitlements dela.
  for ext in "$APP"/Contents/PlugIns/*.appex; do
    codesign --force --options runtime --timestamp --entitlements Controls/QuietbarControls.entitlements -s "$SIGN_IDENTITY" "$ext"
  done
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
