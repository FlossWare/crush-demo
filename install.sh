#!/usr/bin/env bash
# Thin integration installer. Provisioning belongs to coding-agent-setup.
set -euo pipefail

SETUP_INSTALLER="https://raw.githubusercontent.com/FlossWare/coding-agent-setup/main/scripts/install.sh"

say(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "Installing/updating coding-agent-setup"
curl -fsSL --retry 3 "$SETUP_INSTALLER" | bash -s -- --agent crush

FLOSSWARE_AI="${FLOSSWARE_AI_BIN:-$HOME/.local/bin/flossware-ai}"
[[ -x "$FLOSSWARE_AI" ]] || die "flossware-ai was not installed at $FLOSSWARE_AI"

say "Configuring Crush through coding-agent-setup"
"$FLOSSWARE_AI" setup crush --free-only

say "Ready"
printf '%s\n' \
  '  flossware-ai doctor' \
  '  flossware-ai dogfood --strict' \
  '  flossware-models' \
  '  flossware-crush'
