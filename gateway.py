#!/usr/bin/env python3
"""Minimal OpenAI-compatible FlossWare gateway for Crush.

Crush sees one model: ``flossware``. The gateway delegates the actual model
call to coding-agent-ai's provider-neutral router. Only providers explicitly
configured as free are eligible.
"""
from __future__ import annotations

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = os.getenv("FLOSSWARE_GATEWAY_HOST", "127.0.0.1")
PORT = int(os.getenv("FLOSSWARE_GATEWAY_PORT", "8765"))
MODEL = "flossware"


def _router():
    from personal_agent.router import create_router
    return create_router(max_monthly=0.0)


def _models():
    return [{
        "id": MODEL,
        "object": "model",
        "created": int(time.time()),
        "owned_by": "flossware",
    }]


class Handler(BaseHTTPRequestHandler):
    server_version = "FlossWareGateway/0.1"

    def _json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self._json(200, {"status": "ok", "model": MODEL, "policy": "free-only"})
        elif path == "/v1/models":
            self._json(200, {"object": "list", "data": _models()})
        else:
            self._json(404, {"error": {"message": "not found", "type": "not_found"}})

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/v1/chat/completions":
            self._json(404, {"error": {"message": "not found", "type": "not_found"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            messages = body.get("messages", [])
            if not messages:
                raise ValueError("messages is required")
            requested = body.get("model", MODEL)
            if requested != MODEL:
                raise ValueError("only the flossware model is exposed")
            import asyncio
            response = asyncio.run(_router().chat(
                messages,
                temperature=float(body.get("temperature", 0.2)),
                max_tokens=body.get("max_tokens"),
            ))
            self._json(200, {
                "id": "flossware-" + str(int(time.time() * 1000)),
                "object": "chat.completion",
                "created": int(time.time()),
                "model": MODEL,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": response.content},
                    "finish_reason": "stop",
                }],
                "usage": response.usage or {},
            })
        except Exception as exc:
            self._json(503, {"error": {"message": str(exc), "type": "flossware_unavailable"}})

    def log_message(self, fmt, *args):
        print("[flossware-gateway] " + fmt % args, flush=True)


if __name__ == "__main__":
    print(f"FlossWare gateway listening on http://{HOST}:{PORT} (model={MODEL}, free-only)", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
