#!/usr/bin/env bash
# 30_code_server.sh - code-server を導入し、Cline 拡張を入れて起動する（冪等）
#
# ここでは 127.0.0.1 にしかバインドしない。ブラウザからの到達手段は
# 40_/41_/42_ の公開スクリプトが担当する（責務を分離しておくと経路を差し替えやすい）。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

CS_LOG="$LOGDIR/code-server.log"
CS_CONFIG_DIR="$HOME/.config/code-server"
CS_USER_DIR="$HOME/.local/share/code-server/User"

hdr "1. code-server の導入"
if have code-server; then
  ok "導入済み: $(code-server --version 2>&1 | head -1)"
else
  log "code-server をインストールします（1〜2 分）"
  curl -fsSL https://code-server.dev/install.sh | sh
  have code-server || die "code-server のインストールに失敗しました"
  ok "インストール完了: $(code-server --version 2>&1 | head -1)"
fi

hdr "2. パスワードの生成"
# 経路 B/C では公開 URL になる。認証なしで出すのは論外。
if [ -f "$CS_PASSWORD_FILE" ]; then
  ok "既存のパスワードを再利用します"
else
  python3 -c 'import secrets;print(secrets.token_urlsafe(18))' >"$CS_PASSWORD_FILE"
  chmod 600 "$CS_PASSWORD_FILE"
  ok "パスワードを生成しました"
fi
CS_PASSWORD="$(cat "$CS_PASSWORD_FILE")"

mkdir -p "$CS_CONFIG_DIR"
cat >"$CS_CONFIG_DIR/config.yaml" <<EOF
bind-addr: $CS_BIND
auth: password
password: $CS_PASSWORD
cert: false
disable-telemetry: true
disable-update-check: true
EOF
ok "設定を書き込みました: $CS_CONFIG_DIR/config.yaml"

hdr "3. Cline 拡張の導入"
# code-server の既定マーケットプレイスは Open VSX。
# Cline は saoudrizwan.claude-dev として Open VSX に公開されている。
if code-server --list-extensions 2>/dev/null | grep -qix "$CLINE_EXT_ID"; then
  ok "導入済み: $CLINE_EXT_ID"
else
  log "Open VSX から $CLINE_EXT_ID を導入します"
  code-server --install-extension "$CLINE_EXT_ID" \
    || die "Cline の導入に失敗しました。
       Open VSX に到達できているか確認してください:
         curl -I https://open-vsx.org/api/saoudrizwan/claude-dev/latest
       手動導入する場合:
         curl -L -o /tmp/cline.vsix \\
           \"\$(curl -s https://open-vsx.org/api/saoudrizwan/claude-dev/latest | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"files\"][\"download\"])')\"
         code-server --install-extension /tmp/cline.vsix"
  ok "Cline を導入しました"
fi

# 補助拡張（任意）。失敗しても続行する。
for ext in ms-python.python; do
  code-server --list-extensions 2>/dev/null | grep -qix "$ext" && continue
  code-server --install-extension "$ext" >/dev/null 2>&1 \
    && ok "補助拡張を導入: $ext" || warn "補助拡張の導入に失敗（無視）: $ext"
done

hdr "4. エディタ設定の投入"
mkdir -p "$CS_USER_DIR"
# Cline の API プロバイダ設定は拡張側の状態 DB に入るため、ここからは書けない。
# ここで入れるのは、Cline を local LLM で使うときに効くエディタ側の設定のみ。
cat >"$CS_USER_DIR/settings.json" <<'EOF'
{
  "workbench.colorTheme": "Default Dark Modern",
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoUpdate": false,
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 1000,
  "editor.formatOnSave": false,
  "terminal.integrated.defaultProfile.linux": "bash",
  "git.enabled": true,
  "git.autofetch": false,
  "security.workspace.trust.enabled": false
}
EOF
ok "settings.json を書き込みました"

# 動作確認用のワークスペースを用意しておく（空フォルダを開くと Cline が困る）
if [ ! -f "$WORKSPACE/README.md" ]; then
  cat >"$WORKSPACE/README.md" <<'EOF'
# Colab T4 + Cline ワークスペース

このフォルダは Colab VM 上の作業用ディレクトリです。
**セッションが切れると消えます。** 残したいものは git push するか Drive に置いてください。

Cline の動作確認プロンプト例:
  「fizzbuzz.py を作って、1〜30 の FizzBuzz を出力して、実際に実行して結果を見せて」
EOF
  ok "ワークスペースを初期化しました: $WORKSPACE"
fi

hdr "5. 起動"
if port_open 127.0.0.1 "$CS_PORT"; then
  ok "既にポート $CS_PORT で待ち受けています"
else
  start_bg code-server "$CS_LOG" \
    code-server --config "$CS_CONFIG_DIR/config.yaml" "$WORKSPACE"
  wait_http "http://127.0.0.1:$CS_PORT/healthz" 90 "code-server" \
    || die "起動しませんでした。ログ: $CS_LOG"
fi

hdr "完了"
cat <<EOF
    code-server : http://127.0.0.1:$CS_PORT  （VM 内部のみ）
    ワークスペース : $WORKSPACE
    ログ         : $CS_LOG

    ${_c_bold}パスワード: $CS_PASSWORD${_c_reset}
      （$CS_PASSWORD_FILE にも保存済み）

    次はブラウザからの到達手段を選んでください:
      ./40_expose_proxyport.py   経路A  Colab 内蔵プロキシ（外部トンネル無し / WebSocket 要検証）
      ./42_expose_cloudflared.sh 経路C  Cloudflare Quick Tunnel（確実に通るが規約リスク最大）
    経路B（VS Code Remote Tunnel）は code-server を使いません: ./41_expose_tunnel.sh
EOF
