#!/usr/bin/env bash
# 40_terminal_setup.sh - Colab のターミナルから Cline をすぐ使える状態にする（冪等）
#
# ターミナルの出し方（どれも Google 公式機能・全ユーザーが無料で使える）:
#
#   1. Colab ノートブック UI      下部ツールバーの「ターミナル」ボタン
#                                 2025-06-23 に全ユーザーへ無料開放された
#   2. Colab VS Code 拡張         コマンドパレット > `Colab: Open Terminal`
#                                 （実験的機能。Colab ランタイムに繋がる）
#
# ※ 以前は colab-xterm (%xterm) が必要だと書いていましたが、不要です。
#
# このスクリプトが解決する問題:
#   ターミナルはノートブックのカーネルとは**別のシェル**なので、
#   セルで設定した環境変数を引き継ぎません。
#   Ollama の設定と作業ディレクトリを ~/.bashrc に仕込んでおきます。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

BASHRC="$HOME/.bashrc"
MARKER="# >>> colab-cline >>>"
END_MARKER="# <<< colab-cline <<<"

hdr "1. ~/.bashrc の設定"

mkdir -p "$(dirname "$BASHRC")"
touch "$BASHRC"

# 既存ブロックがあれば取り除いてから入れ直す（冪等・設定変更が反映される）
if [ -f "$BASHRC" ] && grep -qF "$MARKER" "$BASHRC"; then
  log "既存のブロックを更新します"
  python3 - "$BASHRC" "$MARKER" "$END_MARKER" <<'PY'
import sys
path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines(True)
out, skip = [], False
for ln in lines:
    if ln.strip() == start:
        skip = True
        continue
    if ln.strip() == end:
        skip = False
        continue
    if not skip:
        out.append(ln)
open(path, "w", encoding="utf-8").writelines(out)
PY
else
  log "新しくブロックを追記します"
fi

cat >>"$BASHRC" <<EOF
$MARKER
export OLLAMA_HOST=$OLLAMA_HOST
export OLLAMA_KEEP_ALIVE=$OLLAMA_KEEP_ALIVE
export OLLAMA_BASE_URL=$OLLAMA_BASE_URL
export CLINE_MODEL=$CLINE_MODEL
export PATH="\$PATH:/usr/local/bin:/usr/bin"
[ -d "$WORKSPACE" ] && cd "$WORKSPACE"

colab_cline_banner() {
  echo
  echo "  ── Colab T4 + Cline ─────────────────────────────────"
  if curl -fsS --max-time 2 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
    echo "   Ollama : up (\$OLLAMA_BASE_URL)"
  else
    echo "   Ollama : DOWN  -> bash /content/colab-cline/scripts/20_ollama.sh"
  fi
  echo "   model  : \$CLINE_MODEL"
  echo "   cwd    : \$(pwd)"
  echo
  echo "   cline                 対話セッション"
  echo "   cline -p '...'        Plan モードで開始"
  echo "   cline --yolo '...'    承認をスキップ"
  echo "   cline doctor          設定の診断"
  echo "   cline config          現在の設定（★ローカルを向いているか確認）"
  echo "  ─────────────────────────────────────────────────────"
  echo
}
# 対話シェルのときだけバナーを出す（スクリプトから source されたとき邪魔しない）
case \$- in *i*) colab_cline_banner ;; esac
$END_MARKER
EOF
ok "$BASHRC を更新しました"

hdr "2. ログインシェルでも読ませる"
# bash は .bashrc を「対話シェル」でしか読まない。
# ログインシェルとして起動された場合に備えて .bash_profile からも読ませる。
PROFILE="$HOME/.bash_profile"
touch "$PROFILE"
if grep -qF 'colab-cline: source .bashrc' "$PROFILE" 2>/dev/null; then
  ok "$PROFILE は設定済みです"
else
  cat >>"$PROFILE" <<'EOF'
# colab-cline: source .bashrc
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
  ok "$PROFILE から .bashrc を読むようにしました"
fi

hdr "3. ターミナルから見えるかの確認"
# Colab のターミナルは対話シェルなので、同じ条件（bash -i）で確かめる
if bash -ic 'command -v cline >/dev/null' </dev/null >/dev/null 2>&1; then
  ok "cline が PATH にあります: $(command -v cline 2>/dev/null || echo '(パス取得は省略)')"
else
  warn "対話シェルから cline が見えません。先に 30_cline_cli.sh を実行してください。"
fi

if curl -fsS --max-time 5 "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
  ok "Ollama が応答しています"
else
  warn "Ollama が応答していません。先に 20_ollama.sh を実行してください。"
fi

hdr "完了"
cat <<EOF
    ターミナルを開いてください:

    ${_c_bold}1) Colab ノートブック UI${_c_reset}
       画面下部のツールバーにある「ターミナル」ボタン
       （2025-06-23 から全ユーザーが無料で使えます）

    ${_c_bold}2) Colab VS Code 拡張${_c_reset}
       コマンドパレット (Ctrl/Cmd+Shift+P) > "Colab: Open Terminal"
       またはノートブック上部の Colab ボタン > Open Terminal

    どちらも Colab ランタイム上のシェルなので、cline から
    $OLLAMA_BASE_URL にそのまま届きます。

    開いたら上のバナーが出ます。出ない場合は  source ~/.bashrc  を実行してください。
EOF
