#!/usr/bin/env bash
# 10_preflight.sh - 着手前に「そもそもこの VM で成立するか」を確認する
#
# ここで落ちたら、後段のセットアップ（十数分かかる）をやる価値がない。
# 判定は落とさず警告に留め、最後にサマリを出す。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

hdr "1. GPU"
if ! have nvidia-smi; then
  die "nvidia-smi がありません。ランタイムのタイプが GPU になっていない可能性があります。
     Colab メニュー: ランタイム > ランタイムのタイプを変更 > ハードウェア アクセラレータ = T4 GPU"
fi
nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version \
           --format=csv,noheader | sed 's/^/    /'

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
VRAM_TOTAL_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
VRAM_USED_MIB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
VRAM_FREE_MIB=$((VRAM_TOTAL_MIB - VRAM_USED_MIB))

case "$GPU_NAME" in
  *T4*) ok "Tesla T4 (sm_75)。bf16 非対応・FlashAttention2 非対応。GGUF 量子化前提で進めます。" ;;
  *L4*|*A100*|*H100*|*L40*) ok "$GPU_NAME。T4 より条件が良いので、より大きいモデル/長い num_ctx を検討できます。" ;;
  *)    warn "想定外の GPU: $GPU_NAME。続行しますが VRAM 見積もりは手順書 §6 を読み替えてください。" ;;
esac

hdr "2. Compute Capability"
python3 - <<'PY' || warn "torch が無いため CC の確認をスキップしました（致命的ではありません）"
import sys
try:
    import torch
except Exception:
    sys.exit(1)
if not torch.cuda.is_available():
    print("    CUDA が利用できません")
    sys.exit(0)
cc = torch.cuda.get_device_capability(0)
print(f"    compute capability = {cc[0]}.{cc[1]}")
if cc < (8, 0):
    print("    -> bf16 非対応。vLLM を使うなら --dtype half が必須。Ollama(GGUF) 推奨。")
else:
    print("    -> bf16 対応。vLLM も選択肢に入ります。")
PY

hdr "3. システム RAM / ディスク"
free -h | sed 's/^/    /'
echo
df -h "$WORKROOT" / | sed 's/^/    /'

RAM_GB="$(free -g | awk '/^Mem:/{print $2}')"
DISK_AVAIL_GB="$(df -BG --output=avail "$WORKROOT" | tail -1 | tr -dc '0-9')"

hdr "4. インストーラの前提コマンド"
# Ollama の公式インストーラは配布アーカイブを zstd で固めており、展開に zstd を要求する。
# Colab の VM には既定で入っておらず、入れずに進むと 20_ollama.sh がここで落ちる:
#   ERROR: This version requires zstd for extraction.
# 20_ollama.sh が自動で導入するので、ここでは有無の報告に留める。
for cmd in curl tar zstd git; do
  if have "$cmd"; then
    ok "$cmd"
  elif [ "$cmd" = zstd ]; then
    log "zstd がありません -> 20_ollama.sh が apt で導入します（Ollama の展開に必須）"
  else
    warn "$cmd がありません。後段で必要になります: apt-get install -y $cmd"
  fi
done

hdr "5. Node.js（Cline CLI の前提）"
if have node; then
  NODE_VER="$(node --version | tr -d 'v')"
  NODE_MAJ="${NODE_VER%%.*}"
  if [ "$NODE_MAJ" -ge "$NODE_MAJOR" ]; then
    ok "node v$NODE_VER（要件 >= $NODE_MAJOR）"
  else
    # Colab の既定は Node 20 系。Cline CLI は 20 でも起動するが
    # 「cannot read the OS trust store (needs >= 22.15)」と警告する。
    warn "node v$NODE_VER は Cline CLI の要件 (>= $NODE_MAJOR) を満たしません。
     30_cline_cli.sh が NodeSource から Node $NODE_MAJOR を入れ直します。"
  fi
else
  warn "node がありません。30_cline_cli.sh が Node $NODE_MAJOR を導入します。"
fi

hdr "6. ターミナルの入手手段"
# 2025-06-23 に Google がターミナルを全ユーザーへ無料開放した。
# 以前必要だった colab-xterm 等の回避策はもう要らない。
if [ -n "${COLAB_RELEASE_TAG:-}" ] || [ -d /content ]; then
  log "Colab 上で動作しています"
  cat <<'EOT'
      いずれも Google 公式機能で、全ユーザーが無料で使えます:
        1. ノートブック UI 下部ツールバーの「ターミナル」ボタン
        2. Colab VS Code 拡張 > コマンドパレット > "Colab: Open Terminal"
        3. ターミナルを使わず、セルから  !bash scripts/50_run.sh "..."

      40_terminal_setup.sh を実行しておくと、ターミナルを開いた時点で
      環境変数と作業ディレクトリが整った状態になります。
EOT
else
  warn "Colab 外で実行しているようです。手順書は Colab 前提で書かれています。"
fi

hdr "7. ネットワーク疎通"
for host in ollama.com registry.npmjs.org deb.nodesource.com; do
  if curl -fsS --max-time 8 -o /dev/null "https://$host" 2>/dev/null; then
    ok "$host  到達可"
  else
    warn "$host  到達不可（後段のインストールが失敗します）"
  fi
done

hdr "8. 判定サマリ"
FAIL=0
printf '    %-28s %s\n' "GPU"            "$GPU_NAME"
printf '    %-28s %s MiB (空き %s MiB)\n' "VRAM" "$VRAM_TOTAL_MIB" "$VRAM_FREE_MIB"
printf '    %-28s %s GB\n' "システム RAM"  "$RAM_GB"
printf '    %-28s %s GB\n' "$WORKROOT 空き" "$DISK_AVAIL_GB"

if [ "$VRAM_FREE_MIB" -lt 7000 ]; then
  warn "空き VRAM が 7GB 未満です。7B q4_K_M すら厳しい状態です。ランタイムを作り直してください。"
  FAIL=1
elif [ "$VRAM_FREE_MIB" -lt 13000 ]; then
  log "空き VRAM ${VRAM_FREE_MIB}MiB。7B 級（既定）で進めてください。14B は載りません。"
else
  log "空き VRAM ${VRAM_FREE_MIB}MiB。14B q4_K_M も選択肢に入ります（手順書 §5 の実測結果で判断）。"
fi
if [ "$DISK_AVAIL_GB" -lt 20 ]; then
  warn "ディスク空きが 20GB 未満です。モデル + Node + Cline CLI で足りなくなる恐れがあります。"
  FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  ok "前提条件を満たしています。20_ollama.sh に進んでください。"
else
  warn "警告があります。手順書 §6（モデル選定）と §9（トラブルシュート）を確認してから進んでください。"
fi
