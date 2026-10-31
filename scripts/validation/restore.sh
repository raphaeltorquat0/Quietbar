#!/bin/sh
# Devolve o Mac ao estado de antes: reabre o app instalado, que já tem as permissões.
pgrep -x Quietbar >/dev/null || open /Applications/Quietbar.app
