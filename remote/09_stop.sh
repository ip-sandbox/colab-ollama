#!/usr/bin/env bash
# remote/09_stop.sh - VM を止める（課金を止める）
#
# ★ この構成でいちばん高くつく事故は「止め忘れ」です。
#   colab stop しない限り、キープアライブが 24 時間回り続けます。
#
#   bash remote/09_stop.sh              … ログを回収してから停止
#   bash remote/09_stop.sh --no-fetch   … 回収せずに即停止
#   bash remote/09_stop.sh --force      … セッションが無いように見えても stop を試す

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

FETCH=1
FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0 ;;
    --force)    FORCE=1 ;;
    -h|--help)  printf '使い方: bash remote/09_stop.sh [--no-fetch] [--force]\n'; exit 0 ;;
    *) die "不明なオプション: $1" ;;
  esac
  shift
done

require_colab_version

hdr "1. セッションの確認"
if session_exists; then
  ok "'$COLAB_SESSION' が起動しています"
else
  if [ "$FORCE" -eq 0 ]; then
    ok "'$COLAB_SESSION' は起動していません。課金は発生していません。"
    log "サーバ側の一覧:"
    colab_cli sessions 2>&1 | sed 's/^/      /'
    close_ssh_master
    exit 0
  fi
  warn "一覧には見えませんが --force なので stop を試します"
  FETCH=0
fi

if [ "$FETCH" -eq 1 ]; then
  hdr "2. 成果物の回収"
  # VM はステートレス。止めた瞬間に全部消えるので、残す価値があるものは先に取る。
  OUTDIR="$REPO_ROOT/artifacts/$COLAB_SESSION-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OUTDIR"

  for p in "$REMOTE_LOGDIR" /content/.cline-env "$REMOTE_WORKSPACE"; do
    if rsh "[ -e '$p' ]" 2>/dev/null; then
      log "回収: $p"
      rpull "$p" "$OUTDIR" 2>/dev/null || warn "  回収できませんでした: $p"
    fi
  done

  if [ -n "$(ls -A "$OUTDIR" 2>/dev/null)" ]; then
    ok "回収しました: $OUTDIR"
    du -sh "$OUTDIR" 2>/dev/null | sed 's/^/      /'
  else
    rmdir "$OUTDIR" 2>/dev/null || true
    warn "回収するものがありませんでした（VM に入れなかった可能性があります）"
  fi
fi

hdr "3. 停止"
# 多重化ソケットを先に畳む。残したまま VM を落とすと次回 stale ソケットで
# 接続に失敗し、原因が分かりにくい。
close_ssh_master
colab_cli stop -s "$COLAB_SESSION" 2>&1 | sed 's/^/      /' \
  || warn "colab stop がエラーを返しました。下の一覧で実際に消えたか確認してください。"

hdr "4. 確認"
log "サーバ側の一覧:"
colab_cli sessions 2>&1 | sed 's/^/      /'
if session_exists; then
  die "まだ残っています。手動で止めてください:
         $(colab_cmd_str) stop -s $COLAB_SESSION"
fi
ok "停止しました。課金は止まっています。"
