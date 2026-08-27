import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import gateway


def test_normalize_tool_calls_string_arguments():
    calls = gateway._normalize_tool_calls([
        {
            "id": "call_1",
            "type": "function",
            "function": {"name": "write_file", "arguments": '{"path":"hello.py","content":"print(1)"}'},
        }
    ])
    assert calls[0]["id"] == "call_1"
    assert calls[0]["type"] == "function"
    assert calls[0]["function"]["name"] == "write_file"
    assert json.loads(calls[0]["function"]["arguments"]) == {"path": "hello.py", "content": "print(1)"}


def test_normalize_tool_calls_object_arguments():
    calls = gateway._normalize_tool_calls([
        {"id": "call_2", "function": {"name": "run", "arguments": {"command": "pytest -q"}}}
    ])
    assert json.loads(calls[0]["function"]["arguments"]) == {"command": "pytest -q"}


def test_normalize_tool_calls_rejects_invalid_json():
    try:
        gateway._normalize_tool_calls([
            {"id": "call_3", "function": {"name": "run", "arguments": "not-json"}}
        ])
    except ValueError as exc:
        assert "invalid JSON arguments" in str(exc)
    else:
        raise AssertionError("invalid tool arguments were accepted")


def test_normalize_response_sets_tool_finish_reason():
    raw = {
        "id": "x",
        "choices": [{
            "message": {
                "role": "assistant",
                "tool_calls": [{
                    "id": "call_4",
                    "type": "function",
                    "function": {"name": "write_file", "arguments": {"path": "x"}},
                }],
            },
            "finish_reason": None,
        }],
    }
    result = gateway._normalize_response(raw)
    call = result["choices"][0]["message"]["tool_calls"][0]
    assert result["choices"][0]["finish_reason"] == "tool_calls"
    assert json.loads(call["function"]["arguments"]) == {"path": "x"}


def test_chat_preserves_tools(monkeypatch):
    captured = {}

    monkeypatch.setattr(gateway, "_backends", lambda: [("test", "account", "http://example", "model", "key")])

    def fake_request(method, url, body=None, api_key=""):
        captured["body"] = body
        return {"choices": [{"message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}]}

    monkeypatch.setattr(gateway, "_request", fake_request)
    raw, backend = gateway._chat(
        [{"role": "user", "content": "hi"}],
        0.2,
        None,
        {"tools": [{"type": "function", "function": {"name": "write_file", "parameters": {}}}], "tool_choice": "auto"},
    )
    assert backend == "test/account/model"
    assert "tools" in captured["body"]
    assert captured["body"]["tool_choice"] == "auto"
    assert raw["choices"][0]["message"]["content"] == "ok"
