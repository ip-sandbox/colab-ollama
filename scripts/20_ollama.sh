#!/usr/bin/env bash
# 20_ollama.sh - Colab VM 上に Ollama を導入し、Cline 用モデルを用意する（冪等）
#
# 2 回目以降の実行は「既にあるものは触らない」で数秒で返る。
# 設定はすべて common.sh の環境変数で上書きできる。
#
#   BASE_MODEL=qwen2.5-coder:7b-instruct-q4_K_M NUM_CTX=65536 ./20_ollama.sh

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

OLLAMA_LOG="$LOGDIR/ollama.log"

hdr "1. Ollama の導入"
if have ollama; then
  ok "導入済み: $(first_line ollama --version)"
else
  # 公式インストーラは配布アーカイブを zstd で固めるようになり、展開に zstd コマンドを
  # 要求する。Colab の VM には既定で入っていないため、ここで先に導入しておく。
  #   ERROR: This version requires zstd for extraction. Please install zstd and try again
  ensure_cmd zstd

  log "Ollama をインストールします（1〜2 分）"
  curl -fsSL https://ollama.com/install.sh | sh \
    || die "Ollama の公式インストーラが失敗しました。上の出力を確認してください。
     展開ツール不足なら:  apt-get install -y zstd tar
     ネットワーク到達性は bash scripts/10_preflight.sh で確認できます。"
  have ollama || die "インストーラは完了しましたが ollama が PATH にありません。
     /usr/local/bin が PATH に入っているか確認してください。"
  ok "インストール完了: $(first_line ollama --version)"
fi

hdr "2. ollama serve の起動"
# Colab には systemd が無いのでサービス化はしない。直接プロセスとして起動する。
mkdir -p "$OLLAMA_MODELS"
if curl -fsS --max-time 3 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
  ok "既に $OLLAMA_BASE_URL で応答しています"
else
  log "環境変数:"
  printf '      OLLAMA_HOST=%s\n      OLLAMA_MODELS=%s\n' "$OLLAMA_HOST" "$OLLAMA_MODELS"
  printf '      OLLAMA_FLASH_ATTENTION=%s  OLLAMA_KV_CACHE_TYPE=%s\n' \
         "$OLLAMA_FLASH_ATTENTION" "$OLLAMA_KV_CACHE_TYPE"
  printf '      OLLAMA_KEEP_ALIVE=%s  OLLAMA_NUM_PARALLEL=%s\n' \
         "$OLLAMA_KEEP_ALIVE" "$OLLAMA_NUM_PARALLEL"
  start_bg ollama "$OLLAMA_LOG" ollama serve
  wait_http "$OLLAMA_BASE_URL/api/tags" 90 "ollama serve" \
    || die "起動しませんでした。ログ: $OLLAMA_LOG"
fi

hdr "3. ベースモデルの取得"
if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$BASE_MODEL"; then
  ok "取得済み: $BASE_MODEL"
else
  log "pull します: $BASE_MODEL"
  warn "14B q4_K_M で約 9GB。回線次第で数分〜十数分かかります。"
  ollama pull "$BASE_MODEL"
  ok "pull 完了: $BASE_MODEL"
fi

hdr "4. Cline 用モデルの作成 (num_ctx=$NUM_CTX)"
# ここが最重要。Ollama の既定 num_ctx は小さく、Cline のシステムプロンプトと
# ファイル内容で即あふれる。あふれた分は "静かに切り捨てられる" ため、
# 「指示を忘れる」「無いファイルを捏造する」という形で症状が出る。
MODELFILE="$STATEDIR/Modelfile.$CLINE_MODEL"
cat >"$MODELFILE" <<EOF
FROM $BASE_MODEL

# --- コンテキスト長 -------------------------------------------------------
# Cline は system prompt + 環境情報 + ファイル内容 + 会話履歴を毎回送る。
# 32768 未満にすると Cline はまともに動かないと考えてよい。
PARAMETER num_ctx $NUM_CTX

# --- 生成長 ---------------------------------------------------------------
# ファイル全体の書き換えを 1 応答で返させるため長めに取る。
PARAMETER num_predict $NUM_PREDICT

# --- サンプリング ---------------------------------------------------------
# コーディングエージェント用途では決定的寄りにする。
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER top_k 40
PARAMETER repeat_penalty 1.05
EOF

log "Modelfile:"
sed 's/^/      /' "$MODELFILE"

# num_ctx を変えた場合は作り直す必要があるので、既存があっても常に create する
# （create 自体は数秒。ベースレイヤは再利用される）
ollama create "$CLINE_MODEL" -f "$MODELFILE"
ok "作成しました: $CLINE_MODEL"

