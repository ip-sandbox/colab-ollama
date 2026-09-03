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
NODE_UPGRADED=0
if have node; then
  NODE_VER="$(node --version | tr -d 'v')"
  # Colab の既定は Node 20 系。Cline CLI は 20 でも一応起動するが、
  #   [cline] Node 20.19.0 cannot read the OS trust store (needs >= 22.15)
  # と警告し、OS の証明書ストアを読めないまま動く。しきい値は 20 ではなく
  # NODE_MAJOR（既定 22）にする。
  if [ "${NODE_VER%%.*}" -ge "$NODE_MAJOR" ]; then
    ok "node v$NODE_VER（要件 >= $NODE_MAJOR を満たしています）"
    NEED_NODE=0
  else
    warn "node v$NODE_VER は Cline CLI の要件 (>= $NODE_MAJOR) を満たしません。入れ直します。"
  fi
fi
if [ "$NEED_NODE" -eq 1 ]; then
  log "NodeSource から Node $NODE_MAJOR を導入します（1〜3 分）"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | as_root bash - \
       >"$LOGDIR/nodesource.log" 2>&1 \
    || die "NodeSource のセットアップに失敗しました。ログ: $LOGDIR/nodesource.log"
  DEBIAN_FRONTEND=noninteractive as_root apt-get install -y nodejs \
       >>"$LOGDIR/nodesource.log" 2>&1 \
    || die "nodejs の導入に失敗しました。ログ: $LOGDIR/nodesource.log"
  have node || die "Node の導入に失敗しました。ログ: $LOGDIR/nodesource.log"
  NODE_UPGRADED=1
  ok "node $(first_line node --version) / npm $(first_line npm --version)"
fi

hdr "2. Cline CLI"
# Node を入れ替えるとグローバル npm の prefix が変わることがあり、
# 旧 Node 向けに入れた cline が壊れたまま PATH に残る。入れ直す。
if have cline && [ "$NODE_UPGRADED" -eq 0 ]; then
  ok "導入済み: $(first_line cline --version)"
else
  if [ "$NODE_UPGRADED" -eq 1 ]; then
    log "Node を入れ替えたので Cline CLI を入れ直します"
  fi
  log "npm install -g cline（1〜3 分）"
  npm install -g cline >"$LOGDIR/npm-cline.log" 2>&1 || die "導入に失敗。ログ: $LOGDIR/npm-cline.log"
  have cline || die "cline が PATH に見つかりません。ログ: $LOGDIR/npm-cline.log"
  ok "導入完了: $(first_line cline --version)"
fi

hdr "3. 前提の確認"
curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1 \
  || die "Ollama が $OLLAMA_BASE_URL で応答しません。先に 20_ollama.sh を実行してください。"
ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${CLINE_MODEL}" \
  || die "モデル \"$CLINE_MODEL\" がありません。先に 20_ollama.sh を実行してください。"
ok "Ollama とモデルを確認しました"

hdr "4. プロバイダ設定"
# 注意: `cline config set key=value` は CLI 3.x では廃止されている
# （`error: too many arguments. Expected 1 argument but got 2.` で失敗する）。
# `cline config` はショー専用コマンドになり、非対話での設定投入は
# `cline auth -p <provider> -m <model> [-b <baseurl>] -k <apikey>` を使う。
# Plan/Act 別プロバイダの概念も無くなり、`cline auth` は現行プロバイダを 1 つ設定する。
#
# `-b/--baseurl` は ollama プロバイダには使えない
# （"base URL is only supported for OpenAI and OpenAI-compatible providers"）。
# ollama プロバイダは常に既定の 127.0.0.1:11434 を見に行く。
#
# `-k/--apikey` は ollama では中身を見ないが必須（無いと
# "auth quick setup requires --apikey <key>" で失敗する）。ダミー値で良い。
case "$CLINE_PROVIDER" in
  ollama)
    log "Ollama プロバイダとして設定します"
    log "  cline auth -p ollama -m $CLINE_MODEL -k ollama"
    cline auth -p ollama -m "$CLINE_MODEL" -k ollama \
         >>"$LOGDIR/cline-config.log" 2>&1 \
      || warn "cline auth に失敗しました。ログ: $LOGDIR/cline-config.log"
    ;;
  openai-compatible)
    # Ollama の /v1 は OpenAI 互換。Ollama 専用ハンドラの 30 秒タイムアウト
    # （cline#9182）を迂回できる可能性がある。手順書 §7 / V-4 を参照。
    # `-p openai` に `-b` を付けると "openai-compatible" プロバイダとして設定される。
    log "OpenAI 互換エンドポイント経由で設定します（30 秒制限の回避を狙う）"
    log "  cline auth -p openai -m $CLINE_MODEL -b ${OLLAMA_BASE_URL}/v1 -k ollama"
    cline auth -p openai -m "$CLINE_MODEL" -b "${OLLAMA_BASE_URL}/v1" -k ollama \
         >>"$LOGDIR/cline-config.log" 2>&1 \
      || warn "cline auth に失敗しました。ログ: $LOGDIR/cline-config.log"
    ;;
  *)
    die "CLINE_PROVIDER は ollama か openai-compatible を指定してください（現在: $CLINE_PROVIDER）"
    ;;
esac

hdr "5. 設定の実出力（★必ず目視で確認）"
cat <<'EOT'
    下の出力に、指定したプロバイダとモデルが反映されているかを確認してください。
    反映されていなければ、対話モードで設定し直します:

        cline auth          # 矢印キーで Ollama を選び、モデルを選択
        cline config        # 対話的に設定を編集（TTY 必須。この場では実行できない）

    ここを確認せずに進むと、ローカルの Ollama ではなく
    Cline のクラウドアカウントに投げ続けることになります。

EOT
# `cline config`（引数なし）は CLI 3.x では対話モード専用になり、
# TTY が無いここでは "interactive mode requires a TTY" で必ず失敗する。
# 設定ファイルを直接見て確認する。
PROVIDERS_JSON="${CLINE_DATA_DIR}/data/settings/providers.json"
if [ -f "$PROVIDERS_JSON" ]; then
  log "lastUsedProvider と設定内容 ($PROVIDERS_JSON):"
  python3 -c "
import json
d = json.load(open('$PROVIDERS_JSON'))
print('    lastUsedProvider:', d.get('lastUsedProvider'))
p = d.get('providers', {}).get(d.get('lastUsedProvider'), {})
print('    settings:', json.dumps(p.get('settings', {}), ensure_ascii=False))
"
else
  warn "$PROVIDERS_JSON がありません。cline auth が失敗した可能性があります。"
fi

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
