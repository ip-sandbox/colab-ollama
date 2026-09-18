#!/usr/bin/env bash
# 34_toolcall_probe.sh - モデルが本物の tool_calls を返すかを、証拠付きで確かめる
#
# なぜこれがあるか
# ----------------
# このリポジトリは同じ形の不具合を 3 回踏んでいる:
#
#   §5.6  qwen2.5-coder:7b … 「Capabilities: tools」を名乗るのに <tool_call>
#                             ラッパーを守らず、生 JSON を content に返す
#   §5.8  qwen2.5-coder:14b … 同上（openai/codex#2229）
#   §12.7 gpt-oss:20b      … harmony のチャネル構文を content に書き出す
#
# いずれも「capabilities に tools と書いてある」ことは何の保証にもならなかった。
# そして毎回、原因が分かるまでに実タスクを何度も走らせて時間を溶かしている。
#
# 先に 1 回だけリクエストを投げて **生の応答を保存** すれば、それで済む。
# 修復コードを書くのはそのあと。このスクリプトはそのための道具で、
# 新しいモデルを評価対象に入れるときは必ず最初にこれを走らせる。
#
# Gemma 4 で特に重要な理由
# ------------------------
# gemma4 には報告済みの不具合が 2 系統あり、**発火条件が組み合わせに依存する**:
#
#   ollama/ollama#15539  system prompt + think:false + tools の 3 つが揃うと
#                        パーサが取りこぼす。どれか 1 つ欠けると再現しない
#   ollama/ollama#15798  テンプレートの特殊トークン（<|tool_call|> 等）が
#                        本文に漏れる。finish_reason は stop
#
# だから 1 点だけ試して「動いた」と結論してはいけない。行列で潰す。
#
# 使い方
# ------
#   bash scripts/34_toolcall_probe.sh
#   MODEL_PROFILE=gemma4-12b-qat bash scripts/34_toolcall_probe.sh
#   PROBE_MODEL=gemma4:12b-it-qat bash scripts/34_toolcall_probe.sh
#
# 出力
#   $STATEDIR/probe/  … 生の応答（JSON）とモデル情報。ここが本体
#   標準出力          … どの組み合わせで tool_calls が埋まったかの表

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs
model_profile_banner

# 既定は Modelfile でラップしたほう（実際にエージェントが使うのはこちら）。
# 素のベースモデルを見たいときは PROBE_MODEL で上書きする。
PROBE_MODEL="${PROBE_MODEL:-$CLINE_MODEL}"
PROBE_DIR="$STATEDIR/probe"
SUMMARY="$PROBE_DIR/summary.tsv"
CURL_MAX="${PROBE_CURL_MAX:-900}"

mkdir -p "$PROBE_DIR"

hdr "0. 前提の確認"
curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1 \
  || die "Ollama が $OLLAMA_BASE_URL で応答しません。先に 20_ollama.sh を実行してください。"
ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${PROBE_MODEL}" \
  || die "モデル \"$PROBE_MODEL\" がありません。先に 20_ollama.sh を実行してください。"
ok "対象モデル: $PROBE_MODEL"
if [ "$ACCEL" = "cpu" ]; then
  warn "CPU モードです。1 リクエストに数分かかることがあります（curl の上限は ${CURL_MAX}s）。
       ここで測りたいのは速度ではなく、tool_calls が埋まるかどうかです。"
fi

hdr "1. モデルの自己申告と実テンプレート"
# capabilities は当てにならないが、「何を名乗っているか」は記録に値する。
# template は <|tool_call|> 等の特殊トークンを実際に使うかを見るために取る。
# modelfile は KV 見積り（KV_MIB_PER_TOKEN）の根拠に使う。
for what in "" --template --parameters --modelfile; do
  name="show${what:+${what#--}}"
  name="${name/show/show-}"; name="${name%-}"
  out="$PROBE_DIR/${name:-show}.txt"
  ollama show "$PROBE_MODEL" $what >"$out" 2>&1 || true
  printf '      %-14s -> %s (%s 行)\n' "ollama show ${what:-（基本）}" "$out" "$(wc -l <"$out")"
