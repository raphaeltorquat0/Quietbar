#!/bin/bash
# E6: dois processos no microfone, um ignorado e outro não. Ferramenta sem bundle: o app identifica pelo nome do processo.
. "$(dirname "$0")/lib.sh"
preflight_mic; build_tools
T="$OUT/e6.jsonl"
cp "$MIC" "$OUT/mic-ignored"; cp "$MIC" "$OUT/mic-other"
IGN=$(python3 -c "print('<'+b'[{\"bundleID\":\"mic-ignored\",\"name\":\"x\"}]'.hex()+'>')")
take_over
start_app "$T" --simulate wh1000xm5 -callRuleEnabled YES -callDelaySeconds 1 -micIgnoredApps "$IGN"
ctl mark "1 so o ignorado"; "$OUT/mic-ignored" hold builtin 6 >/dev/null; sleep 3
ctl mark "2 so o outro"; "$OUT/mic-other" hold builtin 6 >/dev/null; sleep 3
ctl mark "3 ignorado aberto, outro entra e sai"
"$OUT/mic-ignored" hold builtin 16 >/dev/null &
sleep 4; ctl mark "3 outro entra"; "$OUT/mic-other" hold builtin 6 >/dev/null; ctl mark "3 outro saiu"; wait $!; sleep 3
ctl mark "4 outro aberto, ignorado entra, outro sai"
"$OUT/mic-other" hold builtin 10 >/dev/null &
sleep 4; "$OUT/mic-ignored" hold builtin 12 >/dev/null &
I=$!; sleep 7; ctl mark "4 outro saiu"; wait $I; sleep 3
ctl state; sleep 1
stop_app
python3 "$ROOT/scripts/validation/show.py" "$T" | grep -vE ' (decision|trigger|confirm) '
