#!/usr/bin/env bash
# 60_cpu_verify.sh - GPU を使わずに潰せる検証を一括で通す
#
# なぜこれがあるか
# ----------------
# Colab 無料枠の T4 は取り合いで、確保できないことのほうが多い。一方で、
# この構成で確かめたいことの **半分は GPU を必要としない**:
#
#   ツール呼び出しが成立するか … プロトコルの話。速度は関係ない
#   エージェントが何秒で切るか … 遅い上流を作れば測れる。むしろ CPU 向き
#   配線が正しいか             … config.toml / providers.json の話
#
# 残り（実用速度・安全プロンプト長・実タスクの完走率）だけが T4 を要する。
# そこで前者を CPU に寄せ、T4 を確保できた時間を後者に使い切る。
# 手順書 §13 の L1 / L2 に相当する。
#
# 3 層の検証レーン（手順書 §13）
#   L1 モデル不要  … 修復プロキシの単体テスト、Cline のタイムアウト実測
#   L2 CPU 実モデル … gemma4 が本当に tool_calls を返すか（このスクリプト）
#   L3 T4 実機     … 速度と完走率（remote/00_all.sh）
#
# 使い方
# ------
#   MODEL_PROFILE=gemma4-12b-qat bash scripts/60_cpu_verify.sh
#   SKIP_MODEL=1 bash scripts/60_cpu_verify.sh     # L1 だけ（重み不要）
#
# 環境変数
#   SKIP_MODEL=1        モデルを要する段（L2）を飛ばす
#   SKIP_CLINE=1        Cline のタイムアウト実測を飛ばす
#   CPU_TASK_TIMEOUT    Codex の実タスクの上限秒（既定 1800）

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs
model_profile_banner

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="$STATEDIR/cpu-verify-report.md"
CPU_TASK_TIMEOUT="${CPU_TASK_TIMEOUT:-1800}"
SECONDS=0

# 各段の結果を貯めてから最後に 1 枚のレポートにする。
# 途中で失敗しても「どこまで通ったか」が残るよう、都度追記する。
: >"$REPORT"
# printf の書式文字列が "-" で始まると bash はオプションと解釈して落ちる。
# 行頭が箇条書きの "-" になる Markdown を書くので、必ず -- で区切ること。
{
  printf '# CPU 事前検証レポート\n\n'
  printf -- '- 日時       : %s\n' "$(date -Is)"
  printf -- '- ACCEL      : %s\n' "$ACCEL"
  printf -- '- プロファイル: %s\n' "${MODEL_PROFILE:-（未指定）}"
  printf -- '- BASE_MODEL : %s (num_ctx=%s)\n' "$BASE_MODEL" "$NUM_CTX"
  printf -- '- CPU / RAM  : %s コア / %s\n' "$(nproc)" "$(accel_mem_report)"
  printf '\n'
} >>"$REPORT"

STEP=0
next_step() { STEP=$((STEP + 1)); hdr "[$STEP] $*"; }
note() { printf '%s\n' "$*" >>"$REPORT"; }

# --- 1. 前提 ---------------------------------------------------------------
next_step "前提チェック (10_preflight.sh)"
if bash "$SCRIPT_DIR/10_preflight.sh"; then
  note "## 1. 前提チェック: OK"
else
  note "## 1. 前提チェック: 警告あり（上の出力を参照）"
fi
note ""

# ★ ここが「pull で延々と待たない」ための肝。
#   10_preflight.sh が registry.ollama.ai への到達性を判定して
#   $STATEDIR/net-registry-ok に残しているので、それを読む。
REGISTRY_OK="$(cat "$STATEDIR/net-registry-ok" 2>/dev/null || echo 1)"
if [ "$REGISTRY_OK" != "1" ] && [ "${SKIP_MODEL:-0}" != "1" ]; then
  warn "registry.ollama.ai に到達できないため、モデルを要する段 (L2) を飛ばします。
       ollama pull は必ず失敗するので、待つ意味がありません。

       この環境のネットワークポリシーで次を許可してください:
           registry.ollama.ai   （モデルの重み）
           ollama.com           （インストーラ）

       Claude on the web の場合は、環境を作り直すときにネットワーク設定で
       許可します。許可できない場合は Colab の CPU ランタイムでも代替できます:
           bash remote/00_all.sh --gpu cpu --profile ${MODEL_PROFILE:-gemma4-12b-qat}"
  note "## 2. モデルを要する段 (L2): **スキップ**"
  note ""
  note "\`registry.ollama.ai\` に到達できませんでした。ネットワークポリシーで許可が必要です。"
  note ""
  SKIP_MODEL=1
