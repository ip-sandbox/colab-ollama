#!/usr/bin/env python3
"""
40_expose_proxyport.py - 経路A: Colab 内蔵ポートプロキシで code-server を開く

外部トンネル(ngrok/cloudflared/dev tunnels)を一切使わない唯一の経路。
Google 自身が提供する仕組みだけで完結するため、規約上いちばん摩擦が小さい。

ただし code-server は WebSocket 常時接続を前提としており、
Colab のポートプロキシが WebSocket をそのまま通すかは公式に明言されていない。
**このスクリプトは「通るかどうかを確かめる」ためのものでもある。**

必ず Colab のノートブックセルから実行すること。
（google.colab モジュールはノートブックカーネル内にしか無い）

    !python /content/colab-cline/scripts/40_expose_proxyport.py
    ではなく、セルに以下を貼って実行:

    exec(open('/content/colab-cline/scripts/40_expose_proxyport.py').read())
"""

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

PORT = int(os.environ.get("CS_PORT", "8080"))
STATEDIR = os.environ.get("STATEDIR", "/content/.cline-env")
PASSWORD_FILE = os.path.join(STATEDIR, "code-server-password.txt")


def _fail(msg: str) -> None:
    print(f"[FATAL] {msg}", file=sys.stderr)
    raise SystemExit(1)


def port_is_open(port: int) -> bool:
    s = socket.socket()
    s.settimeout(1.0)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def main() -> None:
    print("=== 経路A: Colab 内蔵ポートプロキシ ===\n")

    # --- 1. code-server が上がっているか -----------------------------------
    if not port_is_open(PORT):
        _fail(
            f"127.0.0.1:{PORT} が開いていません。先に 30_code_server.sh を実行してください。"
        )
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/healthz", timeout=5) as r:
            body = json.loads(r.read().decode())
        print(f"[  OK] code-server 応答: {body}")
    except (urllib.error.URLError, ValueError, TimeoutError) as e:
        print(f"[WARN] /healthz が読めませんでした（続行）: {e}")

    # --- 2. Colab 環境か ----------------------------------------------------
    try:
        from google.colab.output import eval_js  # type: ignore
    except ImportError:
        _fail(
            "google.colab が import できません。\n"
            "       このスクリプトは Colab の**ノートブックセル内**でしか動きません。\n"
            "       セルに次を貼って実行してください:\n"
            f"         exec(open('{os.path.abspath(__file__)}').read())"
        )

    # --- 3. プロキシ URL の発行 --------------------------------------------
    print("[INFO] プロキシ URL を発行します…")
    url = eval_js(f"google.colab.kernel.proxyPort({PORT}, {{cache: false}})")
    if not url:
        _fail(
            "proxyPort が空を返しました。\n"
            "       ノートブックのタブが閉じている / 出力がクリアされていると失敗します。"
        )
    url = url.rstrip("/")

    # --- 4. パスワードの表示 ------------------------------------------------
    password = None
    if os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, encoding="utf-8") as f:
            password = f.read().strip()

    print("\n" + "=" * 68)
    print("  ブラウザで開く URL:")
    print(f"    {url}")
    if password:
        print("\n  code-server パスワード:")
        print(f"    {password}")
    print("=" * 68)

    # --- 5. WebSocket 検証の案内 -------------------------------------------
    print(
        """
[ 動作確認のしかた ]

  URL を開いて、次のどれになるかで判定します。

  A) パスワード入力 → VS Code の画面が出て、ファイルツリーが操作できる
       -> WebSocket が通っています。経路A で成立。そのまま Cline を設定してください。

  B) パスワードは通るが「Setting up your workspace...」から進まない
     / 画面左下に "Disconnected" が出続ける / 灰色のまま固まる
       -> WebSocket が通っていません。経路A は不成立です。
          経路B(41_expose_tunnel.sh) か経路C(42_expose_cloudflared.sh) に切り替えてください。

  C) 403 / 404 が返る
       -> プロキシ URL の発行に失敗しています。ノートブックのタブを開き直し、
          このセルを再実行してください（URL はセッションに紐づきます）。

  ブラウザの DevTools > Network > WS タブを開くと、
  wss:// の接続が 101 Switching Protocols になっているかを直接確認できます。
  101 にならず 400/502 で落ちていれば B です。
"""
    )

    # --- 6. 判定を記録 ------------------------------------------------------
    os.makedirs(STATEDIR, exist_ok=True)
    with open(os.path.join(STATEDIR, "proxyport-url.txt"), "w", encoding="utf-8") as f:
        f.write(url + "\n")

    # インラインでも開けるように iframe を出す（同一ページ内なので確認が速い）
    try:
        from google.colab import output as _colab_output  # type: ignore

        print("[INFO] 下にインライン表示を試みます（別タブでも開けます）")
        time.sleep(1)
        _colab_output.serve_kernel_port_as_iframe(PORT, height=800)
    except Exception as e:  # noqa: BLE001 - 表示できなくても致命的ではない
        print(f"[WARN] インライン表示は失敗しました（別タブで URL を開いてください）: {e}")


if __name__ == "__main__":
    main()
