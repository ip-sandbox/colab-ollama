#!/usr/bin/env bash
# 37_codex_timeout_probe.sh - Codex CLI が何秒で切るかを、モデル無しで実測する
#
# なぜこれがあるか
# ----------------
# 35_cline_timeout_probe.sh で Cline は実測した（3.0.62 は 300 秒。手順書 §7 の訂正）。
# **Codex 側は未測定のまま**だった。この構成では Codex がむしろ本命なので、
# 同じ方法で測る。
#
# 測りたいのは 3 つ:
#
#   1. config.toml の stream_idle_timeout_ms（既定 600 秒）が実際に効くか
#   2. 効かない場合、実際には何秒で切られるか
#   3. ★ 修復プロキシを挟むと idle timeout の意味が変わらないか
#
# 3 が実運用に直結する。stream_idle_timeout_ms は「**無通信のまま**何 ms 待つか」で、
# 直結なら Ollama がトークンを吐き始めた時点で計測がリセットされる。ところが
# 修復プロキシ (32_codex_tool_proxy.py) は **上流へ stream:false で投げ、
# 応答が揃うまで何も返さない**。つまりプロキシ経由では
#
#     無通信時間 = 上流の応答時間まるごと
#
# になる。prefill が長い CPU 実行では、直結なら通るものがプロキシ経由で切られる、
# ということが起こりうる。ここを数字で確かめる。
#
# ★ GPU もモデルも要らない（手順書 §13 の L1）。
#
# 使い方
# ------
#   bash scripts/37_codex_timeout_probe.sh
#   PROBE_DELAY_SEC=700 bash scripts/37_codex_timeout_probe.sh
#   PROBE_IDLE_MS=60000 PROBE_DELAY_SEC=90 bash scripts/37_codex_timeout_probe.sh
#
# 環境変数
#   PROBE_DELAY_SEC  上流が応答を返すまでの秒数（既定 60）
#   PROBE_IDLE_MS    config.toml に書く stream_idle_timeout_ms（既定 30000）
#   PROBE_MAX_WAIT   1 試行の打ち切り（既定 PROBE_DELAY_SEC + 120）
#   PROBE_PORT       スタブの待受ポート（既定 11500）
#   PROBE_MODES      測る経路（既定 "direct proxy"）
#   PROBE_STALL      沈黙のさせ方（ttfb = 初回バイトまで待つ / gap = 最初の
#                    イベントを返してから沈黙）。既定 ttfb。
#                    ★ この 2 つで結果が違えば、stream_idle_timeout_ms が
#                      「初回バイトまで」ではなく「イベント間の間隔」だけを
#                      縛っていることになる

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE_DELAY_SEC="${PROBE_DELAY_SEC:-60}"
PROBE_IDLE_MS="${PROBE_IDLE_MS:-30000}"
PROBE_MAX_WAIT="${PROBE_MAX_WAIT:-$((PROBE_DELAY_SEC + 120))}"
PROBE_PORT="${PROBE_PORT:-11500}"
PROBE_MODES="${PROBE_MODES:-direct proxy}"
PROBE_STALL="${PROBE_STALL:-ttfb}"
PROBE_DIR="$STATEDIR/codex-timeout"
RESULT_TSV="$PROBE_DIR/results.tsv"

mkdir -p "$PROBE_DIR"

hdr "0. 前提の確認"
have codex || die "codex がありません。先に入れてください:
     npm install -g @openai/codex
     （このプローブはモデルも Ollama も要りません）"
ok "codex: $(first_line codex --version)"

for p in "$PROBE_PORT" "$CODEX_PROXY_PORT"; do
  if port_open 127.0.0.1 "$p" 2>/dev/null; then
    die "ポート $p が既に使われています。先に止めてください。"
  fi
done
ok "ポート $PROBE_PORT / $CODEX_PROXY_PORT は空いています"

# --- 元の設定を退避 --------------------------------------------------------
CODEX_CFG="$HOME/.codex/config.toml"
BACKUP=""
mkdir -p "$HOME/.codex"
if [ -f "$CODEX_CFG" ]; then
  BACKUP="$PROBE_DIR/config.toml.bak"
  cp "$CODEX_CFG" "$BACKUP"
  log "既存の config.toml を退避しました: $BACKUP"
fi

cleanup() {
  stop_bg codex-timeout-stub 2>/dev/null || true
  stop_bg codex-timeout-proxy 2>/dev/null || true
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$CODEX_CFG"; log "config.toml を元に戻しました"
  else
    rm -f "$CODEX_CFG"
  fi
}
trap cleanup EXIT

