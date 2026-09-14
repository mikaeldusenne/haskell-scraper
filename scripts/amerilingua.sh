#!/usr/bin/env bash
# Reuse exported credentials; prompt locally only for missing values.
set -euo pipefail
AMERILINGUA_LOGIN="${AMERILINGUA_LOGIN:-${AMERILINGUA_EMAIL:-}}"
AMERILINGUA_PASS="${AMERILINGUA_PASS:-${AMERILINGUA_PWD:-}}"
[[ -n "$AMERILINGUA_LOGIN" ]] || IFS= read -r -p 'AmeriLingua email: ' AMERILINGUA_LOGIN
if [[ -z "$AMERILINGUA_PASS" ]]; then
  IFS= read -r -s -p 'AmeriLingua password: ' AMERILINGUA_PASS
  printf '\n'
fi
export AMERILINGUA_LOGIN AMERILINGUA_PASS
exec stack run -- amerilingua "$@"
