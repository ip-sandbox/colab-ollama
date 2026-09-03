#!/usr/bin/env bash
# 42_expose_cloudflared.sh - 経路C: Cloudflare Quick Tunnel で code-server を公開する
#
# 一番確実に動く。WebSocket も素通りする。アカウント登録も不要。
# その代わり Colab の禁止事項に一番はっきり当たる:
#   「リモートプロキシへの接続」「Colab との相互作用的コンピューティングに
#     関係のないウェブサービス」
# 使うかどうかは手順書 §3 のリスク表を読んで自分で決めること。
#
# セキュリティ: trycloudflare.com の URL は推測されにくいだけで、公開 URL です。
# 30_code_server.sh がパスワード認証を有効にしているので、auth: none に
# 書き換えたりしないこと。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

CF_LOG="$LOGDIR/cloudflared.log"
CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"

hdr "0. 前提の確認"
port_open 127.0.0.1 "$CS_PORT" \
  || die "127.0.0.1:$CS_PORT が開いていません。先に 30_code_server.sh を実行してください。"

# 認証なしで外に出す事故を防ぐ
if grep -qE '^\s*auth:\s*none' "$HOME/.config/code-server/config.yaml" 2>/dev/null; then
  die "code-server が auth: none になっています。公開 URL に晒すのは危険なので中止します。
     30_code_server.sh を実行し直してパスワード認証に戻してください。"
fi
ok "code-server はパスワード認証で動いています"

hdr "1. cloudflared の取得"
if [ -x "$CF_BIN" ]; then
  ok "取得済み: $($CF_BIN --version 2>&1 | head -1)"
else
  log "cloudflared をダウンロードします"
  curl -fL --retry 3 \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o "$CF_BIN"
  chmod +x "$CF_BIN"
  ok "取得しました: $($CF_BIN --version 2>&1 | head -1)"
fi

hdr "2. Quick Tunnel の起動"
: >"$CF_LOG"
start_bg cloudflared "$CF_LOG" \
  "$CF_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:$CS_PORT"

log "公開 URL の発行を待っています（最大 60 秒）"
PUBLIC_URL=""
for _ in $(seq 1 60); do
  PUBLIC_URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" | head -1 || true)"
  [ -n "$PUBLIC_URL" ] && break
  sleep 1
done

[ -n "$PUBLIC_URL" ] || die "URL を取得できませんでした。ログ: $CF_LOG"

echo "$PUBLIC_URL" >"$STATEDIR/cloudflared-url.txt"

hdr "完了"
CS_PASSWORD="$(cat "$CS_PASSWORD_FILE" 2>/dev/null || echo '(30_code_server.sh を実行してください)')"
cat <<EOF
    ${_c_bold}$PUBLIC_URL${_c_reset}

    パスワード: $CS_PASSWORD

    ブラウザで開いたら:
      1. パスワードを入力
      2. Cline アイコン（サイドバー）を開く
      3. 設定:
           API Provider   : Ollama
           Base URL       : $OLLAMA_BASE_URL
           Model ID       : $CLINE_MODEL
           Context Window : $NUM_CTX
           Request Timeout: 180000
           Use Compact Prompt : ON

    注意:
      - この URL はセッションごとに変わります
      - cloudflared を止めると即座に到達不能になります: ./99_teardown.sh
      - ログ: $CF_LOG
EOF
