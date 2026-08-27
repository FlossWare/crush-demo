#!/usr/bin/env python3
"""Local OpenAI-compatible FlossWare gateway for Crush."""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = os.getenv("FLOSSWARE_GATEWAY_HOST", "127.0.0.1")
PORT = int(os.getenv("FLOSSWARE_GATEWAY_PORT", "8765"))
MODEL = "flossware"
TIMEOUT = 180
KEY_RE = re.compile(r"^(?P<provider>[A-Z0-9]+)_API_KEY(?:_(?P<account>[A-Z0-9][A-Z0-9_]*))?$")
PROVIDERS = {
    "deepinfra": "https://api.deepinfra.com/v1/openai",
    "openrouter": "https://openrouter.ai/api/v1",
    "groq": "https://api.groq.com/openai/v1",
    "cerebras": "https://api.cerebras.ai/v1",
    "gemini": "https://generativelanguage.googleapis.com/v1beta/openai",
    "huggingface": "https://router.huggingface.co/v1",
}
BLOCKED = {"anthropic", "openai", "redhat", "rh"}


def _request(method: str, url: str, body: dict | None = None, api_key: str = "") -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:1000]
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc


def _ollama_models() -> list[str]:
    try:
        data = _request("GET", "http://127.0.0.1:11434/api/tags")
        return [m.get("name", "") for m in data.get("models", []) if m.get("name")]
    except Exception:
        return []


def _credentials() -> list[tuple[str, str, str, str]]:
    found = []
    for env_name, secret in os.environ.items():
        if not secret:
            continue
        match = KEY_RE.match(env_name)
        if not match:
            continue
        provider = match.group("provider").lower()
        if provider in BLOCKED or provider not in PROVIDERS:
            continue
        account = (match.group("account") or "default").lower()
        found.append((provider, account, env_name, secret))
    return sorted(found, key=lambda x: (x[0], x[1], x[2]))


def _model_hints(provider: str, account: str) -> list[str]:
    suffix = "" if account == "default" else "_" + account.upper()
    for name in (
        f"FLOSSWARE_{provider.upper()}_MODELS{suffix}",
        f"FLOSSWARE_{provider.upper()}_MODEL{suffix}",
        f"{provider.upper()}_MODELS{suffix}",
        f"{provider.upper()}_MODEL{suffix}",
    ):
        value = os.getenv(name, "")
        if value:
            return [x.strip() for x in value.split(",") if x.strip()]
    return []


def _openrouter_free_models(key: str) -> list[str]:
    explicit = [x.strip() for x in os.getenv("FLOSSWARE_OPENROUTER_FREE_MODELS", "").split(",") if x.strip()]
    if explicit:
        return explicit
    try:
        catalog = _request("GET", "https://openrouter.ai/api/v1/models", api_key=key)
        return [
            item.get("id", "") for item in catalog.get("data", [])
            if str(item.get("pricing", {}).get("prompt", "")) == "0"
            and str(item.get("pricing", {}).get("completion", "")) == "0"
            and item.get("id")
        ]
    except Exception:
        return []


def _backends() -> list[tuple[str, str, str, str, str]]:
    result = []
    local = _ollama_models()
    if local:
        result.append(("ollama", "local", "http://127.0.0.1:11434/v1", local[0], ""))
    for provider, account, _env, key in _credentials():
        models = _openrouter_free_models(key) if provider == "openrouter" else _model_hints(provider, account)
        if models:
            result.append((provider, account, PROVIDERS[provider], models[0], key))
    return result


def _normalize_tool_calls(tool_calls: object) -> list[dict]:
    """Return OpenAI-compatible tool calls with JSON-string arguments.

    Providers sometimes return arguments as a dict/object. Crush expects the
    OpenAI wire format where function.arguments is a JSON-encoded string.
    """
    if not isinstance(tool_calls, list):
        return []
    normalized: list[dict] = []
    for index, call in enumerate(tool_calls):
        if not isinstance(call, dict):
            continue
        function = call.get("function") or {}
        if not isinstance(function, dict):
            function = {}
        name = function.get("name") or call.get("name")
        if not isinstance(name, str) or not name:
            continue
        arguments = function.get("arguments", call.get("arguments", "{}"))
        if isinstance(arguments, str):
            try:
                parsed = json.loads(arguments)
            except json.JSONDecodeError:
                # Do not pass malformed arguments downstream to Crush.
                raise ValueError(f"tool call {name!r} returned invalid JSON arguments")
            arguments = json.dumps(parsed, separators=(",", ":"))
        else:
            try:
                arguments = json.dumps(arguments if arguments is not None else {}, separators=(",", ":"))
            except (TypeError, ValueError) as exc:
                raise ValueError(f"tool call {name!r} returned non-serializable arguments") from exc
        normalized.append({
            "id": str(call.get("id") or f"call_flossware_{index}"),
            "type": "function",
            "function": {"name": name, "arguments": arguments},
        })
    return normalized


