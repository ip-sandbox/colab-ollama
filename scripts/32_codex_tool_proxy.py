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

# --- gpt-oss（harmony 形式）がツール呼び出しをテキストに漏らす ---------------
# 本来は harmony のチャネル構文で構造化出力になるが、これをそのまま本文に
# 書き出してしまうことがある:
#     to=functions.<NAME> <|constrain|>json<|message|>{ ...引数... }<|call|>
# マーカーは欠けることがあるので constrain / message は任意にしてある。
# 名前の直後に JSON が続くことを _find_harmony_tool_calls 側で確認するので、
# 単なる言及（JSON が続かない文）を誤って拾うことはない。
_HARMONY_CALL_RE = re.compile(
    r"to\s*=\s*functions\.(?P<name>[A-Za-z0-9_][A-Za-z0-9_.\-]*)"
    r"(?:\s*<\|constrain\|>\s*[A-Za-z0-9_]+)?"
    r"(?:\s*<\|message\|>)?"
)

# --- gpt-oss + Ollama のツール呼び出しパース失敗への再送 ---------------------
# ollama/ollama#17638（2026-08-09 報告・未修正。手元の 0.34.1 でも再現）:
#   gpt-oss の出力が array-wrap になり、開き括弧が無いまま末尾に ] だけ残る。
#       {"cmd":"apply_patch <<'PATCH' ... PATCH"]}
#   Ollama は自分で生成させた出力を自分でパースできず HTTP 500 を返す。
#       error parsing tool call: raw='...', err=invalid character ']' ...
#
# 発生条件は「単一のフリーフォーム文字列引数を取る patch 系ツール」「長いツール
# 説明文」「複数ターン」で、**非決定的**（報告ではおおむね 5 回中 2 回）。
#
# 原因は上流にあり、このプロキシからは生のテキストが見えない（Ollama の内部で
# 落ちて 500 になるため、修復のしようがない）。だが非決定的なので、
# **同じリクエストを投げ直せば通る見込みが高い**。温度 0.2 でサンプリングして
# いるので再送のたびに出力は変わる。
#
# これは対症療法である。上流が直れば不要になる。
_TOOL_PARSE_ERR_RE = re.compile(r"error parsing tool call", re.IGNORECASE)
TOOLCALL_RETRIES = int(os.environ.get("CODEX_PROXY_TOOLCALL_RETRIES", "3"))
_CODE_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)

# --- Gemma 4 系がツール呼び出しをテキストに漏らす ---------------------------
# §5.6 / §5.8 / §12.7 と同じ系統の症状が Gemma 4 でも報告されている。
# 漏れ方が 2 通りあり、どちらも既存の
# 「{"name": ..., "arguments": {...}} を探す」ロジックでは拾えない。
#
# (1) ollama/ollama#15539（ollama 0.20.6 / gemma4:e4b）
#     system prompt + think:false + tools が揃うとパーサが取りこぼし、
#     **ラッパー付きの JSON** が content に落ちる:
#         {"tool_calls":[{"function":"GetLiveContext","args":{}}]}
#         <channel|>
#     キー名が name/arguments ではなく function/args である点が肝。
#     末尾の <channel|> は raw_decode が無視するので前処理は要らない。
#
# (2) ollama/ollama#15798（ollama 0.21.1 / gemma4-64k、Closed as not planned）
#     チャットテンプレートの特殊トークンが本文にそのまま漏れる:
#         <|tool_call|> / <|channel|> / <|tool_response|>
#     加えて "call:" プレフィックスが付き、文字列引数が本来の引用符ではなく
#     <|"|>...<|"|> で囲まれる。finish_reason は stop になるため、
#     クライアントは「普通に喋っただけ」と解釈してターンを終える。
#
# ★ (2) は issue に逐語のサンプルが無く、**記述から起こした実装**である。
#   実機の生応答は scripts/34_toolcall_probe.sh が *.content.txt に保存するので、
#   採取できたら test_tool_proxy_gemma4.py のデータを実物に差し替え、
#   ここの正規表現も必要に応じて直すこと。
#   （test_tool_proxy_harmony.py が実機採取の文字列を使っているのと同じ流儀）
_GEMMA_TOKEN_RE = re.compile(r"<\|(?:tool_call|tool_response|channel|call|message)\|>")
_GEMMA_QUOTE_RE = re.compile(r'<\|"\|>')
# 行頭（や空白直後）の "call:" プレフィックス。JSON の中身には現れない形に限る。
_GEMMA_CALL_PREFIX_RE = re.compile(r"(?:^|\n)\s*call:\s*", re.MULTILINE)

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


