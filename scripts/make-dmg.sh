#!/bin/sh
# Empacota dist/Quietbar.app em dist/Quietbar-<versão>.dmg e assina o .dmg se houver Developer ID.
set -eu
cd "$(dirname "$0")/.."
APP=dist/Quietbar.app
[ -d "$APP" ] || { echo "falta $APP; rode make release" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/Quietbar-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Quietbar -srcfolder "$STAGE" -format UDZO -ov "$DMG"
if [ -n "${QUIETBAR_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp -s "$QUIETBAR_SIGN_IDENTITY" "$DMG"
fi
echo "$DMG"
