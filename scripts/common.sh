#!/usr/bin/env bash
# common.sh - 全スクリプト共通の設定と関数
# 使い方: 各スクリプトの先頭で  . "$(dirname "$0")/common.sh"
#
# 環境変数で上書き可能な設定はすべてここに集約する。

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# パス
# ---------------------------------------------------------------------------
export WORKROOT="${WORKROOT:-/content}"
export LOGDIR="${LOGDIR:-$WORKROOT/logs}"
export WORKSPACE="${WORKSPACE:-$WORKROOT/workspace}"
export STATEDIR="${STATEDIR:-$WORKROOT/.cline-env}"

# ---------------------------------------------------------------------------
# モデルプロファイル
# ---------------------------------------------------------------------------
# モデルを差し替えるたびに BASE_MODEL / NUM_CTX / CODEX_TOOL_REPAIR /
# AGENTS.md の内容を個別に合わせるのは間違えやすい。組み合わせに名前を付けて
# 1 変数で切り替えられるようにする。
#
#   MODEL_PROFILE=gpt-oss-20b bash scripts/00_setup_all.sh --with-codex
#
# 優先順位は「明示した環境変数 > プロファイル > 従来の既定値」。
# MODEL_PROFILE を指定しなければ、従来とまったく同じ挙動になる。
#
# ここで die() を使わないのは、ログ関数の定義がこの下にあるため。
export MODEL_PROFILE="${MODEL_PROFILE:-}"

_p_base=""; _p_ctx=""; _p_repair=""; _p_rules=""; _p_note=""; _p_kv=""
case "$MODEL_PROFILE" in
  "")
    # 未指定。従来の既定値をそのまま使う。
    ;;
  qwen3-8b)
    # 36 層 / KV ヘッド 8 / head_dim 128 -> q8_0 で 2*36*8*128 = 73728 B/token
    _p_base="qwen3:8b";  _p_ctx=32768; _p_repair=0; _p_rules=minimal; _p_kv=0.07
    _p_note="現行既定。tool-calling 実績あり（手順書 §5.6 の V-2 実測）"
    ;;
  qwen3-14b)
    # 40 層 / KV ヘッド 8 / head_dim 128 -> q8_0 で 81920 B/token
    _p_base="qwen3:14b"; _p_ctx=16384; _p_repair=0; _p_rules=minimal; _p_kv=0.08
    _p_note="8b と同系列。思考トークンが生成予算を食う点に注意（§5.4）"
    ;;
  gpt-oss-20b)
    # MXFP4 量子化の MoE。ollama 公称 14GB ≈ 13.0 GiB で、T4 の空き
    # （実測 14913 MiB ≈ 14.56 GiB）に対して余裕が 1GiB 程度しかない。
    # num_ctx を 32768 にすると載らないので 16384 に落としてある。
    # KV は 24 層 / KV ヘッド 8 / head_dim 64 と小さい。q8_0 で 24576 B/token。
    # 汎用の既定値 0.08 を使うと過大評価になり、載るものを NG と判定してしまう。
    # （実測はさらに小さく 0.013 MiB/token。0.024 は安全側の値として残してある）
    #
    # 2026-09-17 の実機実測（T4 / num_ctx=16384、RESULT.md 追記を参照）:
    #   MXFP4 は sm_75 でも動く。offloaded 25/25 layers, 100% GPU
    #   VRAM 12499 MiB 使用 / 2414 MiB 空き
    #   prefill 880 tok/s, generation 34.5 tok/s（qwen3:8b の 23.6 より速い）
    #   安全プロンプト長 13,645 tok（判定 OK）
    # VRAM 的には num_ctx=32768 も載るが、速度側が先に頭打ちになる
    # （安全プロンプト長が 13.6k なので 16384 で釣り合っている）。
    #
    # ★ 修復プロキシを 1 にしているのは、タグ無し JSON の修復（本来の用途）では
    #   なく **ollama/ollama#17638 の再送** のため。gpt-oss は apply_patch のような
    #   「単一のフリーフォーム文字列引数」を取るツールで出力が array-wrap になり、
    #   Ollama 自身がパースに失敗して HTTP 500 を返すことがある（非決定的・
    #   実測 0.34.1 で発生）。プロキシはこの 500 に限って投げ直す。
    #   上流が直れば 0 に戻してよい。
    _p_base="gpt-oss:20b"; _p_ctx=16384; _p_repair=1; _p_rules=minimal; _p_kv=0.024
    _p_note="MXFP4 MoE。T4 で実機確認済み（100% GPU, 34.5 tok/s）。ollama#17638 対策で再送プロキシ経由"
    ;;
  qwen25-coder-14b)
    # 評価対象からは外したが、§5.8 / §5.8.1 の再現用に定義だけ残す。
    # このモデルだけは修復プロキシと apply_patch 回避ルールが要る。
    # 48 層 / KV ヘッド 8 / head_dim 128 -> q8_0 で 98304 B/token
    _p_base="qwen2.5-coder:14b-instruct-q4_K_M"; _p_ctx=16384; _p_kv=0.094
    _p_repair=1; _p_rules=apply-patch-workaround
    _p_note="不具合の再現用（§5.8/§5.8.1）。評価対象からは外している"
    ;;
  *)
    printf '\033[31m[FATAL]\033[0m MODEL_PROFILE=%s は未知です。\n' "$MODEL_PROFILE" >&2
    printf '        使えるもの: qwen3-8b / qwen3-14b / gpt-oss-20b / qwen25-coder-14b\n' >&2
    printf '        （未指定なら従来の既定値で動きます）\n' >&2
    exit 1
    ;;