def _first_json_object(text: str):
    """text の先頭（空白等を読み飛ばした位置）から JSON を 1 つだけ読む。

    _extract_json_objects と違い「どこかにある JSON」を探さない。
    harmony の <|message|> 直後という位置が意味を持つので、そこから読む。
    見つからなければ None。
    """
    decoder = json.JSONDecoder()
    i = 0
    n = len(text)
    # 前置きとして現れうるものだけ読み飛ばす（コードフェンス / 空白 / 改行）
    while i < n and (text[i].isspace() or text[i] == "`"):
        i += 1
    if i >= n or text[i] != "{":
        return None
    try:
        obj, _ = decoder.raw_decode(text, i)
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None


def _find_harmony_tool_calls(text: str, valid_tool_names: set[str]):
    """gpt-oss の harmony 形式のツール呼び出しがテキストに漏れたものを拾う。

    なぜ必要か（実機で観測、2026-09-17）:
      gpt-oss は本来 harmony のチャネル構文で構造化出力を出す:

        <|channel|>commentary to=functions.apply_patch <|constrain|>json
        <|message|>{"patch":"*** Begin Patch ..."}<|call|>

      ところが**この構文をそのままプレーンテキストとして本文に書き出し**、
      ツール呼び出しを発行しないまま「どう呼ぼうか」と延々と悩んで
      出力トークンを使い切ることがある（model_max_output_tokens 8192 に対し
      9,196 / 12,936 トークン使って打ち切られた実例あり）。
      結果、ファイルが 1 つも作られないまま終わる。

      §5.6 / §5.8 の「構造化出力にせずテキストで返す」と同じ系統の症状。
      既存の修復は {"name":..., "arguments":...} 形しか見ていないが、
      harmony ではツール名が JSON の**外側**（to=functions.NAME）にあるため
      拾えない。ここで拾って正しい tool_calls に組み替える。

    誤爆を避けるため、次をすべて満たすものだけ拾う:
      - ツール名が valid_tool_names にある
      - 名前の直後（constrain/message マーカーを挟んでもよい）に
        パース可能な JSON オブジェクトが続く
    単に "to=functions.exec_command を使えばよい" と言及しただけの文（JSON が
    続かない）は拾わない。
    """
    found = []
    for m in _HARMONY_CALL_RE.finditer(text):
        name = m.group("name")
        if name not in valid_tool_names:
            continue
        args = _first_json_object(text[m.end():])
        if args is None:
            continue
        found.append({"name": name, "arguments": args})
    return found


def _gemma_normalize(text: str) -> str:
    """Gemma 4 のテンプレート特殊トークンを剥がして、素の JSON に近づける。

    ollama#15798 で本文に漏れると報告されている装飾だけを落とす:
      <|tool_call|> / <|channel|> / <|tool_response|> / <|call|> / <|message|>
      行頭の "call:" プレフィックス
      文字列引数を囲む <|"|> を本来の " に戻す

    ★ 元の text を壊さないこと。ここで作った文字列は **追加の候補** として
      扱い、元の text も従来どおり走査する（_candidate_texts 参照）。
      装飾が無い応答に対しては何も変わらない。
    """
    if "<|" not in text and "call:" not in text:
        return text
    out = _GEMMA_QUOTE_RE.sub('"', text)
    out = _GEMMA_TOKEN_RE.sub("", out)
    out = _GEMMA_CALL_PREFIX_RE.sub("\n", out)
    return out


