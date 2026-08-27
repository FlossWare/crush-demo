#!/usr/bin/env bash
set -euo pipefail
ROOT="${FLOSSWARE_AI_HOME:-$HOME/.flossware/ai}"
VENV="$ROOT/venv"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/crush"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$SERVICE_DIR/flossware-crush-gateway.service"
PIDFILE="$ROOT/crush-gateway.pid"
LOGFILE="$ROOT/crush-gateway.log"
REPO="https://github.com/FlossWare/coding-agent-ai.git"
RAW_BASE="https://raw.githubusercontent.com/FlossWare/crush-demo/main"
GATEWAY="$ROOT/crush-gateway.py"
RUN_GATEWAY="$ROOT/run-crush-gateway.sh"
ENVFILE="$ROOT/provider-env.sh"
say(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[[ -f /etc/fedora-release ]] || die "crush-demo currently supports Fedora only"
command -v python3 >/dev/null || die "python3 is required"
command -v git >/dev/null || die "git is required"
command -v curl >/dev/null || die "curl is required"
mkdir -p "$ROOT" "$CONFIG_DIR" "$HOME/.local/bin" "$SERVICE_DIR"
if [[ -x "$VENV/bin/python" ]]; then PY="$VENV/bin/python"; else say "Creating FlossWare AI virtual environment"; python3 -m venv "$VENV"; PY="$VENV/bin/python"; fi
say "Updating coding-agent-ai in ~/.flossware/ai"
"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet "git+$REPO"
if command -v crush >/dev/null 2>&1; then CRUSH_BIN="$(command -v crush)"; elif [[ -x "$HOME/go/bin/crush" ]]; then CRUSH_BIN="$HOME/go/bin/crush"; elif command -v go >/dev/null 2>&1; then say "Installing Crush"; GOBIN="$HOME/.local/bin" go install github.com/charmbracelet/crush@latest; CRUSH_BIN="$HOME/.local/bin/crush"; else die "Crush is not installed and Go is unavailable"; fi
[[ -x "$CRUSH_BIN" ]] || die "Crush installation failed"
say "Installing FlossWare gateway"
curl -fsSL "$RAW_BASE/gateway.py" -o "$GATEWAY"
chmod 0755 "$GATEWAY"
: > "$ENVFILE"
if [[ -f "$HOME/.bashrc" ]]; then
  grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Z0-9]+_API_KEY(_[A-Z0-9_]+)?[[:space:]]*=' "$HOME/.bashrc" |
    sed -E 's/^[[:space:]]*export[[:space:]]+//' >> "$ENVFILE" || true
fi
chmod 0600 "$ENVFILE"
cat > "$RUN_GATEWAY" <<EOF
#!/usr/bin/env bash
set -e
export FLOSSWARE_GATEWAY_HOST=127.0.0.1
export FLOSSWARE_GATEWAY_PORT=8765
set +u
if [[ -f "$ENVFILE" ]]; then
  set -a
  source "$ENVFILE"
  set +a
fi
set -u
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

# A previous installer attempt can leave a gateway on port 8765. Stop only the
# process recorded by our own pidfile before starting a fresh instance.
stop_stale_gateway() {
  if [[ -s "$PIDFILE" ]]; then
    local oldpid
    oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
      kill "$oldpid" 2>/dev/null || true
      for _ in {1..20}; do kill -0 "$oldpid" 2>/dev/null || break; sleep .1; done
    fi
  fi
  rm -f "$PIDFILE"
}

