#!/usr/bin/env bash
# Thin integration installer. Provisioning belongs to agent-setup.
set -euo pipefail

SETUP_INSTALLER="https://raw.githubusercontent.com/FlossWare/agent-setup/main/scripts/install.sh"

say(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "Installing/updating agent-setup"
tmp_installer="$(mktemp)"
trap 'rm -f "$tmp_installer"' EXIT
curl -fsSL --retry 3 "$SETUP_INSTALLER" -o "$tmp_installer"
[[ -s "$tmp_installer" ]] || die "agent-setup installer download was empty"
chmod 0700 "$tmp_installer"
bash "$tmp_installer" --agent crush

FLOSSWARE_AI="${FLOSSWARE_AI_BIN:-$HOME/.local/bin/flossware-ai}"
[[ -x "$FLOSSWARE_AI" ]] || die "flossware-ai was not installed at $FLOSSWARE_AI"

say "Configuring Crush through agent-setup"
"$FLOSSWARE_AI" setup crush --free-only

say "Ready"
printf '%s\n' \
  '  flossware-ai doctor' \
  '  flossware-ai dogfood --strict' \
  '  flossware-models' \
  '  flossware-crush'
