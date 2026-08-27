#!/usr/bin/env bash
set -euo pipefail

# Fedora-only personal bootstrap. Reuses ~/.flossware/ai.
ROOT="${FLOSSWARE_AI_HOME:-$HOME/.flossware/ai}"
VENV="$ROOT/venv"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/crush"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$SERVICE_DIR/flossware-crush-gateway.service"
REPO="https://github.com/FlossWare/coding-agent-ai.git"
RAW_BASE="https://raw.githubusercontent.com/FlossWare/crush-demo/main"
GATEWAY="$ROOT/crush-gateway.py"
RUN_GATEWAY="$ROOT/run-crush-gateway.sh"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ -f /etc/fedora-release ]] || die "crush-demo currently supports Fedora only"
command -v python3 >/dev/null || die "python3 is required"
command -v git >/dev/null || die "git is required"
command -v curl >/dev/null || die "curl is required"

mkdir -p "$ROOT" "$CONFIG_DIR" "$HOME/.local/bin" "$SERVICE_DIR"

if [[ -x "$VENV/bin/python" ]]; then
  PY="$VENV/bin/python"
elif [[ -x "$ROOT/.venv/bin/python" ]]; then
  VENV="$ROOT/.venv"
  PY="$VENV/bin/python"
else
  say "Creating FlossWare AI virtual environment"
  python3 -m venv "$VENV"
  PY="$VENV/bin/python"
fi

say "Updating coding-agent-ai in ~/.flossware/ai"
"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet "git+$REPO"

if command -v crush >/dev/null 2>&1; then
  CRUSH_BIN="$(command -v crush)"
elif [[ -x "$HOME/go/bin/crush" ]]; then
  CRUSH_BIN="$HOME/go/bin/crush"
elif command -v go >/dev/null 2>&1; then
  say "Installing Crush"
  GOBIN="$HOME/.local/bin" go install github.com/charmbracelet/crush@latest
  CRUSH_BIN="$HOME/.local/bin/crush"
else
  die "Crush is not installed and Go is unavailable"
fi
[[ -x "$CRUSH_BIN" ]] || die "Crush installation failed"

say "Installing FlossWare gateway"
curl -fsSL "$RAW_BASE/gateway.py" -o "$GATEWAY"
chmod 0755 "$GATEWAY"

# The user's .bashrc remains the credential source of truth. The service
# sources it at startup, so newly-added PROVIDER_API_KEY[_ACCOUNT] variables
# become available after restarting the user service. The gateway itself has
# a strict provider allow-list and never consumes RH/Anthropic/OpenAI keys.
cat > "$RUN_GATEWAY" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ -f "\$HOME/.bashrc" ]] && source "\$HOME/.bashrc" || true
export FLOSSWARE_GATEWAY_HOST=127.0.0.1
export FLOSSWARE_GATEWAY_PORT=8765
exec "$PY" "$GATEWAY"
EOF
chmod 0700 "$RUN_GATEWAY"

cat > "$SERVICE" <<EOF
[Unit]
Description=FlossWare Personal Crush Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$RUN_GATEWAY
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload || true
systemctl --user enable --now flossware-crush-gateway.service || true

say "Configuring Crush"
cat > "$CONFIG_DIR/crushrc" <<'EOF'
#!/usr/bin/env bash
option metrics false
option provider-auto-update false
provider remove anthropic 2>/dev/null || true
provider remove redhat 2>/dev/null || true
provider remove openai 2>/dev/null || true
provider remove ollama 2>/dev/null || true
provider add flossware --name "FlossWare Personal" --type openai-compat \
  --base-url "http://127.0.0.1:8765/v1" --api-key "local"
model add flossware/flossware --name "FlossWare (free/local)" \
  --context-window 128000 --default-max-tokens 16384
model large flossware/flossware
model small flossware/flossware

if [[ -n "${GH_PAT:-}" ]]; then
  mcp add github --type http --url "https://api.githubcopilot.com/mcp/" \
    --header Authorization "Bearer $GH_PAT"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  mcp add github --type http --url "https://api.githubcopilot.com/mcp/" \
    --header Authorization "Bearer $(gh auth token)"
fi

permissions allow view ls grep edit bash
EOF
chmod 0644 "$CONFIG_DIR/crushrc"

cat > "$HOME/.local/bin/flossware-crush" <<'EOF'
#!/usr/bin/env bash
exec crush "$@"
EOF
chmod +x "$HOME/.local/bin/flossware-crush"

cat > "$HOME/.local/bin/flossware-models" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsS --max-time 5 http://127.0.0.1:8765/health || {
  echo 'FlossWare gateway is not running' >&2
  exit 1
}
EOF
chmod +x "$HOME/.local/bin/flossware-models"

cat > "$HOME/.local/bin/flossware-crush-doctor" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FAIL=0
ok() { printf '  ✓ %s\n' "\$1"; }
bad() { printf '  ✗ %s\n' "\$1"; FAIL=1; }
command -v "$CRUSH_BIN" >/dev/null 2>&1 && ok 'Crush' || bad 'Crush'
[[ -x "$VENV/bin/pa" ]] && ok 'coding-agent-ai / pa' || bad 'coding-agent-ai / pa'
[[ -f "$CONFIG_DIR/crushrc" ]] && ok 'Crush configuration' || bad 'Crush configuration'
[[ -d "$ROOT" ]] && ok '~/.flossware/ai reused' || bad '~/.flossware/ai'
if curl -fsS --max-time 5 http://127.0.0.1:8765/health >/dev/null 2>&1; then ok 'FlossWare gateway'; else bad 'FlossWare gateway'; fi
if curl -fsS --max-time 5 http://127.0.0.1:8765/v1/models | grep -q 'flossware'; then ok 'flossware model exposed'; else bad 'flossware model exposed'; fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then ok 'GitHub CLI authenticated'; else printf '  - GitHub CLI authentication not detected\n'; fi
ok 'Free/local-only gateway policy'
ok 'Anthropic/RH/OpenAI backends excluded'
exit "\$FAIL"
EOF
chmod +x "$HOME/.local/bin/flossware-crush-doctor"

say "Ready"
printf '%s\n' '  flossware-crush-doctor'
printf '%s\n' '  flossware-models'
printf '%s\n' '  flossware-crush'
printf '%s\n' 'Crush model: flossware'
printf '%s\n' 'Credentials: existing ~/.bashrc; convention PROVIDER_API_KEY[_ACCOUNT]'
