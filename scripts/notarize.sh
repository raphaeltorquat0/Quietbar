#!/bin/sh
# `make notarize`: notariza e grampeia o .app e o .dmg gerados por `make release`.
#   QUIETBAR_SIGN_IDENTITY   identidade Developer ID usada no `make release`
#   QUIETBAR_NOTARY_PROFILE  perfil do `xcrun notarytool store-credentials`
# O .app é notarizado primeiro, para o .dmg levar a cópia já grampeada.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${QUIETBAR_SIGN_IDENTITY:-}" ] || [ -z "${QUIETBAR_NOTARY_PROFILE:-}" ]; then
  echo "QUIETBAR_SIGN_IDENTITY ou QUIETBAR_NOTARY_PROFILE não definida: notarização pulada, o build continua ad-hoc."
  exit 0
fi

APP=dist/Quietbar.app
[ -d "$APP" ] || { echo "falta $APP; rode make release" >&2; exit 1; }
ZIP=$(mktemp -d)/Quietbar.zip
trap 'rm -rf "$(dirname "$ZIP")"' EXIT

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$QUIETBAR_NOTARY_PROFILE" --wait
# O stapler falha se a Apple não aprovou, o que interrompe o script aqui.
xcrun stapler staple "$APP"

DMG=$(scripts/make-dmg.sh)
xcrun notarytool submit "$DMG" --keychain-profile "$QUIETBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose "$APP"
xcrun stapler validate "$DMG"
echo "$DMG notarizado"
scripts/appcast.sh # o .dmg mudou: a assinatura do update precisa ser refeita
