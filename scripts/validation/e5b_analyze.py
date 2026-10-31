#!/usr/bin/env python3
"""E5b: por ciclo, o override foi preservado? Mede a latência da troca de app até o SET. A fonte do SET é o tráfego."""
import json, statistics, sys
from pathlib import Path

out, name = Path(sys.argv[1]), sys.argv[2]
sets = []  # tempo de cada SET de modo de som
for line in (out / f"{name}.traffic").read_text().splitlines():
    w = line.split(" ")
    if len(w) < 4 or w[2] != ">>":
        continue
    b = bytes.fromhex("".join(w[3:]))
    p = b[7:-2]
    if p[:1] == b"\x68":
        sets.append(int(w[0]))

events = []
for path in (out / f"{name}.jsonl.all",):
    events += [json.loads(l) for l in path.read_text().splitlines() if l.strip()]

steps = [l.split(" ") for l in (out / f"{name}.steps").read_text().splitlines()]
windows = {}
for ms, kind, *rest in steps:
    if kind in ("troca", "fim"):
        windows.setdefault(" ".join(rest), {})[kind] = int(ms)

def last_state(label):
    state = None
    for e in events:
        if e.get("kind") == "state":
            state = e
        if e.get("kind") == "mark" and e.get("text") == f"fim {label}":
            return state

rows = {}
for label, w in windows.items():
    scenario = label.split(" ")[0]
    state = last_state(label) or {}
    inside = [s for s in sets if w["troca"] <= s <= w["fim"]]
    rows.setdefault(scenario, []).append({
        "label": label, "mode": state.get("mode"), "rule": state.get("rule"),
        "sets": len(inside), "latency": inside[0] - w["troca"] if inside else None,
    })

print(f"# {name}")
for scenario, cycles in rows.items():
    kept = [c for c in cycles if c["mode"] == "off" and c["sets"] == 0 and c["rule"] == "Ajuste manual"]
    print(f"{scenario}: n={len(cycles)} override preservado={len(kept)} modos={sorted({str(c['mode']) for c in cycles})} indicadores={sorted({str(c['rule']) for c in cycles})} SETs={sum(c['sets'] for c in cycles)}")
    lat = sorted(c["latency"] for c in cycles if c["latency"] is not None)
    if lat:
        print(f"  troca até o SET, ms: n={len(lat)} mediana={statistics.median(lat):.0f} min={lat[0]} max={lat[-1]} todos={lat}")

reads = [e["latencyMs"] for e in events if e.get("kind") in ("verified", "manual") and e.get("latencyMs") is not None]
if reads:
    print(f"leitura com canal reaberto, ms: n={len(reads)} mediana={statistics.median(reads):.0f} min={min(reads)} max={max(reads)}")
print("eventos:", {k: sum(e.get("kind") == k for e in events) for k in ("verified", "unverified", "write", "confirm", "divergence", "failure", "unavailable")})
confirm = sorted(e["latencyMs"] for e in events if e.get("kind") == "confirm")
if confirm:
    print(f"confirmação, ms: n={len(confirm)} mediana={statistics.median(confirm):.0f} max={confirm[-1]}")

marks = [(int(ms), kind, rest) for ms, kind, *rest in steps if kind in ("dedup", "cc")]
for (t0, kind, r0), (t1, _, r1) in zip(marks[::2], marks[1::2]):
    print(f"{kind} {r0[1]}: SETs={sum(t0 <= s <= t1 for s in sets)}")
last = [e for e in events if e.get("kind") == "state"]
if last:
    print("contadores finais:", {k: last[-1].get(k) for k in ("writes", "confirmed", "divergent", "failed", "redundantBlocked", "overridesKept", "unverified")})
