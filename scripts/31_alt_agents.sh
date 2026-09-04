#!/usr/bin/env bash
# 31_alt_agents.sh - Cline 以外の CLI エージェントを導入し、ローカル Ollama に向ける（冪等）
#
# なぜこれがあるか:
#   Cline CLI は Ollama へのリクエストを 30 秒で切り、CLI 側に設定項目がない（cline#9484）。
#   Codex CLI / aider / Qwen Code はいずれもタイムアウトを設定できる。
#   手順書 §7.1 の比較表を読んでから使ってください。
#
#   性格の違い（T4 では「1 ターンに送るプロンプト量」が実用性を決める）:
#     Codex CLI … Cline に最も近い自律エージェント。ただし送る量も多い（32k〜64k 想定）
#     Qwen Code … 中間。gemini-cli フォークで自律エージェント寄り
#     aider     … ペアプログラマ型。送る量が最も少なく、T4 では一番速い
#
#   bash scripts/31_alt_agents.sh           # 全部
#   bash scripts/31_alt_agents.sh codex     # Codex CLI だけ（Cline に一番近い）
#   bash scripts/31_alt_agents.sh aider     # aider だけ
#   bash scripts/31_alt_agents.sh qwen      # Qwen Code だけ

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

WHICH="${1:-all}"
AGENT_TIMEOUT_SEC="${AGENT_TIMEOUT_SEC:-600}"

hdr "0. 前提の確認"
curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1 \
  || die "Ollama が $OLLAMA_BASE_URL で応答しません。先に 20_ollama.sh を実行してください。"
ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${CLINE_MODEL}" \
  || die "モデル \"$CLINE_MODEL\" がありません。先に 20_ollama.sh を実行してください。"
ok "Ollama とモデル ($CLINE_MODEL) を確認しました"

# ---------------------------------------------------------------------------
# aider
# ---------------------------------------------------------------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "aider" ]; then
  hdr "1. aider"
  if have aider; then
    ok "導入済み: $(first_line aider --version)"
  else
    # Colab のプリインストール済みパッケージと衝突させないため、
    # 隔離環境に入れる aider-install を使う（pip 直インストールはしない）。
    log "aider を隔離環境に導入します（3〜6 分）"
    python3 -m pip install -q aider-install >"$LOGDIR/aider-install.log" 2>&1 \
      || die "aider-install の取得に失敗。ログ: $LOGDIR/aider-install.log"
    aider-install >>"$LOGDIR/aider-install.log" 2>&1 \
      || die "aider の導入に失敗。ログ: $LOGDIR/aider-install.log"
    export PATH="$HOME/.local/bin:$PATH"
    have aider || die "aider が PATH に見つかりません。ログ: $LOGDIR/aider-install.log"
    ok "導入完了: $(first_line aider --version)"
  fi

  log "設定ファイルを書き出します"
  # --- .aider.conf.yml : タイムアウトとモデルの既定値 ---
  cat >"$WORKSPACE/.aider.conf.yml" <<EOF
# aider の既定設定
# --timeout は Cline CLI に無い設定。ここが本スクリプトの存在理由。
model: ollama/$CLINE_MODEL
timeout: $AGENT_TIMEOUT_SEC
# ローカルの小さいモデル向け
stream: true
auto-commits: false
gitignore: false
show-model-warnings: false
EOF

  # --- .aider.model.settings.yml : num_ctx を固定する ---
  cat >"$WORKSPACE/.aider.model.settings.yml" <<EOF
- name: ollama/$CLINE_MODEL
  extra_params:
    num_ctx: $NUM_CTX
EOF
  ok "$WORKSPACE/.aider.conf.yml と .aider.model.settings.yml を書き出しました"

  cat <<EOF

    使い方:
      export OLLAMA_API_BASE=$OLLAMA_BASE_URL
      cd $WORKSPACE
      aider                          # 設定ファイルが読まれる
      aider --timeout 900 app.py     # 都度上書きする場合

EOF
fi

