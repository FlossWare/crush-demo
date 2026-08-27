#!/usr/bin/env python3
"""Tiny OpenAI-compatible FlossWare gateway.

Crush sees one model: ``flossware``. This process chooses only an explicitly
allowed local/free backend. It deliberately does not read Anthropic, OpenAI,
Red Hat, or arbitrary provider credentials.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = os.getenv("FLOSSWARE_GATEWAY_HOST", "127.0.0.1")
PORT = int(os.getenv("FLOSSWARE_GATEWAY_PORT", "8765"))
MODEL = "flossware"
TIMEOUT = 180


def _request(method: str, url: str, body: dict | None = None, api_key: str = "") -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read())


def _ollama_models() -> list[str]:
    try:
        data = _request("GET", "http://127.0.0.1:11434/api/tags")
        return [m.get("name", "") for m in data.get("models", []) if m.get("name")]
    except Exception:
        return []


def _backends() -> list[tuple[str, str, str, str]]:
    """Return (name, base_url, model, key) in safe preference order."""
    result: list[tuple[str, str, str, str]] = []
    local = _ollama_models()
    if local:
        result.append(("ollama", "http://127.0.0.1:11434/v1", local[0], ""))

    explicit = (
        ("gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY", "FLOSSWARE_GEMINI_MODEL"),
        ("groq", "https://api.groq.com/openai/v1", "GROQ_API_KEY", "FLOSSWARE_GROQ_MODEL"),
        ("cerebras", "https://api.cerebras.ai/v1", "CEREBRAS_API_KEY", "FLOSSWARE_CEREBRAS_MODEL"),
        ("huggingface", "https://router.huggingface.co/v1", "HUGGINGFACE_API_KEY", "FLOSSWARE_HUGGINGFACE_MODELS"),
    )
    for name, base, keyvar, modelvar in explicit:
        key = os.getenv(keyvar, "")
        models = [x.strip() for x in os.getenv(modelvar, "").split(",") if x.strip()]
        if key and models:
            result.append((name, base, models[0], key))

    # OpenRouter is special: when no explicit free model is supplied, query
    # its catalog and admit only models whose prompt and completion pricing are
    # exactly zero.
    key = os.getenv("OPENROUTER_API_KEY", "")
    if key:
        models = [x.strip() for x in os.getenv("FLOSSWARE_OPENROUTER_FREE_MODELS", "").split(",") if x.strip()]
        if not models:
            try:
                catalog = _request("GET", "https://openrouter.ai/api/v1/models", api_key=key)
                for item in catalog.get("data", []):
                    pricing = item.get("pricing", {})
                    if str(pricing.get("prompt", "")) == "0" and str(pricing.get("completion", "")) == "0":
                        models.append(item.get("id", ""))
            except Exception:
                pass
        if models:
            result.append(("openrouter", "https://openrouter.ai/api/v1", models[0], key))
    return result


def _chat(messages: list[dict], temperature: float, max_tokens: int | None) -> tuple[str, dict, str]:
    errors: list[str] = []
    for name, base, model, key in _backends():
        body = {"model": model, "messages": messages, "temperature": temperature}
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        try:
            raw = _request("POST", f"{base}/chat/completions", body, key)
            choice = raw.get("choices", [{}])[0]
            content = choice.get("message", {}).get("content", "")
            if content:
                return content, raw.get("usage", {}), f"{name}/{model}"
            errors.append(f"{name}: empty response")
        except Exception as exc:
            errors.append(f"{name}: {exc}")
    raise RuntimeError("No free/local backend succeeded. " + "; ".join(errors) if errors else "No free/local backend configured")


def _models() -> list[dict]:
    return [{"id": MODEL, "object": "model", "created": int(time.time()), "owned_by": "flossware"}]


class Handler(BaseHTTPRequestHandler):
    server_version = "FlossWareGateway/0.2"

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            backends = [b[0] for b in _backends()]
            self._json(200, {"status": "ok", "model": MODEL, "policy": "free-only", "backends": backends})
        elif path == "/v1/models":
            self._json(200, {"object": "list", "data": _models()})
        else:
            self._json(404, {"error": {"message": "not found", "type": "not_found"}})

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/v1/chat/completions":
            self._json(404, {"error": {"message": "not found", "type": "not_found"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            messages = body.get("messages", [])
            if not messages or body.get("model", MODEL) != MODEL:
                raise ValueError("model must be flossware and messages must be non-empty")
            content, usage, backend = _chat(messages, float(body.get("temperature", 0.2)), body.get("max_tokens"))
            self._json(200, {
                "id": "flossware-" + str(int(time.time() * 1000)),
                "object": "chat.completion",
                "created": int(time.time()),
                "model": MODEL,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
                "usage": usage,
                "flossware_backend": backend,
            })
        except Exception as exc:
            self._json(503, {"error": {"message": str(exc), "type": "flossware_unavailable"}})

    def log_message(self, fmt, *args):
        print("[flossware-gateway] " + fmt % args, flush=True)


if __name__ == "__main__":
    print(f"FlossWare gateway listening on http://{HOST}:{PORT}/v1 (model={MODEL}, free-only)", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