hdr "5. ウォームアップ（VRAM へのロード）"
log "モデルを VRAM に載せます（初回は 30〜90 秒）"
curl -fsS --max-time 900 "$OLLAMA_BASE_URL/api/generate" \
     -H 'Content-Type: application/json' \
     -d "{\"model\":\"$CLINE_MODEL\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":8}}" \
     -o "$STATEDIR/warmup.json"
ok "ロード完了"

hdr "6. 速度ベンチマーク（この構成でいちばん重要な数字）"
# Cline CLI は Ollama へのリクエストを 30 秒でタイムアウトする（cline#9182）。
# VS Code 拡張と違い、CLI 側にタイムアウト設定が無い。
# したがって「30 秒でプロンプトを何トークン処理できるか」が実用性の上限を決める。
#
# 長いプロンプトを実際に投げて prompt eval の速度を測り、
# 30 秒で処理しきれるトークン数を逆算する。
log "長いプロンプト + 長めの生成で、prefill と generation の両方を測ります"
# 生成速度も一緒に測る。エージェントはファイル 1 本を書き出すのに数百〜数千トークンを
# 生成するので、「prefill は間に合ったが生成中に切られた」が現実に起きる。
# 16 トークンで測ると誤差が大きすぎるので 256 トークン生成させる。
# thinking モデル（qwen3 系）では、ここで測る eval_count に思考トークンも含まれる。
python3 - "$CLINE_MODEL" >"$STATEDIR/bench-req.json" <<'PY'
import json, sys
# 圧縮の効きにくい擬似コードを並べてトークン数を稼ぐ（約 4000 tok を狙う）
block = "def handler_%d(request, context):\n    payload = request.get('data', {})\n    return {'status': 200, 'body': payload}\n\n"
body = "".join(block % i for i in range(340))
print(json.dumps({
    "model": sys.argv[1],
    "prompt": body + "\nWrite a detailed Python docstring for the handler functions above. Be verbose.",
    "stream": False,
    "options": {"num_predict": 256},
}))
PY

BENCH_START=$(date +%s)
curl -fsS --max-time 900 "$OLLAMA_BASE_URL/api/generate" \
     -H 'Content-Type: application/json' \
     --data-binary "@$STATEDIR/bench-req.json" -o "$STATEDIR/bench-resp.json"
BENCH_END=$(date +%s)

python3 - "$STATEDIR/bench-resp.json" "$((BENCH_END - BENCH_START))" \
         "$CLINE_REQUEST_BUDGET_SEC" "$NUM_CTX" "$STATEDIR/bench.json" <<'PY' \
  | tee "$STATEDIR/bench-summary.txt"
import json, sys

resp_path, wall, budget, num_ctx, out_path = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
)
with open(resp_path, encoding="utf-8") as f:
    r = json.load(f)

pc = r.get("prompt_eval_count") or 0
pd = (r.get("prompt_eval_duration") or 1) / 1e9
ec = r.get("eval_count") or 0
ed = (r.get("eval_duration") or 1) / 1e9

prefill_tps = pc / pd if pd else 0.0
gen_tps = ec / ed if ed else 0.0

print(f"      prompt eval        : {pc} tok / {pd:.1f}s = {prefill_tps:.0f} tok/s")
print(f"      generation         : {ec} tok / {ed:.1f}s = {gen_tps:.1f} tok/s")
print(f"      往復の実測          : {wall}s")
print()

# 1 リクエストの所要 = prefill + generation。
# エージェントは数百〜数千トークンを生成するので、生成分も予算を食う。
print(f"      Cline CLI の 1 リクエスト予算 : {budget}s")
print(f"      所要 = プロンプト/{prefill_tps:.0f} + 出力/{gen_tps:.1f}")
print()
print("      予算内に収まる組み合わせ (O=収まる X=超える):")
outs = [200, 500, 1000, 2000]
print("        prompt \\ 出力 " + "".join(f"{o:>9}" for o in outs))
for pp in (5000, 10000, 15000, 20000, 25000, 30000):
    row = f"        {pp:>13,} "
    for o in outs:
        t = pp / prefill_tps + o / gen_tps if prefill_tps and gen_tps else 9e9
        row += f"{('O' if t <= budget else 'X') + f'{t:4.0f}s':>9}"
    print(row)
print()

