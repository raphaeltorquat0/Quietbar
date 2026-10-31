#!/bin/bash
# E5b: mudança fora do motor com o canal solto, seguida de troca de app. Uso: e5b.sh <sim|real> [novo|antigo] [ciclos].
# "antigo" usa o binário de $APP_OVERRIDE e só mede o que ele tem: override e latência.
. "$(dirname "$0")/lib.sh"
MODE="${1:-sim}"; VARIANT="${2:-novo}"; N="${3:-10}"
NAME="e5b-$MODE-$VARIANT"
T="$OUT/$NAME.jsonl"; S="$OUT/$NAME.steps"
LOG="$HOME/Library/Logs/Quietbar/traffic.log"
CLI="$ROOT/.build/debug/mdr-cli"
PROFILES=$(python3 - <<'PY'
import json
def p(i, name, bundle, mode):
    return {"id": f"00000000-0000-0000-0000-00000000000{i}", "name": name, "enabled": True, "trigger": {"app": {"bundleID": bundle, "name": name}}, "soundMode": mode}
print("<" + json.dumps([p(1, "Calc", "com.apple.calculator", "noiseCanceling"), p(2, "Dict", "com.apple.Dictionary", "ambient")]).encode().hex() + ">")
PY
)
# No simulador o canal solta em 3 s: o que importa é estar solto, e são 10 ciclos.
if [ "$MODE" = sim ]; then IDLE=3; LOOSE=6; ARGS=(--simulate wh1000xm5); else IDLE=15; LOOSE=18; ARGS=(); fi
mono() { python3 -c 'import time;print(time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)//1000000)'; }
step() { echo "$(mono) $*" >> "$S"; }
outside() { if [ "$MODE" = sim ]; then ctl button "$1"; else "$CLI" set mode "$1" > /dev/null 2>&1 || echo "falha no mdr-cli" >&2; fi; sleep 2; }
# Primeiro plano injetado (--fake-front): o Mac pode seguir em uso. O caminho com `open -a` fica no E4.
front() { case "$1" in Calculator) ctl front com.apple.calculator;; Dictionary) ctl front com.apple.Dictionary;; *) ctl front com.apple.Stickies;; esac; }
boot() { start_app "$T" --fake-front "${ARGS[@]}" -logTraffic YES -idleReleaseSeconds "$IDLE" -profiles "$PROFILES" "$@"; }
# O trace é reaberto a cada início: guarda o que já foi gravado.
keep() { cat "$T" >> "$T.all" 2>/dev/null; }
fin() { sleep 1; ctl state; sleep 0.5; ctl mark "fim $1"; step fim "$1"; }

# cycle <cenário> <i> <mudar fora?> <app da troca> <espera>
cycle() {
    front Calculator; sleep 3
    ctl mark "aplicado $1 $2"; ctl state; sleep "$LOOSE"; ctl state; sleep 0.5
    [ "$3" = sim ] && outside "$FORA"
    ctl mark "troca $1 $2"; step troca "$1 $2"; front "$4"; sleep "$5"
    fin "$1 $2"
    front Stickies; sleep 8
}

take_over; forget_held
rm -f "$LOG" "$S" "$T" "$T.all"
[ "$MODE" = real ] && { "$CLI" set mode ambient > /dev/null 2>&1 || { echo "falha ao preparar o fone"; exit 1; }; sleep 1; }
boot
front Stickies; sleep 1
FORA=off
ctl mark inicio
for i in $(seq 1 "$N"); do cycle perfil "$i" sim Dictionary 4; done
for i in $(seq 1 "$N"); do cycle semperfil "$i" sim Stickies 10; done
for i in $(seq 1 "$N"); do cycle controle "$i" nao Dictionary 4; done
if [ "$VARIANT" = novo ]; then
    # GET sem resposta: a regra é aplicada mesmo com o modo mudado, e o log diz que não deu para verificar.
    ctl no_mode_reply on
    for i in 1 2 3; do cycle falha "$i" sim Dictionary 4; done
    ctl no_mode_reply off
    # Deduplicação: cada caminho pede o modo atual, com o canal aberto e com ele solto.
    ctl mode ambient; sleep 2 # sem regra: este SET prepara o estado e fica fora da contagem
    step dedup inicio aberto
    ctl shortcut ambient; sleep 1; ctl intent ambient; sleep 1; ctl mode ambient; sleep 1
    step dedup fim aberto
    sleep "$LOOSE"; ctl state; sleep 0.5
    step dedup inicio solto
    ctl shortcut ambient; sleep 3; ctl state; sleep "$LOOSE"
    ctl intent ambient; sleep 3; sleep "$LOOSE"
    ctl mode ambient; sleep 3
    step dedup fim solto
    # A Central de Controle só alterna, e posta uma notificação Darwin: um SET por toque.
    step cc inicio x
    notifyutil -p io.github.raphaeltorquat0.quietbar.toggleSoundMode; sleep 2
    step cc fim x
fi
ctl state; sleep 1
stop_app; keep
if [ "$MODE" = real ] && [ "$VARIANT" = novo ]; then
    # Reinício: a regra deixa o modo, o app sai, o modo muda, o app volta com o perfil em primeiro plano.
    for i in 1 2 3; do
        boot; ctl mark "reinicio $i"
        front Stickies; sleep 1; front Calculator; sleep 3; ctl state; sleep 1
        stop_app; keep
        outside off
        step troca "reinicio $i"
        boot; front Dictionary; sleep 4
        fin "reinicio $i"
        sleep 1; stop_app; keep
        "$CLI" set mode ambient > /dev/null 2>&1; sleep 1
    done
fi
cp "$LOG" "$OUT/$NAME.traffic"
rm -f "$LOG"; rmdir "$HOME/Library/Logs/Quietbar" 2>/dev/null
forget_held
python3 "$ROOT/scripts/validation/e5b_analyze.py" "$OUT" "$NAME"
