#!/bin/sh
# `make release`: build Release universal, assinatura e .dmg em dist/.
#   QUIETBAR_SIGN_IDENTITY  identidade Developer ID; sem ela, o build sai ad-hoc
set -eu
cd "$(dirname "$0")/.."
if [ -z "${QUIETBAR_SIGN_IDENTITY:-}" ]; then
  echo "QUIETBAR_SIGN_IDENTITY não definida: assinatura de Developer ID pulada, build ad-hoc."
fi
scripts/build-app.sh
scripts/make-dmg.sh
