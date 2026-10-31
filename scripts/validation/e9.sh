#!/bin/bash
# E9: sleep e wake com regras ativas. Uso: e9.sh [sim|real]. As notificações são postadas no centro que o sistema usa.
. "$(dirname "$0")/lib.sh"
MODE="${1:-sim}"
T="$OUT/e9-$MODE.jsonl"
take_over
if [ "$MODE" = sim ]; then start_app "$T" --simulate wh1000xm5; else start_app "$T"; fi
ctl mark inicio; ctl state; sleep 1
ctl rule focus ambient; sleep 3
ctl rule call noiseCanceling; sleep 3; ctl state; sleep 1
for i in 1 2 3 4 5; do
    ctl mark "ciclo $i sleep"; ctl sleep; sleep 2; ctl state; sleep 1
    ctl mark "ciclo $i wake";  ctl wake;  sleep 5; ctl state; sleep 1
done
ctl mark "pendente: fone some, regra acaba, acorda"; ctl unavailable on; ctl sleep; sleep 1; ctl rule call none; sleep 2; ctl state; sleep 1
ctl unavailable off; ctl wake; sleep 6; ctl state; sleep 1
ctl mark "ocioso 20 s: procura laco"; sleep 20; ctl state; sleep 1
ctl rule focus none; sleep 3; ctl state; sleep 1
stop_app
python3 "$ROOT/scripts/validation/show.py" "$T"
