#!/bin/bash
# E1: mute por track.enabled=false num navegador Chromium. Uso: e1.sh <parte do nome do microfone> <rótulo> [mudo em s]
# O Brave substitui o Chrome, que não está instalado nesta máquina: mesmo motor e mesma flag.
. "$(dirname "$0")/lib.sh"
preflight_mic; build_tools
WANT="$1"; TAG="$2"; MUTE="${3:-60}"
B="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
PROFILE=/tmp/qb-e1-profile; PORT=8765
PH="$OUT/e1-$TAG-phases.jsonl"; SA="$OUT/e1-$TAG-samples.jsonl"; T="$OUT/e1-$TAG-app.jsonl"
rm -rf "$PROFILE"; : > "$PH"
[ -x "$OUT/responsible" ] || swiftc -o "$OUT/responsible" "$ROOT/scripts/validation/responsible.swift"
take_over
start_app "$T" --simulate wh1000xm5 -callRuleEnabled YES -callDelaySeconds 3
python3 "$ROOT/scripts/validation/e1_server.py" "$PORT" "$ROOT/scripts/validation/e1_page.html" "$PH" &
SERVER=$!
"$MIC" sample $((MUTE + 50)) > "$SA" &
SAMPLER=$!
"$B" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --use-fake-ui-for-media-stream about:blank > /dev/null 2>&1 &
BRAVE=$!
sleep 4
# Portão: só segue se o TCC atribuir o Brave a quem já está autorizado. Sem isso, o getUserMedia abriria o diálogo.
ME=$("$OUT/responsible" | awk '{print $4}')
RESP=$("$OUT/responsible" "$BRAVE" | head -1 | sed 's/.*responsavel: //' | awk '{print $1}')
if [ "$ME" != "$RESP" ]; then echo "responsável diferente ($RESP, eu $ME): abortado sem abrir o microfone"; kill "$BRAVE" "$SERVER" "$SAMPLER"; stop_app; exit 4; fi
"$B" --user-data-dir="$PROFILE" "http://localhost:$PORT/?device=$WANT&mute=$MUTE" > /dev/null 2>&1 &
wait "$SAMPLER"
kill "$BRAVE" "$SERVER" 2>/dev/null
pkill -f "$PROFILE" 2>/dev/null
ctl state; sleep 1
stop_app
rm -rf "$PROFILE"
python3 - "$PH" "$SA" "$T" <<'PY'
import json, sys
load = lambda p: [json.loads(l) for l in open(p) if l.strip()]
ph, sa, app = map(load, sys.argv[1:4])
ev = sorted(ph + sa + [e for e in app if e["kind"] in ("mic", "call", "write")], key=lambda e: e["t"])
t0 = ph[0]["t"] if ph else ev[0]["t"]
for e in ev:
    if e["kind"] == "phase": print(f"{(e['t']-t0)/1000:7.1f} FASE {e['name']} {e['extra']}")
    elif e["kind"] == "sample": print(f"{(e['t']-t0)/1000:7.1f} amostra devices={e['devices']} processos={e['processes']}")
    elif e["kind"] == "mic": print(f"{(e['t']-t0)/1000:7.1f} detector running={e['running']} {e['processes']}")
    elif e["kind"] == "call": print(f"{(e['t']-t0)/1000:7.1f} CHAMADA {e['active']}")
    else: print(f"{(e['t']-t0)/1000:7.1f} escrita {e['fields']}")
PY
