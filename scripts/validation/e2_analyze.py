#!/usr/bin/env python3
"""E2: confere o debounce ao vivo e repete as mesmas bordas do microfone com outros valores."""
import json, statistics as st, sys


def load(path):
    out = []
    for line in open(path):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


app, pattern = load(sys.argv[1]), load(sys.argv[2])
mic = [(e["t"], e["running"] == "true") for e in app if e["kind"] == "mic"]
live = [(e["t"], e["active"] == "true") for e in app if e["kind"] == "call"]
opens = [e for e in pattern if e["kind"] == "open"]
closes = [e for e in pattern if e["kind"] == "close"]


def replay(delay_ms):
    """Mesma lógica do Debouncer: a mudança só vale se ficar de pé por delay_ms."""
    stable = wanted = False
    pending = None
    out = []
    for t, v in mic + [(mic[-1][0] + 60000, False)]:
        if pending and t >= pending[0]:
            stable = pending[1]
            out.append((pending[0], stable))
            pending = None
        if v == wanted:
            continue
        wanted = v
        pending = None if v == stable else (t + delay_ms, v)
    return out


on_lat = [next(t for t, v in mic if v and t >= o["t"] - 50) - o["t"] for o in opens if any(v and t >= o["t"] - 50 for t, v in mic)]
off_lat = [next(t for t, v in mic if not v and t >= c["t"] - 50) - c["t"] for c in closes if any(not v and t >= c["t"] - 50 for t, v in mic)]
print(f"bordas do microfone: {len(mic)}; aberturas {len(opens)}")
print(f"latência abertura->detector: mediana {st.median(on_lat)} ms, máx {max(on_lat)} ms")
print(f"latência fechamento->detector: mediana {st.median(off_lat)} ms, máx {max(off_lat)} ms")

steps = sorted({o["step"] for o in opens}, key=lambda s: (float(s.split(":")[0]), float(s.split(":")[1])))
print("\nvalor  picos que viraram chamada (aberto s: n/3)          reaberturas que encerraram a chamada (intervalo s: n/2)")
for d in (1, 2, 3, 4, 5, 8):
    r = replay(d * 1000)
    enters = [t for t, v in r if v]
    peaks = {}
    for o in opens:
        length, gap = o["step"].split(":")
        if gap != "9":
            continue
        c = next(c for c in closes if c["t"] > o["t"])
        hit = any(o["t"] <= t <= c["t"] + 8000 for t in enters)
        peaks.setdefault(length, []).append(hit)
    reopen = {}
    for o in opens:
        length, gap = o["step"].split(":")
        if length != "8" or gap == "14":
            continue
        c = next(c for c in closes if c["t"] > o["t"])
        nxt = next(n for n in opens if n["t"] > o["t"])
        reopen.setdefault(gap, []).append(any(c["t"] <= t <= nxt["t"] + 400 and not v for t, v in r))
    print(f"{d:>3} s  " + " ".join(f"{k}:{sum(v)}/3" for k, v in sorted(peaks.items(), key=lambda x: float(x[0])))
          + "   |   " + " ".join(f"{k}:{sum(v)}/2" for k, v in sorted(reopen.items(), key=lambda x: float(x[0]))))

print(f"\nao vivo: {len(live)} mudanças de chamada; replay no valor do app: conferir abaixo")
for d in (1, 2, 3, 4, 5, 8):
    n = len(replay(d * 1000))
    print(f"  replay {d} s: {n} mudanças")
