#!/usr/bin/env bash
# remote/03_setup.sh - VM 上で 00_setup_all.sh を走らせる（切断耐性つき）
#
# Ollama の導入とモデルの pull で 10〜20 分かかる。素朴に ssh の前景で流すと、
# 途中で接続が切れた時点で全部やり直しになる。
#
# そこで VM 側では nohup で切り離して走らせ、手元は tail -f でログを眺めるだけに
# する。手元が切れてもセットアップは VM 上で走り続け、もう一度このスクリプトを
# 叩けば走っているものに合流する。
#
# モデルの切り替えは MODEL_PROFILE（未実装の間は BASE_MODEL）で行う:
#   BASE_MODEL=gpt-oss:20b NUM_CTX=16384 bash remote/03_setup.sh

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_colab_version
require_session
write_ssh_config

SETUP_LOG="$REMOTE_LOGDIR/setup.log"
SETUP_PID="$REMOTE_LOGDIR/setup.pid"
SENTINEL="__SETUP_EXIT__"

# VM 側に渡す環境変数。指定されたものだけを通す（未指定なら VM 側の既定に任せる）。
PASS_ENV=""
for v in MODEL_PROFILE BASE_MODEL CLINE_MODEL NUM_CTX NUM_PREDICT \
         CODEX_TOOL_REPAIR CLINE_PROVIDER; do
  if [ -n "${!v:-}" ]; then
    PASS_ENV="$PASS_ENV $v=$(printf '%q' "${!v}")"
    log "VM へ渡す: $v=${!v}"
  fi
done
[ -n "$PASS_ENV" ] || log "環境変数の指定なし（VM 側の既定値で動きます）"

hdr "1. 既に走っていないか"
# pidfile ではなくプロセスの実体を見る。pidfile の書き込みに失敗しても
# セットアップ自体は走っていることがあり（実機で踏んだ）、pidfile だけを
# 信じると二重起動して pull とインストールがぶつかる。
#
# ★ パターンの先頭を [0] にしているのは pgrep -f の自己マッチ避け。
#   ssh 越しに走らせると、pgrep を含むリモートシェルのコマンドラインにも
#   "00_setup_all.sh" という文字列が載るため、素直に書くと pgrep が
#   自分自身を拾って「常に走行中」になる（実機で踏んだ）。
#   [0]0_... と書けばパターン文字列と被らないので自己マッチしない。
if rsh "pgrep -f '[0]0_setup_all\.sh' >/dev/null 2>&1"; then
  ok "セットアップは既に走っています。ログに合流します。"
  ALREADY=1
else
  ALREADY=0
fi

if [ "$ALREADY" -eq 0 ]; then
  hdr "2. VM 上で起動（nohup で切り離し）"
  warn "10〜20 分かかります。手元の接続が切れても VM 側は走り続けます。"
  # setsid + nohup で親から切り離す。scripts/common.sh の start_bg() と同じ考え方。
  # 終了時にセンチネルと終了コードをログへ落とし、手元はそれを見て完了を判定する。
  # ★ 区切りは必ず ';' にすること。'A && B && C & echo $!' と書くと、
  #   '&' はチェーン全体にかかるので mkdir が終わる前に echo が走り、
  #   「$REMOTE_LOGDIR/setup.pid: No such file or directory」で落ちる（実機で踏んだ）。
  #   バックグラウンドにしたいのは setsid の行だけ。
  rsh "mkdir -p '$REMOTE_LOGDIR'; \
       cd '$REMOTE_ROOT' || exit 1; \
       rm -f '$SETUP_LOG'; \
       setsid nohup bash -c '$PASS_ENV bash scripts/00_setup_all.sh --with-codex \
         >>\"$SETUP_LOG\" 2>&1; echo \"$SENTINEL=\$?\" >>\"$SETUP_LOG\"' \
         >/dev/null 2>&1 & \
       echo \$! > '$SETUP_PID'" \
    || die "セットアップを起動できませんでした"
  ok "起動しました（pid は VM 上の $SETUP_PID）"
fi

hdr "3. ログ"
log "Ctrl-C で見るのをやめても、VM 側の処理は止まりません。"
log "再度見るには、このスクリプトをもう一度実行してください。"
echo
# sed /SENTINEL/q はセンチネル行を出力してから終了する。tail は SIGPIPE で落ちる。
rsh "tail -n +1 -f '$SETUP_LOG' 2>/dev/null" | sed "/$SENTINEL/q" || true

hdr "4. 結果"
EXIT_LINE="$(rsh "grep -h '$SENTINEL' '$SETUP_LOG' 2>/dev/null | tail -1" || true)"
if [ -z "$EXIT_LINE" ]; then
  warn "まだ終わっていないようです。もう一度このスクリプトを実行して合流してください。"
  exit 0
fi
SETUP_RC="${EXIT_LINE#*=}"
if [ "$SETUP_RC" != "0" ]; then
  die "セットアップが失敗しました（終了コード $SETUP_RC）。
     ログ全体:
         bash remote/common.sh -c 'cat $SETUP_LOG'"
fi
ok "セットアップ完了"

hdr "5. 出来上がりの確認"
rsh "echo '    ollama list:'; ollama list 2>/dev/null | sed 's/^/      /'; \
     echo; echo '    VRAM:'; nvidia-smi --query-gpu=memory.total,memory.used,memory.free \
       --format=csv,noheader | sed 's/^/      /'; \
     echo; echo '    codex:'; (codex --version 2>&1 || echo 'なし') | sed 's/^/      /'"

hdr "6. ベンチ結果（この構成でいちばん重要な数字）"
rsh "cat /content/.cline-env/bench-summary.txt 2>/dev/null" || warn "ベンチ結果が読めませんでした"

hdr "完了"
cat <<EOF
    次: bash remote/04_attach.sh   （VM のシェルに入って codex を起動）

    ${_c_bold}終わったら必ず:${_c_reset}  bash remote/09_stop.sh
EOF
