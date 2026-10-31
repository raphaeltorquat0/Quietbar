#!/bin/bash
# E4: alterna apps com e sem perfil por 3 minutos em cada intervalo, no fone real.
# Uso: e4.sh <novo|antigo|novo-hold> [segundos de cada intervalo] . "antigo" é o binário da main, em $OLD_APP.
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
take_over
for I in 1 3 10; do
    T="$OUT/e4-$VARIANT-$I.jsonl"; S="$OUT/e4-$VARIANT-$I.steps"; TR="$OUT/e4-$VARIANT-$I.traffic"
    rm -f "$LOG" "$S"
    "$ROOT/.build/debug/mdr-cli" set mode off > /dev/null 2>&1 || { echo "falha ao preparar o fone"; exit 1; }
    sleep 1
    if [ "$VARIANT" = antigo ]; then
        "$OLD_APP" -logTraffic YES -macSoundEnabled NO -profiles "$PROFILES" > "$OUT/app.out" 2>&1 &
        APP_PID=$!; sleep 4
    else
        EXTRA=(); [ "$VARIANT" = novo-hold ] && EXTRA=(-appRuleHoldSeconds "${HOLD:-5}")
        start_app "$T" -logTraffic YES -profiles "$PROFILES" "${EXTRA[@]}"
    fi
    open -a Stickies; sleep 1
    END=$(( $(date +%s) + DURATION ))
    while [ "$(date +%s)" -lt "$END" ]; do
        for A in Calculator Stickies Dictionary Stickies; do
            python3 -c "import time;print(int(time.time()*1000),'$A')" >> "$S"
            open -a "$A"
            sleep "$I"
            [ "$(date +%s)" -lt "$END" ] || break
        done
    done
    sleep 3
    [ "$VARIANT" = antigo ] || { ctl state; sleep 1; }
    if [ "$VARIANT" = antigo ]; then kill "$APP_PID"; wait "$APP_PID" 2>/dev/null; else stop_app; fi
    cp "$LOG" "$TR"
    sleep 1
done
rm -f "$LOG"
pkill -x Calculator; pkill -x Dictionary; pkill -x Stickies
python3 "$ROOT/scripts/validation/e4_analyze.py" "$OUT" "$VARIANT"
