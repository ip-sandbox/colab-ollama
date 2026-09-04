#!/usr/bin/env bash
# 90_healthcheck.sh - 「今どうなっているか」を 1 画面で出す
#
# Cline が動かないときは、まずこれ。落ちない（常に exit 0）。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
trap - ERR
set +e

PASS=0; FAILED=0
mark_ok()  { printf '    %s[  OK]%s %s\n' "$_c_green" "$_c_reset" "$1"; PASS=$((PASS+1)); }
mark_ng()  { printf '    %s[  NG]%s %s\n' "$_c_red"   "$_c_reset" "$1"; FAILED=$((FAILED+1)); }
check() { local label="$1"; shift; "$@" >/dev/null 2>&1 && mark_ok "$label" || mark_ng "$label"; }

hdr "GPU"
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu \
           --format=csv 2>/dev/null | sed 's/^/    /' || echo "    nvidia-smi 不可"

hdr "プロセス"
for name in ollama; do
  pidfile="$STATEDIR/$name.pid"
  if { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; } || pgrep -x "$name" >/dev/null 2>&1; then
    printf '    %s[  UP]%s %s\n' "$_c_green" "$_c_reset" "$name"
  else
    printf '    %s[DOWN]%s %s  -> bash scripts/20_ollama.sh\n' "$_c_yellow" "$_c_reset" "$name"
  fi
done

hdr "エンドポイント"
check "Ollama    $OLLAMA_BASE_URL/api/tags"  curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags"
check "OpenAI互換 $OLLAMA_BASE_URL/v1/models" curl -fsS --max-time 5 "$OLLAMA_BASE_URL/v1/models"

hdr "モデル"
if curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
  ollama list 2>/dev/null | sed 's/^/    /'
  echo
  if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${CLINE_MODEL}"; then
    mark_ok "Cline 用モデル \"$CLINE_MODEL\" があります"
    echo "    実効パラメータ:"
    ollama show "$CLINE_MODEL" --parameters 2>/dev/null | sed 's/^/      /'
  else
    mark_ng "Cline 用モデル \"$CLINE_MODEL\" がありません -> bash scripts/20_ollama.sh"
  fi

  echo
  echo "    VRAM にロード済みのモデル (/api/ps):"
  curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/ps" 2>/dev/null \
    | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("      (取得失敗)"); raise SystemExit
ms=d.get("models") or []
if not ms:
    print("      なし  <- 次のリクエストでロードが走り、その時間が Cline の 30 秒予算を食う")
for m in ms:
    name = m.get("name")
    size_vram = m.get("size_vram", 0) / 2**30
    until = m.get("expires_at", "?")
    print(f"      {name}  size_vram={size_vram:.1f}GiB  until={until}")
'
else
  echo "    Ollama が応答しないためスキップ"
fi

hdr "Node / Cline CLI"
if have node; then mark_ok "node $(node --version)"; else mark_ng "node がありません -> bash scripts/30_cline_cli.sh"; fi
if have cline; then
  mark_ok "cline $(first_line cline --version)"
  echo
  echo "    現在の設定（★ローカルの Ollama を向いているか目視確認）:"
  # `cline config`（引数なし）は CLI 3.x では対話専用になり TTY が無いと失敗するため、
  # 設定ファイルを直接読む。
  PROVIDERS_JSON="${CLINE_DATA_DIR}/data/settings/providers.json"
  if [ -f "$PROVIDERS_JSON" ]; then
    python3 -c "
import json
d = json.load(open('$PROVIDERS_JSON'))
print('      lastUsedProvider:', d.get('lastUsedProvider'))
p = d.get('providers', {}).get(d.get('lastUsedProvider'), {})
print('      settings:', json.dumps(p.get('settings', {}), ensure_ascii=False))
" 2>&1 | sed 's/^/  /'
  else
    echo "      $PROVIDERS_JSON が無い -> bash scripts/30_cline_cli.sh"
  fi
else
  mark_ng "cline がありません -> bash scripts/30_cline_cli.sh"
fi

hdr "prefill ベンチ結果"
if [ -f "$STATEDIR/bench-summary.txt" ]; then
  sed 's/^/  /' "$STATEDIR/bench-summary.txt"
else
  echo "    未計測 -> bash scripts/20_ollama.sh"
fi

hdr "エンドツーエンド疎通 (30 秒予算のシミュレーション)"
# Cline のシステムプロンプト相当（compact prompt で 6〜8k トークン）を模した
# 長さのリクエストを投げ、30 秒以内に応答が返るかを実測する。
python3 - "$CLINE_MODEL" >"$STATEDIR/e2e-req.json" <<'PY'
import json, sys
block = "def handler_%d(request, context):\n    return {'status': 200}\n\n"
print(json.dumps({
    "model": sys.argv[1],
    "prompt": "".join(block % i for i in range(700)) + "\nReply with the single word: pong",
    "stream": False,
    "options": {"num_predict": 8},
}))
PY
E2E_START=$(date +%s)
if curl -fsS --max-time 120 "$OLLAMA_BASE_URL/api/generate" \
     -H 'Content-Type: application/json' \
     --data-binary "@$STATEDIR/e2e-req.json" -o "$STATEDIR/e2e-resp.json" 2>/dev/null; then
  E2E_SEC=$(( $(date +%s) - E2E_START ))
  python3 -c "
import json
d=json.load(open('$STATEDIR/e2e-resp.json',encoding='utf-8'))
print(f\"    プロンプト {d.get('prompt_eval_count',0)} tok を {$E2E_SEC}s で処理\")
print('    応答:', (d.get('response') or '').strip()[:60])
"
  if [ "$E2E_SEC" -lt "$CLINE_REQUEST_BUDGET_SEC" ]; then
    mark_ok "${E2E_SEC}s < ${CLINE_REQUEST_BUDGET_SEC}s 予算内"
  else
    mark_ng "${E2E_SEC}s >= ${CLINE_REQUEST_BUDGET_SEC}s  Cline CLI ではタイムアウトします（手順書 §7）"
  fi
else
  mark_ng "/api/generate が失敗しました"
fi

hdr "サマリ"
printf '    OK=%d  NG=%d\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ] && ok "すべて正常です。" || warn "NG があります。手順書 §9 を参照してください。"
echo
echo "    ログ: $LOGDIR"
exit 0
