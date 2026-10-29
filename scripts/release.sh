#!/bin/sh
# Gera o .dmg de distribuição: dist/Quietbar-<versão>.dmg (para instalar na própria máquina, use `make install`).
#   SIGN_IDENTITY  identidade do codesign (padrão "-" = ad-hoc)
#   NOTARY_PROFILE perfil do `xcrun notarytool store-credentials`; se definido, notariza e grampeia
#   SANDBOX=0      assina sem App Sandbox (padrão: com sandbox)
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh
APP=dist/Quietbar.app

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/Quietbar-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Quietbar -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "${SIGN_IDENTITY:--}" = "-" ] && { echo "notarização exige SIGN_IDENTITY (Developer ID)" >&2; exit 1; }
  codesign -s "$SIGN_IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "$DMG"