hdr "1. 遅い上流スタブ（沈黙 ${PROBE_DELAY_SEC}s / モード ${PROBE_STALL}）"
STUB_PORT="$PROBE_PORT" STUB_DELAY_SEC="$PROBE_DELAY_SEC" \
STUB_STALL_MODE="$PROBE_STALL" \
STUB_MODEL="$CLINE_MODEL" STUB_LOG="$PROBE_DIR/requests.jsonl" \
  start_bg codex-timeout-stub "$LOGDIR/codex-timeout-stub.log" \
  python3 "$SCRIPT_DIR/test_slow_upstream_stub.py"
wait_http "http://127.0.0.1:$PROBE_PORT/v1/models" 20 "codex-timeout-stub" \
  || die "スタブが起動しませんでした。ログ: $LOGDIR/codex-timeout-stub.log"

hdr "2. 計測"
printf 'mode\tstall\tidle_ms\tdelay_sec\telapsed_sec\texit\tverdict\n' >"$RESULT_TSV"

for mode in $PROBE_MODES; do
  hdr "2.$mode"
  case "$mode" in
    direct)
      BASE="http://127.0.0.1:$PROBE_PORT"
      ;;
    proxy)
      # 修復プロキシを、上流をスタブにして起動する
      OLLAMA_BASE_URL="http://127.0.0.1:$PROBE_PORT" \
        start_bg codex-timeout-proxy "$LOGDIR/codex-timeout-proxy.log" \
        python3 "$SCRIPT_DIR/32_codex_tool_proxy.py"
      wait_http "$CODEX_PROXY_BASE_URL/v1/models" 20 "codex-timeout-proxy" \
        || die "プロキシが起動しませんでした。ログ: $LOGDIR/codex-timeout-proxy.log"
      BASE="$CODEX_PROXY_BASE_URL"
      ;;
    *) warn "未知のモード: $mode"; continue ;;
  esac

  cat >"$CODEX_CFG" <<EOF
# 37_codex_timeout_probe.sh が生成（測定後に復元されます）
model = "$CLINE_MODEL"
model_provider = "probe-stub"
model_context_window = 8192
model_max_output_tokens = 512
sandbox_mode = "danger-full-access"
approval_policy = "never"

[model_providers.probe-stub]
name = "probe stub"
base_url = "$BASE/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = $PROBE_IDLE_MS
EOF
  log "base_url=$BASE/v1  stream_idle_timeout_ms=$PROBE_IDLE_MS"

  RUN_LOG="$PROBE_DIR/run-$mode.log"
  START="$(date +%s)"
  set +e
  timeout "$PROBE_MAX_WAIT" codex exec --skip-git-repo-check "say ok" \
    </dev/null >"$RUN_LOG" 2>&1
  RC=$?
  set -e
  ELAPSED=$(( $(date +%s) - START ))

  if [ "$RC" -eq 124 ]; then
    VERDICT="打ち切り(${PROBE_MAX_WAIT}s 到達)"
  elif [ "$ELAPSED" -lt $((PROBE_DELAY_SEC - 3)) ]; then
    VERDICT="タイムアウトあり(${ELAPSED}s で切断)"
  else
    VERDICT="最後まで待てた"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
         "$mode" "$PROBE_STALL" "$PROBE_IDLE_MS" "$PROBE_DELAY_SEC" "$ELAPSED" \
         "$RC" "$VERDICT" >>"$RESULT_TSV"
  printf '      %-8s stall=%-5s idle=%-7s delay=%-5s %4ss exit=%-3s %s\n' \
         "$mode" "$PROBE_STALL" "$PROBE_IDLE_MS" "$PROBE_DELAY_SEC" "$ELAPSED" \
         "$RC" "$VERDICT"
  if grep -qiE 'timeout|timed out|idle' "$RUN_LOG" 2>/dev/null; then
    grep -iE 'timeout|timed out|idle' "$RUN_LOG" | head -3 | sed 's/^/        /'
  fi
done

hdr "3. 結果"
awk -F'\t' '{printf "    %-8s %-7s %-9s %-10s %-12s %-6s %s\n", $1,$2,$3,$4,$5,$6,$7}' "$RESULT_TSV"
cat <<EOF

    上流は一律 ${PROBE_DELAY_SEC}s で応答しています。
    stream_idle_timeout_ms は ${PROBE_IDLE_MS}ms (= $((PROBE_IDLE_MS / 1000))s)。

    direct と proxy で結果が違えば、それは **修復プロキシが上流の応答を
    まとめて返す** ことによる差です（無通信時間 = 上流の応答時間まるごと）。
    CPU 実行のように prefill が長い場面では、直結なら通るものが
    プロキシ経由で切られることになります。

    生ログ    : $PROBE_DIR/run-*.log
    リクエスト: $PROBE_DIR/requests.jsonl
    結果 TSV  : $RESULT_TSV
EOF
