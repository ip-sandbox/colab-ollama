#!/usr/bin/env bash
# remote/proxycommand.sh - ssh の ProxyCommand として使う薄いラッパー
#
# ★ なぜ colab ssh を直接 ProxyCommand に書かないのか
#
#   `colab ssh --proxy-mode -s NAME` は **セッションが無いと黙って新しい VM を
#   作る**（ssh.py の docstring に "with -s NAME the session is created if it
#   does not exist (so a config host works on first connect)" と明記されている）。
#
#   これは初回接続を楽にするための親切機能だが、運用では事故になる。実際に踏んだ:
#     - 走らせていた T4 の VM が Colab 側に回収された（free 枠は勝手に reclaim される）
#     - 状況確認のつもりで ssh したら、**新しい VM が黙って作られた**
#     - しかも --gpu を渡していないので **CPU ランタイム**だった
#     - 前の VM のログも成果物も無い別マシンに繋がり、課金だけ増えた
#
#   colab ssh 側に自動作成を止めるフラグは無いので、こちら側で塞ぐ。
#   接続の前にセッションの存在を確認し、無ければ**繋がずに失敗する**。
#
#   VM を作るのは remote/01_new.sh の仕事だけにする、という切り分け。
#
# ★ 注意: ProxyCommand の stdout は ssh の通信路そのもの。
#   このスクリプトは stdout に一切書いてはいけない（メッセージは stderr へ）。

set -euo pipefail

REMOTE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh は変数と関数を定義するだけで stdout には書かない
. "$REMOTE_DIR/common.sh"

if ! colab_cli sessions 2>/dev/null | grep -qF "$COLAB_SESSION"; then
  {
    printf 'セッション "%s" がありません。\n' "$COLAB_SESSION"
    printf '接続を中止しました（colab ssh はセッションが無いと黙って新しい VM を\n'
    printf '作ってしまい、しかも --gpu 未指定だと CPU ランタイムになるため）。\n\n'
    printf '    VM を作る          :  bash remote/01_new.sh\n'
    printf '    いまの一覧を見る   :  %s sessions\n' "$(colab_cmd_str)"
  } >&2
  exit 1
fi

# ここから先が本来の ProxyCommand。exec で置き換えて stdio を明け渡す。
if [ -n "$COLAB_CONFIG" ]; then
  exec colab --auth="$COLAB_AUTH" --config "$COLAB_CONFIG" \
       ssh --proxy-mode -s "$COLAB_SESSION"
else
  exec colab --auth="$COLAB_AUTH" ssh --proxy-mode -s "$COLAB_SESSION"
fi
