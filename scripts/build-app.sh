#!/bin/sh
# Compila o Quietbar.app em Release (universal) e assina. Saída: dist/Quietbar.app
#   QUIETBAR_SIGN_IDENTITY  identidade do codesign (padrão "-" = ad-hoc)
#   SANDBOX=0               assina sem App Sandbox (padrão: com sandbox)
# Versão: só em project.yml (MARKETING_VERSION e CURRENT_PROJECT_VERSION).
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${QUIETBAR_SIGN_IDENTITY:--}"
ENTITLEMENTS=App/Support/Quietbar-Sandbox.entitlements
[ "${SANDBOX:-1}" = 0 ] && ENTITLEMENTS=App/Support/Quietbar.entitlements
BUILD=.build/release-app
BUILT="$BUILD/Build/Products/Release/Quietbar.app"
LOG="$BUILD/xcodebuild.log"
STARTED="$BUILD/build-started"

yaml_value() { sed -n "s/^ *$1: \"\(.*\)\"$/\1/p" project.yml; }
VERSION=$(yaml_value MARKETING_VERSION)
BUILD_NUMBER=$(yaml_value CURRENT_PROJECT_VERSION)

command -v xcodegen >/dev/null && xcodegen generate --quiet

# Sem .app anterior, uma falha de build nunca reaproveita um produto antigo.
rm -rf "$BUILT" dist/Quietbar.app
mkdir -p "$BUILD" dist
touch "$STARTED"
xcodebuild -project Quietbar.xcodeproj -scheme Quietbar -configuration Release \
  -derivedDataPath "$BUILD" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" QUIETBAR_APP_ENTITLEMENTS="$ENTITLEMENTS" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" build -quiet > "$LOG" 2>&1 || {
    grep -E 'error:|\*\* BUILD' "$LOG" >&2 || tail -20 "$LOG" >&2
    echo "build falhou (log completo: $LOG)" >&2
    exit 1
}

fail() { echo "build inválido: $1" >&2; exit 1; }
[ -d "$BUILT" ] || fail "$BUILT não foi gerado"
[ "$BUILT/Contents/MacOS/Quietbar" -nt "$STARTED" ] || fail "o binário é anterior a este build"
PLIST="$BUILT/Contents/Info.plist"
GOT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
GOT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
[ "$GOT_VERSION ($GOT_BUILD)" = "$VERSION ($BUILD_NUMBER)" ] \
  || fail "o app tem $GOT_VERSION ($GOT_BUILD) e o project.yml pede $VERSION ($BUILD_NUMBER); rode xcodegen generate"
for arch in arm64 x86_64; do
  lipo "$BUILT/Contents/MacOS/Quietbar" -verify_arch "$arch" || fail "falta a arquitetura $arch"
done

scripts/check-release-clean.sh "$BUILT/Contents/MacOS/Quietbar"

cp -R "$BUILT" dist/
APP=dist/Quietbar.app

if [ "$SIGN_IDENTITY" != "-" ]; then
  # De dentro para fora, sem --deep: o Sparkle pede os serviços e auxiliares um a um.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  sign() { codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$@"; }
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
  for ext in "$APP"/Contents/PlugIns/*.appex; do
    codesign --force --options runtime --timestamp --entitlements Controls/QuietbarControls.entitlements -s "$SIGN_IDENTITY" "$ext"
  done
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "dist/Quietbar.app $VERSION ($BUILD_NUMBER)"
