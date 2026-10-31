#!/bin/bash
# E3: comandos no XM5 com a entrada dele aberta (HFP). 10 repetições, sem o detector: mede só o canal.
. "$(dirname "$0")/lib.sh"
preflight_mic; build_tools
T="$OUT/e3.jsonl"; A="$OUT/e3-audio.jsonl"; : > "$A"
take_over
start_app "$T"
ctl state; sleep 1
for r in 1 2 3 4 5 6 7 8 9 10; do
    ctl mark "rep $r a2dp"; "$MIC" output >> "$A"
    "$MIC" hold bluetooth 16 >> "$A" &
    H=$!
    sleep 4
    ctl mark "rep $r hfp"; "$MIC" output >> "$A"
    for m in noiseCanceling ambient off; do ctl mode "$m"; sleep 3; ctl state; done
    wait "$H"
    sleep 4
    ctl mark "rep $r fechado"; "$MIC" output >> "$A"; ctl state; sleep 1
done
ctl mode ambient; sleep 2; ctl state; sleep 1
stop_app
python3 - "$T" "$A" <<'PY'
import json, statistics as st, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
au = [json.loads(l) for l in open(sys.argv[2])]
d = [e for e in ev if e["kind"] == "direct"]
ok = [int(e["ms"]) for e in d if e.get("ok") == "true"]
print("comandos", len(d), "ok", len(ok), "falhas", [e for e in d if e.get("ok") != "true"][:5])
if ok: print("latência SET até o fone informar (ms): mediana", st.median(ok), "p95", sorted(ok)[int(len(ok) * .95) - 1], "máx", max(ok))
print("taxa da saída por etapa:", [e["rate"] for e in au if e["kind"] == "output"])
print("fases do canal:", sorted({e["phase"] for e in ev if e["kind"] == "state"}))
print("modos lidos após fechar:", [e["mode"] for e in ev if e["kind"] == "state"][-14:])
PY
