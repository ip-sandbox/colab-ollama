#!/usr/bin/env bash
# remote/04_attach.sh - VM のシェルに入る（Codex の TUI はここで動かす）
#
#   bash remote/04_attach.sh              … ワークスペースでシェルを開く
#   bash remote/04_attach.sh codex        … そのまま codex を起動する
#   bash remote/04_attach.sh -- <cmd...>  … 任意のコマンドを 1 つ実行して抜ける

. "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_colab_version
require_session
write_ssh_config

case "${1:-}" in
  --)
    shift
    [ "$#" -gt 0 ] || die "-- の後にコマンドを書いてください"
    exec ssh -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- "$@"
    ;;
  codex)
    hdr "Codex CLI を起動します"
    log "ワークスペース: $REMOTE_WORKSPACE"
    # codex は TUI なので必ず端末を割り当てる。
    # 環境変数は ssh 経由では引き継がれないので、VM 側の ~/.bashrc に頼らず
    # ログインシェルとして起動する（40_terminal_setup.sh が仕込んだ内容が効く）。
    exec ssh -t -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- \
      "cd '$REMOTE_WORKSPACE' && exec bash -lc codex"
    ;;
  "")
    hdr "VM のシェルに入ります"
    cat <<EOF
    ワークスペース : $REMOTE_WORKSPACE
    リポジトリ     : $REMOTE_ROOT

    中でよく使うもの:
        codex                                    対話 TUI
        codex exec "fizzbuzz.py を作って実行して"   非対話
        ollama list / nvidia-smi
        cat /content/.cline-env/bench-summary.txt

    抜けるには exit。${_c_bold}VM は止まりません${_c_reset}（止めるなら remote/09_stop.sh）。

EOF
    exec ssh -t -F "$SSH_CONFIG" "$SSH_HOST_ALIAS" -- \
      "cd '$REMOTE_WORKSPACE' && exec bash -l"
    ;;
  *)
    die "使い方: bash remote/04_attach.sh [codex | -- <コマンド>]"
    ;;
esac