esac

# AGENTS.md に書く運用ルールの種類。
#   minimal                 … 「1ファイルずつ」「書いたら確認」程度
#   apply-patch-workaround  … qwen2.5-coder 用。apply_patch を禁じ heredoc を強制
export AGENTS_RULESET="${AGENTS_RULESET:-${_p_rules:-minimal}}"

# KV キャッシュの 1 トークンあたりのサイズ（MiB, q8_0 想定）。
# 20_ollama.sh の pull 前 VRAM チェックが使う。モデルの層数 / KV ヘッド数 /
# head_dim で決まるのでモデルごとに違う。既定は安全側に倒した汎用値。
export KV_MIB_PER_TOKEN="${KV_MIB_PER_TOKEN:-${_p_kv:-0.08}}"

# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------
# 127.0.0.1 のみ。外部公開はしない（する必要が無い構成になった）。
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"

# T4 (sm_75) は bf16 非対応。GGUF 量子化で回避する。
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
# ★重要: Cline CLI は Ollama へのリクエストを 30 秒でタイムアウトする（cline#9182）。
#   モデルのロード時間がその 30 秒に食い込むと確実に落ちるので、絶対にアンロードさせない。
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-/root/.ollama/models}"

# 既定は qwen3:8b。理由は docs/手順書.md §5.6 — qwen2.5-coder:7b-instruct-q4_K_M は
# 「Capabilities: tools」を名乗るが、Ollama の <tool_call> ラッパー要求に実際には従わない
# （生の JSON をそのままテキストで返す）。Cline はそれをツール呼び出しとして解釈できず、
# チャットで説明するだけで一切ファイルを書かない。qwen3:8b は同一条件で <tool_call> を
# 正しく守り、実タスクが完走することを実機で確認済み（V-2 実測、2026-09-03）。
export BASE_MODEL="${BASE_MODEL:-${_p_base:-qwen3:8b}}"
export CLINE_MODEL="${CLINE_MODEL:-cline-coder}"
export NUM_CTX="${NUM_CTX:-${_p_ctx:-32768}}"
export NUM_PREDICT="${NUM_PREDICT:-8192}"

# Cline CLI が 1 リクエストに使える秒数（実測値の評価基準に使う）
export CLINE_REQUEST_BUDGET_SEC="${CLINE_REQUEST_BUDGET_SEC:-30}"

