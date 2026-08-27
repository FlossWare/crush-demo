#!/usr/bin/env bash
set -euo pipefail

ROOT="${FLOSSWARE_AI_HOME:-$HOME/.flossware/ai}"
VENV="$ROOT/venv"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/crush"
REPO="https://github.com/FlossWare/coding-agent-ai.git"
RAW_BASE="https://raw.githubusercontent.com/FlossWare/crush-demo/main"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

say "FlossWare Personal + Crush"
printf 'FlossWare AI home: %s\n' "$ROOT"
printf 'Crush config:      %s/crushrc\n' "$CONFIG_DIR"
printf 'Policy:            personal / $0 only\n'

mkdir -p "$ROOT" "$CONFIG_DIR" "$HOME/.local/bin"

# Reuse an existing FlossWare venv when available. Otherwise create one inside
# ~/.flossware/ai. We deliberately do not touch a system Python installation.
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

cat > "$HOME/.local/bin/pa" <<EOF
#!/usr/bin/env bash
exec "$VENV/bin/pa" "\$@"
EOF
chmod +x "$HOME/.local/bin/pa"

# Install Crush without requiring root. Prefer an existing binary, then Go.
if command -v crush >/dev/null 2>&1; then
  CRUSH_BIN="$(command -v crush)"
elif [[ -x "$HOME/go/bin/crush" ]]; then
  CRUSH_BIN="$HOME/go/bin/crush"
elif command -v go >/dev/null 2>&1; then
  say "Installing Crush with Go"
  GOBIN="$HOME/.local/bin" go install github.com/charmbracelet/crush@latest
  CRUSH_BIN="$HOME/.local/bin/crush"
else
  die "Crush is not installed and Go is unavailable. Install Crush with your package manager, then rerun this installer."
fi

[[ -x "$CRUSH_BIN" ]] || die "Crush installation failed"

# curl|bash has no repository working tree, so fetch the config explicitly.
TMP_CONFIG="$(mktemp)"
trap 'rm -f "$TMP_CONFIG"' EXIT
curl -fsSL "$RAW_BASE/crushrc" -o "$TMP_CONFIG"
install -m 0644 "$TMP_CONFIG" "$CONFIG_DIR/crushrc"

cat > "$HOME/.local/bin/flossware-crush" <<'EOF'
#!/usr/bin/env bash
exec crush "$@"
EOF
chmod +x "$HOME/.local/bin/flossware-crush"

cat > "$HOME/.local/bin/flossware-models" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'FlossWare Personal model sources'
printf '%s\n' '--------------------------------'
if command -v crush >/dev/null 2>&1; then
  crush models || true
else
  echo 'Crush not found'
fi
printf '\nConfigured free-account variables:\n'
for v in GEMINI_API_KEY GROQ_API_KEY CEREBRAS_API_KEY OPENROUTER_API_KEY; do
  if [[ -n "${!v:-}" ]]; then printf '  ✓ %s\n' "$v"; else printf '  - %s\n' "$v"; fi
done
if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo '  ✓ Ollama local endpoint'
else
  echo '  - Ollama local endpoint'
fi
EOF
chmod +x "$HOME/.local/bin/flossware-models"

cat > "$HOME/.local/bin/flossware-crush-doctor" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FAIL=0
check() { if "\$@" >/dev/null 2>&1; then printf '  ✓ %s\\n' "\$1"; else printf '  ✗ %s\\n' "\$1"; FAIL=1; fi; }
echo 'FlossWare Crush Personal Doctor'
echo '-------------------------------'
check "$CRUSH_BIN" --version
check "$VENV/bin/pa" --help
[[ -f "$CONFIG_DIR/crushrc" ]] && echo '  ✓ personal Crush configuration' || { echo '  ✗ personal Crush configuration'; FAIL=1; }
[[ -d "$ROOT" ]] && echo '  ✓ ~/.flossware/ai reused' || { echo '  ✗ ~/.flossware/ai'; FAIL=1; }
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then echo '  ✓ GitHub CLI authenticated'; else echo '  - GitHub CLI authentication not detected'; fi
echo '  ✓ Red Hat provider is not configured by this demo'
echo '  ✓ Anthropic provider is not configured by this demo'
exit "$FAIL"
EOF
chmod +x "$HOME/.local/bin/flossware-crush-doctor"

say "Installation complete"
printf '%s\n' 'Make sure ~/.local/bin is on PATH, then run:'
printf '  flossware-crush-doctor\n'
printf '  flossware-models\n'
printf '  flossware-crush\n'
printf '\nExisting worker/arbiter CLI:\n'
printf '  pa "Review this repository" --repo . --max-iter 3\n'
printf '\nFree providers are opt-in through their environment variables. No paid or Red Hat provider is configured.\n'
