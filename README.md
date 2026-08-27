# FlossWare Crush Demo

A deliberately thin integration demo for **Crush + coding-agent-ai**.

It reuses the existing FlossWare AI environment at `~/.flossware/ai` and configures a **personal, $0-only** coding environment. No Red Hat configuration is installed or imported.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/FlossWare/crush-demo/main/install.sh | bash
```

The installer:

- reuses `~/.flossware/ai` when present
- installs `coding-agent-ai` into that environment when needed
- installs Crush if it is missing
- creates a personal Crush configuration
- enables local Ollama discovery
- enables only explicitly configured free-provider credentials
- disables Anthropic/paid providers for this profile
- configures the FlossWare worker/arbiter CLI
- detects GitHub CLI authentication
- runs a basic doctor check

## Quick start

```bash
flossware-crush-doctor
flossware-models
crush
```

For the existing FlossWare worker/arbiter loop:

```bash
pa "Review this repository for correctness" --repo . --max-iter 3
```

## Free-provider policy

The demo does not assume that an API provider is free merely because it has a free tier. Providers are enabled only when a personal credential is present and the FlossWare profile permits it. Anthropic and Red Hat configuration are intentionally excluded.

Local Ollama models are supported with no API cost.

## GitHub

If `gh auth status` succeeds, the demo records GitHub as available. The Crush MCP configuration is generated only when a `GH_PAT` is explicitly supplied, so credentials are never committed to this repository.

## Scope

This demo intentionally defers Thompson Sampling, genetic algorithms, and the larger knowledge/optimization stack. The useful first milestone is:

**free/local models + workers/arbiter + GitHub + Crush.**

## Existing FlossWare component

`coding-agent-ai` already provides the provider-neutral worker/arbiter coding-agent loop. This repository is an integration layer, not a replacement for it.
