#!/bin/sh
# Gera uma fixture sem identificadores a partir de uma captura em captures/.
#   scripts/sanitize-capture.sh <captura> <nome> --model <modelo> --firmware <versão> --source "<origem>"
#   scripts/sanitize-capture.sh --check     confere todas as fixtures e regenera o código do simulador
# <captura>: pasta de .bin da libmdr ou arquivo de texto com "rx <hex>" / "tx <hex>" por linha.
# --deny <arquivo>: textos reais (um por linha, fora do git) que não podem restar na fixture.
# Falha se sobrar algo que pareça identificador real. Veja docs/SIMULATOR.md.
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/sanitize_capture.py "$@"
