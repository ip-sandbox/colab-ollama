#!/usr/bin/env bash
# remote/common.sh - 手元から Colab VM を操作するための共通設定と関数
#
# 使い方: 各スクリプトの先頭で  . "$(dirname "$0")/common.sh"
#
# scripts/common.sh は「VM の中で」動く設定、こちらは「手元で」動く設定。
# 混ざると事故るので、変数名の接頭辞を COLAB_ / REMOTE_ で分けている。
#
# 前提: colab CLI >= 0.7.0（colab ssh が入ったバージョン）。
#       PyPI には 0.6.0 までしか出ていないので git から入れる必要がある。
#       詳細は docs/リモート化計画.md §0.1。

set -Eeuo pipefail

REMOTE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$REMOTE_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# セッション
# ---------------------------------------------------------------------------
export COLAB_SESSION="${COLAB_SESSION:-colab-ollama}"

# T4|L4|G4|H100|A100 のみ。
# ★ colab CLI は未知の値を渡すと黙って A100 にフォールバックする（付属の
#   COLAB_SKILL.md に明記）。A100 は無料枠では引けないので、次のステップで
#   意味不明な 400 が返ってくることになる。ここで先に弾く。
export COLAB_GPU="${COLAB_GPU:-T4}"

# 認証方式。
# ★ 手元の実環境では oauth2 が既に通っている（~/.config/colab-cli/token.json）。
#   計画段階では adc を既定にするつもりだったが、ADC は未設定だったので
#   oauth2 を既定にした。adc に切り替えたい場合は §0.2 の gcloud コマンドで
#   スコープ 4 つを明示して取り直してから COLAB_AUTH=adc を指定すること。
export COLAB_AUTH="${COLAB_AUTH:-oauth2}"

# colab CLI のセッション状態ファイル。既定（~/.config/colab-cli/sessions.json）の
# ままで良いが、並行作業するときはここを分けると混ざらない。
export COLAB_CONFIG="${COLAB_CONFIG:-}"

# ---------------------------------------------------------------------------
# VM 側のパス
# ---------------------------------------------------------------------------
export REMOTE_ROOT="${REMOTE_ROOT:-/content/colab-cline}"
export REMOTE_WORKSPACE="${REMOTE_WORKSPACE:-/content/workspace}"
export REMOTE_LOGDIR="${REMOTE_LOGDIR:-/content/logs}"

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
export SSH_IDENTITY="${SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
# 生成物。git に入れない（セッション名が焼き込まれるため）
export SSH_CONFIG="${SSH_CONFIG:-$REMOTE_DIR/.ssh_config}"
export SSH_HOST_ALIAS="colab-vm"
# 接続多重化のソケット。UNIX ドメインソケットのパス長上限（約 104 文字）に
# 引っかかるとエラーになるので、リポジトリの下ではなく /tmp に置く。
export SSH_CONTROL_PATH="${SSH_CONTROL_PATH:-/tmp/.colab-cm-$COLAB_SESSION}"

# ---------------------------------------------------------------------------
# ログ出力（scripts/common.sh と同じ見た目にそろえる）
# ---------------------------------------------------------------------------
_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_green=$'\033[32m'
_c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_bold=$'\033[1m'