def _find_gemma_wrapped_tool_calls(text: str, valid_tool_names: set[str]):
    """{"tool_calls":[{"function":NAME,"args":{...}}]} 形を拾う（ollama#15539）。

    既存の _find_tool_calls_in_text はトップレベルに name と arguments を
    持つオブジェクトしか見ないので、この形は素通りしてしまう。

    キー名は実装によって揺れるため、function/name と args/arguments の
    どちらも受ける。誤爆防止は既存方針どおり「ツール名が有効集合にあること」。
    """
    found = []
    for obj in _extract_json_objects(text):
        if not isinstance(obj, dict):
            continue
        calls = obj.get("tool_calls")
        if not isinstance(calls, list):
            continue
        for call in calls:
            if not isinstance(call, dict):
                continue
            # {"function": "NAME", ...} と {"function": {"name": "NAME"}} の両方
            fn = call.get("function")
            name = fn if isinstance(fn, str) else None
            if name is None and isinstance(fn, dict):
                name = fn.get("name")
            if name is None:
                name = call.get("name")
            if not isinstance(name, str) or name not in valid_tool_names:
                continue
            args = call.get("args")
            if args is None and isinstance(fn, dict):
                args = fn.get("arguments")
            if args is None:
                args = call.get("arguments")
            if args is None:
                args = {}
            found.append({"name": name, "arguments": args})
    return found


def _candidate_texts(content: str):
    """content から「JSON があるかもしれない箇所」の候補文字列を列挙する。"""
    yield content
    for m in _TOOL_CALL_TAG_RE.finditer(content):
        yield m.group(1)
    for m in _CODE_FENCE_RE.finditer(content):
        yield m.group(1)
    # Gemma 4 の特殊トークンを剥がした版。元の content と違うときだけ足す。
    normalized = _gemma_normalize(content)
    if normalized != content:
        yield normalized
        for m in _CODE_FENCE_RE.finditer(normalized):
            yield m.group(1)


def _find_tool_calls_in_text(text: str, valid_tool_names: set[str]):
    """text から {"name": <有効なツール名>, "arguments": {...}} 形状を抽出する。

    誤爆防止のため、name が valid_tool_names に無ければ拾わない
    （本物のテキスト回答をツール呼び出しと誤認しないため）。
    """
    if not isinstance(text, str) or not text.strip():
        return []
    # harmony 形式を先に見る。形が具体的なぶん誤爆しにくく、
    # ツール名が JSON の外側にあるため下の汎用ロジックでは拾えない。
    harmony = _find_harmony_tool_calls(text, valid_tool_names)
    if harmony:
        return harmony
    # Gemma 4 のラッパー形（ollama#15539）。こちらもトップレベルに
    # name/arguments を持たないので、下の汎用ロジックでは拾えない。
    # 特殊トークンが被っている場合に備え、剥がした版でも試す。
    for candidate in (text, _gemma_normalize(text)):
        wrapped = _find_gemma_wrapped_tool_calls(candidate, valid_tool_names)
        if wrapped:
            return wrapped
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

    def _post_upstream(self, path: str, data: bytes):
        """上流へ POST し、パース済み body を返す。

        ollama/ollama#17638（gpt-oss のツール呼び出しが array-wrap になり
        Ollama 自身がパースに失敗して 500 を返す）は**非決定的**なので、
        その 500 に限って投げ直す。それ以外のエラーはそのまま客に返す。

        失敗して応答を送信済みの場合は None を返す。
        """
        last_err_body = b""
        for attempt in range(1, TOOLCALL_RETRIES + 2):
            try:
                req = urllib.request.Request(
                    f"{UPSTREAM}{path}", data=data, method="POST",
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=600) as resp:
                    return json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                body = e.read()
                # 再送して意味があるのは、上流がツール呼び出しのパースに
                # 失敗したときだけ。400 などを投げ直しても同じ結果になる。
                if e.code >= 500 and _TOOL_PARSE_ERR_RE.search(
                    body.decode("utf-8", "replace")
                ):
                    last_err_body = body
                    if attempt <= TOOLCALL_RETRIES:
                        _log(f"upstream {e.code} error parsing tool call "
                             f"(ollama#17638) — 再送します "
                             f"({attempt}/{TOOLCALL_RETRIES})")
                        continue
                    _log(f"upstream {e.code} error parsing tool call — "
                         f"{TOOLCALL_RETRIES} 回再送しても直りませんでした")
                    self._send_bytes(e.code, "application/json", last_err_body)
                    return None
                self._send_bytes(e.code, "application/json", body)
                return None
            except Exception as e:
                self._send_json(502, {"error": {"message": str(e)}})
                return None
        return None

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
        resp_body = self._post_upstream(path, upstream_data)
        if resp_body is None:
            return  # エラー応答は _post_upstream が送信済み

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
