#!/usr/bin/env python3
"""わざと遅い上流サーバ。エージェント側のタイムアウトを **モデル無しで** 測る。

なぜ必要か
----------
手順書 §7 の中心的な主張は「Cline CLI は Ollama へのリクエストを 30 秒で切り、
CLI 側に設定項目が無い（cline#9182 / #9484）」で、§7 の対策 6 番と V-4 に
「CLINE_PROVIDER=openai-compatible（/v1 経由）なら回避できる可能性がある」
という **未検証の仮説** が残っている。

この 2 つを確かめるのに実モデルは要らない。要るのは「応答に N 秒かかる上流」
だけで、それならスタブで作れる。むしろスタブのほうが良い:

  - T4 も CPU の長時間実行も要らない（数十秒で終わる）
  - 遅延を秒単位で指定できるので、境界（29s は通る / 31s は切れる）を
    はっきりさせられる。実モデルでは遅延を狙って作れない
  - モデルの出来不出来が混入しない。切れたなら原因はクライアント側だけ

scripts/test_harmony_e2e_stub.py と役割が違う点
-----------------------------------------------
あちらは Codex CLI 用で `/v1/responses` しか喋らない。Cline は
Ollama ネイティブ API（`/api/tags`, `/api/chat`）か OpenAI 互換
（`/v1/chat/completions`）を使うので、同じスタブには乗らない。
こちらは **4 つの API 形状すべて** に応え、どれが叩かれたかを記録する
（Ollama ネイティブ / OpenAI 互換 chat / OpenAI 互換 responses / 探索系）。
`/v1/responses` があるのは Codex CLI 0.15x がそれしか喋らないため。

環境変数
--------
  STUB_PORT       待受ポート（既定 11434 = Ollama の既定ポート）
                  ★ Cline の ollama プロバイダは接続先を設定できず、常に
                    127.0.0.1:11434 を見に行く。そのプロバイダを測るときは
                    このポートで待ち受けるしかない（本物の ollama serve が
                    動いていたら先に止めること）
  STUB_DELAY_SEC  応答を返すまでに待つ秒数（既定 45）
                  最初の 1 バイトを送る前に待つ。prefill が長いときの
                  見え方と同じにするため
  STUB_MODEL      名乗るモデル名（既定 cline-coder）
  STUB_STALL_MODE 沈黙のさせ方（既定 ttfb）
                    ttfb … 最初の 1 バイトまで STUB_DELAY_SEC 待つ
                            （= 上流がまったく応答しない状態）
                    gap  … ヘッダと最初のイベントは即返し、**その後**
                            STUB_DELAY_SEC 沈黙してから完了イベントを返す
                  ★ この 2 つを撃ち分けないと、クライアントの
                    「idle timeout」が *初回バイトまで* を縛るのか
                    *イベント間の間隔* を縛るのかが分からない。
                    実際 Codex CLI 0.155.1 は前者を縛らなかった。
  STUB_LOG        リクエストの記録先（既定 /tmp/slow-upstream-requests.jsonl）

使い方
------
    STUB_DELAY_SEC=45 python3 scripts/test_slow_upstream_stub.py &
    # 別のシェルで cline を走らせ、何秒で切られるかを測る
    # 一括でやるなら scripts/35_cline_timeout_probe.sh
"""

from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PORT", "11434"))
DELAY_SEC = float(os.environ.get("STUB_DELAY_SEC", "45"))
MODEL = os.environ.get("STUB_MODEL", "cline-coder")
STALL_MODE = os.environ.get("STUB_STALL_MODE", "ttfb")
LOG_PATH = os.environ.get("STUB_LOG", "/tmp/slow-upstream-requests.jsonl")

# 応答本文。ツール呼び出しはさせない（ここで測りたいのは時間だけ）。
REPLY_TEXT = "ok"

_calls = {"n": 0}


def _record(method: str, path: str, body: dict, delayed: bool) -> int:
    _calls["n"] += 1
    n = _calls["n"]
    rec = {
        "call": n,
        "t": time.time(),
        "method": method,
        "path": path,
        "stream": body.get("stream"),
        "model": body.get("model"),
        "delayed_sec": DELAY_SEC if delayed else 0,
    }
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass
    print(f"[stub] call#{n} {method} {path} stream={body.get('stream')} "
          f"delay={'yes' if delayed else 'no'}", flush=True)
    return n


# --- 各 API 形状の応答本文 --------------------------------------------------

def _ollama_tags() -> dict:
    return {
        "models": [
            {
                "name": f"{MODEL}:latest",
                "model": f"{MODEL}:latest",
                "modified_at": "2026-09-18T00:00:00Z",
                "size": 7_200_000_000,
                "digest": "0" * 64,
                "details": {
                    "parent_model": "",
                    "format": "gguf",
                    "family": "gemma4",
                    "families": ["gemma4"],
                    "parameter_size": "12B",
                    "quantization_level": "Q4_0",
                },
            }
        ]
    }


def _ollama_show() -> dict:
    return {
        "license": "",
        "modelfile": f"FROM {MODEL}",
        "parameters": "num_ctx 16384",
        "template": "{{ .Prompt }}",
        "capabilities": ["completion", "tools"],
        "details": {"family": "gemma4", "parameter_size": "12B"},
        "model_info": {"general.architecture": "gemma4"},
    }


def _ollama_chat() -> dict:
    return {
        "model": MODEL,
        "created_at": "2026-09-18T00:00:00Z",
        "message": {"role": "assistant", "content": REPLY_TEXT},
        "done": True,
        "done_reason": "stop",
        "total_duration": int(DELAY_SEC * 1e9),
        "prompt_eval_count": 10,
        "eval_count": 1,
    }


