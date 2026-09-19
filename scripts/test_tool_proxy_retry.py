#!/usr/bin/env python3
"""32_codex_tool_proxy.py の再送ロジックの検証（VM 不要・ネットワーク不要）。

偽の上流サーバを立て、ollama/ollama#17638 の 500 を指定回数だけ返させて、
プロキシが投げ直して最終的に成功を返すことを確認する。

    python3 scripts/test_tool_proxy_retry.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent

# #17638 が返すエラー body（実際に観測した文言をそのまま使う）
PARSE_ERR = {
    "error": "error parsing tool call: raw='{\"cmd\":\"apply_patch <<'PATCH'"
             "\\n*** Begin Patch\\n*** End Patch\\nPATCH\"]}', "
             "err=invalid character ']' after object key:value pair"
}
OK_BODY = {
    "id": "resp_1",
    "object": "response",
    "status": "completed",
    "output": [{"type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "done"}]}],
}


class FakeOllama(BaseHTTPRequestHandler):
    """指定回数だけ #17638 の 500 を返し、その後 200 を返す上流。"""

    fail_times = 0
    other_error = None   # (code, body) を入れるとそれを返し続ける
    hits = 0

    def log_message(self, *a):
        pass

    def do_POST(self):
        FakeOllama.hits += 1
        self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))

        if FakeOllama.other_error is not None:
            code, body = FakeOllama.other_error
            payload = json.dumps(body).encode()
            self.send_response(code)
        elif FakeOllama.hits <= FakeOllama.fail_times:
            payload = json.dumps(PARSE_ERR).encode()
            self.send_response(500)
        else:
            payload = json.dumps(OK_BODY).encode()
            self.send_response(200)

        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def start(server_cls, handler, port=0):
    srv = server_cls(("127.0.0.1", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def load_proxy(upstream_port: int, retries: int):
    """環境変数を設定してからプロキシモジュールを読み込む。

    モジュール先頭で UPSTREAM / TOOLCALL_RETRIES を決めているので、
    import 前に環境変数を入れる必要がある。毎回読み直す。
    """
    os.environ["OLLAMA_BASE_URL"] = f"http://127.0.0.1:{upstream_port}"
    os.environ["CODEX_PROXY_TOOLCALL_RETRIES"] = str(retries)
    spec = importlib.util.spec_from_file_location(
        f"tool_proxy_{upstream_port}_{retries}", HERE / "32_codex_tool_proxy.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def post(port, body):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/responses",
        data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


def run_case(name, *, fail_times, retries, other_error=None, expect_status,
             expect_hits):
    FakeOllama.fail_times = fail_times
    FakeOllama.other_error = other_error
    FakeOllama.hits = 0

    up, up_port = start(ThreadingHTTPServer, FakeOllama)
    mod = load_proxy(up_port, retries)
    px, px_port = start(ThreadingHTTPServer, mod.Handler)
    try:
        status, _ = post(px_port, {"model": "m", "input": "hi", "stream": False})
    finally:
        px.shutdown()
        up.shutdown()

    ok = (status == expect_status) and (FakeOllama.hits == expect_hits)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    print(f"         status={status} (期待 {expect_status}) / "
          f"上流アクセス {FakeOllama.hits} 回 (期待 {expect_hits})")
    return ok


def main() -> int:
    print("32_codex_tool_proxy.py 再送ロジックの検証 (ollama#17638)")
    results = [
        # 2 回失敗 -> 3 回目で成功。retries=3 なので届く
        run_case("一時的な #17638 の 500 から回復する",
                 fail_times=2, retries=3, expect_status=200, expect_hits=3),
        # 一度も失敗しない -> 再送しない
        run_case("正常時は再送しない",
                 fail_times=0, retries=3, expect_status=200, expect_hits=1),
        # 常に失敗 -> 初回 + 再送 3 回 = 4 回で諦め、500 を客に返す
        run_case("再送しきったら 500 を返す",
                 fail_times=99, retries=3, expect_status=500, expect_hits=4),
        # #17638 以外のエラーは再送しない（投げ直しても同じなので）
        run_case("関係ない 500 は再送しない",
                 fail_times=0, retries=3,
                 other_error=(500, {"error": "out of memory"}),
                 expect_status=500, expect_hits=1),
        run_case("400 は再送しない",
                 fail_times=0, retries=3,
                 other_error=(400, {"error": "bad request"}),
                 expect_status=400, expect_hits=1),
        # 再送を無効化できる
        run_case("CODEX_PROXY_TOOLCALL_RETRIES=0 で再送しない",
                 fail_times=99, retries=0, expect_status=500, expect_hits=1),
    ]
    print()
    if all(results):
        print(f"すべて成功 ({len(results)}/{len(results)})")
        return 0
    print(f"失敗あり ({sum(results)}/{len(results)})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
