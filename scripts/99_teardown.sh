#!/usr/bin/env bash
# 99_teardown.sh - 停止と片付け
#
# この構成には外部公開が無いので、旧構成（トンネル）ほど片付けは切実ではない。
# それでも VRAM を解放したいとき、状態をリセットしたいときに使う。
#
#   ./99_teardown.sh            モデルを VRAM からアンロード（Ollama は生かす）
#   ./99_teardown.sh --all      Ollama も止める
#   ./99_teardown.sh --purge    全部止めて、生成した状態も消す

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
trap - ERR
set +e

MODE="${1:-unload}"

hdr "モデルのアンロード"
if curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
  # keep_alive: 0 で即座に VRAM から降ろす
  curl -fsS --max-time 30 "$OLLAMA_BASE_URL/api/generate" \
       -H 'Content-Type: application/json' \
       -d "{\"model\":\"$CLINE_MODEL\",\"keep_alive\":0}" >/dev/null 2>&1 \
    && ok "$CLINE_MODEL を VRAM から降ろしました" \
    || warn "アンロード要求に失敗（既に降りている可能性）"
  sleep 2
  nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>/dev/null | sed 's/^/    /'
else
  log "Ollama は応答していません"
fi

if [ "$MODE" = "--all" ] || [ "$MODE" = "--purge" ]; then
  hdr "Ollama の停止"
  stop_bg ollama
  pkill -x ollama 2>/dev/null && ok "残存 ollama を停止しました"
fi

if [ "$MODE" = "--purge" ]; then
  hdr "状態の削除"
  rm -rf "$STATEDIR"
  ok "$STATEDIR を削除しました"
  warn "ログ ($LOGDIR) とワークスペース ($WORKSPACE) は残しています。
       Cline の設定 ($CLINE_DATA_DIR) も残しています。
       完全に初期化したい場合は手動で削除してください。"
fi

hdr "現在の状態"
for name in ollama; do
  pgrep -x "$name" >/dev/null 2>&1 \
    && printf '    %s[  UP]%s %s\n' "$_c_yellow" "$_c_reset" "$name" \
    || printf '    %s[DOWN]%s %s\n' "$_c_green"  "$_c_reset" "$name"
done

echo
warn "Colab ランタイム自体は止まっていません。
     計算リソースの消費を止めるには、Colab メニューの
     「ランタイム > ランタイムを接続解除して削除」を実行してください。
     ${_c_bold}その前に、書いたコードを git push してください。${_c_reset}"