# ---------------------------------------------------------------------------
# Qwen Code
# ---------------------------------------------------------------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "qwen" ]; then
  hdr "2. Qwen Code"
  have node || die "node がありません。先に 30_cline_cli.sh を実行してください（Node $NODE_MAJOR を導入します）。"

  if have qwen; then
    ok "導入済み: $(first_line qwen --version)"
  else
    log "npm install -g @qwen-code/qwen-code（1〜3 分）"
    npm install -g @qwen-code/qwen-code@latest >"$LOGDIR/npm-qwen.log" 2>&1 \
      || die "導入に失敗。ログ: $LOGDIR/npm-qwen.log"
    have qwen || die "qwen が PATH に見つかりません。ログ: $LOGDIR/npm-qwen.log"
    ok "導入完了: $(first_line qwen --version)"
  fi

  log "settings.json を書き出します"
  mkdir -p "$HOME/.qwen"
  # timeout はドキュメントでローカルサーバ向けに 300000ms が推奨されている。
  # ここでは AGENT_TIMEOUT_SEC に合わせる。
  python3 - "$HOME/.qwen/settings.json" "$CLINE_MODEL" "$OLLAMA_BASE_URL" \
           "$((AGENT_TIMEOUT_SEC * 1000))" "$NUM_PREDICT" <<'PY'
import json, os, sys

path, model, base, timeout_ms, max_tokens = sys.argv[1:6]

# 既存設定があればマージする（他の設定を壊さない）
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except (FileNotFoundError, ValueError):
    cfg = {}

cfg.setdefault("modelProviders", {})["openai"] = [
    {
        "id": model,
        "name": f"{model} (local Ollama)",
        "envKey": "OPENAI_API_KEY",
        "baseUrl": base.rstrip("/") + "/v1",
        "generationConfig": {
            "timeout": int(timeout_ms),
            "maxRetries": 1,
            "samplingParams": {
                "temperature": 0.2,
                "max_tokens": int(max_tokens),
            },
        },
    }
]

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f"    書き出しました: {path}")
PY
  ok "$HOME/.qwen/settings.json を更新しました"

  cat <<EOF

    使い方:
      export OPENAI_BASE_URL=$OLLAMA_BASE_URL/v1
      export OPENAI_API_KEY=ollama          # 中身は何でもよいが空だと弾かれる
      export OPENAI_MODEL=$CLINE_MODEL
      cd $WORKSPACE
      qwen

EOF
fi

# ---------------------------------------------------------------------------
# Codex CLI  — Cline に最も近い自律エージェント
# ---------------------------------------------------------------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "codex" ]; then
  hdr "3. Codex CLI"
  have node || die "node がありません。先に 30_cline_cli.sh を実行してください。"

  if have codex; then
    ok "導入済み: $(first_line codex --version)"
  else
    log "npm install -g @openai/codex（1〜3 分）"
    npm install -g @openai/codex >"$LOGDIR/npm-codex.log" 2>&1 \
      || die "導入に失敗。ログ: $LOGDIR/npm-codex.log"
    have codex || die "codex が PATH に見つかりません。ログ: $LOGDIR/npm-codex.log"
    ok "導入完了: $(first_line codex --version)"
  fi

  # --- モデルが tool calling に対応しているか ---------------------------
  # Codex はネイティブの function calling を前提にしている。
  # Ollama のテンプレートが tools に対応していないモデルだと、推論前に弾かれる。
  log "モデルの tools 対応を確認します"
  if ollama show "$CLINE_MODEL" 2>/dev/null | grep -qi 'tools'; then
    ok "$CLINE_MODEL は tools に対応しています"
  else
    warn "$CLINE_MODEL の capabilities に tools が見当たりません。
       Codex は 'does not support tools' で失敗する可能性があります。
       確認: ollama show $CLINE_MODEL
       （qwen2.5-coder 系は対応しています。ベースモデルを変えた場合は要確認）"
  fi

  # --- wire_api の判定 --------------------------------------------------
  # Ollama 0.13.3 以降は /v1/responses を出す。それ以前は /v1/chat/completions のみ。
  # Codex はどちらも喋れるので、実際に生えているほうに合わせる。
  log "Ollama がどのエンドポイントを出しているか調べます"
  RESP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -X POST "$OLLAMA_BASE_URL/v1/responses" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$CLINE_MODEL\",\"input\":\"hi\",\"max_output_tokens\":16}" 2>/dev/null || echo 000)"
  if [ "$RESP_CODE" = "404" ] || [ "$RESP_CODE" = "000" ]; then
    WIRE_API="chat"
    log "/v1/responses は使えません (HTTP $RESP_CODE) -> wire_api = \"chat\""
  else
    WIRE_API="responses"
    ok "/v1/responses が応答しました (HTTP $RESP_CODE) -> wire_api = \"responses\""
  fi

  # --- config.toml ------------------------------------------------------
  mkdir -p "$HOME/.codex"
  CODEX_CFG="$HOME/.codex/config.toml"
  if [ -f "$CODEX_CFG" ]; then
    cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%s)"
    warn "既存の config.toml をバックアップして上書きします"
  fi
  cat >"$CODEX_CFG" <<EOF
