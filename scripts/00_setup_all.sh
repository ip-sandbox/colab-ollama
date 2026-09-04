#!/usr/bin/env bash
# 00_setup_all.sh - ノートブックを使わずに一連のセットアップを一括実行する（冪等）
#
# notebooks/colab_cline.ipynb の各セルが順番にやっていること
#   (0. 配置確認 -> 1. 前提確認 -> 2. Ollama -> 3. Cline CLI -> 4. ターミナル準備 -> 7. 状態確認)
# を、ターミナル（Colab のターミナルボタン / VS Code 拡張 / SSH）から
# このスクリプト 1 本で通す。中身は各 NN_*.sh の呼び出しだけで、
# ロジックの重複は無い。個別に叩き直したい場合は README の表を参照。
#
#   cd /content && git clone https://github.com/ip-sandbox/colab-ollama.git colab-cline
#   cd colab-cline
#   bash scripts/00_setup_all.sh
#
# 主要な設定は環境変数で上書きできる（各 NN_*.sh と同じ）:
#   BASE_MODEL=qwen2.5-coder:14b-instruct-q4_K_M NUM_CTX=16384 bash scripts/00_setup_all.sh
#   CLINE_PROVIDER=openai-compatible bash scripts/00_setup_all.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
ensure_dirs

WITH_ALT_AGENTS=""
WITH_CODEX=0

usage() {
  cat <<'EOF'
使い方: bash scripts/00_setup_all.sh [オプション]

  --with-codex
        Cline CLI に加えて Codex CLI も導入し、ローカル Ollama を向ける
        （既定では導入しない）。Codex は --timeout を設定できるため、
        Cline CLI の 30 秒制限（手順書 §7）や、既定モデルでも起きうる
        editor ツールの無限ループ（手順書 §5.7）を回避したい場合の代替になる。
  --with-alt-agents[=codex|aider|qwen|all]
        Cline CLI に加えて、タイムアウトを設定できる代替エージェントも導入する
        （既定では導入しない）。値を省略すると all 扱い。--with-codex と併用可
  -h, --help
        このヘルプを表示する

環境変数（各 NN_*.sh と共通。詳細は README / docs/手順書.md）:
  BASE_MODEL, NUM_CTX, CLINE_MODEL, CLINE_PROVIDER, NODE_MAJOR など
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-codex)             WITH_CODEX=1 ;;
    --with-alt-agents)       WITH_ALT_AGENTS="all" ;;
    --with-alt-agents=*)     WITH_ALT_AGENTS="${1#*=}" ;;
    -h|--help)                usage; exit 0 ;;
    *) die "不明なオプション: $1（--help を参照）" ;;
  esac
  shift
done

cd "$SCRIPT_DIR/.."
chmod +x scripts/*.sh

SECONDS=0
hdr "colab-cline 一括セットアップ開始"
log "リポジトリ: $(pwd)"
log "BASE_MODEL=$BASE_MODEL  NUM_CTX=$NUM_CTX  CLINE_MODEL=$CLINE_MODEL  CLINE_PROVIDER=$CLINE_PROVIDER"

hdr "[1/5] 前提条件チェック (10_preflight.sh)"
bash scripts/10_preflight.sh

hdr "[2/5] Ollama とモデルの構築 (20_ollama.sh)"
bash scripts/20_ollama.sh

hdr "[3/5] Cline CLI の導入とローカル接続 (30_cline_cli.sh)"
bash scripts/30_cline_cli.sh

CODEX_INSTALLED=0
if [ "$WITH_ALT_AGENTS" = "codex" ] || [ "$WITH_ALT_AGENTS" = "all" ]; then
  CODEX_INSTALLED=1
elif [ "$WITH_CODEX" -eq 1 ]; then
  CODEX_INSTALLED=1
  hdr "[3.5/5] Codex CLI の導入 (31_alt_agents.sh codex)"
  bash scripts/31_alt_agents.sh codex
fi

if [ -n "$WITH_ALT_AGENTS" ]; then
  hdr "[3.5/5] 代替エージェントの導入 (31_alt_agents.sh $WITH_ALT_AGENTS)"
  bash scripts/31_alt_agents.sh "$WITH_ALT_AGENTS"
fi

hdr "[4/5] ターミナル用の下準備 (40_terminal_setup.sh)"
bash scripts/40_terminal_setup.sh

hdr "[5/5] 状態確認 (90_healthcheck.sh)"
bash scripts/90_healthcheck.sh

hdr "完了（所要 ${SECONDS}s）"
cat <<EOF
    これでターミナル（ノートブック下部の「ターミナル」ボタン、
    または Colab VS Code 拡張の "Colab: Open Terminal"）を開くだけで使えます。

        cd $WORKSPACE
        cline                 # 対話セッション
        cline -p "..."        # Plan モードで開始
        cline --yolo "..."    # 承認をスキップ

    ターミナルを使わず、このシェルからそのまま走らせる場合:

        bash scripts/50_run.sh "fizzbuzz.py を作って実行して"

    VM は最長 12 時間でステートレスに戻ります。作業の区切りごとに:

        cd $WORKSPACE && git add -A && git commit -m "wip" && git push
EOF

if [ "$CODEX_INSTALLED" -eq 1 ]; then
  cat <<EOF

    Codex CLI も導入済みです（--timeout を設定できるので、Cline CLI の
    30 秒制限や editor ツールの無限ループ〈手順書 §5.7〉を避けたい場合に）:

        cd $WORKSPACE
        codex                                   # 対話 TUI
        codex exec "fizzbuzz.py を作って実行して"  # 非対話
EOF
fi
