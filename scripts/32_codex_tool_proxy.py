#!/usr/bin/env python3
"""32_codex_tool_proxy.py - Codex CLI と Ollama の間でツール呼び出しを修復する透過プロキシ

なぜこれがあるか（docs/手順書.md §5.6 / §5.8）:
  Ollama はモデルに「ツールを呼ぶときは <tool_call>{...}</tool_call> で囲んで返せ」と
  テンプレートで指示するが、qwen2.5-coder 系はこのラッパーを付けずに生の JSON を
  プレーンテキストとして返すことがある。Ollama サーバのパーサーは <tool_call> タグの
  有無だけで構造化出力を埋めるかどうかを決めているため、タグが無いと丸ごと
  プレーンテキストとして返る。Codex はテキストをツール呼び出しとして実行できないため、
  JSON を印字するだけで何も起きない (openai/codex#2229 と同じ症状)。

  Codex CLI 0.15x 系は wire_api = "chat" を廃止し、/v1/responses (Responses API)
  のみをサポートする（`wire_api = "chat" is no longer supported.`）。そのため
  このプロキシは /v1/responses を主目的として実装し、レスポンスの output に
  埋もれたツール呼び出し JSON を検出して正しい function_call item に組み替える。
  /v1/chat/completions も同様の修復付きで実装している（aider 等、Chat
  Completions 形式のクライアント向け）。プロンプトやモデルには一切手を入れない。

  使い方: 単体では起動しない。scripts/31_alt_agents.sh が CODEX_TOOL_REPAIR=1 の
  ときに起動し、Codex の config.toml の base_url をこのプロキシに向ける。
"""
from __future__ import annotations

import itertools
import json
import os
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/")
LISTEN_PORT = int(os.environ.get("CODEX_PROXY_PORT", "11435"))

_TOOL_CALL_TAG_RE = re.compile(r"<tool_call>(.*?)</tool_call>", re.DOTALL)
_CODE_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)

_id_counter = itertools.count()


def _log(msg: str) -> None:
    print(f"[codex-tool-proxy] {msg}", flush=True)


def _next_id(prefix: str) -> str:
    return f"{prefix}_repaired_{next(_id_counter)}"


def _extract_json_objects(text: str):
    """text 中から JSON オブジェクトをバランス走査で抽出する（best-effort）。"""
    objs = []
    decoder = json.JSONDecoder()
    i = 0
    n = len(text)
    while i < n:
        start = text.find("{", i)
        if start == -1:
            break
        try:
            obj, end = decoder.raw_decode(text, start)
            objs.append(obj)
            i = end
        except json.JSONDecodeError:
            i = start + 1
    return objs


def _candidate_texts(content: str):
    """content から「JSON があるかもしれない箇所」の候補文字列を列挙する。"""
    yield content
    for m in _TOOL_CALL_TAG_RE.finditer(content):
        yield m.group(1)
    for m in _CODE_FENCE_RE.finditer(content):
        yield m.group(1)


def _find_tool_calls_in_text(text: str, valid_tool_names: set[str]):
    """text から {"name": <有効なツール名>, "arguments": {...}} 形状を抽出する。

    誤爆防止のため、name が valid_tool_names に無ければ拾わない
    （本物のテキスト回答をツール呼び出しと誤認しないため）。
    """
    if not isinstance(text, str) or not text.strip():
        return []
    found = []
    seen = set()
    for candidate in _candidate_texts(text):
        if candidate in seen:
            continue
        seen.add(candidate)
        for obj in _extract_json_objects(candidate):
            if not isinstance(obj, dict):
                continue
            name = obj.get("name")
            if not isinstance(name, str) or name not in valid_tool_names:
                continue
            if "arguments" not in obj:
                continue
            found.append(obj)
        if found:
            break
    return found


