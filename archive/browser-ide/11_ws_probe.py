#!/usr/bin/env python3
"""
11_ws_probe.py - 経路A の成否を 2 分で判定する（V-1 の検証）

code-server を入れてから「WebSocket が通らないので経路A は無理でした」と
分かるのは時間の無駄です。先にこれで確かめます。

やっていること:
  1. 極小の HTTP + WebSocket エコーサーバを起動する（依存ライブラリ無し・標準ライブラリのみ）
  2. google.colab.kernel.proxyPort でその URL を発行する
  3. Colab の出力セル内の JavaScript から wss:// でその URL に繋ぎ、
     エコーが返るかをブラウザ上で判定して画面に表示する

Colab の**ノートブックセル**で実行してください:

    exec(open('/content/colab-cline/scripts/11_ws_probe.py').read())
"""

import base64
import hashlib
import os
import socket
import struct
import sys
import threading

PROBE_PORT = int(os.environ.get("PROBE_PORT", "8799"))
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

_HTML = b"""<!doctype html><meta charset=utf-8>
<title>ws probe</title>
<body style="font:14px system-ui;padding:20px">
<h3>WebSocket probe</h3><pre id=out>connecting...</pre>
<script>
const out = document.getElementById('out');
const url = location.origin.replace(/^http/, 'ws') + location.pathname.replace(/\\/$/, '') + '/ws';
out.textContent = 'connecting to ' + url + ' ...';
const ws = new WebSocket(url);
const t = setTimeout(() => { out.textContent = 'TIMEOUT: no response in 10s -> WebSocket is BLOCKED'; ws.close(); }, 10000);
ws.onopen  = () => ws.send('ping');
ws.onmessage = (e) => { clearTimeout(t); out.textContent = 'RESULT: ' + (e.data === 'ping' ? 'OK - WebSocket works' : 'unexpected: ' + e.data); ws.close(); };
ws.onerror = () => { clearTimeout(t); out.textContent = 'RESULT: NG - WebSocket handshake failed (blocked by the proxy)'; };
</script>
"""


def _ws_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def _read_frame(conn) -> bytes | None:
    hdr = conn.recv(2)
    if len(hdr) < 2:
        return None
    length = hdr[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", conn.recv(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", conn.recv(8))[0]
    mask = conn.recv(4) if hdr[1] & 0x80 else None
    data = bytearray()
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            break
        data += chunk
    if mask:
        data = bytearray(b ^ mask[i % 4] for i, b in enumerate(data))
    return bytes(data)


def _write_frame(conn, payload: bytes) -> None:
    n = len(payload)
    if n < 126:
        conn.sendall(b"\x81" + bytes([n]) + payload)
    else:
        conn.sendall(b"\x81\x7e" + struct.pack(">H", n) + payload)


def _handle(conn) -> None:
    try:
        raw = conn.recv(8192).decode("latin-1")
        if not raw:
            return
        headers = {}
        for line in raw.split("\r\n")[1:]:
            if ": " in line:
                k, v = line.split(": ", 1)
                headers[k.lower()] = v
        path = raw.split(" ", 2)[1] if " " in raw else "/"

        if "sec-websocket-key" in headers:
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: " + _ws_accept(headers["sec-websocket-key"]).encode()
                + b"\r\n\r\n"
            )
            print(f"[probe] WebSocket handshake OK  path={path}")
            while True:
                msg = _read_frame(conn)
                if msg is None:
                    break
                print(f"[probe] recv={msg!r} -> echo")
                _write_frame(conn, msg)
        else:
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                b"Cache-Control: no-store\r\n"
                b"Content-Length: " + str(len(_HTML)).encode() + b"\r\n\r\n" + _HTML
            )
    except OSError:
        pass
    finally:
        conn.close()


def _serve(port: int) -> None:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    print(f"[probe] listening on 127.0.0.1:{port}")
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=_handle, args=(conn,), daemon=True).start()


def main() -> None:
    threading.Thread(target=_serve, args=(PROBE_PORT,), daemon=True).start()

    try:
        from google.colab import output  # type: ignore
    except ImportError:
        print(
            "[FATAL] google.colab が import できません。\n"
            "        Colab のノートブックセルで実行してください:\n"
            f"          exec(open('{os.path.abspath(__file__)}').read())",
            file=sys.stderr,
        )
        raise SystemExit(1)

    url = output.eval_js(f"google.colab.kernel.proxyPort({PROBE_PORT}, {{cache: false}})")
    print(f"[probe] proxy URL = {url}")
    print(
        "\n下の枠に RESULT が出ます:\n"
        "  'OK - WebSocket works'  -> 経路A は成立。30_code_server.sh + 40_expose_proxyport.py へ\n"
        "  'NG' / 'TIMEOUT'        -> 経路A は不成立。経路B(41_) か経路C(42_) を使ってください\n"
    )
    output.serve_kernel_port_as_iframe(PROBE_PORT, height=220)


if __name__ == "__main__":
    main()
