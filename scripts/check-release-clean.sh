#!/bin/sh
# Falha se o simulador entrou no executável. O build de release chama este script.
set -eu
BIN="${1:-dist/Quietbar.app/Contents/MacOS/Quietbar}"
PATTERN='MDRSimulator|VirtualDevice|VirtualTransport|DeviceProfile|--simulate'
FOUND=$( { nm -a "$BIN" 2>/dev/null || true; strings -a "$BIN"; } | grep -cE "$PATTERN" || true)
if [ "$FOUND" -ne 0 ]; then
  echo "o simulador entrou no binário de release ($FOUND ocorrências)" >&2
  exit 1
fi
echo "binário de release sem o simulador"