def _normalize_response(raw: dict) -> dict:
    """Normalize an upstream completion for Crush."""
    choices = raw.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ValueError("upstream response has no choices")
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        message = choice.get("message")
        if isinstance(message, dict) and message.get("tool_calls") is not None:
            calls = _normalize_tool_calls(message.get("tool_calls"))
            message["tool_calls"] = calls
            if calls:
                message.pop("content", None)
                choice["finish_reason"] = "tool_calls"
    return raw


def _chat(messages: list[dict], temperature: float, max_tokens: int | None, extra: dict | None = None) -> tuple[dict, str]:
    errors = []
    extra = extra or {}
    for provider, account, base, model, key in _backends():
        body = {"model": model, "messages": messages, "temperature": temperature}
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        for field in ("tools", "tool_choice", "response_format", "top_p", "stop", "seed"):
            if field in extra:
                body[field] = extra[field]
        try:
            raw = _normalize_response(_request("POST", f"{base}/chat/completions", body, key))
            choice = raw.get("choices", [{}])[0]
            message = choice.get("message", {})
            if message.get("content") or message.get("tool_calls"):
                return raw, f"{provider}/{account}/{model}"
            errors.append(f"{provider}/{account}: empty response")
        except Exception as exc:
            errors.append(f"{provider}/{account}: {exc}")
    raise RuntimeError("No free/local backend succeeded." + (" " + "; ".join(errors) if errors else " No backend configured."))


def _models() -> list[dict]:
    return [{"id": MODEL, "object": "model", "created": int(time.time()), "owned_by": "flossware"}]


class Handler(BaseHTTPRequestHandler):
    server_version = "FlossWareGateway/0.6"

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _sse(self, raw: dict, backend: str) -> None:
        choice = raw.get("choices", [{}])[0]
        message = choice.get("message", {})
        content = message.get("content") or ""
        tool_calls = _normalize_tool_calls(message.get("tool_calls")) if message.get("tool_calls") else []
        response_id = raw.get("id", "flossware-" + str(int(time.time() * 1000)))
        created = raw.get("created", int(time.time()))

        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            if tool_calls:
                # Emit one complete, valid tool call. Crush can consume a complete
                # tool call even though the upstream provider was non-streaming.
                for index, call in enumerate(tool_calls):
                    delta = {
                        "role": "assistant" if index == 0 else None,
                        "tool_calls": [{
                            "index": index,
                            "id": call["id"],
                            "type": "function",
                            "function": {
                                "name": call["function"]["name"],
                                "arguments": call["function"]["arguments"],
                            },
                        }],
                    }
                    delta = {k: v for k, v in delta.items() if v is not None}
                    chunk = {"index": 0, "delta": delta, "finish_reason": None}
                    payload = {"id": response_id, "object": "chat.completion.chunk", "created": created, "model": MODEL, "choices": [chunk]}
                    self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
                    self.wfile.flush()
                finish = "tool_calls"
            else:
                chunk = {"index": 0, "delta": {"role": "assistant", "content": content}, "finish_reason": None}
                payload = {"id": response_id, "object": "chat.completion.chunk", "created": created, "model": MODEL, "choices": [chunk]}
                self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
                self.wfile.flush()
                finish = choice.get("finish_reason", "stop")
            payload = {"id": response_id, "object": "chat.completion.chunk", "created": created, "model": MODEL, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
            self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            self._json(200, {"status": "ok", "model": MODEL, "policy": "free-only"})
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
            raw, backend = _chat(messages, float(body.get("temperature", 0.2)), body.get("max_tokens"), body)
            if body.get("stream"):
                self._sse(raw, backend)
                return
            raw["model"] = MODEL
            raw["flossware_backend"] = backend
            self._json(200, raw)
        except ValueError as exc:
            self._json(400, {"error": {"message": str(exc), "type": "invalid_request_error"}})
        except Exception as exc:
            self._json(503, {"error": {"message": str(exc), "type": "flossware_unavailable"}})

    def log_message(self, fmt, *args):
        print("[flossware-gateway] " + fmt % args, flush=True)


if __name__ == "__main__":
    print(f"FlossWare gateway listening on http://{HOST}:{PORT}/v1 (model={MODEL}, free-only)", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