# ---------------------------------------------------------------------------
# Codex CLI 用ツール呼び出し修復プロキシ（手順書 §5.8）
# ---------------------------------------------------------------------------
# qwen2.5-coder 系は Ollama の <tool_call> ラッパー要求に従わず、ツール呼び出しの
# JSON を message.content にプレーンテキストで返すことがある（§5.6 と同根、
# openai/codex#2229）。CODEX_TOOL_REPAIR=1（既定）のとき、31_alt_agents.sh は
# scripts/32_codex_tool_proxy.py を Codex と Ollama の間に起動し、Codex の
# config.toml をこのプロキシへ向ける。0 にすると旧来どおり Ollama に直結する。
#
# 既定値はプロファイル依存。壊れていないモデル（qwen3 系・gpt-oss）に噛ませても
# 益は無く、ストリーミング表示を 1 チャンクに潰す副作用だけが残るため 0 にする。
# プロファイル未指定のときは従来どおり 1（qwen2.5-coder を想定した既定）。
export CODEX_TOOL_REPAIR="${CODEX_TOOL_REPAIR:-${_p_repair:-1}}"
export CODEX_PROXY_PORT="${CODEX_PROXY_PORT:-11435}"
export CODEX_PROXY_BASE_URL="${CODEX_PROXY_BASE_URL:-http://127.0.0.1:$CODEX_PROXY_PORT}"

# ---------------------------------------------------------------------------
# Cline CLI
# ---------------------------------------------------------------------------
export NODE_MAJOR="${NODE_MAJOR:-22}"
# Ollama プロバイダを使うか、OpenAI 互換 (/v1) 経由にするか。
#   ollama          … 素直だが 30 秒タイムアウトの影響を受ける
#   openai-compatible … /v1 経由。30 秒制限を回避できる可能性がある（要検証 V-4）
export CLINE_PROVIDER="${CLINE_PROVIDER:-ollama}"
export CLINE_DATA_DIR="${CLINE_DATA_DIR:-$HOME/.cline}"

# ---------------------------------------------------------------------------
# ターミナル（無料枠用）
# ---------------------------------------------------------------------------
export XTERM_PORT="${XTERM_PORT:-10001}"
export XTERM_HEIGHT="${XTERM_HEIGHT:-600}"

# ---------------------------------------------------------------------------
# ログ出力
# ---------------------------------------------------------------------------
_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_green=$'\033[32m'
_c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_bold=$'\033[1m'

log()  { printf '%s[ INFO]%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()   { printf '%s[   OK]%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '%s[ WARN]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s[FATAL]%s %s\n' "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }
hdr()  { printf '\n%s=== %s ===%s\n' "$_c_bold" "$*" "$_c_reset"; }

# bash の既知の罠: ERR トラップは `set +e` を敷いていても発火する（`set -e` の
# 免除規則と同じ条件でしか止まらないだけで、trap 自体の発火は errexit の on/off と
# 無関係）。そのため `set +e` で「失敗を握りつぶして最後に判定する」つもりのコードでも
# 最初の失敗で die() が走ってしまっていた（30_cline_cli.sh など）。
# $- を見て errexit が実際に有効なときだけ die する。
trap 'if [[ $- == *e* ]]; then die "line $LINENO で失敗しました (exit=$?)"; fi' ERR

# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------
# 選択中のモデル構成を 1 行で示す。どのモデルで測った数字なのかを
# ログに必ず残すため、主要スクリプトの冒頭で呼ぶ。
model_profile_banner() {
  if [ -n "$MODEL_PROFILE" ]; then
    log "MODEL_PROFILE=$MODEL_PROFILE"
    [ -n "${_p_note:-}" ] && printf '       %s\n' "$_p_note"
  else
    log "MODEL_PROFILE 未指定（従来の既定値で動きます）"
  fi
  printf '       BASE_MODEL=%s  NUM_CTX=%s  CODEX_TOOL_REPAIR=%s  AGENTS_RULESET=%s\n' \
         "$BASE_MODEL" "$NUM_CTX" "$CODEX_TOOL_REPAIR" "$AGENTS_RULESET"
}

ensure_dirs() { mkdir -p "$LOGDIR" "$WORKSPACE" "$STATEDIR"; }

have() { command -v "$1" >/dev/null 2>&1; }

# first_line <コマンド...> — 版数などを 1 行だけ安全に取り出す。
#
# `$(cmd 2>&1 | head -1)` を直接書いてはいけない。理由が 2 つある。
#   1. set -Eeuo pipefail 下では、cmd が非ゼロ終了したり head -1 が
#      早期に閉じて SIGPIPE を起こしたりすると、コマンド置換のサブシェルで
#      ERR trap が発火し、実際には失敗していないのに [FATAL] が出る
#      （親シェルは死なないので「FATAL の直後に OK が出る」謎の出力になる）。
#   2. 警告を stderr に出すコマンドだと、head -1 が版数ではなく警告を拾う。
# ここでは失敗を握りつぶし、stdout を優先して stderr にフォールバックする。
first_line() {
  local tmp out
  tmp="$(mktemp)"
  out="$("$@" 2>"$tmp" | head -1 || true)"
  [ -n "$out" ] || out="$(head -1 "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  printf '%s\n' "$out"
}

# root でなければ sudo を挟む。Colab は root なのでそのまま実行される。
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "root 権限が必要ですが sudo がありません: $*"
  fi
}

