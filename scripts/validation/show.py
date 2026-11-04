#!/usr/bin/env python3
"""Linha do tempo legível de um trace JSONL."""
import json, sys

t0 = None
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    t0 = t0 or e["t"]
    rest = " ".join(f"{k}={v}" for k, v in sorted(e.items()) if k not in ("t", "kind"))
    print(f"{(e['t'] - t0) / 1000:7.2f} {e['kind']:12} {rest}"[:130])
