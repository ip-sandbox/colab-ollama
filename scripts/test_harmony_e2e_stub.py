#!/usr/bin/env python3
"""harmony 修復の実機エンドツーエンド検証に使うスタブ上流サーバ。

なぜ必要か
----------
scripts/test_tool_proxy_harmony.py は「テキストから tool_calls を組み立てられるか」
までしか検証できない。本当に知りたいのはその先、

    **Codex が修復後の tool_calls を受け取って、実際にツールを実行するか**

で、これはユニットテストでは確かめられない。かといって本物の gpt-oss:20b は
13GB あり、T4 が取れないときの CPU ランタイム（RAM 約 12.7GB）には載らない。

そこで **モデルを使わずに**、プロキシの上流をこのスタブに差し替える:

    Codex CLI  ->  32_codex_tool_proxy.py  ->  このスタブ

スタブは 1 回目の応答で、実機の gpt-oss が出したのと同じ
「harmony 構文がテキストに漏れた本文」を返す。プロキシがそれを修復し、
Codex がツールを実行してファイルを作れば、修復が実際に機能している証拠になる。

モードは STUB_MODE で切り替える:
  probe   … リクエスト（特に tools の定義）をログに落として、ツールは呼ばせない
  harmony … 1 回目に harmony 構文入りの本文を返す。2 回目以降は完了メッセージ

使い方（VM 上）:
    STUB_MODE=probe STUB_PORT=11500 python3 scripts/test_harmony_e2e_stub.py
"""

from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PORT", "11500"))
MODE = os.environ.get("STUB_MODE", "probe")
LOG_PATH = os.environ.get("STUB_LOG", "/tmp/stub-requests.jsonl")
# harmony モードで呼ばせるツール名と引数（probe の結果を見て指定する）
TOOL_NAME = os.environ.get("STUB_TOOL_NAME", "shell")
TOOL_ARGS = os.environ.get("STUB_TOOL_ARGS", '{"command":["bash","-lc","echo hi"]}')

_calls = {"n": 0}


def _harmony_text() -> str:
    """実機で観測した「harmony 構文がテキストに漏れた」本文を模したもの。

    実機（2026-09-17 / gpt-oss:20b）で観測した形をそのまま踏襲している:
      - 前後に普通の思考テキストが混ざる
      - JSON を伴わない単なる言及も混ざる（これは拾ってはいけない）
      - 最後に to=functions.NAME <|constrain|>json<|message|>{...} が来る
    """
    return (
        "Let's inspect previous calls from the conversation? No prior usage.\n\n"
        "Given ambiguity, perhaps we should use `commentary to=functions."
        "nonexistent_tool` to run a shell command. But easier: write the file.\n\n"
        "Use:\n\n```\n"
        f"commentary to=functions.{TOOL_NAME} <|constrain|>json<|message|>{TOOL_ARGS}\n"
        "```\n"
    )


def _message_item(text: str) -> dict:
    return {
        "type": "message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text}],
    }


def _response(output: list) -> dict:
    return {
        "id": f"resp_stub_{_calls['n']}",
        "object": "response",
        "status": "completed",
        "model": "stub",
        "output": output,
        "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
    }


class Stub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[stub] {fmt % args}", flush=True)

    def _send(self, status: int, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # プロキシの起動待ち (/v1/models) と、Codex の疎通確認に応える
        self._send(200, {"object": "list", "data": [{"id": "stub", "object": "model"}]})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            body = {}

        _calls["n"] += 1
        n = _calls["n"]

        # リクエストの要点を記録する。tools の定義を知るのが probe の目的。
        tools = body.get("tools") or []
        record = {
            "call": n,
            "model": body.get("model"),
            "stream": body.get("stream"),
            "tool_names": [t.get("name") for t in tools if isinstance(t, dict)],
            "tools": tools,
            "input_tail": str(body.get("input"))[-400:],
        }
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(f"[stub] call#{n} tools={record['tool_names']}", flush=True)

        if MODE == "harmony" and n == 1:
            print(f"[stub] -> harmony 構文入りの本文を返します (tool={TOOL_NAME})",
                  flush=True)
            self._send(200, _response([_message_item(_harmony_text())]))
            return

        # 2 回目以降（＝ツールが実行されて結果が返ってきた場合を含む）は終了する
        print("[stub] -> 完了メッセージを返します", flush=True)
        self._send(200, _response([_message_item("完了しました。")]))


def main() -> int:
    open(LOG_PATH, "w").close()
    print(f"[stub] mode={MODE} port={PORT} log={LOG_PATH}", flush=True)
    if MODE == "harmony":
        print(f"[stub] 呼ばせるツール: {TOOL_NAME} args={TOOL_ARGS}", flush=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Stub)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