done

if grep -qi 'tools' "$PROBE_DIR/show.txt" 2>/dev/null; then
  ok "capabilities に tools があります（ただし保証にはなりません。§5.6 参照）"
else
  warn "capabilities に tools が見当たりません。Codex は 'does not support tools' で失敗します。"
fi

# テンプレートに漏れやすい特殊トークンが含まれるか。#15798 の予兆になる。
if grep -qE '<\|tool_call\|>|<\|channel\|>|<\|tool_response\|>' \
        "$PROBE_DIR/show-template.txt" 2>/dev/null; then
  warn "テンプレートが <|tool_call|> 系の特殊トークンを使っています。
       これが本文に漏れるのが ollama#15798 です。下の行列で実挙動を確認してください。"
fi

hdr "2. ツール呼び出しの行列"
# 1 つのツールだけを与える。ツール名が具体的なほど、修復側の
# 「有効なツール名集合」による誤爆防止が効いているかも同時に見られる。
TOOL_NAME="write_file"

printf 'endpoint\tsystem\tthink\tstream\ttool_calls\thttp\tfile\n' >"$SUMMARY"

# probe_one <ラベル> <URL> <リクエストJSONファイル> <判定キー>
probe_one() {
  local label="$1" url="$2" reqfile="$3" kind="$4"
  local out="$PROBE_DIR/$label.json" code

  code="$(curl -sS --max-time "$CURL_MAX" -o "$out" -w '%{http_code}' \
          -X POST "$url" -H 'Content-Type: application/json' \
          --data-binary "@$reqfile" 2>>"$PROBE_DIR/curl-errors.log" || echo 000)"

  # tool_calls が埋まったかを判定する。埋まっていなければ content を残す
  # （この生文字列が、修復プロキシのテストデータになる）。
  python3 - "$out" "$kind" "$PROBE_DIR/$label.content.txt" <<'PY'
import json, sys
path, kind, content_out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f:
        body = json.load(f)
except Exception:
    print("PARSE_ERROR"); raise SystemExit(0)

calls, content = [], ""
if kind == "responses":
    for item in body.get("output") or []:
        if isinstance(item, dict) and item.get("type") == "function_call":
            calls.append(item.get("name"))
        elif isinstance(item, dict) and item.get("type") == "message":
            for c in item.get("content") or []:
                if isinstance(c, dict):
                    content += c.get("text") or ""
elif kind == "chat":            # /v1/chat/completions
    for ch in body.get("choices") or []:
        msg = ch.get("message") or {}
        for tc in msg.get("tool_calls") or []:
            calls.append((tc.get("function") or {}).get("name"))
        content += msg.get("content") or ""
else:                            # /api/chat
    msg = body.get("message") or {}
    for tc in msg.get("tool_calls") or []:
        calls.append((tc.get("function") or {}).get("name"))
    content += msg.get("content") or ""

if content:
    with open(content_out, "w", encoding="utf-8") as f:
        f.write(content)
print(",".join(c for c in calls if c) if calls else "NONE")
PY
}

# --- /api/chat（Ollama ネイティブ） ---------------------------------------
# think の有無だけを振る。ollama#15539 の発火条件に think が入っているため。
for think in unset false; do
  for sys_prompt in with without; do
    label="api-chat.sys-$sys_prompt.think-$think"
    req="$PROBE_DIR/$label.req.json"
    python3 - "$PROBE_MODEL" "$TOOL_NAME" "$sys_prompt" "$think" >"$req" <<'PY'
import json, sys
model, tool, sys_prompt, think = sys.argv[1:5]
msgs = []
if sys_prompt == "with":
    msgs.append({"role": "system",
                 "content": "You are a coding agent. Use the provided tools."})
msgs.append({"role": "user", "content": "Create a file named hello.txt containing hi."})
body = {
    "model": model, "stream": False, "messages": msgs,
    "tools": [{
        "type": "function",
        "function": {
            "name": tool,
            "description": "Write text to a file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "file path"},
                    "content": {"type": "string", "description": "file content"},
                },
                "required": ["path", "content"],
            },
        },
    }],
    "options": {"temperature": 0},
}
if think == "false":
    body["think"] = False