# 「典型的な出力 500 トークン」を前提にした安全プロンプト長を主指標にする
TYPICAL_OUT = 500
gen_cost = TYPICAL_OUT / gen_tps if gen_tps else budget
prefill_budget = max(budget - gen_cost, 0.0)
safe_tokens = int(prefill_tps * prefill_budget)
print(f"      出力 {TYPICAL_OUT} トークンを前提にすると:")
print(f"        生成に      {gen_cost:.1f}s")
print(f"        prefill に  {prefill_budget:.1f}s")
print(f"      ★ 安全に投げられるプロンプト長 : 約 {safe_tokens:,} トークン")
print()

# --- thinking モデルの検出 --------------------------------------------
# qwen3 系は既定で思考モードに入る。思考トークンは eval_count に載るが
# 応答本文には出ないため、「生成が遅いのに答えが短い」形で予算を食う。
# Modelfile では止められない（PARAMETER think は未サポート）ので、
# ここでは実測して警告するだけにする。
resp_text = r.get("response") or ""
thinking = ("<think>" in resp_text) or ("</think>" in resp_text)
visible = len(resp_text.replace("<think>", "").split("</think>")[-1])
if thinking:
    print("      ⚠ 思考トークン（<think>）を検出しました。")
    print(f"        生成 {ec} トークンのうち、応答本文は約 {visible} 文字ぶんです。")
    print("        思考ぶんも 30 秒予算を食います。Modelfile では止められません")
    print("        （PARAMETER think は未サポート / SYSTEM /no_think は")
    print("         クライアントの system prompt に上書きされる）。")
    print("        遅いと感じたら think 非対応の小型モデルに替えてください。")
    print()

if safe_tokens >= num_ctx:
    verdict = "OK"
    msg = (f"num_ctx={num_ctx:,} を満たしています。文脈を使い切っても "
           f"{budget}s に収まる計算です。")
elif safe_tokens >= 12000:
    verdict = "OK"
    msg = (f"num_ctx={num_ctx:,} は使い切れませんが、実用上は十分です。\n"
           f"      大きいファイルを一度に読ませると詰まる可能性があります。")
elif safe_tokens >= 6000:
    verdict = "WARN"
    msg = ("Cline のシステムプロンプト（compact prompt で 6〜8k 程度）を\n"
           "      処理した時点で予算の大半を使います。1 ファイルずつの小さいタスクに限定してください。\n"
           "      より小さいモデルへの切り替えを検討する価値があります。")
else:
    verdict = "NG"
    msg = ("Cline のシステムプロンプトだけで 30 秒を超えます。この構成では実用になりません。\n"
           "      対策: (1) BASE_MODEL をより小さいものにする\n"
           "            (2) CLINE_PROVIDER=openai-compatible を試す（/v1 経由で 30 秒制限を回避できる可能性）\n"
           "            (3) モデルが VRAM に載り切っているか確認する（CPU オフロードは致命的に遅い）")

print(f"      判定: {verdict}")
print(f"      {msg}")

# 後続スクリプトが読めるように書き出す
if gen_tps and (2000 / gen_tps) > budget:
    print()
    print(f"      ⚠ 生成 {gen_tps:.1f} tok/s だと、出力 2000 トークン（ファイル1本の書き出し）だけで")
    print(f"        {2000/gen_tps:.0f}s かかります。プロンプトが短くてもここで切られます。")
    print("        → 1ファイルまるごと書かせず、部分置換で編集させてください。")

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"prefill_tps": prefill_tps, "gen_tps": gen_tps,
               "safe_prompt_tokens": safe_tokens, "verdict": verdict,
               "typical_out_tokens": TYPICAL_OUT, "thinking_detected": thinking}, f)
PY

hdr "7. VRAM 実測"
nvidia-smi --query-gpu=memory.total,memory.used,memory.free \
           --format=csv,noheader | sed 's/^/      /'
VRAM_FREE_MIB="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)"
if [ "$VRAM_FREE_MIB" -lt 512 ]; then
  warn "空き VRAM が ${VRAM_FREE_MIB}MiB しかありません。長い文脈を投げた瞬間に OOM します。
       NUM_CTX を下げる（32768 -> 16384）か、BASE_MODEL を 7B 級に落としてください。"
elif [ "$VRAM_FREE_MIB" -lt 1500 ]; then
  warn "空き VRAM ${VRAM_FREE_MIB}MiB。動きますが余裕がありません。長時間セッションでは NUM_CTX を下げる方が安全です。"
else
  ok "空き VRAM ${VRAM_FREE_MIB}MiB。余裕があります。"
fi

hdr "完了"
cat <<EOF
    モデル         : $CLINE_MODEL  (base: $BASE_MODEL)
    num_ctx        : $NUM_CTX
    エンドポイント : $OLLAMA_BASE_URL
    ベンチ結果     : $STATEDIR/bench-summary.txt

    次: bash scripts/30_cline_cli.sh
EOF
