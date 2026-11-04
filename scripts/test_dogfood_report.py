#!/usr/bin/env python3
"""Confere `dogfood-report` com um histórico inventado. Roda sem o app: `python3 scripts/test_dogfood_report.py`."""
import json
import subprocess
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

SCRIPT = Path(__file__).with_name("dogfood-report")
T0 = datetime.fromisoformat("2026-11-02T09:00:00-03:00")


def ev(kind, seconds=0, day=0, /, **fields):
    at = T0 + timedelta(days=day, seconds=seconds)
    return {"t": at.isoformat(timespec="milliseconds"), "ev": kind, **fields}


def good_call(day, seconds=0):
    return [
        ev("call.start", seconds, day, apps=["us.zoom.xos"], wanted="noiseCanceling", headphone=True, mode="ambient"),
        ev("rule.applied", seconds + 1, day, rule="call", **{"from": "ambient"}, to="noiseCanceling", ackMs=80),
        ev("call.end", seconds + 600, day, apps=["us.zoom.xos"], durationS=600),
        ev("rule.undone", seconds + 604, day, rule="default", **{"from": "noiseCanceling"}, to="ambient", ackMs=70),
    ]


def run(events, crash_files=()):
    with tempfile.TemporaryDirectory() as folder:
        data, reports = Path(folder, "data"), Path(folder, "crash")
        data.mkdir()
        reports.mkdir()
        for e in events:
            with data.joinpath(e["t"][:10] + ".jsonl").open("a") as f:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")
        for name, text in crash_files:
            reports.joinpath(name).write_text(text)
        return subprocess.run([str(SCRIPT), "--dir", str(data), "--crashes", str(reports)],
                              capture_output=True, text=True, check=True).stdout


def line(text, start):
    return next(l for l in text.splitlines() if l.startswith(start))


# Uso limpo: 7 dias, 10 chamadas certas.
clean = [ev("app.open", -60, d, version="1.4.0", build="6", macOS="27.2") for d in range(7)]
clean += [e for d, s in [(d, 0) for d in range(7)] + [(d, 3600) for d in range(3)] for e in good_call(d, s)]
text = run(clean)
assert "pode liberar" in text and "ainda não libera" not in text, text
assert "10 de 10 (100%)" in text

# Vazio não quebra.
assert "Sem eventos" in run([])

# Cada critério reprova sozinho.
assert "❌" in line(run([e for e in clean if e["t"][:10] != "2026-11-08"]), "| 7 dias")

bad = clean + [
    ev("call.start", 9000, 0, apps=["com.apple.FaceTime"], wanted="noiseCanceling", headphone=True),
    ev("call.end", 9100, 0, durationS=100),
    ev("call.start", 9200, 0, apps=["x"], wanted="noiseCanceling", headphone=True),
    ev("rule.applied", 9201, 0, rule="call", **{"from": "ambient"}, to="noiseCanceling", ackMs=80),
    ev("call.end", 9300, 0, durationS=100),
    ev("call.start", 9400, 0, apps=["sem-fone"], wanted="noiseCanceling", headphone=False),
    ev("call.end", 9500, 0, durationS=100),
    ev("rule.applied", 20000, 1, rule="wifi", name="abc123", to="ambient", **{"from": "off"}, ackMs=90),
    ev("manual", 20030, 1, source="panel", to="off"),
    ev("rule.applied", 21000, 1, rule="app", name="Slack", to="ambient", **{"from": "off"}, ackMs=90),
    ev("manual", 21060, 1, source="externalChange", to="off"),
    ev("rule.applied", 22000, 2, rule="app", name="Slack", to="ambient", **{"from": "off"}, ackMs=90),
    ev("manual", 22500, 2, source="hotkey", to="off"),
    ev("manual", 23000, 2, source="channelReopened", to="off", late=True),
    ev("set.sent", 100, 1, message="noiseControl"),
    ev("set.redundant", 101, 1, message="noiseControl"),
    ev("watchdog.close", 30000, 1, uis=1, idleS=20),
    ev("watchdog.close", 30300, 1, uis=2, idleS=20),
    ev("moment", 30200, 1, id="a", state={"mode": "ambient", "wifiHash": "abc123"}),
    ev("moment.note", 30210, 1, id="a", note="watchdog fechou com o painel aberto"),
    ev("moment", 30300, 1, id="b", state={"mode": "off"}),
    ev("protocol.error", 300, 3, kind="action", error="Sem resposta do fone"),
    ev("link.down", 400, 3),
    ev("channel.close", 401, 3, reason="unexpected"),
    ev("link.up", 500, 3),
    ev("channel.close", 900, 3, reason="unexpected"),
    ev("channel.close", 950, 3, reason="idle"),
    ev("macsound.set", 1000, 3, on=True, processing=True),
    ev("macsound.sample", 1300, 3, latencyMs=12.0, cpuPct=1.2, load=0.1, phase="active"),
    ev("macsound.sample", 1600, 3, latencyMs=14.0, cpuPct=1.4, load=0.1, phase="active"),
    ev("macsound.set", 1700, 3, on=False, processing=False),
    ev("focus.change", 1800, 3, active=True, profile="Trabalho"),
    ev("profile.applied", 1900, 3, kind="wifi", name="abc123"),
    ev("evento.novo", 2000, 3),
]
crash = json.dumps({"app_version": "1.4.0", "bug_type": "309"}) + "\n" + json.dumps({"procPath": "/Applications/Quietbar.app/Contents/MacOS/Quietbar", "exception": {"type": "EXC_BAD_ACCESS"}})
dev = json.dumps({"app_version": "1.4.0"}) + "\n" + json.dumps({"procPath": "/Users/x/.build/Quietbar.app/Contents/MacOS/Quietbar"})
text = run(bad, [("Quietbar-2026-11-03-101010.ips", crash), ("Quietbar-2026-11-03-101011.ips", dev), ("Quietbar-2026-10-01-101010.ips", crash)])

assert "ainda não libera" in text
assert "❌" in line(text, "| Zero falhas") and "1 relatórios de falha, 1 erros" in text
assert "EXC_BAD_ACCESS" in text and "101011" not in text and "2026-10-01" not in text
assert "❌" in line(text, "| Troca correta") and "10 de 12" in text  # sem fone não entra na conta
assert "não trocou" in text and "não voltou para ambient" in text and "fone fora do Mac" in text
assert "❌" in line(text, "| No máximo 1") and "pior dia: 2" in text
assert "Logo depois de uma troca automática (até 120 s): **3**" in text
assert "❌" in line(text, "| Zero SETs") and "Redundantes: **1**" in text
assert "1 sem explicação, de 2" in text
assert "watchdog fechou com o painel aberto" in text and "(sem texto)" in text and '"wifiHash": "abc123"' in text
assert "Reconexões do Bluetooth: 1. Quedas do canal sem motivo: 1" in text
assert "Latência: mediana 13.0 ms" in text and "CPU do app: mediana 1.3%" in text
assert "Tipos que este relatório não conhece:** evento.novo" in text
assert "Trocas de Foco: 1" in text and "{'wifi': 1}" in text
# Um gesto no fone que muda nível e foco na voz é um ajuste, não dois (04/11 11:01:52).
gesture = good_call(0) + [
    ev("manual", 640, 0, source="other", fields={"ambientLevel": "20"}),
    ev("manual", 640.003, 0, source="other", fields={"focusOnVoice": "true"}),
]
text = run(gesture)
assert "Total: 1." in text and "Logo depois de uma troca automática (até 120 s): **1**" in text, text
assert "'ambientLevel': '20', 'focusOnVoice': 'true'" in text
print("ok")
