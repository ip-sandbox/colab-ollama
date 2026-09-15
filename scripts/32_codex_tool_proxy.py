#!/usr/bin/env python3
"""32_codex_tool_proxy.py - Codex CLI と Ollama の間でツール呼び出しを修復する透過プロキシ

なぜこれがあるか（docs/手順書.md §5.6 / §5.8）:
  Ollama はモデルに「ツールを呼ぶときは <tool_call>{...}</tool_call> で囲んで返せ」と
  テンプレートで指示するが、qwen2.5-coder 系はこのラッパーを付けずに生の JSON を
  プレーンテキストとして返すことがある。Ollama サーバのパーサーは <tool_call> タグの
  有無だけで message.tool_calls を埋めるかどうかを決めているため、タグが無いと
  丸ごと message.content（ただのテキスト）に落ちる。Codex はテキストをツール呼び出し
  として実行できないため、JSON を印字するだけで何も起きない
  (openai/codex#2229 で報告されているのと同じ症状)。

  このプロキシは Ollama の /v1/chat/completions のレスポンスを検査し、
  content に埋もれたツール呼び出し JSON を検出して正しい tool_calls 構造に
  組み替えてから Codex に返す。プロンプトやモデルには一切手を入れない。

  使い方: 単体では起動しない。scripts/31_alt_agents.sh が CODEX_TOOL_REPAIR=1 の
  ときに起動し、Codex の config.toml の base_url をこのプロキシに向ける。
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/")
LISTEN_PORT = int(os.environ.get("CODEX_PROXY_PORT", "11435"))

_TOOL_CALL_TAG_RE = re.compile(r"<tool_call>(.*?)</tool_call>", re.DOTALL)
_CODE_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)


def _log(msg: str) -> None:
    print(f"[codex-tool-proxy] {msg}", flush=True)


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


def _repair_message(message: dict, valid_tool_names: set[str]) -> bool:
    """message.tool_calls が無ければ content からの抽出を試みる。

    抽出・変換できれば True を返し、message を書き換える。
    誤爆防止のため、抽出した "name" が valid_tool_names に無ければ何もしない。
    """
    if message.get("tool_calls"):
        return False
    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        return False

    found = []
    seen_texts = set()
    for candidate in _candidate_texts(content):
        if candidate in seen_texts:
            continue
        seen_texts.add(candidate)
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

    if not found:
        return False

    tool_calls = []
    for idx, obj in enumerate(found):
        args = obj["arguments"]
        args_str = args if isinstance(args, str) else json.dumps(args, ensure_ascii=False)
        tool_calls.append({
            "id": f"call_repaired_{idx}",
            "type": "function",
            "function": {"name": obj["name"], "arguments": args_str},
        })

    message["tool_calls"] = tool_calls
    message["content"] = None
    return True


def _repair_response(body: dict, valid_tool_names: set[str]) -> bool:
    repaired_any = False
    for choice in body.get("choices", []):
        message = choice.get("message")
        if not isinstance(message, dict):
            continue
        if _repair_message(message, valid_tool_names):
            choice["finish_reason"] = "tool_calls"
            repaired_any = True
    return repaired_any


def _sse_wrap(body: dict) -> bytes:
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
            "id": body.get("id", "chatcmpl-repaired"),
            "object": "chat.completion.chunk",
            "created": body.get("created", 0),
            "model": body.get("model", ""),
            "choices": [{
                "index": choice.get("index", 0),
                "delta": delta,
                "finish_reason": None,
            }],
        })
    final_chunks = []
    for choice in body.get("choices", []):
        final_chunks.append({
            "id": body.get("id", "chatcmpl-repaired"),
            "object": "chat.completion.chunk",
            "created": body.get("created", 0),
            "model": body.get("model", ""),
            "choices": [{
                "index": choice.get("index", 0),
                "delta": {},
                "finish_reason": choice.get("finish_reason", "stop"),
            }],
        })

    out = []
    for c in chunks + final_chunks:
        out.append(f"data: {json.dumps(c, ensure_ascii=False)}\n\n")
    out.append("data: [DONE]\n\n")
    return "".join(out).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib override
        _log(fmt % args)

    def _forward_get(self, path: str) -> None:
        try:
            req = urllib.request.Request(f"{UPSTREAM}{path}", method="GET")
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:  # pragma: no cover - network failure path
            self._send_json(502, {"error": {"message": str(e)}})

    def do_GET(self):
        self._forward_get(self.path)

    def _send_json(self, status: int, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            # このプロキシは chat.completions のみ対応。それ以外は素通しする。
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            try:
                req = urllib.request.Request(
                    f"{UPSTREAM}{self.path}", data=raw, method="POST",
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=600) as resp:
                    data = resp.read()
                    self.send_response(resp.status)
                    self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
            except urllib.error.HTTPError as e:
                data = e.read()
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(502, {"error": {"message": str(e)}})
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            req_body = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "invalid JSON body"}})
            return

        client_wanted_stream = bool(req_body.get("stream"))
        req_body["stream"] = False  # 上流へは常に非ストリーミングで転送する

        valid_tool_names = set()
        for tool in req_body.get("tools") or []:
            fn = (tool or {}).get("function") or {}
            name = fn.get("name")
            if isinstance(name, str):
                valid_tool_names.add(name)

        upstream_data = json.dumps(req_body).encode("utf-8")
        try:
            up_req = urllib.request.Request(
                f"{UPSTREAM}/v1/chat/completions", data=upstream_data, method="POST",
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(up_req, timeout=600) as resp:
                resp_body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        except Exception as e:
            self._send_json(502, {"error": {"message": str(e)}})
            return

        repaired = _repair_response(resp_body, valid_tool_names)
        _log(f"POST /v1/chat/completions -> {'repaired' if repaired else 'passthrough'}"
             f" (tools={len(valid_tool_names)}, stream_requested={client_wanted_stream})")

        if client_wanted_stream:
            data = _sse_wrap(resp_body)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
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
