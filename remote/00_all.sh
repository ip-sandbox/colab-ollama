#!/usr/bin/env bash
# remote/00_all.sh - 手元から VM 構築までを一括で通すラッパー（冪等）
#
# VM 側の scripts/00_setup_all.sh と対になる、手元側の一括実行スクリプト。
# 中身は remote/NN_*.sh を順番に呼ぶだけで、ロジックの重複は無い。
#
#   00_doctor -> 01_new -> 02_deploy -> 03_setup -> [04_attach | 評価] -> [09_stop]
#
# ★ 既定では最後に VM を止めない。止めてしまうと Codex を使えないため。
#   使い終わったら必ず  bash remote/09_stop.sh  を実行すること。
#   放置すると 24 時間キープアライブが回り続けて課金される。
#   無人で回す場合は --stop を付けること。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

ATTACH=0
DO_STOP=0
EVAL_RUNS=0
EVAL_PROMPT="pythonでfizzbuzzを書いてテストして。"
SKIP_DOCTOR=0

usage() {
  cat <<'EOF'
使い方: bash remote/00_all.sh [オプション]

  --gpu VALUE          確保するアクセラレータ（既定 T4。GPU 無しは cpu）
  --retry N            確保に失敗したとき N 回まで再試行する（既定 0）
                       T4 は無料枠では取り合いで 503 が普通に返るため、
                       T4 を狙うなら --retry 10 などを付けると通りやすい
  --profile NAME       MODEL_PROFILE（qwen3-8b / qwen3-14b / gpt-oss-20b /
                       qwen25-coder-14b）。省略時は VM 側の既定値
  --attach             セットアップ後そのまま codex TUI に入る
  --eval N             評価タスクを N 回走らせて結果を表で出す（非対話）
  --prompt TEXT        --eval で投げるプロンプト
                       既定: "pythonでfizzbuzzを書いてテストして。"
  --stop               最後に VM を止める（無人実行するなら必須）
  --skip-doctor        前提チェックを飛ばす（2 回目以降の実行で速くなる）
  -h, --help           このヘルプ

例:

  # T4 が空くまで待って gpt-oss を構築し、そのまま codex に入る
  bash remote/00_all.sh --gpu T4 --retry 10 --profile gpt-oss-20b --attach

  # 無人で評価だけ回して必ず止める
  bash remote/00_all.sh --retry 10 --profile gpt-oss-20b --eval 5 --stop

  # GPU が取れないときの退避（大きいモデルは載らない）
  bash remote/00_all.sh --gpu cpu

環境変数でも同じことができる（COLAB_GPU / MODEL_PROFILE / COLAB_SESSION など）。
詳細は docs/リモート運用ガイド.md を参照。
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --gpu)       COLAB_GPU="${2:?--gpu には値が必要です}"; shift 2 ;;
    --gpu=*)     COLAB_GPU="${1#*=}"; shift ;;
    --retry)     COLAB_NEW_RETRIES="${2:?--retry には回数が必要です}"; shift 2 ;;
    --retry=*)   COLAB_NEW_RETRIES="${1#*=}"; shift ;;
    --profile)   MODEL_PROFILE="${2:?--profile には値が必要です}"; shift 2 ;;
    --profile=*) MODEL_PROFILE="${1#*=}"; shift ;;
    --prompt)    EVAL_PROMPT="${2:?--prompt には値が必要です}"; shift 2 ;;
    --prompt=*)  EVAL_PROMPT="${1#*=}"; shift ;;
    --eval)      EVAL_RUNS="${2:?--eval には回数が必要です}"; shift 2 ;;
    --eval=*)    EVAL_RUNS="${1#*=}"; shift ;;
    --attach)    ATTACH=1; shift ;;
    --stop)      DO_STOP=1; shift ;;
    --skip-doctor) SKIP_DOCTOR=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) printf '不明なオプション: %s（--help を参照）\n' "$1" >&2; exit 2 ;;
  esac
done

export COLAB_GPU MODEL_PROFILE COLAB_NEW_RETRIES

# 引数の誤りは VM を作る前に弾く。die() は「VM が残っているかも」と停止を促すが、
# この時点では VM は存在しないので誤誘導になる。専用の出口を使う。
usage_error() {
  printf '%s[引数エラー]%s %s\n\n' "$_c_red" "$_c_reset" "$*" >&2
  printf '    bash remote/00_all.sh --help\n\n' >&2
  exit 2
}

case "$EVAL_RUNS" in
  ''|*[!0-9]*) usage_error "--eval には数値を指定してください: $EVAL_RUNS" ;;
esac
case "${COLAB_NEW_RETRIES:-0}" in
  ''|*[!0-9]*) usage_error "--retry には数値を指定してください: $COLAB_NEW_RETRIES" ;;
esac
if [ "$ATTACH" -eq 1 ] && [ "$EVAL_RUNS" -gt 0 ]; then
  usage_error "--attach と --eval は同時に使えません（対話と非対話で排他）"
fi

# プロファイル名も手元で検証する。VM を確保してから typo で落ちると
# 10 分と課金を無駄にするため。一覧は scripts/common.sh と揃えること。
case "${MODEL_PROFILE:-}" in
  ""|qwen3-8b|qwen3-14b|gpt-oss-20b|qwen25-coder-14b) ;;
  *) usage_error "--profile が不正です: $MODEL_PROFILE
    使えるもの: qwen3-8b / qwen3-14b / gpt-oss-20b / qwen25-coder-14b" ;;
esac

# アクセラレータ名も同様（colab CLI は未知の値を黙って A100 に読み替える）
require_gpu_valid

