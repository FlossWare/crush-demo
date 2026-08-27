# FlossWare Crush Demo

A thin integration layer that turns the existing FlossWare stack into a usable **Fedora coding agent now**.

Crush sees exactly one model:

```text
Crush
  -> flossware (localhost OpenAI-compatible gateway)
  -> free/local backend
  -> coding-agent-ai + existing FlossWare components
```

The installer reuses `~/.flossware/ai`. It does not install or import Red Hat configuration, and the personal gateway does not read Anthropic/OpenAI/RH credentials.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/FlossWare/crush-demo/main/install.sh | bash
```

The Fedora-only installer:

- reuses `~/.flossware/ai` and its existing virtual environment when possible
- installs/updates `coding-agent-ai`
- installs Crush if missing and Go is available
- installs a local FlossWare OpenAI-compatible gateway
- creates a systemd **user** service so the gateway starts automatically
- creates `~/.config/crush/crushrc` with one model: `flossware`
- persists only explicitly named personal/free provider credentials in a `0600` file
- supports Ollama automatically when it is running
- supports explicitly named free-tier models from Gemini, Groq, Cerebras, Hugging Face, and OpenRouter
- for OpenRouter, automatically accepts only catalog entries whose prompt and completion prices are exactly zero when no explicit model list is supplied
- configures GitHub MCP from `GH_PAT` or an existing `gh auth` login
- never configures Anthropic, OpenAI, or Red Hat as backends

## Start

```bash
flossware-crush-doctor
flossware-models
crush
```

Inside Crush, select/use **FlossWare (free/local)**. You do not need to choose the underlying provider for every task.

The gateway is local-only:

```text
http://127.0.0.1:8765/v1
```

Health:

```bash
curl http://127.0.0.1:8765/health
```

Models:

```bash
curl http://127.0.0.1:8765/v1/models
```

## Free accounts

If the provider credentials already exist in the shell when you install, the installer copies only these allow-listed variables to `~/.config/flossware/personal.env` with mode `0600`:

```text
GEMINI_API_KEY
GROQ_API_KEY
CEREBRAS_API_KEY
OPENROUTER_API_KEY
HUGGINGFACE_API_KEY
```

For cloud providers that need an explicit model, also set the corresponding model variable before installation, for example:

```bash
export FLOSSWARE_GROQ_MODEL='your-known-free-tier-model'
export FLOSSWARE_CEREBRAS_MODEL='your-known-free-tier-model'
export FLOSSWARE_GEMINI_MODEL='your-known-free-tier-model'
```

OpenRouter can use `FLOSSWARE_OPENROUTER_FREE_MODELS`, a comma-separated allow-list. If it is omitted, the gateway queries the OpenRouter catalog and admits only models with exactly-zero prompt and completion pricing.

A free-tier account is still subject to that provider's quota. The gateway prevents selection of models that are not explicitly free; it cannot manufacture unlimited provider quota out of optimism.

## Existing worker/arbiter

The existing local worker/arbiter CLI remains available:

```bash
pa "Review this repository for correctness" --repo . --max-iter 3
```

Crush is the interactive coding-agent front end. `coding-agent-ai` remains the reusable worker/arbiter intelligence layer.

## GitHub

Authenticate once with GitHub CLI if needed:

```bash
gh auth login
gh auth status
```

The installer uses that authentication for the Crush GitHub MCP configuration when available. A `GH_PAT` can be used instead.

## Scope

The first useful milestone is intentionally small:

**free/local models + FlossWare-as-a-model + local workers/arbiter + GitHub + Crush.**

Remote workers, Thompson Sampling, genetic algorithms, and the larger optimization/knowledge stack can be added later and then folded into this same development environment.

The point of this repository is to use FlossWare to build FlossWare. `coding-agent-setup` can eventually package the proven environment, rather than being a prerequisite for developing it.
