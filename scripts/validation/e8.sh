#!/bin/bash
# E8: reassina uma cópia do build de Release com hardened runtime, ad hoc, e confere o Metadata.appintents.
# Não substitui a notarização: ad hoc não tem Team ID nem passa pelo serviço da Apple.
. "$(dirname "$0")/lib.sh"
SRC="$ROOT/dist/Quietbar.app"; COPY="$OUT/e8/Quietbar.app"
rm -rf "$OUT/e8"; mkdir -p "$OUT/e8"; ditto "$SRC" "$COPY"
sums() { (cd "$1/Contents/Resources" && find Metadata.appintents en.lproj -type f -exec shasum -a 256 {} + | sort -k2); }
sums "$SRC" > "$OUT/e8/antes.txt"
ENT="$ROOT/App/Support/Quietbar-Sandbox.entitlements"
# De dentro para fora, como scripts/build-app.sh faz com Developer ID.
S="$COPY/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --options runtime --timestamp=none -s - "$@"; }
sign "$S/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$S/Versions/B/XPCServices/Downloader.xpc"
sign "$S/Versions/B/Autoupdate"; sign "$S/Versions/B/Updater.app"; sign "$S"
for x in "$COPY"/Contents/PlugIns/*.appex; do codesign --force --options runtime --timestamp=none --entitlements "$ROOT/Controls/QuietbarControls.entitlements" -s - "$x"; done
codesign --force --options runtime --timestamp=none --entitlements "$ENT" -s - "$COPY"
sums "$COPY" > "$OUT/e8/depois.txt"
diff "$OUT/e8/antes.txt" "$OUT/e8/depois.txt" && echo "recursos idênticos: $(wc -l < "$OUT/e8/depois.txt") arquivos"
codesign --verify --deep --strict "$COPY" && echo "assinatura válida"
codesign -dv "$COPY" 2>&1 | grep -E 'flags=|Signature|TeamIdentifier'
python3 - "$COPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/Contents/Resources/Metadata.appintents/extract.actionsdata"))
print("intents:", sorted(d["actions"]), "atalhos:", len(d["autoShortcuts"]))
PY
echo "--- com hardened runtime e ad hoc (Team ID vazio):"
"$COPY/Contents/MacOS/Quietbar" --mic-status > "$OUT/e8/run1.txt" 2>&1; echo "saída: $?"; head -1 "$OUT/e8/run1.txt" | cut -c1-90
echo "--- variante só deste teste, com disable-library-validation, para o Sparkle ad hoc carregar:"
cp "$ENT" "$OUT/e8/ent.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$OUT/e8/ent.plist"
codesign --force --options runtime --timestamp=none --entitlements "$OUT/e8/ent.plist" -s - "$COPY" 2>/dev/null
"$COPY/Contents/MacOS/Quietbar" --mic-status > "$OUT/e8/run2.txt" 2>&1; echo "saída: $?"; tail -1 "$OUT/e8/run2.txt" | cut -c1-90
sums "$COPY" | diff "$OUT/e8/antes.txt" - && echo "recursos ainda idênticos"