SECONDS=0
hdr "リモート一括実行"
log "セッション   : $COLAB_SESSION"
log "アクセラレータ: $COLAB_GPU（再試行 ${COLAB_NEW_RETRIES:-0} 回）"
log "プロファイル : ${MODEL_PROFILE:-（VM 側の既定値）}"
log "終了時の停止 : $([ "$DO_STOP" -eq 1 ] && echo する || echo しない)"

# 途中で失敗しても「VM が残っているかもしれない」ことを必ず伝える。
# 停止忘れがこの構成でいちばん高くつく事故なので、出口を一本化する。
_finish() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\n%s[中断]%s 途中で失敗しました (exit=%s)。\n' \
           "$_c_yellow" "$_c_reset" "$rc" >&2
    printf '    VM が起動したままかもしれません。確認と停止:\n' >&2
    printf '        %s sessions\n' "$(colab_cmd_str)" >&2
    printf '        bash remote/09_stop.sh\n\n' >&2
  fi
  return "$rc"
}
trap _finish EXIT

STEP=0
next_step() { STEP=$((STEP + 1)); hdr "[$STEP] $*"; }

if [ "$SKIP_DOCTOR" -eq 0 ]; then
  next_step "前提チェック (00_doctor.sh) — VM は作りません"
  bash "$REMOTE_DIR/00_doctor.sh"
fi

next_step "VM の確保 (01_new.sh)"
bash "$REMOTE_DIR/01_new.sh"

next_step "作業ツリーの転送 (02_deploy.sh)"
bash "$REMOTE_DIR/02_deploy.sh"

next_step "Ollama + モデル + Codex (03_setup.sh) — 10〜20 分"
bash "$REMOTE_DIR/03_setup.sh"

# --- 評価 -------------------------------------------------------------------
if [ "$EVAL_RUNS" -gt 0 ]; then
  next_step "評価タスクを $EVAL_RUNS 回 (codex exec)"
  log "プロンプト: $EVAL_PROMPT"
  # VM 側で完結させる。手元の接続が切れても追えるようにログへ落とす。
  #
  # ★ プロンプトは base64 で渡す。ssh 越しの二重引用の中に日本語や
  #   クォートを含む任意のテキストを埋め込むと壊れやすいため。
  #
  # 判定は「codex が正常終了し、かつ fizzbuzz.py の中身が空でないか」。
  # 手順書 §5.8.1 の「ファイルは作るが中身が空」を取りこぼさないよう、
  # 存在だけでなくサイズを見る（実測で 7 バイトのファイルが作られた例がある）。
  PROMPT_B64="$(printf '%s' "$EVAL_PROMPT" | base64 | tr -d '\n')"
  rsh "set -u
    mkdir -p '$REMOTE_LOGDIR'
    cd '$REMOTE_WORKSPACE' || exit 1
    git init -q 2>/dev/null || true
    P=\$(printf '%s' '$PROMPT_B64' | base64 -d)
    printf '      %-4s %-6s %-7s %s\\n' 試行 結果 所要 生成物
    for i in \$(seq 1 $EVAL_RUNS); do
      rm -f fizzbuzz.py test_fizzbuzz.py
      S=\$(date +%s)
      timeout 600 codex exec --skip-git-repo-check \"\$P\" \
        </dev/null >'$REMOTE_LOGDIR'/eval-\$i.log 2>&1
      RC=\$?
      D=\$(( \$(date +%s) - S ))
      FILES=\$(ls -l fizzbuzz.py test_fizzbuzz.py 2>/dev/null \
                | awk '{printf \"%s(%sB) \", \$9, \$5}')
      SZ=\$(stat -c%s fizzbuzz.py 2>/dev/null || echo 0)
      if [ \"\$RC\" -eq 0 ] && [ \"\$SZ\" -ge 50 ]; then V=OK; else V=NG; fi
      printf '      %-4s %-6s %-7s %s\\n' \"\$i\" \"\$V\" \"\${D}s\" \"\${FILES:-（無し）}\"
    done" || warn "評価の途中で失敗しました（ログ: $REMOTE_LOGDIR/eval-*.log）"

  hdr "修復プロキシの発火状況"
  rsh "grep -c '17638' '$REMOTE_LOGDIR/codex-tool-proxy.log' 2>/dev/null \
         | sed 's/^/      ollama#17638 の再送: /' || true
       grep -c 'repaired' '$REMOTE_LOGDIR/codex-tool-proxy.log' 2>/dev/null \
         | sed 's/^/      harmony 等の修復  : /' || true" || true
fi

# --- 後始末 -----------------------------------------------------------------
if [ "$DO_STOP" -eq 1 ]; then
  next_step "停止と成果物の回収 (09_stop.sh)"
  bash "$REMOTE_DIR/09_stop.sh"
  hdr "完了（所要 ${SECONDS}s）"
  ok "VM は停止しました。課金は止まっています。"
  exit 0
fi

hdr "完了（所要 ${SECONDS}s）"
cat <<EOF
    ${_c_bold}VM は起動したままです。${_c_reset}

    使う:
        bash remote/04_attach.sh codex     codex TUI に入る
        bash remote/04_attach.sh           VM のシェルに入る
        bash remote/common.sh -c 'ollama ps'

    ${_c_bold}${_c_red}終わったら必ず:${_c_reset}  bash remote/09_stop.sh
    （止めない限り 24 時間キープアライブが回り続けて課金されます）
EOF

if [ "$ATTACH" -eq 1 ]; then
  next_step "Codex に入ります (04_attach.sh codex)"
  warn "codex を抜けても VM は止まりません。bash remote/09_stop.sh を忘れずに。"
  exec bash "$REMOTE_DIR/04_attach.sh" codex
fi
