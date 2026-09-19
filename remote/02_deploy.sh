#!/usr/bin/env bash
# remote/02_deploy.sh - 手元の作業ツリーを VM に同期する
#
# git clone ではなく手元のツリーをそのまま送る。理由:
#   - 未コミットの変更（まさに今いじっているスクリプト）が乗る
#   - GitHub への到達性やリポジトリ名の綴りに依存しない（手順書 §3.4 の罠）
#   - 15MB 程度なので tar で数秒
#
# 転送は rsync ではなく tar 経由。手元に rsync が無い環境でも動かすため。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_colab_version
require_session
write_ssh_config

hdr "1. 送るもの"
log "ローカル : $REPO_ROOT"
log "VM       : $REMOTE_ROOT"
# .git を除くので、VM 側では git のコミットはできない。
# コードを残したいときは手元で commit/push すること（VM はステートレス）。
SIZE="$(tar -C "$REPO_ROOT" --exclude='.git' --exclude='__pycache__' \
            --exclude='.ssh_config' -czf - . 2>/dev/null | wc -c)"
log "転送サイズ: $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "$SIZE bytes")"

hdr "2. 転送"
rpush "$REPO_ROOT" "$REMOTE_ROOT" \
  || die "転送に失敗しました。ssh が通るか確認してください:
         ssh -F $SSH_CONFIG $SSH_HOST_ALIAS -- 'echo ok'"
ok "転送しました"

hdr "3. VM 側の確認"
rsh "cd '$REMOTE_ROOT' && chmod +x scripts/*.sh 2>/dev/null; \
     echo '    配置先:'; ls -la '$REMOTE_ROOT' | head -20; \
     echo; echo '    scripts/:'; ls '$REMOTE_ROOT/scripts' | sed 's/^/      /'"

# scripts/common.sh が読めることをもって「壊れていない」判定にする。
rsh "bash -c '. \"$REMOTE_ROOT/scripts/common.sh\" && echo \"    BASE_MODEL=\$BASE_MODEL NUM_CTX=\$NUM_CTX CLINE_MODEL=\$CLINE_MODEL\"'" \
  || die "VM 上で scripts/common.sh を読み込めませんでした。転送が壊れています。"
ok "VM 上でスクリプトが読めます"

hdr "完了"
cat <<EOF
    次: bash remote/03_setup.sh
        （Ollama の導入とモデルの取得。10〜20 分かかります）

    ${_c_bold}終わったら必ず:${_c_reset}  bash remote/09_stop.sh
EOF