print(json.dumps(body))
PY
    res="$(probe_one "$label" "$OLLAMA_BASE_URL/api/chat" "$req" native)"
    printf '/api/chat\t%s\t%s\tfalse\t%s\t-\t%s\n' \
           "$sys_prompt" "$think" "$res" "$label.json" >>"$SUMMARY"
    printf '      %-44s -> %s\n' "$label" "$res"
  done
done

# --- /v1/chat/completions（OpenAI 互換） ----------------------------------
for sys_prompt in with without; do
  label="v1-chat.sys-$sys_prompt"
  req="$PROBE_DIR/$label.req.json"
  python3 - "$PROBE_MODEL" "$TOOL_NAME" "$sys_prompt" >"$req" <<'PY'
import json, sys
model, tool, sys_prompt = sys.argv[1:4]
msgs = []
if sys_prompt == "with":
    msgs.append({"role": "system",
                 "content": "You are a coding agent. Use the provided tools."})
msgs.append({"role": "user", "content": "Create a file named hello.txt containing hi."})
print(json.dumps({
    "model": model, "stream": False, "temperature": 0, "messages": msgs,
    "tools": [{
        "type": "function",
        "function": {
            "name": tool,
            "description": "Write text to a file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    }],
}))
PY
  res="$(probe_one "$label" "$OLLAMA_BASE_URL/v1/chat/completions" "$req" chat)"
  printf '/v1/chat/completions\t%s\t-\tfalse\t%s\t-\t%s\n' \
         "$sys_prompt" "$res" "$label.json" >>"$SUMMARY"
  printf '      %-44s -> %s\n' "$label" "$res"
done

# --- /v1/responses（Codex CLI 0.15x はこれしか喋らない） -------------------
label="v1-responses"
req="$PROBE_DIR/$label.req.json"
python3 - "$PROBE_MODEL" "$TOOL_NAME" >"$req" <<'PY'
import json, sys
model, tool = sys.argv[1:3]
print(json.dumps({
    "model": model, "stream": False,
    "instructions": "You are a coding agent. Use the provided tools.",
    "input": "Create a file named hello.txt containing hi.",
    "tools": [{
        "type": "function",
        "name": tool,
        "description": "Write text to a file.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["path", "content"],
        },
    }],
}))
PY
res="$(probe_one "$label" "$OLLAMA_BASE_URL/v1/responses" "$req" responses)"
printf '/v1/responses\twith\t-\tfalse\t%s\t-\t%s\n' "$res" "$label.json" >>"$SUMMARY"
printf '      %-44s -> %s\n' "$label" "$res"

hdr "3. 結果"
awk -F'\t' 'NR==1 {printf "    %-22s %-8s %-7s %-14s %s\n", $1, $2, $3, $5, $7; next}
            {printf "    %-22s %-8s %-7s %-14s %s\n", $1, $2, $3, $5, $7}' "$SUMMARY"
echo

NONE_COUNT="$(awk -F'\t' 'NR>1 && $5=="NONE"' "$SUMMARY" | wc -l)"
TOTAL="$(($(wc -l <"$SUMMARY") - 1))"
if [ "$NONE_COUNT" -eq 0 ]; then
  ok "全 $TOTAL 通りで tool_calls が埋まりました。修復プロキシは不要かもしれません
     （CODEX_TOOL_REPAIR=0 を試す価値があります）。"
else
  warn "$TOTAL 通り中 $NONE_COUNT 通りで tool_calls が空でした。
       その場合の本文は *.content.txt に保存してあります。
       中身を見て、修復プロキシ（scripts/32_codex_tool_proxy.py）が
       拾える形かどうかを判断してください。"
  ls "$PROBE_DIR"/*.content.txt 2>/dev/null | sed 's/^/        /' || true
fi

cat <<EOF

    生データ: $PROBE_DIR
    要約    : $SUMMARY

    tool_calls が空だった本文を、そのまま修復プロキシの単体テストへ
    持っていってください（scripts/test_tool_proxy_gemma4.py の流儀）。
EOF
