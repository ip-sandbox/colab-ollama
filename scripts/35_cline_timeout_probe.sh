#!/usr/bin/env bash
# 35_cline_timeout_probe.sh - Cline CLI が何秒でリクエストを切るかを実測する
#
# なぜこれがあるか
# ----------------
# 手順書 §7 はこの構成の最大の壁として「Cline CLI は Ollama へのリクエストを
# 30 秒で切り、CLI 側に設定項目が無い（cline#9182 / #9484）」を挙げている。
# そして §7 の対策 6 番と V-4 に、次の **未検証の仮説** が残っている:
#
#     CLINE_PROVIDER=openai-compatible（/v1 経由）なら回避できるかもしれない
#
# これを確かめるのに実モデルは要らない。要るのは「応答に N 秒かかる上流」だけで、
# それは scripts/test_slow_upstream_stub.py で作れる。むしろスタブのほうが良い:
# 遅延を秒単位で指定できるので、境界をはっきりさせられる。
#
# ★ GPU が要らないので、T4 が取れないときに先へ進める検証の 1 つ（手順書 §13）。
#
# 使い方
# ------
#   bash scripts/35_cline_timeout_probe.sh              # 既定 45 秒の上流で測る
#   PROBE_DELAY_SEC=20 bash scripts/35_cline_timeout_probe.sh
#   PROBE_PROVIDERS="ollama" bash scripts/35_cline_timeout_probe.sh
#
# 環境変数
#   PROBE_DELAY_SEC   上流が応答を返すまでの秒数（既定 45 = 30 秒を確実に超える）
#   PROBE_PROVIDERS   測るプロバイダ（既定 "ollama openai-compatible"）
#   PROBE_MAX_WAIT    1 試行の打ち切り（既定 PROBE_DELAY_SEC + 60）
#   PROBE_PORT        スタブの待受ポート（既定 11434）
#                     ★ ollama プロバイダは接続先を設定できず常に
#                       127.0.0.1:11434 を見るので、既定から変えると
#                       そちらは測れない

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE_DELAY_SEC="${PROBE_DELAY_SEC:-45}"
PROBE_PROVIDERS="${PROBE_PROVIDERS:-ollama openai-compatible}"
PROBE_MAX_WAIT="${PROBE_MAX_WAIT:-$((PROBE_DELAY_SEC + 60))}"
PROBE_PORT="${PROBE_PORT:-11434}"
PROBE_DIR="$STATEDIR/cline-timeout"
STUB_LOG="$LOGDIR/slow-upstream-stub.log"
RESULT_TSV="$PROBE_DIR/results.tsv"

mkdir -p "$PROBE_DIR"

hdr "0. 前提の確認"
have cline || die "cline がありません。先に 30_cline_cli.sh を実行してください
     （このプローブだけなら  npm install -g cline  でも足ります）。"
ok "cline: $(first_line cline --version)"

# ★ 本物の ollama serve が 11434 を掴んでいると、スタブが起動できない。
#   気付かずに進むと「本物の ollama に投げて速く返ってきた」結果を
#   タイムアウトの実測だと誤読することになる。必ず先に弾く。
if port_open 127.0.0.1 "$PROBE_PORT" 2>/dev/null; then
  die "ポート $PROBE_PORT が既に使われています。
     本物の ollama serve が動いているなら、先に止めてください:
       bash scripts/99_teardown.sh --all
     測り終えたら 20_ollama.sh で戻せます。"
fi
ok "ポート $PROBE_PORT は空いています"

# --- 元の設定を退避する ----------------------------------------------------
# このスクリプトは cline auth でプロバイダ設定を書き換える。測り終えたら
# 必ず元に戻す。戻し忘れると、次に cline を使ったときスタブを向いたままになる。
PROVIDERS_JSON="$(cline_providers_json)"
BACKUP=""
if [ -f "$PROVIDERS_JSON" ]; then
  BACKUP="$PROBE_DIR/providers.json.bak"
  cp "$PROVIDERS_JSON" "$BACKUP"
  log "既存の cline 設定を退避しました: $BACKUP"
fi

cleanup() {
  stop_bg slow-upstream-stub 2>/dev/null || true
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    mkdir -p "$(dirname "$PROVIDERS_JSON")"
    cp "$BACKUP" "$PROVIDERS_JSON"
    log "cline の設定を元に戻しました"
  fi
}
trap cleanup EXIT

hdr "1. 遅い上流スタブの起動（応答まで ${PROBE_DELAY_SEC}s）"
STUB_PORT="$PROBE_PORT" STUB_DELAY_SEC="$PROBE_DELAY_SEC" \
STUB_MODEL="$CLINE_MODEL" STUB_LOG="$PROBE_DIR/requests.jsonl" \
  start_bg slow-upstream-stub "$STUB_LOG" \
  python3 "$SCRIPT_DIR/test_slow_upstream_stub.py"
