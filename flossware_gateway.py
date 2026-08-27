#!/usr/bin/env python3
"""Tiny OpenAI-compatible gateway exposing FlossWare as one Crush model.

The gateway deliberately knows only about a small allow-list of personal/free
provider credentials. It does not read arbitrary dotenv files or Red Hat
configuration. The existing ~/.flossware/ai environment supplies the Python
package; this process supplies the Crush-facing API boundary.
"""
from __future__ import annotations

import asyncio
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from personal_agent.router import SimpleRouter

HOST = os.environ.get("FLOSSWARE_HOST", "127.0.0.1")
PORT = int(os.environ.get("FLOSSWARE_PORT", "8765"))
MODEL = "flossware"

# Only these credentials are eligible for the Personal/$0 profile.
PROVIDERS = {
    "groq": {"env": "GROQ_API_KEY", "model": os.environ.get("FLOSSWARE_GROQ_MODEL", "llama-3.1-8b-instant"), "url": "https://api.groq.com/openai/v1/chat/completions"},
    "cerebras": {"env": "CEREBRAS_API_KEY", "model": os.environ.get("FLOSSWARE_CEREBRAS_MODEL", "llama-3.1-8b"), "url": "https://api.cerebras.ai/v1/chat/completions"},
    "gemini": {"env": "GEMINI_API_KEY", "model": os.environ.get("FLOSSWARE_GEMINI_MODEL", "gemini-2.5-flash"), "url": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"},
    "openrouter": {"env": "OPENROUTER_API_KEY", "model": os.environ.get("FLOSSWARE_OPENROUTER_MODEL", "openrouter/free"), "url": "https://openrouter.ai/api/v1/chat/completions"},
    "huggingface": {"env": "HF_TOKEN", "model": os.environ.get("FLOSSWARE_HF_MODEL", "Qwen/Qwen2.5-Coder-32B-Instruct"), "url": "https://router.huggingface.co/v1/chat/completions"},
}


def build_router() -> SimpleRouter:
    providers: list[dict[str, Any]] = []
    for name, cfg in PROVIDERS.items():
        key = os.environ.get(cfg["env"], "")
        if key:
            providers.append({"name": name, "model": cfg["model"], "url": cfg["url"], "key": key})

    # Local Ollama requires no account and is always eligible when running.
    if os.environ.get("FLOSSWARE_OLLAMA", "auto").lower() != "off":
        try:
            import urllib.request
            with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=1):
                providers.insert(0, {"name": "ollama", "model": os.environ.get("FLOSSWARE_OLLAMA_MODEL", ""), "url": "http://127.0.0.1:11434/v1/chat/completions", "key": ""})
        except Exception:
            pass

    if not providers:
        raise RuntimeError("No personal/free provider is configured. Set a supported free-account API key or run Ollama.")
    return SimpleRouter(providers)


ROUTER = build_router()


def run_chat(messages: list[dict[str, str]], **kwargs: Any) -> Any:
    return asyncio.run(ROUTER.chat(messages, **kwargs))


class Handler(BaseHTTPRequestHandler):
    server_version = "FlossWare/0.1"

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._json(200, {"status": "ok", "model": MODEL, "providers": list(ROUTER._providers) and [p["name"] for p in ROUTER._providers]})
            return
        if self.path == "/v1/models":
            self._json(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "FlossWare"}]})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/chat/completions":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length))
            messages = request.get("messages") or []
            if not messages:
                raise ValueError("messages is required")
            started = time.time()
            response = run_chat(messages, temperature=request.get("temperature", 0.2), max_tokens=request.get("max_tokens"))
            content = response.content
            payload = {
                "id": f"flossware-{int(started * 1000)}",
                "object": "chat.completion",
                "created": int(started),
                "model": MODEL,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
                "usage": response.usage or {},
                "flossware": {"provider": response.provider, "upstream_model": response.model, "cost_policy": "personal-free"},
            }
            self._json(200, payload)
        except Exception as exc:
            self._json(500, {"error": {"message": str(exc), "type": "flossware_gateway_error"}})

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[flossware] {fmt % args}")


if __name__ == "__main__":
    print(f"FlossWare model endpoint: http://{HOST}:{PORT}/v1")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
