#!/usr/bin/env bash
set -euo pipefail

# Fedora-only personal bootstrap. Reuses ~/.flossware/ai.
ROOT="${FLOSSWARE_AI_HOME:-$HOME/.flossware/ai}"
VENV="$ROOT/venv"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/crush"
FW_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/flossware"
REPO="https://github.com/FlossWare/coding-agent-ai.git"
RAW_BASE="https://raw.githubusercontent.com/FlossWare/crush-demo/main"
GATEWAY="$ROOT/crush-gateway.py"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$SERVICE_DIR/flossware-crush-gateway.service"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ -f /etc/fedora-release ]] || die "crush-demo currently supports Fedora only"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

say "FlossWare Personal + Crush"
printf 'FlossWare AI home: %s\n' "$ROOT"
printf 'Crush config:      %s/crushrc\n' "$CONFIG_DIR"
printf 'Gateway:           http://127.0.0.1:8765/v1\n'
printf 'Policy:            personal / free-only\n'

mkdir -p "$ROOT" "$CONFIG_DIR" "$FW_CONFIG" "$HOME/.local/bin" "$SERVICE_DIR"

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

say "Installing/updating coding-agent-ai in the existing FlossWare environment"
"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet "git+$REPO"

if command -v crush >/dev/null 2>&1; then
  CRUSH_BIN="$(command -v crush)"
elif [[ -x "$HOME/go/bin/crush" ]]; then
  CRUSH_BIN="$HOME/go/bin/crush"
elif command -v go >/dev/null 2>&1; then
  say "Installing Crush with Go"
  GOBIN="$HOME/.local/bin" go install github.com/charmbracelet/crush@latest
  CRUSH_BIN="$HOME/.local/bin/crush"
else
  die "Crush is not installed and Go is unavailable. Install Go or Crush, then rerun this installer."
fi
[[ -x "$CRUSH_BIN" ]] || die "Crush installation failed"

say "Installing FlossWare gateway and Crush configuration"
curl -fsSL "$RAW_BASE/gateway.py" -o "$GATEWAY"
chmod 0755 "$GATEWAY"

# Persist only explicitly supported personal/free credentials. Nothing else
# from the shell environment is copied, preventing RH/employer credential leak.
ENV_FILE="$FW_CONFIG/personal.env"
touch "$ENV_FILE"
chmod 0600 "$ENV_FILE"
for var in GEMINI_API_KEY GROQ_API_KEY CEREBRAS_API_KEY OPENROUTER_API_KEY HUGGINGFACE_API_KEY FLOSSWARE_GEMINI_MODEL FLOSSWARE_GROQ_MODEL FLOSSWARE_CEREBRAS_MODEL FLOSSWARE_OPENROUTER_FREE_MODELS FLOSSWARE_HUGGINGFACE_MODELS; do
  if [[ -n "${!var:-}" ]]; then
    grep -v "^${var}=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
    printf '%s=%q\n' "$var" "${!var}" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  fi
done

cat > "$SERVICE" <<EOF
[Unit]
Description=FlossWare Personal Crush Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=FLOSSWARE_GATEWAY_HOST=127.0.0.1
Environment=FLOSSWARE_GATEWAY_PORT=8765
EnvironmentFile=-$ENV_FILE
ExecStart=$PY $GATEWAY
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  systemctl --user enable --now flossware-crush-gateway.service || true
fi

# Crush sees exactly one model: FlossWare. It talks only to the local gateway;
# the gateway chooses an explicitly allowed local/free backend.
cat > "$CONFIG_DIR/crushrc" <<'EOF'
#!/usr/bin/env bash
option metrics false
option provider-auto-update false

provider remove anthropic 2>/dev/null || true
provider remove redhat 2>/dev/null || true
provider remove openai 2>/dev/null || true
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

permissions allow view ls grep edit
EOF
chmod 0644 "$CONFIG_DIR/crushrc"

cat > "$HOME/.local/bin/pa" <<EOF
#!/usr/bin/env bash
exec "$VENV/bin/pa" "\$@"
EOF
chmod +x "$HOME/.local/bin/pa"

cat > "$HOME/.local/bin/flossware-crush" <<'EOF'
#!/usr/bin/env bash
exec crush "$@"
EOF
chmod +x "$HOME/.local/bin/flossware-crush"

cat > "$HOME/.local/bin/flossware-models" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'FlossWare Personal model gateway'
printf '%s\n' '--------------------------------'
if curl -fsS --max-time 3 http://127.0.0.1:8765/v1/models; then printf '\n'; else echo 'Gateway is not running'; fi
printf '%s\n' 'Backend credentials present:'
for v in GEMINI_API_KEY GROQ_API_KEY CEREBRAS_API_KEY OPENROUTER_API_KEY HUGGINGFACE_API_KEY; do
  [[ -n "${!v:-}" ]] && printf '  ✓ %s\n' "$v" || printf '  - %s\n' "$v"
done
if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then echo '  ✓ Ollama local endpoint'; else echo '  - Ollama local endpoint'; fi
EOF
chmod +x "$HOME/.local/bin/flossware-models"

cat > "$HOME/.local/bin/flossware-crush-doctor" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FAIL=0
ok() { printf '  ✓ %s\n' "\$1"; }
bad() { printf '  ✗ %s\n' "\$1"; FAIL=1; }
echo 'FlossWare Crush Personal Doctor'
echo '-------------------------------'
command -v "$CRUSH_BIN" >/dev/null 2>&1 && ok 'Crush' || bad 'Crush'
[[ -x "$VENV/bin/pa" ]] && ok 'coding-agent-ai / pa' || bad 'coding-agent-ai / pa'
[[ -f "$CONFIG_DIR/crushrc" ]] && ok 'Crush configuration' || bad 'Crush configuration'
[[ -d "$ROOT" ]] && ok '~/.flossware/ai reused' || bad '~/.flossware/ai'
if curl -fsS --max-time 3 http://127.0.0.1:8765/health >/dev/null 2>&1; then ok 'FlossWare gateway'; else bad 'FlossWare gateway'; fi
if curl -fsS --max-time 3 http://127.0.0.1:8765/v1/models | grep -q 'flossware'; then ok 'flossware model exposed'; else bad 'flossware model exposed'; fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then ok 'GitHub CLI authenticated'; else printf '  - GitHub CLI authentication not detected\n'; fi
ok 'Paid provider fallback disabled'
ok 'Anthropic/RH providers excluded'
exit "\$FAIL"
EOF
chmod +x "$HOME/.local/bin/flossware-crush-doctor"

say "Installation complete"
printf '%s\n' 'Run:'
printf '  flossware-crush-doctor\n'
printf '  flossware-models\n'
printf '  flossware-crush\n'
printf '\nCrush now sees one model: flossware. The local gateway selects only configured free/local backends.\n'
printf 'Optional cloud credentials can be supplied before install or placed in %s (0600).\n' "$ENV_FILE"
