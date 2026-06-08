"""Anthropic provider — translates OpenAI-shape messages/tools to Anthropic's /v1/messages API and back.

Env vars:
  ANTHROPIC_API_KEY   required
  MODEL               passed through (e.g. claude-opus-4-5)
  ANTHROPIC_VERSION   defaults to "2023-06-01"
  MAX_TOKENS          defaults to 4096
"""
import json
import os

import requests

API_URL = "https://api.anthropic.com/v1/messages"


def chat(messages, tools):
    """Translate, call, translate back. Returns an OpenAI-shape assistant message dict.

    Exceptions bubble up to agent.py's retry loop.
    """
    system, anthropic_messages = _split_system_and_convert(messages)
    body = {
        "model": os.environ["MODEL"],
        "max_tokens": int(os.environ.get("MAX_TOKENS", "4096")),
        "messages": anthropic_messages,
    }
    if system:
        body["system"] = system
    if tools:
        body["tools"] = [_convert_tool(t) for t in tools]

    r = requests.post(
        API_URL,
        headers={
            "x-api-key": os.environ["ANTHROPIC_API_KEY"],
            "anthropic-version": os.environ.get("ANTHROPIC_VERSION", "2023-06-01"),
            "content-type": "application/json",
        },
        json=body,
        timeout=120,
    )
    data = r.json()
    if "content" not in data:
        raise RuntimeError(f"{r.status_code}: {data}")
    return _convert_response(data)


def _split_system_and_convert(messages):
    """Peel off role:system into top-level field; convert each remaining message."""
    system = None
    out = []
    for m in messages:
        role = m["role"]
        content = m.get("content")
        if role == "system":
            text = content if isinstance(content, str) else ""
            system = text if system is None else f"{system}\n\n{text}"
            continue
        if role == "assistant":
            blocks = []
            if content:
                blocks.append({"type": "text", "text": content})
            for tc in m.get("tool_calls") or []:
                blocks.append({
                    "type": "tool_use",
                    "id": tc["id"],
                    "name": tc["function"]["name"],
                    "input": json.loads(tc["function"]["arguments"] or "{}"),
                })
            if not blocks:
                blocks.append({"type": "text", "text": ""})
            out.append({"role": "assistant", "content": blocks})
        elif role == "tool":
            result_content = content if isinstance(content, str) else json.dumps(content)
            out.append({"role": "user", "content": [{
                "type": "tool_result",
                "tool_use_id": m["tool_call_id"],
                "content": result_content,
            }]})
        else:  # user
            if isinstance(content, list):
                out.append({"role": "user", "content": content})
            else:
                out.append({"role": "user", "content": [{"type": "text", "text": content or ""}]})
    return system, out


def _convert_tool(tool):
    fn = tool["function"]
    return {
        "name": fn["name"],
        "description": fn.get("description", ""),
        "input_schema": fn.get("parameters") or {"type": "object", "properties": {}},
    }


def _convert_response(data):
    """Anthropic response → OpenAI assistant message dict."""
    text_parts = []
    tool_calls = []
    for block in data.get("content") or []:
        btype = block.get("type")
        if btype == "text":
            text_parts.append(block.get("text", ""))
        elif btype == "tool_use":
            tool_calls.append({
                "id": block["id"],
                "type": "function",
                "function": {
                    "name": block["name"],
                    "arguments": json.dumps(block.get("input") or {}),
                },
            })
    out = {"role": "assistant", "content": "\n".join(text_parts) if text_parts else ""}
    if tool_calls:
        out["tool_calls"] = tool_calls
    return out
