#!/usr/bin/env python3
"""E4: conta SETs de NC no tráfego e compara o estado lido com o esperado em cada passo."""
import datetime, json, os, sys

out, variant = sys.argv[1], sys.argv[2]
mode_of = lambda en, amb: "off" if not en else "ambient" if amb else "noiseCanceling"
total = {}
for interval in (1, 3, 10):
    base = f"{out}/e4-{variant}-{interval}"
    if not os.path.exists(base + ".traffic"):
        continue
    sets, reports = [], []
    for line in open(base + ".traffic"):
        stamp, way, *hexes = line.split()
        b = bytes.fromhex("".join(hexes))
        if len(b) < 12 or b[1] not in (0x0C,):
            continue
        p = b[7:-2]
        t = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1000
        if way == ">>" and p[0] == 0x68 and p[1] == 0x17:
            sets.append(t)
        if way == "<<" and p[0] in (0x67, 0x69) and p[1] == 0x17:
            reports.append((t, mode_of(p[3] == 1, p[4] == 1)))
    steps = [(int(a), b) for a, b in (l.split() for l in open(base + ".steps"))]
    profile = {"Calculator": "noiseCanceling", "Dictionary": "ambient"}
    held = "off"
    wrong = 0
    checked = 0
    for i, (t, app) in enumerate(steps[:-1]):
        # Esperado: perfil do app; sem perfil, o novo volta ao padrão e o antigo mantém o último.
        if variant == "antigo":
            held = profile.get(app, held)
        else:
            held = profile.get(app, "off")
        end = steps[i + 1][0]
        seen = [m for rt, m in reports if rt <= end]
        checked += 1
        if not seen or seen[-1] != held:
            wrong += 1
    ev = []
    if os.path.exists(base + ".jsonl"):
        ev = [json.loads(l) for l in open(base + ".jsonl")]
    count = lambda k: sum(e["kind"] == k for e in ev)
    minutes = (steps[-1][0] - steps[0][0]) / 60000
    print(f"{variant:9} intervalo {interval:>2} s: passos {len(steps):>3}  SETs NC {len(sets):>3} ({len(sets) / minutes:5.1f}/min)  "
          f"motor: escritas {count('write'):>3} confirmadas {count('confirm'):>3} divergentes {count('divergence')} falhas {count('failure')} manuais {count('manual')}  "
          f"passos com estado errado no fim {wrong}/{checked}")
