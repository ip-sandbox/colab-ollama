#!/usr/bin/env bash
# remote/00_doctor.sh - 手元側の前提を確認する（VM は作らない・課金しない）
#
# ここが全部通っていれば 01_new.sh 以降は素直に動く。
# 逆に、ここを飛ばして 401/403 やハンドシェイク失敗に出くわすと原因の切り分けが面倒。

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

FAIL=0
soft_fail() { warn "$*"; FAIL=1; }

hdr "1. colab CLI"
require_colab_version

hdr "2. アクセラレータ指定"
require_gpu_valid
ok "COLAB_GPU=$COLAB_GPU"
if [ "$COLAB_GPU" != "T4" ]; then
  warn "無料枠で引けるのは T4 のみです。$COLAB_GPU は 400 で弾かれる可能性が高いです。"
fi

hdr "3. SSH 鍵"
require_ssh_key
ok "$SSH_IDENTITY ($(ssh-keygen -y -f "$SSH_IDENTITY" 2>/dev/null | awk '{print $1}'))"

hdr "4. 手元のコマンド"
for c in ssh ssh-keygen tar git; do
  if have "$c"; then
    ok "$c: $(command -v "$c")"
  else
    soft_fail "$c がありません"
  fi
done
# rsync は無くても動く（rpush は tar 経由）。あれば速いというだけ。
have rsync && ok "rsync: $(command -v rsync)" \
            || log "rsync はありません（tar 経由で転送するので問題ありません）"

hdr "5. 認証"
log "方式: $COLAB_AUTH"
case "$COLAB_AUTH" in
  adc)
    ADC="$HOME/.config/gcloud/application_default_credentials.json"
    if [ ! -f "$ADC" ]; then
      soft_fail "ADC がありません: $ADC
       ★ スコープ 4 つを明示して取り直してください（1 つでも欠けると
         セッション確保かキープアライブが 401/403 で落ちます）:

           gcloud auth application-default login \\
             --scopes=openid,\\
       https://www.googleapis.com/auth/cloud-platform,\\
       https://www.googleapis.com/auth/userinfo.email,\\
       https://www.googleapis.com/auth/colaboratory

       ブラウザが開くので、手元で 1 回だけ実行してください。
       （oauth2 で良ければ COLAB_AUTH=oauth2 を指定してください）"
    else
      ok "ADC: $ADC"
    fi
    ;;
  oauth2)
    TOKEN="$HOME/.config/colab-cli/token.json"
    [ -f "$TOKEN" ] && ok "トークンキャッシュ: $TOKEN" \
                    || log "トークン未取得。初回だけブラウザでの認可が要ります。"
    ;;
  *)
    soft_fail "COLAB_AUTH=$COLAB_AUTH は不正です（adc か oauth2）"
    ;;
esac

hdr "6. 実地確認（読み取りのみ・VM は作りません）"
# ここが通れば認証は本当に効いている。token.json があるだけでは判断できない
# （期限切れ・スコープ不足はこの呼び出しで初めて露見する）。
if SESSIONS="$(colab_cli sessions 2>&1)"; then
  ok "colab sessions が応答しました"
  printf '%s\n' "$SESSIONS" | sed 's/^/      /'
  if printf '%s' "$SESSIONS" | grep -qF "$COLAB_SESSION"; then
    warn "セッション '$COLAB_SESSION' は既に起動しています。
       課金が続いているので、使わないなら止めてください: bash remote/09_stop.sh"
  fi
else
  soft_fail "colab sessions が失敗しました:
$(printf '%s' "$SESSIONS" | sed 's/^/       /')

       401 ならトークンの期限切れ、403 ならスコープ不足です。
       ★ 'colab auth' は VM 側に GCP 認証情報を入れる別コマンドです。
         ここの 401/403 の対処には使えません。"
fi

hdr "7. 生成する SSH 設定"
write_ssh_config
ok "$SSH_CONFIG"
sed 's/^/      /' "$SSH_CONFIG"
cat <<EOF

    これで ProxyCommand 経由の ssh が使えます（VM 起動後）:

        ssh -F $SSH_CONFIG $SSH_HOST_ALIAS
        scp -F $SSH_CONFIG file $SSH_HOST_ALIAS:/content/

    VS Code の Remote-SSH から使う場合は、この内容を ~/.ssh/config に
    貼り付けてください（Host 名はそのままで構いません）。

EOF

hdr "結果"
if [ "$FAIL" -eq 0 ]; then
  ok "前提は揃っています。次: bash remote/01_new.sh"
else
  die "上の WARN を解消してから 01_new.sh に進んでください。"
fi
