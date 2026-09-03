#!/usr/bin/env bash
# 30_cline_cli.sh - Colab VM 上に Cline CLI を導入し、ローカル Ollama に向ける（冪等）
#
# 注意点が 2 つある。
#
# (1) Cline CLI は既定で「無料の Cline アカウント」を使う。
#     何も設定しないと、Colab の Ollama ではなくクラウドに投げる。
#     ここで明示的にローカルへ向けるまで、ローカル LLM は使われていない。
#
# (2) `cline config set` のキー名は CLI のバージョンで変わりうる。
#     このスクリプトは複数の候補を試し、最後に `cline config` の実出力を表示するので、
#     必ず目視で確認すること。うまく入らなければ対話 `cline auth` を使う。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

hdr "1. Node.js $NODE_MAJOR"
NEED_NODE=1
if have node; then
  NODE_VER="$(node --version | tr -d 'v')"
  [ "${NODE_VER%%.*}" -ge 20 ] && { ok "node v$NODE_VER（要件を満たしています）"; NEED_NODE=0; } \
                               || warn "node v$NODE_VER は古いので入れ直します"
fi
if [ "$NEED_NODE" -eq 1 ]; then
  log "NodeSource から Node $NODE_MAJOR を導入します（1〜3 分）"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >"$LOGDIR/nodesource.log" 2>&1
  apt-get install -y nodejs >>"$LOGDIR/nodesource.log" 2>&1
  have node || die "Node の導入に失敗しました。ログ: $LOGDIR/nodesource.log"
  ok "node $(node --version) / npm $(npm --version)"
fi

hdr "2. Cline CLI"
if have cline; then
  ok "導入済み: $(cline --version 2>&1 | head -1)"
else
  log "npm install -g cline（1〜3 分）"
  npm install -g cline >"$LOGDIR/npm-cline.log" 2>&1 || die "導入に失敗。ログ: $LOGDIR/npm-cline.log"
  have cline || die "cline が PATH に見つかりません。ログ: $LOGDIR/npm-cline.log"
  ok "導入完了: $(cline --version 2>&1 | head -1)"
fi

hdr "3. 前提の確認"
curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1 \
  || die "Ollama が $OLLAMA_BASE_URL で応答しません。先に 20_ollama.sh を実行してください。"
ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${CLINE_MODEL}" \
  || die "モデル \"$CLINE_MODEL\" がありません。先に 20_ollama.sh を実行してください。"
ok "Ollama とモデルを確認しました"

hdr "4. プロバイダ設定"
# 失敗しても続行し、最後に実出力で判定する
set +e
cfg() {
  log "  cline config set $1"
  cline config set "$1" >>"$LOGDIR/cline-config.log" 2>&1
}

case "$CLINE_PROVIDER" in
  ollama)
    log "Ollama プロバイダとして設定します"
    # Cline は Plan モードと Act モードで別々のプロバイダを持つ。両方に入れる。
    for mode in plan-mode act-mode; do
      cfg "${mode}-api-provider=ollama"
      cfg "${mode}-ollama-model-id=${CLINE_MODEL}"
      cfg "${mode}-ollama-base-url=${OLLAMA_BASE_URL}"
      # 実効コンテキスト長。キー名はバージョン差があるため両方試す。
      cfg "${mode}-ollama-api-options-num-ctx=${NUM_CTX}"
    done
    ;;
  openai-compatible)
    # Ollama の /v1 は OpenAI 互換。Ollama 専用ハンドラの 30 秒タイムアウト
    # （cline#9182）を迂回できる可能性がある。手順書 §7 / V-4 を参照。
    log "OpenAI 互換エンドポイント経由で設定します（30 秒制限の回避を狙う）"
    for mode in plan-mode act-mode; do
      cfg "${mode}-api-provider=openai"
      cfg "${mode}-openai-model-id=${CLINE_MODEL}"
      cfg "${mode}-openai-base-url=${OLLAMA_BASE_URL}/v1"
    done
    cfg "openai-api-key=ollama"   # 中身は何でもよいが空だと弾かれることがある
    ;;
  *)
    die "CLINE_PROVIDER は ollama か openai-compatible を指定してください（現在: $CLINE_PROVIDER）"
    ;;
esac
set -e

hdr "5. 設定の実出力（★必ず目視で確認）"
cat <<'EOT'
    下の出力に、指定したプロバイダとモデルが反映されているかを確認してください。
    反映されていなければ、対話モードで設定し直します:

        cline auth          # 矢印キーで Ollama を選び、モデルを選択
        cline config        # 対話的に設定を編集

    ここを確認せずに進むと、ローカルの Ollama ではなく
    Cline のクラウドアカウントに投げ続けることになります。

EOT
cline config 2>&1 | sed 's/^/    /' || warn "cline config の実行に失敗しました"

hdr "6. doctor"
cline doctor 2>&1 | sed 's/^/    /' || warn "cline doctor でエラーが出ました（上の出力を確認）"

hdr "7. ワークスペースの用意"
if [ ! -d "$WORKSPACE/.git" ]; then
  mkdir -p "$WORKSPACE"
  ( cd "$WORKSPACE" && git init -q 2>/dev/null ) || true
  cat >"$WORKSPACE/README.md" <<'EOF'
# Colab T4 + Cline CLI ワークスペース

Colab VM 上の作業ディレクトリです。**セッションが切れると消えます。**
残したいものは必ず git push するか Drive にコピーしてください。
EOF
  ok "初期化しました: $WORKSPACE"
else
  ok "既にあります: $WORKSPACE"
fi

# Cline に「小さく動け」と伝えるプロジェクトルール。
# ローカルの小さいモデルではこれが効く。
mkdir -p "$WORKSPACE/.cline/rules"
cat >"$WORKSPACE/.cline/rules/local-model.md" <<'EOF'
# ローカルモデル運用ルール

このワークスペースは Colab の T4 上で動く小さなローカルモデルで運用されています。
1 リクエストあたりの処理時間に厳しい上限があるため、以下を守ってください。

- 一度に読み込むファイルは 1 つ。300 行を超えるファイルは範囲を指定して部分的に読む
- 変更は 1 ファイルずつ。複数ファイルの同時編集はしない
- ディレクトリ全体の走査や再帰的な検索は避ける
- 手順を長く説明せず、実行してから結果を短く報告する
- 不明な点は推測で進めず、1 つだけ質問する
EOF
ok "プロジェクトルールを配置しました: $WORKSPACE/.cline/rules/local-model.md"

hdr "完了"
cat <<EOF
    次: bash scripts/40_terminal_setup.sh
        （ターミナルは別シェルなので、環境変数を ~/.bashrc に仕込みます）

    使い方:

    ${_c_bold}ターミナルから（対話 TUI・推奨）${_c_reset}
      ノートブック下部の「ターミナル」ボタン、または
      Colab VS Code 拡張の "Colab: Open Terminal"
      ※ どちらも全ユーザーが無料で使えます（2025-06-23〜）

        cd $WORKSPACE
        cline                 # 対話セッション
        cline -p "..."        # Plan モードで開始

    ${_c_bold}ノートブックのセルから（自動化向け）${_c_reset}
      !bash scripts/50_run.sh "fizzbuzz.py を作って 1〜30 を出力して実行して"
EOF
