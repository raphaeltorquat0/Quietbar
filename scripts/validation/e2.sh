#!/bin/bash
# E2: abre o microfone interno em padrões e registra quando o motor entra e sai de chamada (debounce do app: $1 s).
. "$(dirname "$0")/lib.sh"
preflight_mic; build_tools
DELAY="${1:-3}"
T="$OUT/e2-app.jsonl"; P="$OUT/e2-pattern.jsonl"
take_over
start_app "$T" --simulate wh1000xm5 -callRuleEnabled YES -callDelaySeconds "$DELAY"
: > "$P"
for r in 1 2 3; do
    for peak in 0.1 0.3 1 2 3 5; do "$MIC" pattern builtin "$peak:9" >> "$P"; done
done
for gap in 0.5 1 2 3 5 10; do
    for r in 1 2; do "$MIC" pattern builtin "8:$gap" "8:14" >> "$P"; done
done
stop_app
python3 "$ROOT/scripts/validation/e2_analyze.py" "$T" "$P"