log()  { printf '%s[ INFO]%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()   { printf '%s[   OK]%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '%s[ WARN]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
hdr()  { printf '\n%s=== %s ===%s\n' "$_c_bold" "$*" "$_c_reset"; }

# die は「VM を止め忘れていないか」を必ず思い出させる。
# 停止忘れがこの構成でいちばん高くつく事故なので、失敗時は毎回出す。
die() {
  printf '%s[FATAL]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2
  printf '\n    VM が起動したままかもしれません。確認と停止:\n' >&2
  printf '        bash remote/09_stop.sh\n' >&2
  printf '        %s sessions\n\n' "$(colab_cmd_str)" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# colab CLI の呼び出し
# ---------------------------------------------------------------------------
# グローバルフラグ（--auth / --config）は**サブコマンドより前**に置く必要がある。
# 後ろに書くと typer に叱られるので、必ずこの関数を経由すること。
colab_cli() {
  local args=(--auth="$COLAB_AUTH")
  [ -n "$COLAB_CONFIG" ] && args+=(--config "$COLAB_CONFIG")
  command colab "${args[@]}" "$@"
}

# エラーメッセージ表示用の文字列版
colab_cmd_str() {
  if [ -n "$COLAB_CONFIG" ]; then
    printf 'colab --auth=%s --config %s' "$COLAB_AUTH" "$COLAB_CONFIG"
  else
    printf 'colab --auth=%s' "$COLAB_AUTH"
  fi
}

# ---------------------------------------------------------------------------
# 前提チェック
# ---------------------------------------------------------------------------

# colab CLI が 0.7.0 以上か。0.6.x には colab ssh が無い。
require_colab_version() {
  have colab || die "colab CLI がありません。導入:
       uv tool install \"git+https://github.com/googlecolab/google-colab-cli@v0.7.1\""

  local ver major minor
  ver="$(command colab version 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -1)"
  [ -n "$ver" ] || die "colab のバージョンを判定できませんでした（colab version の出力が想定外）"

  major="${ver%%.*}"
  minor="$(printf '%s' "$ver" | cut -d. -f2)"
  if [ "$major" -eq 0 ] && [ "$minor" -lt 7 ]; then
    die "colab CLI $ver には 'colab ssh' がありません（0.7.0 で追加）。
     PyPI には 0.6.0 までしか出ていないので、git から入れ直してください:

         uv tool install --force \"git+https://github.com/googlecolab/google-colab-cli@v0.7.1\"

     詳細: docs/リモート化計画.md §0.1"
  fi
  ok "colab CLI $ver（ssh 対応）"
}

require_gpu_valid() {
  case "$COLAB_GPU" in
    # cpu / none は「アクセラレータ無しで取る」。T4 が Service Unavailable で
    # 取れないときの退避先。Ollama で大きいモデルは動かせない（無料枠の CPU
    # ランタイムは RAM 約 12.7GB）が、ツール呼び出しまわりの検証には使える。
    cpu|CPU|none|NONE) COLAB_GPU="cpu" ;;
    T4|L4|G4|H100|A100) ;;
    *) die "COLAB_GPU=$COLAB_GPU は不正です。T4 / L4 / G4 / H100 / A100 のいずれかにしてください。
     ★ colab CLI は未知の値を黙って A100 に読み替えるため、ここで弾いています。
     無料枠で引ける GPU は T4 のみです（L4 は不可、TPU v5e-1 は Ollama 非対応）。
     GPU 無しで取るなら COLAB_GPU=cpu を指定してください。" ;;
  esac
}

require_ssh_key() {
  # サーバ側は RSA 鍵を拒否する。ed25519 か ecdsa が要る。
  if [ ! -f "$SSH_IDENTITY" ]; then
    die "SSH 秘密鍵がありません: $SSH_IDENTITY
     ★ Colab 側は ssh-rsa を拒否します。ed25519 で作ってください:
         ssh-keygen -t ed25519 -f $SSH_IDENTITY -N ''"
  fi
  case "$(ssh-keygen -y -f "$SSH_IDENTITY" 2>/dev/null | awk '{print $1}')" in
    ssh-ed25519|ecdsa-sha2-*) ;;
    ssh-rsa) die "$SSH_IDENTITY は RSA 鍵です。Colab 側がサーバで拒否します。
     ed25519 を作って SSH_IDENTITY に指定してください。" ;;
    "") die "$SSH_IDENTITY から公開鍵を導出できませんでした（パスフレーズ付き？）。" ;;
  esac
}

# セッションがサーバ側に存在するか
session_exists() {
  colab_cli sessions 2>/dev/null | grep -qF "$COLAB_SESSION"
}