# Colab T4 + ローカル Ollama 用の Codex CLI 設定
# 生成: scripts/31_alt_agents.sh

model = "$CLINE_MODEL"
model_provider = "ollama-local"

# Codex は 32k 以上、できれば 64k のコンテキストを想定している。
# T4 では 7B + 32k が現実的な上限（手順書 §5.3）。
model_context_window = $NUM_CTX
model_max_output_tokens = $NUM_PREDICT

# Colab の VM はすでにコンテナで隔離されている。
# Codex の seccomp/landlock サンドボックスはコンテナ内では動かないことが多く、
# 公式ドキュメントも「コンテナが境界ならサンドボックスを二重にするな」としている。
# ※ この設定は「VM 内で何でも実行できる」ことを意味する。使い捨ての Colab VM だから
#   許容できるのであって、手元のマシンで同じ設定にしてはいけない。
sandbox_mode = "danger-full-access"
approval_policy = "never"

[model_providers.ollama-local]
name = "Ollama (local)"
base_url = "$OLLAMA_BASE_URL/v1"
wire_api = "$WIRE_API"

# ★ ここが Cline CLI に無い設定。
#   stream_idle_timeout_ms は「無通信のまま何 ms 待つか」。
#   prefill 中は何も返ってこないので、prefill の長さがここに効く。
request_max_retries = 2
stream_max_retries = 5
stream_idle_timeout_ms = $((AGENT_TIMEOUT_SEC * 1000))
EOF
  ok "$CODEX_CFG を書き出しました (wire_api=$WIRE_API)"

  cat <<EOF

    使い方:
      cd $WORKSPACE
      codex                                   # 対話 TUI
      codex exec "テストを書いて実行して"        # 非対話
      codex --oss -m $CLINE_MODEL              # config を使わず直接 Ollama を指す

    注意:
      - Codex は git リポジトリ内で動かすことを想定しています
        （$WORKSPACE は 30_cline_cli.sh が git init 済み）
      - サンドボックスを無効にしています。Colab の使い捨て VM 前提の設定です

EOF
fi

# ---------------------------------------------------------------------------
# ターミナル用の環境変数を仕込む
# ---------------------------------------------------------------------------
hdr "4. ターミナル用の環境変数"
BASHRC="$HOME/.bashrc"
MARK="# >>> colab-cline-agents >>>"
END="# <<< colab-cline-agents <<<"
touch "$BASHRC"
if grep -qF "$MARK" "$BASHRC"; then
  python3 - "$BASHRC" "$MARK" "$END" <<'PY'
import sys
path, start, end = sys.argv[1:4]
out, skip = [], False
for ln in open(path, encoding="utf-8").read().splitlines(True):
    if ln.strip() == start: skip = True; continue
    if ln.strip() == end:   skip = False; continue
    if not skip: out.append(ln)
open(path, "w", encoding="utf-8").writelines(out)
PY
fi
cat >>"$BASHRC" <<EOF
$MARK
export PATH="\$HOME/.local/bin:\$PATH"
export OLLAMA_API_BASE=$OLLAMA_BASE_URL
export OPENAI_BASE_URL=$OLLAMA_BASE_URL/v1
export OPENAI_API_KEY=ollama
export OPENAI_MODEL=$CLINE_MODEL
export AIDER_TIMEOUT=$AGENT_TIMEOUT_SEC
$END
EOF
ok "$BASHRC に追記しました（ターミナルを開き直すか source ~/.bashrc）"

hdr "完了"
cat <<EOF
    タイムアウトはいずれも ${AGENT_TIMEOUT_SEC}s に設定しました
    （Cline CLI は 30s 固定で変更できません）。

    ${_c_bold}ただし、これは対症療法です。${_c_reset}
    30 秒待っていたものが ${AGENT_TIMEOUT_SEC} 秒待てるようになるだけで、体感は良くなりません。
    $STATEDIR/bench-summary.txt の判定が NG なら、
    エージェントを替えても解決しません。モデルを小さくしてください。
EOF
