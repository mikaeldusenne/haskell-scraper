#!/usr/bin/env bash
# Prompt locally; credentials exist only in this process and its children.
set -euo pipefail
IFS= read -r -p 'AmeriLingua email: ' AMERILINGUA_LOGIN
IFS= read -r -s -p 'AmeriLingua password: ' AMERILINGUA_PASS
printf '\n'
export AMERILINGUA_LOGIN AMERILINGUA_PASS
exec stack run -- amerilingua "$@"
