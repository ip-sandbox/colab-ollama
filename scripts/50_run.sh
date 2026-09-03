#!/usr/bin/env bash
# 50_run.sh - ノートブックのセルから Cline を走らせる薄いラッパ
#
# ターミナルを一切出さずに使えるので、無料枠では ${_c_bold}こちらが本命${_c_reset}。
# 規約上もノートブック UI の中で完結する。
#
#   !bash scripts/50_run.sh "fizzbuzz.py を作って 1〜30 を出力して実行して"
#   !bash scripts/50_run.sh -p "このリポジトリの構成を調べて改善案を出して"   # Plan モード
#   !bash scripts/50_run.sh --json "TODO コメントを列挙して"                  # 機械可読出力
#
# 環境変数:
#   AUTO_APPROVE=0   … 承認スキップを無効にする（既定は 1 = --yolo）
#   TASK_TIMEOUT=900 … タスク全体の上限秒数

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

AUTO_APPROVE="${AUTO_APPROVE:-1}"
TASK_TIMEOUT="${TASK_TIMEOUT:-900}"

[ "$#" -ge 1 ] || die "使い方: bash scripts/50_run.sh [cline のオプション] \"やってほしいこと\""

# --- 前提チェック（ここで弾くと原因が一目で分かる） ---------------------
have cline || die "cline がありません。先に 30_cline_cli.sh を実行してください。"
curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1 \
  || die "Ollama が応答しません。先に 20_ollama.sh を実行してください。"

# モデルが VRAM に載っているか。載っていないとロード時間が
# Cline CLI の 30 秒リクエスト予算に食い込んで失敗する。
LOADED="$(curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/ps" 2>/dev/null || echo '{}')"
if ! printf '%s' "$LOADED" | grep -q "$CLINE_MODEL"; then
  warn "モデルが VRAM に載っていません。先にウォームアップします（30〜90 秒）"
  curl -fsS --max-time 900 "$OLLAMA_BASE_URL/api/generate" \
       -H 'Content-Type: application/json' \
       -d "{\"model\":\"$CLINE_MODEL\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":4}}" \
       >/dev/null
  ok "ロードしました"
fi

# --- 実行 ----------------------------------------------------------------
ARGS=(--cwd "$WORKSPACE" --timeout "$TASK_TIMEOUT")
[ "$AUTO_APPROVE" = "1" ] && ARGS+=(--yolo)

hdr "Cline 実行"
printf '    cwd     : %s\n' "$WORKSPACE"
printf '    model   : %s (num_ctx=%s)\n' "$CLINE_MODEL" "$NUM_CTX"
printf '    timeout : %ss\n' "$TASK_TIMEOUT"
[ "$AUTO_APPROVE" = "1" ] && printf '    approve : --yolo（承認スキップ）\n' \
                          || printf '    approve : 対話承認\n'
echo

cd "$WORKSPACE"
set +e
cline "${ARGS[@]}" "$@"
RC=$?
set -e

echo
if [ "$RC" -eq 0 ]; then
  ok "完了 (exit=0)"
else
  warn "異常終了 (exit=$RC)
     'Ollama request timed out after 30 seconds' が出た場合は、プロンプトが
     この構成の処理能力を超えています。手順書 §7 を参照してください:
       - タスクをもっと小さく切る
       - より小さいモデルに切り替える (BASE_MODEL)
       - CLINE_PROVIDER=openai-compatible で 30 秒制限の回避を試す"
fi
exit "$RC"
