#!/bin/bash
# E5: o estado do fone muda fora do motor. Canal aberto: comando direto à sessão, dentro do app.
# Canal solto: o mdr-cli, em outro processo, faz o papel do botão físico. App e CLI não dividem o RFCOMM.
. "$(dirname "$0")/lib.sh"
CLI="$ROOT/.build/debug/mdr-cli"
T="$OUT/e5.jsonl"
take_over
start_app "$T" -idleReleaseSeconds 15
ctl mark "A canal aberto"; ctl rule focus noiseCanceling; sleep 4; ctl state; sleep 1
ctl mark "A fora do motor: ambient"; ctl mode ambient; sleep 3; ctl state; sleep 1
ctl mark "A contexto muda"; ctl rule focus none; sleep 3; ctl state; sleep 1
ctl mark "B regra ativa, canal abre"; ctl rule focus noiseCanceling; sleep 4; ctl state; sleep 1
ctl mark "B espera soltar o canal"; sleep 20; ctl state; sleep 1
ctl mark "B botão físico simulado, fora do app"
"$CLI" set mode ambient > "$OUT/e5-cli.txt" 2>&1; echo "cli saiu com $?" >> "$OUT/e5-cli.txt"
sleep 2; ctl state; sleep 1
ctl mark "B canal abre por outro motivo"; ctl mode_read; sleep 3; ctl state; sleep 1
ctl mark "B espera soltar de novo"; sleep 20; ctl state; sleep 1
ctl mark "B contexto muda com o canal solto"; ctl rule focus none; sleep 4; ctl state; sleep 1
stop_app
cat "$OUT/e5-cli.txt"
python3 "$ROOT/scripts/validation/show.py" "$T" | grep -vE ' decision '
