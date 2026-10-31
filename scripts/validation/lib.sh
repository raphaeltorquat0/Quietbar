# Comum aos experimentos. Sem cliques, sem diálogos: o app Debug roda do shell e herda as permissões dele.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/.build/validation"
APP="$ROOT/.build/xcode-debug/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar"
MIC="$OUT/mic"
CTL="$OUT/ctl"
mkdir -p "$OUT"

# O preflight só consulta. Abrir uma entrada sem autorização abriria o diálogo: sem o 0, nada abre.
preflight_mic() {
    [ -x "$OUT/tcc" ] || swiftc -o "$OUT/tcc" "$ROOT/scripts/validation/tcc.swift"
    "$OUT/tcc" | grep -q '^0$' || { echo "microfone sem autorização neste shell: experimento não roda" >&2; exit 3; }
}

build_tools() {
    [ "$OUT/mic" -nt "$ROOT/scripts/validation/mic.swift" ] || swiftc -O -o "$OUT/mic" "$ROOT/scripts/validation/mic.swift"
}

# O app instalado disputa o RFCOMM. Fica fechado até scripts/validation/restore.sh.
take_over() { pkill -x Quietbar 2>/dev/null; sleep 1; }

# start_app <trace> [argumentos]. Sem Som no Mac: nenhum experimento monta tap.
start_app() {
    trace="$1"; shift
    rm -f "$CTL"; mkfifo "$CTL"
    "$APP" --hw-test --headless --automation-trace "$trace" --control "$CTL" -macSoundEnabled NO "$@" > "$OUT/app.out" 2>&1 &
    APP_PID=$!
    sleep 4
}

ctl() { echo "$*" > "$CTL"; }
stop_app() { kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; rm -f "$CTL"; }