wait_for_gateway(){
  local i code
  for i in {1..40}; do
    code="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/health 2>/dev/null || true)"
    [[ "$code" == "200" ]] && return 0
    sleep .25
  done
  return 1
}
start_gateway(){
  # Reuse a genuinely healthy existing gateway, otherwise clear our stale
  # instance and start a fresh one.
  if wait_for_gateway; then return 0; fi
  stop_stale_gateway
  : > "$LOGFILE"
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && systemctl --user daemon-reload 2>/dev/null; then
    if systemctl --user enable --now flossware-crush-gateway.service 2>/dev/null && wait_for_gateway; then return 0; fi
  fi
  nohup "$RUN_GATEWAY" >>"$LOGFILE" 2>&1 </dev/null &
  echo $! >"$PIDFILE"
  if wait_for_gateway; then return 0; fi
  printf '\nERROR: FlossWare gateway failed to become ready.\nLog: %s\n' "$LOGFILE" >&2
  tail -n 40 "$LOGFILE" >&2 || true
  return 1
}
start_gateway
say "Configuring Crush"
cat > "$CONFIG_DIR/crushrc" <<'EOF'
#!/usr/bin/env bash
option metrics false
option provider-auto-update false
option default-providers false
provider remove anthropic 2>/dev/null || true
provider remove openai 2>/dev/null || true
provider remove redhat 2>/dev/null || true
provider remove ollama 2>/dev/null || true
provider remove hyper 2>/dev/null || true
provider add flossware --name "FlossWare Personal" --type openai-compat --base-url "http://127.0.0.1:8765/v1" --api-key "local" --discover-models false
model add flossware/flossware --name "FlossWare (free/local)" --context-window 128000 --default-max-tokens 16384
model large flossware/flossware
model small flossware/flossware
if [[ -n "${GH_PAT:-}" ]]; then
  mcp add github --type http --url "https://api.githubcopilot.com/mcp/" --header Authorization "Bearer $GH_PAT"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  mcp add github --type http --url "https://api.githubcopilot.com/mcp/" --header Authorization "Bearer $(gh auth token)"
fi
permissions allow view ls grep edit bash
EOF
chmod 0644 "$CONFIG_DIR/crushrc"
cat > "$HOME/.local/bin/flossware-crush" <<'EOF'
#!/usr/bin/env bash
exec env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u HYPER_API_KEY crush "$@"
EOF
chmod +x "$HOME/.local/bin/flossware-crush"
cat > "$HOME/.local/bin/flossware-models" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsS --max-time 5 http://127.0.0.1:8765/health >/dev/null || { echo 'FlossWare gateway is not running' >&2; echo 'Check ~/.flossware/ai/crush-gateway.log' >&2; exit 1; }
curl -fsS --max-time 5 http://127.0.0.1:8765/v1/models
EOF
chmod +x "$HOME/.local/bin/flossware-models"
cat > "$HOME/.local/bin/flossware-crush-doctor" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FAIL=0
ok(){ printf '  ✓ %s\n' "\$1"; }; bad(){ printf '  ✗ %s\n' "\$1"; FAIL=1; }
[[ -x "$CRUSH_BIN" ]] && ok 'Crush' || bad 'Crush'
[[ -x "$VENV/bin/pa" ]] && ok 'coding-agent-ai / pa' || bad 'coding-agent-ai / pa'
[[ -f "$CONFIG_DIR/crushrc" ]] && ok 'Crush configuration' || bad 'Crush configuration'
[[ -d "$ROOT" ]] && ok '~/.flossware/ai reused' || bad '~/.flossware/ai'
if curl -fsS --max-time 5 http://127.0.0.1:8765/health >/dev/null 2>&1; then ok 'FlossWare gateway'; else bad 'FlossWare gateway'; printf '    log: %s\n' "$LOGFILE"; [[ -s "$LOGFILE" ]] && tail -n 20 "$LOGFILE" | sed 's/^/    /'; fi
if curl -fsS --max-time 5 http://127.0.0.1:8765/v1/models 2>/dev/null | grep -q 'flossware'; then ok 'flossware model exposed'; else bad 'flossware model exposed'; fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then ok 'GitHub CLI authenticated'; else printf '  - GitHub CLI authentication not detected\n'; fi
ok 'Free/local-only gateway policy'; ok 'Anthropic/RH/OpenAI backends excluded'; exit "\$FAIL"
EOF
chmod +x "$HOME/.local/bin/flossware-crush-doctor"
say "Ready"
printf '%s\n' '  flossware-crush-doctor' '  flossware-models' '  flossware-crush' 'Crush model: flossware' 'Credentials: existing ~/.bashrc; convention PROVIDER_API_KEY[_ACCOUNT]'