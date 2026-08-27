# FlossWare Crush Demo

A thin Fedora integration layer that turns the existing FlossWare stack into a usable coding agent.

```text
Crush
  -> model: flossware
  -> localhost:8765/v1
  -> FlossWare gateway
  -> free/local provider account
  -> coding-agent-ai + workers/arbiter
  -> GitHub/files/tests
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/FlossWare/crush-demo/main/install.sh | bash
```

The Fedora-only installer reuses `~/.flossware/ai`, updates `coding-agent-ai`, installs Crush if needed, installs the local gateway, creates the systemd user service, and writes the global Crush `crushrc`.

After installation:

```bash
flossware-crush-doctor
flossware-models
flossware-crush
```

Crush sees one model: **FlossWare (free/local)**. Crush's normal coding tools remain available, including file inspection/editing and `bash` for builds/tests. GitHub is exposed through MCP when `GH_PAT` or an existing `gh auth` login is available.

## Existing account environment

The credential source of truth is the user's existing `~/.bashrc`. The gateway does not require another credential database and does not copy the keys into a second file.

The standard FlossWare convention is:

```text
PROVIDER_API_KEY
PROVIDER_API_KEY_ACCOUNT
```

The account suffix is optional. For example:

```text
DEEPINFRA_API_KEY
DEEPINFRA_API_KEY_HOTMAIL
DEEPINFRA_API_KEY_NCRR
DEEPINFRA_API_KEY_FLOSSWARE
```

These are interpreted as:

```text
DeepInfra / default
DeepInfra / HOTMAIL
DeepInfra / NCRR
DeepInfra / FLOSSWARE
```

The same convention works for every provider known to the gateway. The gateway allow-lists supported providers and never consumes Anthropic, OpenAI, Red Hat, or arbitrary unrelated secrets.

Optional model hints may use the same account suffix, for example:

```text
GROQ_MODEL
GROQ_MODEL_FLOSSWARE
FLOSSWARE_GROQ_MODEL
FLOSSWARE_GROQ_MODEL_FLOSSWARE
```

OpenRouter can discover models and admits only models whose catalog prompt and completion prices are exactly zero unless an explicit free-model allow-list is supplied.

A free API account still has provider quotas. The gateway enforces model eligibility; it cannot create infinite quota, because apparently physics remains annoyingly relevant.

## Gateway

The gateway is local-only:

```text
http://127.0.0.1:8765/v1
```

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/v1/models
```

It exposes exactly one model:

```text
flossware
```

The backend can be Ollama or an eligible configured provider/account. Provider/account metadata is visible in health output, never secret values.

## Worker / arbiter

The existing local worker/arbiter implementation remains the reusable intelligence layer:

```bash
pa "Review this repository for correctness" --repo . --max-iter 3
```

The intended development loop is:

```text
Crush
  -> FlossWare
  -> worker(s)
  -> implementation/tests
  -> arbiter
  -> accepted result
  -> GitHub
```

Remote workers are intentionally deferred. Thompson Sampling, genetic algorithms, and larger optimization/knowledge components can be added later and dogfooded through this same environment.

## Personal-only boundary

This repository is deliberately a personal Fedora development environment:

- no Red Hat configuration
- no Red Hat credentials
- no Anthropic backend
- no OpenAI backend
- free/local model policy
- existing personal environment variables reused
- `~/.flossware/ai` remains the main FlossWare runtime

The goal is to **use FlossWare to build FlossWare**. Once this environment is proven, `coding-agent-setup` can package it rather than being required to develop it.