def _args_to_str(args) -> str:
    return args if isinstance(args, str) else json.dumps(args, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Chat Completions (/v1/chat/completions) 用の修復
# ---------------------------------------------------------------------------

def _repair_chat_message(message: dict, valid_tool_names: set[str]) -> bool:
    if message.get("tool_calls"):
        return False
    found = _find_tool_calls_in_text(message.get("content"), valid_tool_names)
    if not found:
        return False
    message["tool_calls"] = [
        {
            "id": _next_id("call"),
            "type": "function",
            "function": {"name": obj["name"], "arguments": _args_to_str(obj["arguments"])},
        }
        for obj in found
    ]
    message["content"] = None
    return True


def _repair_chat_response(body: dict, valid_tool_names: set[str]) -> bool:
    repaired_any = False
    for choice in body.get("choices", []):
        message = choice.get("message")
        if isinstance(message, dict) and _repair_chat_message(message, valid_tool_names):
            choice["finish_reason"] = "tool_calls"
            repaired_any = True
    return repaired_any


def _chat_sse_wrap(body: dict) -> bytes:
    """非ストリーミングのレスポンス body を OpenAI 互換 SSE 1チャンクに包む。"""
    chunks = []
    for choice in body.get("choices", []):
        message = choice.get("message", {}) or {}
        delta = {}
        if message.get("role"):
            delta["role"] = message["role"]
        if message.get("content") is not None:
            delta["content"] = message["content"]
        if message.get("tool_calls"):
            delta["tool_calls"] = message["tool_calls"]
        chunks.append({
            "id": body.get("id", "chatcmpl-repaired"), "object": "chat.completion.chunk",
            "created": body.get("created", 0), "model": body.get("model", ""),
            "choices": [{"index": choice.get("index", 0), "delta": delta, "finish_reason": None}],
        })
    for choice in body.get("choices", []):
        chunks.append({
            "id": body.get("id", "chatcmpl-repaired"), "object": "chat.completion.chunk",
            "created": body.get("created", 0), "model": body.get("model", ""),
            "choices": [{"index": choice.get("index", 0), "delta": {},
                         "finish_reason": choice.get("finish_reason", "stop")}],
        })
    out = [f"data: {json.dumps(c, ensure_ascii=False)}\n\n" for c in chunks]
    out.append("data: [DONE]\n\n")
    return "".join(out).encode("utf-8")


# ---------------------------------------------------------------------------
# Responses API (/v1/responses) 用の修復 — Codex CLI 0.15x 系はこちらのみ対応
# ---------------------------------------------------------------------------

def _repair_responses_body(body: dict, valid_tool_names: set[str]) -> bool:
    output = body.get("output")
    if not isinstance(output, list):
        return False

    repaired_any = False
    new_output = []
    for item in output:
        if not (isinstance(item, dict) and item.get("type") == "message"
                and item.get("role") == "assistant"):
            new_output.append(item)
            continue

        texts = []
        for part in item.get("content") or []:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                texts.append(part["text"])
        combined = "\n".join(texts)
        found = _find_tool_calls_in_text(combined, valid_tool_names)

        if not found:
            new_output.append(item)
            continue

        for obj in found:
            new_output.append({
                "type": "function_call",
                "id": _next_id("fc"),
                "call_id": _next_id("call"),
                "name": obj["name"],
                "arguments": _args_to_str(obj["arguments"]),
                "status": "completed",
            })
        repaired_any = True

    if repaired_any:
        body["output"] = new_output
    return repaired_any


def _responses_sse_wrap(body: dict) -> bytes:
    """非ストリーミングの Responses body を最小限の SSE イベント列に包む。

    Codex は response.completed の中の完成済み response オブジェクトから
    最終状態を読み取れるので、途中経過イベントは output_item 単位の
    added/done のみとし、delta イベントは省略する（正しさ優先の簡略化）。
    """
    events = []

    def emit(event_type: str, data: dict) -> None:
        events.append((event_type, data))

    created_stub = dict(body)
    created_stub["output"] = []
    created_stub["status"] = "in_progress"
    emit("response.created", {"type": "response.created", "response": created_stub})

    for idx, item in enumerate(body.get("output", [])):
        emit("response.output_item.added", {
            "type": "response.output_item.added", "output_index": idx, "item": item,
        })
        emit("response.output_item.done", {
            "type": "response.output_item.done", "output_index": idx, "item": item,
        })

    emit("response.completed", {"type": "response.completed", "response": body})

    out = []
    for event_type, data in events:
        out.append(f"event: {event_type}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n")
    return "".join(out).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib override
        _log(fmt % args)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _send_bytes(self, status: int, content_type: str, data: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, status: int, obj: dict) -> None:
        self._send_bytes(status, "application/json", json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def _proxy_passthrough(self, method: str, path: str, raw: bytes) -> None:
        try:
            req = urllib.request.Request(
                f"{UPSTREAM}{path}", data=raw or None, method=method,
                headers={"Content-Type": "application/json"} if raw else {},
            )
            with urllib.request.urlopen(req, timeout=600) as resp:
                data = resp.read()
                self._send_bytes(resp.status, resp.headers.get("Content-Type", "application/json"), data)
        except urllib.error.HTTPError as e:
            self._send_bytes(e.code, "application/json", e.read())
        except Exception as e:  # pragma: no cover - network failure path
            self._send_json(502, {"error": {"message": str(e)}})

    def do_GET(self):
        self._proxy_passthrough("GET", self.path, b"")

    def do_POST(self):
        path = self.path.rstrip("/")
        raw = self._read_body()

        if path not in ("/v1/responses", "/v1/chat/completions"):
            self._proxy_passthrough("POST", self.path, raw)
            return

        try:
            req_body = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "invalid JSON body"}})
            return

        client_wanted_stream = bool(req_body.get("stream"))
        req_body["stream"] = False  # 上流へは常に非ストリーミングで転送し、修復してから返す

        if path == "/v1/responses":
            valid_tool_names = {
                t.get("name") for t in (req_body.get("tools") or [])
                if isinstance(t, dict) and t.get("type") == "function" and isinstance(t.get("name"), str)
            }
        else:
            valid_tool_names = {
                (t.get("function") or {}).get("name") for t in (req_body.get("tools") or [])
                if isinstance(t, dict)
            }
            valid_tool_names.discard(None)

        upstream_data = json.dumps(req_body).encode("utf-8")
        try:
            up_req = urllib.request.Request(
                f"{UPSTREAM}{path}", data=upstream_data, method="POST",
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(up_req, timeout=600) as resp:
                resp_body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            self._send_bytes(e.code, "application/json", e.read())
            return
        except Exception as e:
            self._send_json(502, {"error": {"message": str(e)}})
            return

        if path == "/v1/responses":
            repaired = _repair_responses_body(resp_body, valid_tool_names)
        else:
            repaired = _repair_chat_response(resp_body, valid_tool_names)

        _log(f"POST {path} -> {'repaired' if repaired else 'passthrough'}"
             f" (tools={len(valid_tool_names)}, stream_requested={client_wanted_stream})")

        if client_wanted_stream:
            if path == "/v1/responses":
                data = _responses_sse_wrap(resp_body)
            else:
                data = _chat_sse_wrap(resp_body)
            self._send_bytes(200, "text/event-stream", data)
        else:
            self._send_json(200, resp_body)


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    _log(f"listening on 127.0.0.1:{LISTEN_PORT} -> upstream {UPSTREAM}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