fi

# --- 2. モデル不要の検証 (L1) ---------------------------------------------
next_step "L1: 修復プロキシの単体テスト（モデル不要）"
L1_FAIL=0
note "## L1: 修復プロキシの単体テスト"
note ""
note '| テスト | 結果 |'
note '|---|---|'
for t in "$SCRIPT_DIR"/test_tool_proxy_*.py; do
  [ -f "$t" ] || continue
  name="$(basename "$t")"
  if python3 "$t" >"$LOGDIR/$name.log" 2>&1; then
    ok "$name"
    note "| \`$name\` | OK |"
  else
    warn "$name が失敗しました（ログ: $LOGDIR/$name.log）"
    note "| \`$name\` | **NG** — \`$LOGDIR/$name.log\` |"
    L1_FAIL=1
  fi
done
note ""

# --- 3. Cline のタイムアウト実測 (L1) -------------------------------------
if [ "${SKIP_CLINE:-0}" != "1" ] && have cline; then
  next_step "L1: Cline のタイムアウト実測（モデル不要）"
  # ★ スタブが 11434 を使うので、本物の ollama が動いていると測れない。
  #   L2 を先に走らせてしまうと衝突するため、この順番は変えないこと。
  if port_open 127.0.0.1 11434 2>/dev/null; then
    warn "ポート 11434 が使用中のため、Cline のタイムアウト実測は飛ばします
       （本物の ollama serve が動いています）。単独で測るなら:
         bash scripts/99_teardown.sh --all && bash scripts/35_cline_timeout_probe.sh"
    note "## L1: Cline のタイムアウト実測: スキップ（ポート 11434 使用中）"
  else
    if bash "$SCRIPT_DIR/35_cline_timeout_probe.sh"; then
      note "## L1: Cline のタイムアウト実測"
      note ""
      note '```'
      cat "$STATEDIR/cline-timeout/results.tsv" >>"$REPORT" 2>/dev/null || true
      note '```'
    else
      warn "タイムアウト実測に失敗しました"
      note "## L1: Cline のタイムアウト実測: **失敗**"
    fi
  fi
  note ""
else
  log "Cline のタイムアウト実測は飛ばします（SKIP_CLINE か cline 未導入）"
fi

# --- 4. 実モデル (L2) ------------------------------------------------------
if [ "${SKIP_MODEL:-0}" = "1" ]; then
  hdr "L2 はスキップされました"