def _openai_models() -> dict:
    return {
        "object": "list",
        "data": [{"id": MODEL, "object": "model", "created": 0, "owned_by": "stub"}],
    }


def _openai_chat() -> dict:
    return {
        "id": "chatcmpl-stub",
        "object": "chat.completion",
        "created": 0,
        "model": MODEL,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": REPLY_TEXT},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11},
    }


def _openai_responses() -> dict:
    """Codex CLI 0.15x 系が喋る /v1/responses の形。

    test_harmony_e2e_stub.py が返す形に合わせてある（あちらは harmony 修復の
    検証用、こちらは遅延の検証用で、役割だけが違う）。
    """
    return {
        "id": "resp_stub",
        "object": "response",
        "status": "completed",
        "model": MODEL,
        "output": [{
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": REPLY_TEXT}],
        }],
        "usage": {"input_tokens": 10, "output_tokens": 1, "total_tokens": 11},
    }


class Stub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 既定のアクセスログは抑制する
        pass

    # --- 送信ヘルパ --------------------------------------------------------
    def _send_json(self, obj: dict, status: int = 200) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_ollama_stream(self, obj: dict) -> None:
        """Ollama のストリームは JSON Lines（SSE ではない）。"""
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n"
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_openai_stream(self, obj: dict) -> None:
        chunk = {
            "id": obj["id"],
            "object": "chat.completion.chunk",
            "created": 0,
            "model": obj["model"],
            "choices": [
                {
                    "index": 0,
                    "delta": {"role": "assistant", "content": REPLY_TEXT},
                    "finish_reason": "stop",
                }
            ],
        }
        body = (
            f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode("utf-8")
            + b"data: [DONE]\n\n"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_chunked_stream(self, first: bytes, rest: bytes, gap: float) -> None:
        """ヘッダと first を即送り、gap 秒沈黙してから rest を送る。

        Content-Length を先に決められないので chunked で送る。
        これが「イベント間の間隔」を作る唯一の方法で、
        idle timeout の意味を切り分けるために要る。
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def chunk(b: bytes) -> bytes:
            return f"{len(b):x}\r\n".encode() + b + b"\r\n"

        self.wfile.write(chunk(first))
        self.wfile.flush()
        print(f"[stub] 最初のイベントを送信。{gap}s 沈黙します", flush=True)
        time.sleep(gap)
        self.wfile.write(chunk(rest))
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def _send_responses_stream(self, obj: dict) -> None:
        ev = [
            ("response.created", {"type": "response.created", "response": {"id": obj["id"]}}),
            ("response.completed", {"type": "response.completed", "response": obj}),
        ]
        body = b"".join(
            f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8")
            for name, payload in ev
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # --- ルーティング ------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        _record("GET", path, {}, delayed=False)
        # 探索系（モデル一覧）は遅らせない。ここで待たせると、測りたい
        # 「推論リクエストのタイムアウト」ではなく起動時の疎通を測ってしまう。
        if path.startswith("/v1/models"):
            self._send_json(_openai_models())
        elif path.startswith("/api/tags") or path.startswith("/api/ps"):
            self._send_json(_ollama_tags() if path.startswith("/api/tags")
                            else {"models": []})
        else:
            self._send_json({"status": "ok"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            body = {}

        # /api/show はモデルの能力を聞いているだけなので遅らせない
        if path.startswith("/api/show"):
            _record("POST", path, body, delayed=False)
            self._send_json(_ollama_show())
            return

        # ここからが本番。推論リクエストだけを遅らせる。
        _record("POST", path, body, delayed=True)
        stream = bool(body.get("stream"))

        # gap モードは「最初のイベントを即返してから沈黙」なので、
        # ここでは待たずにストリーム送信側で待つ。ストリームでない
        # リクエストには間隔という概念が無いので ttfb と同じ扱いにする。
        if STALL_MODE == "gap" and stream and path.startswith("/v1/responses"):
            obj = _openai_responses()
            first = (b"event: response.created\ndata: "
                     + json.dumps({"type": "response.created",
                                   "response": {"id": obj["id"]}}).encode() + b"\n\n")
            rest = (b"event: response.completed\ndata: "
                    + json.dumps({"type": "response.completed",
                                  "response": obj}).encode() + b"\n\n")
            try:
                self._send_chunked_stream(first, rest, DELAY_SEC)
            except BrokenPipeError:
                print("[stub] クライアントが沈黙中に切断しました（idle timeout 発火）",
                      flush=True)
            return

        print(f"[stub] -> {DELAY_SEC}s 待ってから応答します", flush=True)
        time.sleep(DELAY_SEC)
        try:
            if path.startswith("/v1/responses"):
                self._send_responses_stream(_openai_responses()) if stream \
                    else self._send_json(_openai_responses())
            elif path.startswith("/v1/chat/completions"):
                self._send_openai_stream(_openai_chat()) if stream \
                    else self._send_json(_openai_chat())
            elif path.startswith("/api/chat") or path.startswith("/api/generate"):
                self._send_ollama_stream(_ollama_chat()) if stream \
                    else self._send_json(_ollama_chat())
            else:
                self._send_json({"status": "ok"})
        except BrokenPipeError:
            # クライアントが待ちきれずに切った = まさに測りたかった事象
            print("[stub] クライアントが先に切断しました（タイムアウト発生）",
                  flush=True)


def main() -> int:
    try:
        open(LOG_PATH, "w").close()
    except OSError:
        pass
    print(f"[stub] port={PORT} delay={DELAY_SEC}s model={MODEL} log={LOG_PATH}",
          flush=True)
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Stub)
    except OSError as e:
        print(f"[stub] ポート {PORT} を掴めません: {e}", file=sys.stderr)
        print("[stub] 本物の ollama serve が動いていませんか？", file=sys.stderr)
        return 1
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