require_session() {
  # die() は「VM が起動したままかも」と停止を促すが、ここはまさに
  # VM が無いケースなので矛盾する。専用のメッセージで抜ける。
  session_exists && return 0
  printf '%s[FATAL]%s セッション "%s" がありません。先に作ってください:\n' \
         "$_c_red" "$_c_reset" "$COLAB_SESSION" >&2
  printf '            bash remote/01_new.sh\n\n' >&2
  printf '    別の名前で作っている場合は COLAB_SESSION を指定してください。\n' >&2
  printf '    いま動いているものの一覧:  %s sessions\n\n' "$(colab_cmd_str)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------

# ~/.ssh/config に書く代わりに、専用の config を生成して -F で渡す。
# 手元の ~/.ssh/config を汚さずに済み、セッション名を変えても作り直すだけで済む。
write_ssh_config() {
  local proxy
  # ★ colab ssh を直接書かない。セッションが無いと黙って新しい VM を
  #   （しかも --gpu 未指定なので CPU で）作ってしまうため、
  #   remote/proxycommand.sh を挟んで存在確認してから繋ぐ。理由の詳細は
  #   proxycommand.sh の先頭コメント。
  proxy="$REMOTE_DIR/proxycommand.sh"
  cat >"$SSH_CONFIG" <<EOF
# 自動生成: remote/common.sh（編集しても次回上書きされます）
# セッション: $COLAB_SESSION / GPU: $COLAB_GPU

Host $SSH_HOST_ALIAS
    HostName colab-runtime
    User root
    IdentityFile $SSH_IDENTITY
    IdentitiesOnly yes
    ProxyCommand $proxy
    # VM は毎回作り直されてホスト鍵が変わる。既知ホストの照合は無意味なので切る。
    # 経路そのものは Google への認証済み WebSocket なので、ここは中間者の
    # 心配をする箇所ではない（手元の ~/.ssh/known_hosts も汚さない）。
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ServerAliveInterval 30
    ServerAliveCountMax 6
    # 接続を多重化する。ProxyCommand は 1 回ごとに colab CLI を起動して
    # 認証し直すため、素朴に ssh を繰り返すと 1 回あたり数秒かかる。
    # ログのポーリングなど短い呼び出しを何十回もするので、ここが効く。
    ControlMaster auto
    ControlPath $SSH_CONTROL_PATH
    ControlPersist 10m
EOF
  chmod 600 "$SSH_CONFIG"
}

# 多重化ソケットを畳む。VM を止める前に呼ぶ（残ると次回 stale になる）。
close_ssh_master() {
  [ -S "$SSH_CONTROL_PATH" ] || return 0
  ssh -F "$SSH_CONFIG" -O exit "$SSH_HOST_ALIAS" >/dev/null 2>&1 || true
  rm -f "$SSH_CONTROL_PATH"
}

# ssh の終了コード 255 は「経路そのものの失敗」。いちばん多い原因は
# VM が消えていること（Colab は free 枠のセッションを勝手に回収する）。
# ProxyCommand が出した stderr は ssh に飲まれて表示されないので、
# ここで拾って案内する。
_explain_ssh_255() {
  [ "$1" -eq 255 ] || return "$1"
  {
    printf '\n%s[ヒント]%s ssh の経路が張れませんでした (exit 255)。\n' \
           "$_c_yellow" "$_c_reset"
    if session_exists; then
      printf '    セッションはあります。VM 側がまだ起動しきっていないか、\n'
      printf '    多重化ソケットが古くなっている可能性があります:\n'
      printf '        rm -f %s\n' "$SSH_CONTROL_PATH"
    else
      printf '    ★ セッション "%s" が消えています。\n' "$COLAB_SESSION"
      printf '      Colab は free 枠の VM を予告なく回収します。\n'
      printf '      作り直してください:  bash remote/01_new.sh\n'
    fi
  } >&2
  return 255
}

# rsh <コマンド...> — VM 上でシェルコマンドを 1 つ実行する。
# 標準入出力はそのまま素通しするので、パイプもリダイレクトも普通に使える。
rsh() {
  [ -f "$SSH_CONFIG" ] || write_ssh_config
  local rc=0
  ssh -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- "$@" || rc=$?
  [ "$rc" -eq 0 ] || _explain_ssh_255 "$rc" || return $?
  return "$rc"
}

# rsh_tty <コマンド...> — 端末を割り当てて実行する（TUI 用）
rsh_tty() {
  [ -f "$SSH_CONFIG" ] || write_ssh_config
  local rc=0
  ssh -t -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- "$@" || rc=$?
  [ "$rc" -eq 0 ] || _explain_ssh_255 "$rc" || return $?
  return "$rc"
}

# rpush <ローカルディレクトリ> <VM 上のパス>
#   rsync が手元に無い環境でも動くよう tar 経由にしている。
#   .git と __pycache__ は送らない（VM 側は git clone しないので .git は不要）。
rpush() {
  local src="$1" dst="$2"
  [ -d "$src" ] || die "rpush: ディレクトリがありません: $src"
  [ -f "$SSH_CONFIG" ] || write_ssh_config
  tar -C "$src" \
      --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
      --exclude='.ssh_config' --exclude='node_modules' \
      -czf - . \
    | ssh -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- \
        "mkdir -p '$dst' && tar -C '$dst' -xzf -"
}

# vm_bootstrap_env — VM 側の環境を SSH から使える状態にする（冪等）
#
# ★ これを飛ばすと静かに壊れる。実機で踏んだ罠:
#
#   Colab のノートブックカーネルは LD_LIBRARY_PATH=/usr/lib64-nvidia を
#   設定しているが、**素の SSH ログインにはそれが引き継がれない**。
#   その結果、GPU デバイス（/dev/nvidia0）は見えているのに
#
#       NVIDIA-SMI couldn't find libnvidia-ml.so library in your system
#
#   となる。怖いのは nvidia-smi が落ちることではなく、**Ollama が CUDA を
#   検出できずに黙って CPU にフォールバックする**こと。エラーも出ないまま
#   推論が一桁遅くなり、ベンチの数字が丸ごと無意味になる。
#
#   環境変数ではなく ldconfig で直すのは、Ollama をどう起動しても
#   （nohup でも systemd 風でも子プロセスでも）効かせるため。
vm_bootstrap_env() {
  rsh "set -e
    # 1. NVIDIA ライブラリをローダの探索パスに入れる
    if [ ! -f /etc/ld.so.conf.d/colab-nvidia.conf ]; then
      echo /usr/lib64-nvidia > /etc/ld.so.conf.d/colab-nvidia.conf
      # 既存の無関係な警告（libtbbbind 等が symlink でない）が出るので捨てる
      ldconfig 2>/dev/null || true
    fi
    # 2. 対話シェル用にも入れておく（ssh -t で入ったとき用）
    cat > /etc/profile.d/colab-nvidia.sh <<'PROFILE'
# 自動生成: remote/common.sh vm_bootstrap_env
export LD_LIBRARY_PATH=\"/usr/lib64-nvidia\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"
export PATH=\"/usr/local/bin:\$PATH\"
PROFILE
    chmod 644 /etc/profile.d/colab-nvidia.sh
  " || return 1

  # 直ったことを実際に確かめる。ここを確認せずに進むと上の罠に戻る。
  rsh 'nvidia-smi -L' >/dev/null 2>&1
}

# rpull <VM 上のパス> <ローカルディレクトリ>
rpull() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  [ -f "$SSH_CONFIG" ] || write_ssh_config
  ssh -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- \
      "tar -C '$(dirname "$src")' -czf - '$(basename "$src")'" \
    | tar -C "$dst" -xzf -
}

# ---------------------------------------------------------------------------
# 単体でも使えるようにしておく:  bash remote/common.sh -c 'nvidia-smi'
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    -c) shift; require_colab_version >/dev/null; require_session; rsh "$@" ;;
    *)  printf '使い方: bash remote/common.sh -c "<VM 上で実行するコマンド>"\n' >&2; exit 2 ;;
  esac
fi
