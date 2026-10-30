#!/bin/sh
# Assina o .dmg com a chave EdDSA do Keychain e grava a entrada da versão em docs/appcast.xml.
# Sem a chave, pula a etapa: o .dmg continua válido, só não é oferecido pelo Sparkle.
set -eu
cd "$(dirname "$0")/.."
BIN=.build/release-app/SourcePackages/artifacts/sparkle/Sparkle/bin
ACCOUNT=quietbar
FEED=docs/appcast.xml
PLIST=dist/Quietbar.app/Contents/Info.plist

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")
DMG="dist/Quietbar-$VERSION.dmg"

KEY=$("$BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null | tail -1 || true)
if [ -z "$KEY" ] || [ "$KEY" = "${KEY#*=}" ]; then
  echo "chave do Sparkle não encontrada no Keychain (conta $ACCOUNT): assinatura do update e appcast pulados."
  exit 0
fi
[ "$KEY" = "$EXPECTED_KEY" ] || { echo "a chave do Keychain não é a do SUPublicEDKey" >&2; exit 1; }

ATTRIBUTES=$("$BIN/sign_update" --account "$ACCOUNT" "$DMG")
URL="https://github.com/raphaeltorquat0/Quietbar/releases/download/v$VERSION/Quietbar-$VERSION.dmg"
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

ITEM=$(mktemp)
trap 'rm -f "$ITEM"' EXIT
cat > "$ITEM" <<ENTRY
    <item><!-- $VERSION -->
      <title>$VERSION</title>
      <link>https://github.com/raphaeltorquat0/Quietbar/releases/tag/v$VERSION</link>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $ATTRIBUTES/>
    </item>
ENTRY

# Refazer a mesma versão troca a entrada: o `make notarize` gera um .dmg novo.
sed -i '' "/<item><!-- $VERSION -->/,/<\/item>/d" "$FEED"
sed -i '' "/<!-- novas versões entram aqui -->/r $ITEM" "$FEED"
echo "$FEED: $VERSION ($BUILD_NUMBER)"
