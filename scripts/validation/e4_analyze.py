#!/usr/bin/env python3
"""E4: critério de aceite. Lê o traffic.log (tempo monotônico em ms), independente do motor.

Mudança audível: o fone informa um modo diferente do anterior.
SET redundante: SET de NC igual ao último estado que o fone informou (GET ou NOTIFY).
Mudança real de perfil: o perfil do app em frente muda. App sem perfil só conta se ficar mais que HOLD s,
porque antes disso é passagem. Depende só dos passos, não da variante medida.
"""
import json, os, sys

out = sys.argv[1]
variants = sys.argv[2:] or ["antigo", "novo", "suave"]
HOLD = float(os.environ.get("HOLD", 6)) * 1000
PROFILE = {"Calculator": "Calc", "Dictionary": "Dict"}


def traffic(path):
    """(ms, mão, bytes do NC) de cada SET enviado e estado recebido."""
    rows = []
    for line in open(path):
        ms, _, way, *hexes = line.split()
        b = bytes.fromhex("".join(hexes))
        if len(b) < 12 or b[1] != 0x0C:
            continue
        p = b[7:-2]
        if len(p) > 6 and p[1] == 0x17 and ((way == ">>" and p[0] == 0x68) or (way == "<<" and p[0] in (0x67, 0x69))):
            rows.append((int(ms), way, tuple(p[3:7])))
    return rows


def mode(s):
    return "off" if not s[0] else "ambient" if s[1] else "cancelamento"


def real_changes(steps):
    count = 0
    current = None
    for i, (t, app) in enumerate(steps):
        stay = steps[i + 1][0] - t if i + 1 < len(steps) else 0
        name = PROFILE.get(app)
        if name is None and stay <= HOLD:
            continue
        if name != current:
            count += 1
            current = name
    return count


print("| Variante | Intervalo | Passos | Mudanças reais de perfil | Mudanças audíveis | Audíveis por mudança real | SETs de NC | SETs/min | SETs redundantes | Confirmados pelo motor |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
for variant in variants:
    for interval in ("1", "5", "10", "rajada"):
        base = f"{out}/e4-{variant}-{interval}"
        if not os.path.exists(base + ".traffic"):
            continue
        rows = traffic(base + ".traffic")
        steps = [(int(a), b) for a, b in (l.split() for l in open(base + ".steps"))]
        begin = steps[0][0]
        last = None
        audible = sets = redundant = 0
        for ms, way, state in rows:
            if way == ">>":
                if ms >= begin:
                    sets += 1
                    redundant += last == state
            else:
                if last is not None and ms >= begin and mode(last) != mode(state):
                    audible += 1
                last = state
        real = real_changes(steps)
        minutes = (steps[-1][0] - begin) / 60000 or 1
        engine = "-"
        if os.path.exists(base + ".jsonl"):
            ev = [json.loads(l) for l in open(base + ".jsonl")]
            n = lambda k: sum(e["kind"] == k for e in ev)
            engine = f"{n('confirm')}/{n('write')}, {n('divergence')} div., {n('failure')} falhas"
        name = f"{interval} s" if interval != "rajada" else "rajada"
        print(f"| {variant} | {name} | {len(steps)} | {real} | {audible} | {audible / real:.2f} | {sets} | {sets / minutes:.1f} | {redundant} | {engine} |")