wait_http "http://127.0.0.1:$PROBE_PORT/api/tags" 20 "slow-upstream-stub" \
  || die "スタブが起動しませんでした。ログ: $STUB_LOG"

hdr "2. 計測"
printf 'provider\telapsed_sec\texit_code\tverdict\n' >"$RESULT_TSV"

# 短くて ASCII だけのプロンプトにする理由:
#   - 日本語をコマンドライン引数で渡すと Cline CLI 3.x は必ず落ちる（§7.2）。
#     ここでは標準入力で渡すので問題ないが、測定対象を増やさないため単純にする
#   - プロンプトが長いと、上流の遅延ではなく Cline 側の前処理時間が混ざる
PROMPT='say ok'

for provider in $PROBE_PROVIDERS; do
  hdr "2.$provider"
  case "$provider" in
    ollama)
      log "cline auth -p ollama -m $CLINE_MODEL -k ollama"
      cline auth -p ollama -m "$CLINE_MODEL" -k ollama \
        >"$PROBE_DIR/auth-$provider.log" 2>&1 \
        || warn "cline auth に失敗しました（ログ: $PROBE_DIR/auth-$provider.log）"
      ;;
    openai-compatible)
      log "cline auth -p openai -m $CLINE_MODEL -b http://127.0.0.1:$PROBE_PORT/v1 -k ollama"
      cline auth -p openai -m "$CLINE_MODEL" \
                 -b "http://127.0.0.1:$PROBE_PORT/v1" -k ollama \
        >"$PROBE_DIR/auth-$provider.log" 2>&1 \
        || warn "cline auth に失敗しました（ログ: $PROBE_DIR/auth-$provider.log）"
      ;;
    *)
      warn "未知のプロバイダなので飛ばします: $provider"
      continue
      ;;
  esac

  RUN_LOG="$PROBE_DIR/run-$provider.log"
  log "投げます（上流は ${PROBE_DELAY_SEC}s 待ってから応答します）"
  START="$(date +%s)"
  set +e
  printf '%s' "$PROMPT" \
    | timeout "$PROBE_MAX_WAIT" cline --cwd "$WORKSPACE" --auto-approve true \
        >"$RUN_LOG" 2>&1
  RC=$?
  set -e
  ELAPSED=$(( $(date +%s) - START ))

  # 判定:
  #   上流の遅延より **明らかに早く** 終わったなら、クライアントが切っている。
  #   遅延より後に終わったなら、最後まで待てている。
  #   境界のゆらぎを吸収するため 3 秒の余裕を見る。
  if [ "$RC" -eq 124 ]; then
    VERDICT="打ち切り(${PROBE_MAX_WAIT}s 到達)"
  elif [ "$ELAPSED" -lt $((PROBE_DELAY_SEC - 3)) ]; then
    VERDICT="タイムアウトあり(${ELAPSED}s で切断)"
  else
    VERDICT="最後まで待てた"
  fi

  printf '%s\t%s\t%s\t%s\n' "$provider" "$ELAPSED" "$RC" "$VERDICT" >>"$RESULT_TSV"
  printf '      %-20s %4ss  exit=%-3s %s\n' "$provider" "$ELAPSED" "$RC" "$VERDICT"

  # タイムアウト由来のメッセージが出ていれば、それも証拠として残す
  if grep -qiE 'timed out|timeout' "$RUN_LOG" 2>/dev/null; then
    printf '      %s\n' "ログ中のタイムアウト表記:"
    grep -iE 'timed out|timeout' "$RUN_LOG" | head -3 | sed 's/^/        /'
  fi
done

hdr "3. 結果"
# column(1) は util-linux 由来で、最小構成のコンテナには入っていないことがある
# （実際に無い環境で落ちた）。整形のためだけに外部コマンドへ依存しない。
awk -F'\t' '{printf "    %-20s %-12s %-10s %s\n", $1, $2, $3, $4}' "$RESULT_TSV"
echo
cat <<EOF
    上流は一律 ${PROBE_DELAY_SEC}s で応答しています。
    それより明らかに早く終わったプロバイダは、Cline 側が切っています。

    生ログ    : $PROBE_DIR/run-*.log
    リクエスト: $PROBE_DIR/requests.jsonl（スタブがどの API を叩かれたか）
    結果 TSV  : $RESULT_TSV

    切れることが確認できたら:
        bash scripts/33_patch_cline_timeout.sh
    を実行してから、このスクリプトをもう一度走らせて差を見てください。
EOF
