"""Sanitiza capturas MDR: troca identificadores por valores falsos determinísticos e recusa o que restar."""
import argparse
import hashlib
import pathlib
import re
import sys

START, END, ESCAPE = 0x3E, 0x3C, 0x3D
TABLE1, TABLE2 = {0x0C, 0x1C}, {0x0E, 0x1E}
FIXTURES = pathlib.Path("Packages/MDRSimulator/Tests/Fixtures")
GENERATED = pathlib.Path("Packages/MDRSimulator/Sources/MDRSimulator/Profiles/CapturedFrames.generated.swift")

MAC = re.compile(rb"[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}")
FAKE_MAC = re.compile(rb"02:00:00:[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}")
LONG_HEX = re.compile(rb"(?<![0-9A-Za-z])[0-9A-Fa-f]{12,}(?![0-9A-Za-z])")
PRINTABLE = re.compile(rb"[\x20-\x7E]{4,}")
FAKE_TEXT = re.compile(rb"^x[0-9a-f]+$")

# Comandos em que texto é parte do protocolo, não dado da pessoa (tabela, comando): motivo.
TEXT_ALLOWED = {
    (1, 0x05): "modelo, firmware e série do fone",
    (1, 0x07): "lista binária de funções",
    (2, 0x07): "lista binária de funções",
    (1, 0xD1): "nomes fixos dos ajustes gerais",
    (1, 0x51): "nomes de presets de EQ",
    (1, 0xF1): "capacidades binárias",
}
# Texto livre que pertence à pessoa: faixa tocando e aparelhos pareados.
SCRUB_TEXT = {(1, 0xA7), (1, 0xA9), (2, 0x37), (2, 0x39)}
CAPABILITY_INFO = (1, 0x03)


