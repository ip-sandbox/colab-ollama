#!/usr/bin/env bash
# remote/01_new.sh - Colab VM を確保し、ssh で実機を確認する
#
# ★ ここから課金（コンピューティングユニット消費）が始まります。
#   使い終わったら必ず  bash remote/09_stop.sh  を実行してください。
#   止めない限り 24 時間キープアライブが回り続けます。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_colab_version
require_gpu_valid
require_ssh_key

hdr "1. 既存セッションの確認"
if session_exists; then
  ok "セッション '$COLAB_SESSION' は既にあります（作り直しません）"
else
  hdr "2. セッションの確保（GPU: $COLAB_GPU）"
  warn "ここから課金が始まります。終わったら bash remote/09_stop.sh を忘れずに。"
  # 400 は「そのアクセラレータの割り当てが無い」、503 (Service Unavailable) は
  # 「今は空きが無い」。
  # ★ T4 は無料枠では取り合いになっており、503 (Service Unavailable) が普通に
  #   返る。400（割り当てが無い）と違って時間をおけば取れるので、
  #   COLAB_NEW_RETRIES 回まで待って再試行する。
  #   0（既定）なら従来どおり 1 回で諦める。
  RETRIES="${COLAB_NEW_RETRIES:-0}"
  INTERVAL="${COLAB_NEW_RETRY_INTERVAL:-60}"
  attempt=0
  while : ; do
    attempt=$((attempt + 1))
    if [ "$COLAB_GPU" = "cpu" ]; then
      log "colab new -s $COLAB_SESSION  （アクセラレータ無し）"
      colab_cli new -s "$COLAB_SESSION" && break
    else
      log "colab new -s $COLAB_SESSION --gpu $COLAB_GPU（試行 $attempt）"
      colab_cli new -s "$COLAB_SESSION" --gpu "$COLAB_GPU" && break
    fi

    if [ "$attempt" -gt "$RETRIES" ]; then
      die "セッションを確保できませんでした（$attempt 回試行）。
     400 なら、このアカウントに $COLAB_GPU の割り当てがありません。
     503 (Service Unavailable) なら空きが無いだけなので、時間をおけば取れます:
         COLAB_NEW_RETRIES=10 bash remote/01_new.sh
     GPU 無しで進めるなら:
         COLAB_GPU=cpu bash remote/01_new.sh"
    fi
    warn "確保できませんでした。${INTERVAL}s 待って再試行します（残り $((RETRIES - attempt + 1)) 回）"
    sleep "$INTERVAL"
  done
  ok "確保しました: $COLAB_SESSION"
fi

hdr "3. SSH 設定の生成"
write_ssh_config
ok "$SSH_CONFIG"

hdr "4. SSH 経路の確認"
# ここが通れば「手元 -> ProxyCommand -> WebSocket -> VM」の経路が全部生きている。
log "ssh で VM に入れるか確かめます（初回は鍵の受け渡しで数秒かかります）"
# ssh の終了コード 255 は「経路そのものの失敗」。リモートコマンドの失敗
# （非 255）と区別しないと、VM 内のエラーを「ssh が失敗した」と誤診する。
if ! PROBE="$(rsh 'echo READY; hostname' 2>&1)"; then
  RC=$?
  if [ "$RC" -eq 255 ]; then
    die "ssh 経路が張れませんでした:
$(printf '%s' "$PROBE" | sed 's/^/       /')

     よくある原因:
       - 鍵が ed25519/ecdsa でない（RSA はサーバ側で拒否されます）
       - セッションがまだ起動しきっていない（数十秒おいて再実行）
     手動で切り分ける場合:
         ssh -v -F $SSH_CONFIG $SSH_HOST_ALIAS"
  fi
  die "VM 上でコマンドが失敗しました (exit=$RC):
$(printf '%s' "$PROBE" | sed 's/^/       /')"
fi
ok "VM に入れました（$(printf '%s' "$PROBE" | tail -1)）"

if [ "$COLAB_GPU" = "cpu" ]; then
  hdr "5. VM 側の環境を整える（CPU なので GPU まわりは飛ばします）"
  warn "アクセラレータ無しのセッションです。
       Ollama は CPU で動きますが、無料枠の RAM は約 12.7GB しかないため
       13GB の gpt-oss:20b などは載りません。小さいモデルで試してください。"
  rsh 'free -g | awk "NR==2{print \"      RAM: \"\$2\"GB (空き \"\$7\"GB)\"}"' || true
  hdr "完了"
  cat <<EOF
    セッション : $COLAB_SESSION （CPU）
    ssh        : ssh -F $SSH_CONFIG $SSH_HOST_ALIAS

    次: bash remote/02_deploy.sh

    ${_c_bold}終わったら必ず:${_c_reset}  bash remote/09_stop.sh
EOF
  exit 0
fi

hdr "5. VM 側の環境を整える"
# ★ ここを飛ばすと Ollama が黙って CPU に落ちる。詳細は common.sh の
#   vm_bootstrap_env のコメント。
log "NVIDIA ライブラリをローダの探索パスに登録します（ldconfig）"
vm_bootstrap_env \
  || die "VM 側の環境整備に失敗しました。GPU ライブラリが見つかりません。
     手動で確認:
         ssh -F $SSH_CONFIG $SSH_HOST_ALIAS -- 'ls /usr/lib64-nvidia; nvidia-smi -L'"
ok "nvidia-smi が環境変数なしで通るようになりました"

hdr "6. 実機の確認"
GPU_INFO="$(rsh 'nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader')" \
  || die "nvidia-smi が失敗しました"
printf '      %s\n' "$GPU_INFO"

case "$GPU_INFO" in
  *T4*)  ok "Tesla T4 (sm_75)。bf16 非対応・FlashAttention2 非対応。GGUF 量子化前提で進めます。" ;;
  *L4*|*A100*|*H100*) ok "$COLAB_GPU が引けています。T4 より条件が良いです。" ;;
  *) warn "GPU が想定と違います。VRAM 見積もりを読み替えてください。" ;;
esac

hdr "7. VM の素の状態"
rsh 'echo "    uptime : $(uptime -p 2>/dev/null || true)";
     echo "    disk   : $(df -h /content | awk "NR==2{print \$4\" 空き / \"\$2}")";
     echo "    ram    : $(free -g | awk "NR==2{print \$7\"GB 空き / \"\$2\"GB\"}")";
     echo "    python : $(python3 --version 2>&1)";
     echo "    node   : $(node --version 2>/dev/null || echo なし)"' || true

hdr "完了"
cat <<EOF
    セッション : $COLAB_SESSION
    GPU        : $COLAB_GPU
    ssh        : ssh -F $SSH_CONFIG $SSH_HOST_ALIAS

    次: bash remote/02_deploy.sh

    ${_c_bold}終わったら必ず:${_c_reset}  bash remote/09_stop.sh
EOF