else
  next_step "L2: Ollama と $BASE_MODEL の用意（CPU なので時間がかかります）"
  bash "$SCRIPT_DIR/20_ollama.sh"
  note "## L2: モデルの用意: OK（$BASE_MODEL, num_ctx=$NUM_CTX）"
  note ""

  next_step "L2: ツール呼び出しの実挙動 (34_toolcall_probe.sh)"
  if bash "$SCRIPT_DIR/34_toolcall_probe.sh"; then
    note "## L2: ツール呼び出しの実挙動"
    note ""
    note '```'
    cat "$STATEDIR/probe/summary.tsv" >>"$REPORT" 2>/dev/null || true
    note '```'
    note ""
    # 生の本文が残っていれば、それがいちばん重要な成果物
    if ls "$STATEDIR"/probe/*.content.txt >/dev/null 2>&1; then
      note "tool_calls が空だったケースの本文:"
      note ""
      for c in "$STATEDIR"/probe/*.content.txt; do
        note "\`$(basename "$c")\`:"
        note ""
        note '```'
        head -c 2000 "$c" >>"$REPORT"
        printf '\n' >>"$REPORT"
        note '```'
        note ""
      done
    fi
  else
    warn "プローブが失敗しました"
    note "## L2: ツール呼び出しの実挙動: **失敗**"
    note ""
  fi

  next_step "L2: Codex CLI の導入と最小タスク"
  # ★ CPU なのでタスクは最小にする。ここで測りたいのは速度ではなく
  #   「ツール呼び出しが成立してファイルが書かれるか」の 1 点だけ。
  if bash "$SCRIPT_DIR/31_alt_agents.sh" codex; then
    cd "$WORKSPACE"
    git init -q 2>/dev/null || true
    rm -f hello.txt
    log "codex exec に最小タスクを投げます（上限 ${CPU_TASK_TIMEOUT}s）"
    T0=$SECONDS
    set +e
    timeout "$CPU_TASK_TIMEOUT" codex exec --skip-git-repo-check \
      "Create a file named hello.txt containing exactly: hi" \
      </dev/null >"$LOGDIR/cpu-codex-task.log" 2>&1
    RC=$?
    set -e
    ELAPSED=$((SECONDS - T0))
    SZ="$(stat -c%s hello.txt 2>/dev/null || echo 0)"
    if [ "$RC" -eq 0 ] && [ "$SZ" -gt 0 ]; then
      ok "完走しました（${ELAPSED}s, hello.txt = ${SZ}B）"
      note "## L2: Codex の最小タスク: **OK**（${ELAPSED}s, hello.txt = ${SZ}B）"
    else
      warn "完走しませんでした（exit=$RC, ${ELAPSED}s, hello.txt = ${SZ}B）
       ログ: $LOGDIR/cpu-codex-task.log"
      note "## L2: Codex の最小タスク: **NG**（exit=$RC, ${ELAPSED}s, hello.txt = ${SZ}B）"
    fi
    note ""
    # 修復プロキシが何回仕事をしたか。ここが 0 なら素で通っている。
    if [ "$CODEX_TOOL_REPAIR" = "1" ] && [ -f "$LOGDIR/codex-tool-proxy.log" ]; then
      R="$(grep -c 'repaired' "$LOGDIR/codex-tool-proxy.log" 2>/dev/null || echo 0)"
      note "修復プロキシの発火回数: ${R}"
      note ""
      log "修復プロキシの発火: $R 回"
    fi
  else
    warn "Codex CLI の導入に失敗しました"
    note "## L2: Codex の最小タスク: **導入に失敗**"
    note ""
  fi
fi

# --- 5. まとめ -------------------------------------------------------------
hdr "完了（所要 ${SECONDS}s）"
{
  printf '\n---\n\n'
  printf '## 測っていないこと\n\n'
  printf 'CPU での測定なので、以下は**この検証では分からない**:\n\n'
  printf -- '- 実用速度（prefill / generation）と安全プロンプト長\n'
  printf -- '- 実タスクの完走率（1 回では分からない。T4 で `--eval N`）\n'
  printf -- '- VRAM に載るか（RAM に載ることしか確かめていない）\n\n'
  printf 'T4 を確保できたら:\n\n'
  printf '```\nbash remote/00_all.sh --gpu T4 --retry 3 --profile %s --eval 5 --stop\n```\n' \
         "${MODEL_PROFILE:-gemma4-12b-qat}"
} >>"$REPORT"

ok "レポート: $REPORT"
cat <<EOF

    L1（モデル不要）の単体テスト: $([ "$L1_FAIL" -eq 0 ] && echo 全て OK || echo 失敗あり)
    レポート                     : $REPORT

    次にやること:
      - レポートの「ツール呼び出しの実挙動」を見る。NONE があれば、その
        本文を scripts/test_tool_proxy_gemma4.py のテストデータにして
        scripts/32_codex_tool_proxy.py に修復を足す
      - T4 が取れたら remote/00_all.sh で速度と完走率を測る
EOF
