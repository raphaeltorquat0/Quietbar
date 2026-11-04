#!/bin/bash
# E7: roda os atalhos "QB ..." 10 vezes e usa o log do app instalado para ver se a regra veio do perform ou do polling.
# Exige o app 1.4.0 instalado e aberto, e os atalhos descritos em MANUAL_TEST.md, seção "Atalhos do E7".
. "$(dirname "$0")/lib.sh"
LIST=$(shortcuts list)
NEEDED=("QB Foco On" "QB Foco Off" "QB Intent Modo" "QB Intent Ambiente" "QB Intent Perfil" "QB Intent EQ" "QB Intent Bateria")
MISSING=0
for s in "${NEEDED[@]}"; do grep -qx "$s" <<< "$LIST" || { echo "falta o atalho: $s"; MISSING=1; }; done
[ "$MISSING" = 0 ] || { echo "experimento parado: crie os atalhos de MANUAL_TEST.md"; exit 5; }
R="$OUT/e7.jsonl"; : > "$R"
now() { python3 -c 'import time;print(int(time.time()*1000))'; }
run() {
    local start code end
    start=$(now); shortcuts run "$1" < /dev/null > "$OUT/e7-out.txt" 2>&1; code=$?; end=$(now)
    echo "{\"shortcut\":\"$1\",\"round\":$2,\"start\":$start,\"end\":$end,\"exit\":$code}" >> "$R"
}
for i in 1 2 3 4 5 6 7 8 9 10; do
    run "QB Foco On" "$i"; sleep 35   # mais que os 30 s da consulta: dá tempo de as duas fontes aparecerem
    run "QB Foco Off" "$i"; sleep 35
done
for s in Modo Ambiente Perfil EQ Bateria; do
    for i in 1 2 3 4 5 6 7 8 9 10; do run "QB Intent $s" "$i"; sleep 2; done
done
/usr/bin/log show --last 40m --style ndjson --predicate 'subsystem == "io.github.raphaeltorquat0.Quietbar" AND category == "automation"' > "$OUT/e7-log.ndjson"
python3 - "$R" "$OUT/e7-log.ndjson" <<'PY'
import datetime, json, statistics as st, sys
runs = [json.loads(l) for l in open(sys.argv[1])]
logs = []
for l in open(sys.argv[2]):
    try:
        e = json.loads(l)
    except ValueError:
        continue
    if "gatilho=focus." in e.get("eventMessage", ""):
        t = datetime.datetime.strptime(e["timestamp"][:23], "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000
        logs.append((t, "perform" if "focus.perform" in e["eventMessage"] else "poll"))
for name in sorted({r["shortcut"] for r in runs}):
    rs = [r for r in runs if r["shortcut"] == name]
    print(f"{name}: {len(rs)} execuções, {sum(r['exit'] == 0 for r in rs)} ok, duração mediana {st.median(r['end'] - r['start'] for r in rs):.0f} ms")
    if "Foco" in name:
        hits = [next(((t - r["start"], s) for t, s in logs if t >= r["start"]), None) for r in rs]
        hits = [h for h in hits if h]
        print("  fonte:", {s: sum(h[1] == s for h in hits) for s in ("perform", "poll")}, "latência mediana ms:", st.median(h[0] for h in hits) if hits else "-")
PY