# ensure_cmd <コマンド名> [パッケージ名]
#   コマンドが無ければ apt で導入する（冪等）。パッケージ名の既定はコマンド名。
#   Colab の VM は最小構成で、公式インストーラが前提にしているツールが
#   入っていないことがある（例: ollama の install.sh が要求する zstd）。
ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}" aptlog
  if have "$cmd"; then
    return 0
  fi
  mkdir -p "$LOGDIR"
  aptlog="$LOGDIR/apt.log"
  log "$cmd がありません。apt で $pkg を導入します（ログ: $aptlog）"
  if ! DEBIAN_FRONTEND=noninteractive as_root apt-get install -y "$pkg" >>"$aptlog" 2>&1; then
    log "  失敗したので apt-get update してから再試行します"
    DEBIAN_FRONTEND=noninteractive as_root apt-get update >>"$aptlog" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive as_root apt-get install -y "$pkg" >>"$aptlog" 2>&1 \
      || die "$pkg の導入に失敗しました。ログ: $aptlog"
  fi
  have "$cmd" || die "$pkg を導入しましたが $cmd が PATH にありません。ログ: $aptlog"
  ok "$cmd を導入しました（$pkg）"
}

port_open() {
  local host="$1" port="$2"
  python3 - "$host" "$port" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(1.0)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
}

wait_http() {
  local url="$1" timeout="${2:-90}" label="${3:-$1}" i=0
  log "$label の起動を待機中 (最大 ${timeout}s): $url"
  while [ "$i" -lt "$timeout" ]; do
    curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && { ok "$label が応答しました (${i}s)"; return 0; }
    sleep 1; i=$((i + 1))
  done
  return 1
}

# 冪等なバックグラウンド起動。setsid で親から切り離すので、
# ノートブックのセルが終了しても生き残る。
start_bg() {
  local name="$1" logfile="$2"; shift 2
  local pidfile="$STATEDIR/$name.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    ok "$name は既に起動しています (pid=$(cat "$pidfile"))"; return 0
  fi
  log "$name を起動します -> $logfile"
  setsid nohup "$@" >>"$logfile" 2>&1 &
  echo $! >"$pidfile"
  sleep 1
  kill -0 "$(cat "$pidfile")" 2>/dev/null || die "$name の起動に失敗。$logfile を確認してください"
  ok "$name を起動しました (pid=$(cat "$pidfile"))"
}

stop_bg() {
  local name="$1"
  local pidfile="$STATEDIR/$name.pid" pid
  [ -f "$pidfile" ] || { log "$name は起動していません"; return 0; }
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true
    ok "$name を停止しました (pid=$pid)"
  fi
  rm -f "$pidfile"
}