def fake(original: bytes) -> bytes:
    """Mesmo tamanho do original, para os campos de comprimento continuarem válidos."""
    digest = hashlib.sha256(b"quietbar-fixture:" + original).hexdigest().encode()
    return (b"x" + digest * (len(original) // 64 + 1))[: len(original)]


def fake_mac(original: bytes) -> bytes:
    if FAKE_MAC.fullmatch(original):
        return original
    d = hashlib.sha256(b"quietbar-fixture:" + original.upper()).hexdigest().upper().encode()
    return b"02:00:00:" + d[:2] + b":" + d[2:4] + b":" + d[4:6]


def decode(raw: bytes):
    if len(raw) < 9 or raw[0] != START or raw[-1] != END:
        raise ValueError("frame sem marcadores")
    body, i = bytearray(), 1
    while i < len(raw) - 1:
        b = raw[i]
        if b == ESCAPE:
            i += 1
            b = raw[i] + 0x10
        body.append(b)
        i += 1
    if sum(body[:-1]) & 0xFF != body[-1]:
        raise ValueError("checksum inválido")
    if int.from_bytes(body[2:6], "big") != len(body) - 7:
        raise ValueError("comprimento inválido")
    return body[0], body[1], bytes(body[6:-1])


def encode(kind: int, seq: int, payload: bytes) -> bytes:
    body = bytes([kind, seq]) + len(payload).to_bytes(4, "big") + payload
    body += bytes([sum(body) & 0xFF])
    out = bytearray([START])
    for b in body:
        out += bytes([ESCAPE, b - 0x10]) if b in (START, END, ESCAPE) else bytes([b])
    return bytes(out + bytes([END]))


def table(kind: int) -> int:
    return 1 if kind in TABLE1 else 2 if kind in TABLE2 else 0


def sanitize(kind: int, payload: bytes) -> bytes:
    if not payload:
        return payload
    key = (table(kind), payload[0])
    out = MAC.sub(lambda m: fake_mac(m.group()), payload)
    if key == CAPABILITY_INFO and len(out) > 4:
        n = out[3]
        out = out[:4] + (fake_mac(out[4:4 + n]) if MAC.fullmatch(out[4:4 + n]) else fake(out[4:4 + n])) + out[4 + n:]
    if key in SCRUB_TEXT:
        out = PRINTABLE.sub(lambda m: m.group() if FAKE_MAC.fullmatch(m.group()) or FAKE_TEXT.match(m.group()) else fake(m.group()), out)
    return out


def problems(kind: int, payload: bytes, deny: list[bytes]) -> list[str]:
    found = []
    key = (table(kind), payload[0] if payload else -1)
    for m in MAC.finditer(payload):
        if not FAKE_MAC.fullmatch(m.group()):
            found.append(f"endereço {m.group().decode()}")
    for m in LONG_HEX.finditer(payload):
        found.append(f"sequência hexadecimal longa {m.group().decode()}")
    if key not in TEXT_ALLOWED:
        for m in PRINTABLE.finditer(payload):
            text = m.group()
            if not FAKE_MAC.fullmatch(text) and not FAKE_TEXT.match(text):
                found.append(f"texto {text.decode()!r} no comando {key[1]:#04x}")
    for d in deny:
        if d in payload:
            found.append("texto da lista --deny")
    return found


def read_capture(path: pathlib.Path):
    if path.is_dir():
        for f in sorted(path.glob("*.bin")):
            yield ("tx" if "-tx." in f.name else "rx"), f.read_bytes()
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        log = re.search(r"(>>|<<) ((?:[0-9a-fA-F]{2} ?)+)", line)  # mdr-cli --log-hex
        if log:
            yield ("tx" if log.group(1) == ">>" else "rx"), bytes.fromhex(log.group(2))
        elif line and not line.startswith("#"):
            direction, data = line.split(None, 1)
            yield direction.lower(), bytes.fromhex(data)


def fixture_frames(path: pathlib.Path):
    for line in path.read_text().splitlines():
        if line and not line.startswith("#"):
            direction, data = line.split()
            yield direction, bytes.fromhex(data)


def generate() -> None:
    lines = ["// Gerado por scripts/sanitize-capture.sh a partir de Tests/Fixtures. Não edite.", "",
             "enum CapturedFrames {", "    static let all: [String: [String]] = ["]
    for path in sorted(FIXTURES.glob("*.capture")):
        lines.append(f'        "{path.stem}": [')
        lines += [f'            "{d} {raw.hex()}",' for d, raw in fixture_frames(path)]
        lines.append("        ],")
    lines += ["    ]", "}", ""]
    GENERATED.parent.mkdir(parents=True, exist_ok=True)
    GENERATED.write_text("\n".join(lines))


def check_all(deny: list[bytes]) -> int:
    failed = 0
    for path in sorted(FIXTURES.glob("*.capture")):
        for direction, raw in fixture_frames(path):
            kind, _, payload = decode(raw)
            for p in problems(kind, payload, deny):
                print(f"{path.name}: {p}", file=sys.stderr)
                failed += 1
    return failed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", nargs="?")
    ap.add_argument("name", nargs="?")
    ap.add_argument("--model")
    ap.add_argument("--firmware", default="?")
    ap.add_argument("--source", default="?")
    ap.add_argument("--deny")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    deny = [l.encode() for l in pathlib.Path(a.deny).read_text().splitlines() if l.strip()] if a.deny else []

    if a.check:
        failed = check_all(deny)
        if failed:
            print(f"{failed} problema(s) nas fixtures", file=sys.stderr)
            return 1
        generate()
        print("fixtures limpas")
        return 0

    if not (a.capture and a.name and a.model):
        ap.error("informe a captura, o nome e --model")
    out, failed, skipped = [], 0, 0
    for direction, raw in read_capture(pathlib.Path(a.capture)):
        try:
            kind, seq, payload = decode(raw)
        except (ValueError, IndexError):
            skipped += 1  # frame corrompido não entra numa fixture de contrato
            continue
        clean = sanitize(kind, payload)
        for p in problems(kind, clean, deny):
            print(f"identificador possível: {p}", file=sys.stderr)
            failed += 1
        out.append(f"{direction} {encode(kind, seq, clean).hex()}")
    if failed:
        print("nada foi gravado", file=sys.stderr)
        return 1
    FIXTURES.mkdir(parents=True, exist_ok=True)
    header = [f"# model: {a.model}", f"# firmware: {a.firmware}", f"# source: {a.source}"]
    (FIXTURES / f"{a.name}.capture").write_text("\n".join(header + out) + "\n")
    generate()
    print(f"{a.name}: {len(out)} frames, {skipped} descartados")
    return 0


if __name__ == "__main__":
    sys.exit(main())
