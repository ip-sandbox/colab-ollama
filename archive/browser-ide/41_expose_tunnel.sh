#!/usr/bin/env bash
# 41_expose_tunnel.sh - 経路B: VS Code Remote Tunnel で vscode.dev から接続する
#
# code-server は使わない。Microsoft 公式の VS Code CLI が VM 上に
# リモート拡張ホストを立て、ブラウザの vscode.dev がそこに繋がる。
#
# この経路の決定的な利点:
#   - Cline 拡張が「Colab VM 側」で動く。したがって Cline から見た
#     http://127.0.0.1:11434 は VM 上の Ollama そのもの。トンネルを 2 本張る必要がない。
#   - Cline のターミナル実行も VM 上で走る（T4 の GPU がそのまま使える）。
#   - 拡張は本家 VS Code Marketplace から入る（Open VSX の版ずれを気にしなくてよい）。
#
# 代償: Microsoft が運用するトンネルへ常時アウトバウンド接続する。
#       Colab の禁止事項「リモートプロキシへの接続」に真正面から当たる読みがある。
#       手順書 §3 のリスク表を読んでから使うこと。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

TUNNEL_NAME="${TUNNEL_NAME:-colab-t4-cline}"
CLI_DIR="${CLI_DIR:-$STATEDIR/vscode-cli}"
TUNNEL_LOG="$LOGDIR/vscode-tunnel.log"

hdr "1. VS Code CLI の取得"
mkdir -p "$CLI_DIR"
if [ -x "$CLI_DIR/code" ]; then
  ok "取得済み: $CLI_DIR/code"
else
  log "VS Code CLI (cli-alpine-x64) をダウンロードします"
  curl -fL 'https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64' \
       -o "$STATEDIR/vscode_cli.tar.gz"
  tar -xf "$STATEDIR/vscode_cli.tar.gz" -C "$CLI_DIR"
  chmod +x "$CLI_DIR/code"
  ok "展開しました: $($CLI_DIR/code --version 2>&1 | head -1)"
fi

hdr "2. トンネルの起動"
cat <<EOF
    これから GitHub / Microsoft アカウントでのデバイス認証が必要です。

      1. 下に出る URL とコードをブラウザで入力
      2. 認証が通ると "Open this link in your browser" と共に
         https://vscode.dev/tunnel/$TUNNEL_NAME が表示される
      3. その URL をブラウザで開く

    ${_c_bold}このセルは走らせっぱなしにしてください。${_c_reset}
    止めるとトンネルが切れます。

EOF

cat <<EOF
    接続できたら、vscode.dev の画面で次を行ってください:

      1. 拡張機能パネル (Ctrl+Shift+X) で "Cline" を検索して Install
         -> "Install in <$TUNNEL_NAME>" と表示されることを確認する。
            リモート側（= Colab VM）に入らないと Ollama に届きません。
      2. フォルダを開く: $WORKSPACE
      3. Cline の設定:
           API Provider   : Ollama
           Base URL       : $OLLAMA_BASE_URL
           Model ID       : $CLINE_MODEL
           Context Window : $NUM_CTX
           Request Timeout: 180000
           Use Compact Prompt : ON

EOF

# --accept-server-license-terms を付けないと対話プロンプトで止まる。
# トンネルはフォアグラウンドで走らせ続ける（切ると接続が落ちる）。
"$CLI_DIR/code" tunnel \
  --accept-server-license-terms \
  --name "$TUNNEL_NAME" \
  --verbose 2>&1 | tee -a "$TUNNEL_LOG"
