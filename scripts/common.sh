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

# 既定は 7B。理由は docs/手順書.md §5 — CLI の 30 秒制限下では
# 「賢さ」より「prompt eval の速さ」が実用性を決める。
export BASE_MODEL="${BASE_MODEL:-qwen2.5-coder:7b-instruct-q4_K_M}"
export CLINE_MODEL="${CLINE_MODEL:-cline-coder}"
export NUM_CTX="${NUM_CTX:-32768}"
export NUM_PREDICT="${NUM_PREDICT:-8192}"

# Cline CLI が 1 リクエストに使える秒数（実測値の評価基準に使う）
export CLINE_REQUEST_BUDGET_SEC="${CLINE_REQUEST_BUDGET_SEC:-30}"

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

trap 'die "line $LINENO で失敗しました (exit=$?)"' ERR

# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------
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
  local name="$1" pidfile="$STATEDIR/$name.pid" pid
  [ -f "$pidfile" ] || { log "$name は起動していません"; return 0; }
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true
    ok "$name を停止しました (pid=$pid)"
  fi
  rm -f "$pidfile"
}
