#!/bin/bash
# E4: alterna apps com e sem perfil no fone real, por 3 minutos em cada intervalo, e uma rajada estilo Cmd-Tab.
# Uso: e4.sh <antigo|novo|suave> [segundos de cada intervalo].
# "antigo" é o binário da main em $OLD_APP, só com o timestamp monotônico no traffic.log. "suave" liga appRuleSmoothing.
. "$(dirname "$0")/lib.sh"
VARIANT="${1:-novo}"; DURATION="${2:-180}"
LOG="$HOME/Library/Logs/Quietbar/traffic.log"
PROFILES=$(python3 - <<'PY'
import json
def p(i, name, bundle, mode):
    return {"id": f"00000000-0000-0000-0000-00000000000{i}", "name": name, "enabled": True, "trigger": {"app": {"bundleID": bundle, "name": name}}, "soundMode": mode}
print("<" + json.dumps([p(1, "Calc", "com.apple.calculator", "noiseCanceling"), p(2, "Dict", "com.apple.Dictionary", "ambient")]).encode().hex() + ">")
PY
)
mono() { python3 -c 'import time;print(time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)//1000000)'; }
step() { echo "$(mono) $1" >> "$S"; open -a "$1"; }

begin() {
    T="$OUT/e4-$VARIANT-$1.jsonl"; S="$OUT/e4-$VARIANT-$1.steps"
    rm -f "$LOG" "$S"
    "$ROOT/.build/debug/mdr-cli" set mode off > /dev/null 2>&1 || { echo "falha ao preparar o fone"; exit 1; }
    sleep 1
    open -a Stickies; sleep 1
    if [ "$VARIANT" = antigo ]; then
        "$OLD_APP" -logTraffic YES -macSoundEnabled NO -profiles "$PROFILES" > "$OUT/app.out" 2>&1 &
        APP_PID=$!; sleep 4
    else
        EXTRA=(-appRuleSmoothing NO); [ "$VARIANT" = suave ] && EXTRA=(-appRuleSmoothing YES)
        start_app "$T" -logTraffic YES -profiles "$PROFILES" "${EXTRA[@]}"
    fi
}

finish() {
    sleep 3
    if [ "$VARIANT" = antigo ]; then kill "$APP_PID"; wait "$APP_PID" 2>/dev/null; else ctl state; sleep 1; stop_app; fi
    cp "$LOG" "$OUT/e4-$VARIANT-$1.traffic"
    sleep 1
}

take_over
for I in ${INTERVALS:-1 5 10}; do
    begin "$I"
    END=$(( $(date +%s) + DURATION ))
    while [ "$(date +%s)" -lt "$END" ]; do
        for A in Calculator Stickies Dictionary Stickies; do
            step "$A"; sleep "$I"
            [ "$(date +%s)" -lt "$END" ] || break
        done
    done
    finish "$I"
done
[ -n "$INTERVALS" ] && { stop_clean=1; }
# Rajada: passa por vários apps em menos de 400 ms cada e para num com perfil.
if [ -z "$stop_clean" ]; then
    begin rajada
    for r in 1 2 3 4 5 6 7 8 9 10; do
        [ $((r % 2)) = 0 ] && LAST=Calculator || LAST=Dictionary
        for A in Dictionary Stickies Calculator Stickies "$LAST"; do step "$A"; done
        sleep 6
    done
    finish rajada
fi
rm -f "$LOG"; rmdir "$HOME/Library/Logs/Quietbar" 2>/dev/null
pkill -x Calculator; pkill -x Dictionary; pkill -x Stickies
python3 "$ROOT/scripts/validation/e4_analyze.py" "$OUT" "$VARIANT"
