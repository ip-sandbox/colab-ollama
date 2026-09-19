#!/usr/bin/env bash
# 10_preflight.sh - 着手前に「そもそもこの VM で成立するか」を確認する
#
# ここで落ちたら、後段のセットアップ（十数分かかる）をやる価値がない。
# 判定は落とさず警告に留め、最後にサマリを出す。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

hdr "1. アクセラレータ ($ACCEL)"
# ★ 以前はここで nvidia-smi が無ければ die していた。しかし無料枠の T4 は
#   取れないことのほうが多く、「GPU が無い」というだけで、CPU でも潰せる検証
#   （ツール呼び出しが成立するか / Cline が何秒で切るか）まで T4 待ちになっていた。
#   CPU は CPU として先へ進め、GPU 固有の項目だけを飛ばす。手順書 §13 を参照。
if [ "$ACCEL" = "cpu" ]; then
  warn "nvidia-smi がありません。CPU モードで続行します。
     GPU を使うつもりだったなら、ランタイムのタイプを確認してください:
     Colab メニュー > ランタイム > ランタイムのタイプを変更 > T4 GPU
     CPU のままで良い場合は、このまま進めて構いません（手順書 §13）。"
  GPU_NAME="(GPU 無し / CPU モード)"
  MEM_TOTAL_MIB="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
  MEM_FREE_MIB="$(accel_free_mib)"
else
  # ★ 出力する項目名も併記すること。ヘッダ無しの CSV だと remote/01_new.sh が
  #   出す memory.free と見分けが付かず、「空き 0 MiB」と読み違える（実際にやった）。
  nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version \
             --format=csv,noheader \
    | sed 's/^/    /; s/$/  (name, total, used, driver)/'

  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  MEM_TOTAL_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
  MEM_USED_MIB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
  MEM_FREE_MIB=$((MEM_TOTAL_MIB - MEM_USED_MIB))

  case "$GPU_NAME" in
    *T4*) ok "Tesla T4 (sm_75)。bf16 非対応・FlashAttention2 非対応。GGUF 量子化前提で進めます。" ;;
    *L4*|*A100*|*H100*|*L40*) ok "$GPU_NAME。T4 より条件が良いので、より大きいモデル/長い num_ctx を検討できます。" ;;
    *)    warn "想定外の GPU: $GPU_NAME。続行しますが VRAM 見積もりは手順書 §6 を読み替えてください。" ;;
  esac
fi

hdr "2. Compute Capability"
if [ "$ACCEL" = "cpu" ]; then
  log "CPU モードなのでスキップします"
else
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
fi

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
# ★ registry.ollama.ai を独立して見ること。ollama.com はインストーラの配布元で、
#   モデルの重みを配るのは registry.ollama.ai。egress ポリシーで後者だけが
#   塞がれている環境が実在し（Claude on the web の既定ポリシーがそう）、
#   その場合は ollama のインストールまで通ってから pull だけが失敗する。
#   どちらが落ちたのかを区別できないと、原因の切り分けに時間を使う。
#
# ★ 「到達できたか」は HTTP ステータスで判断してはいけない。
#   registry.ollama.ai はルートに GET すると **404 を返すのが正常**
#   （/v2/<name>/manifests/<tag> しか生えていない）。ここで curl -f を使うと
#   404 で失敗扱いになり、**実際には pull できる環境を「届きません」と誤判定する**。
#   実際に踏んだ: レジストリからマニフェストを取得できている機械で
#   「registry.ollama.ai に届きません」と出た（2026-09-18）。
#   しかもこの判定は 60_cpu_verify.sh が L2 を飛ばすかどうかに使われるので、
#   誤判定すると「pull できるのに検証を丸ごと飛ばす」という最悪の方向に倒れる。
#
#   欲しいのは「egress ポリシーに塞がれていないか」なので、
#   **HTTP 応答が返ってきたか** だけを見る。塞がれている場合、curl は
#   CONNECT の失敗（exit 56）になり http_code は 000 になる。
#   200 でも 401 でも 404 でも、応答が返る時点でホストには届いている。
NET_REGISTRY_OK=1
for host in ollama.com registry.ollama.ai registry.npmjs.org deb.nodesource.com; do
  # ★ `|| echo 000` を足してはいけない。curl は失敗時にも -w の書式を評価して
  #   "000" を stdout に出すので、フォールバックが連結されて "000000" になり、
  #   != "000" の判定をすり抜けて **到達不可を到達可と誤報する**（実際に踏んだ）。
  #   終了コードは捨て、出力が空のときだけ 000 を補う。
  code="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' \
          "https://$host" 2>/dev/null)" || true
  [ -n "$code" ] || code=000
  if [ "$code" != "000" ]; then
    ok "$host  到達可 (HTTP $code)"
  else
    warn "$host  到達不可（egress ポリシーに塞がれている可能性）"
    [ "$host" = "registry.ollama.ai" ] && NET_REGISTRY_OK=0
  fi
done
# 後続（60_cpu_verify.sh）が「pull で長時間待たずに即座に理由を言う」ために読む。
mkdir -p "$STATEDIR"
printf '%s\n' "$NET_REGISTRY_OK" >"$STATEDIR/net-registry-ok"
if [ "$NET_REGISTRY_OK" -eq 0 ]; then
  warn "registry.ollama.ai に届きません。ollama のインストールは通っても
     ollama pull は必ず失敗します。ネットワークポリシーで許可してください
     （Claude on the web なら環境のネットワーク設定、社内 proxy なら許可リスト）。"
fi

hdr "8. 判定サマリ"
FAIL=0
MEM_LABEL="$(accel_mem_label)"
printf '    %-28s %s\n' "アクセラレータ"  "$ACCEL"
printf '    %-28s %s\n' "GPU"            "$GPU_NAME"
printf '    %-28s %s MiB (空き %s MiB)\n' "$MEM_LABEL" "$MEM_TOTAL_MIB" "$MEM_FREE_MIB"
printf '    %-28s %s GB\n' "システム RAM"  "$RAM_GB"
printf '    %-28s %s GB\n' "$WORKROOT 空き" "$DISK_AVAIL_GB"

# しきい値は GPU（T4 の 15GB）を前提に決めてある。CPU はシステム RAM 全体を
# 見ているので同じ数字では判断できない。判定の言葉も変える。
if [ "$MEM_FREE_MIB" -lt 7000 ]; then
  warn "空き $MEM_LABEL が 7GB 未満です。7B q4_K_M すら厳しい状態です。"
  FAIL=1
elif [ "$MEM_FREE_MIB" -lt 13000 ]; then
  log "空き $MEM_LABEL ${MEM_FREE_MIB}MiB。7B 級（既定）で進めてください。14B は載りません。"
else
  log "空き $MEM_LABEL ${MEM_FREE_MIB}MiB。12〜14B 級も選択肢に入ります（手順書 §5 の実測結果で判断）。"
fi
if [ "$ACCEL" = "cpu" ]; then
  warn "CPU モードです。推論は GPU の一桁以上遅くなります。
     ここで測る速度は実力ではないので、ベンチの判定は参考値として扱ってください。
     CPU で確定させられるのは「ツール呼び出しが成立するか」「何秒で切られるか」で、
     速度の評価は T4 の仕事です（手順書 §13）。"
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
