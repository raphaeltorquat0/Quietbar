#!/bin/sh
# Compila o SonyCtl.app em Release (universal) e assina. Saída: dist/SonyCtl.app
#   SIGN_IDENTITY  identidade do codesign (padrão "-" = ad-hoc)
#   SANDBOX=0      assina sem App Sandbox (padrão: com sandbox)
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS=App/Support/SonyCtl-Sandbox.entitlements
[ "${SANDBOX:-1}" = 0 ] && ENTITLEMENTS=App/Support/SonyCtl.entitlements
BUILD=.build/release-app

command -v xcodegen >/dev/null && xcodegen generate --quiet

xcodebuild -project SonyCtl.xcodeproj -scheme SonyCtl -configuration Release \
  -derivedDataPath "$BUILD" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" SONYCTL_APP_ENTITLEMENTS="$ENTITLEMENTS" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" build -quiet 2>&1 | grep -v 'IDERunDestination\|appintentsmetadataprocessor' || true

APP="$BUILD/Build/Products/Release/SonyCtl.app"
[ -d "$APP" ] || { echo "build falhou" >&2; exit 1; }
rm -rf dist/SonyCtl.app && mkdir -p dist
cp -R "$APP" dist/
APP=dist/SonyCtl.app

if [ "$SIGN_IDENTITY" != "-" ]; then
  # De dentro para fora: a extensão primeiro, com os entitlements dela.
  for ext in "$APP"/Contents/PlugIns/*.appex; do
    codesign --force --options runtime --timestamp --entitlements Controls/SonyCtlControls.entitlements -s "$SIGN_IDENTITY" "$ext"
  done
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
