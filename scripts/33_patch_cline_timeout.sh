#!/usr/bin/env bash
# 33_patch_cline_timeout.sh - Cline CLI の Ollama リクエストタイムアウトを引き上げる
#
# 前提となる実測（2026-09-18、Cline CLI 3.0.62）
# ----------------------------------------------
# 手順書 §7 は長らく「Cline CLI は Ollama へのリクエストを 30 秒で切り、
# CLI 側に設定項目が無い（cline#9182）」を最大の壁として扱ってきた。
# scripts/35_cline_timeout_probe.sh で実測したところ、**これは 3.0.62 では
# もう成り立たない**:
#
#     @cline/llms の OLLAMA_DEFAULT_TIMEOUT_MS = 300000（= 300 秒）
#
# 仕組み自体（AbortController で中断し "Ollama request timed out after N
# seconds" を投げる）は残っているが、既定値が 30 秒から 300 秒に上がっている。
# 実際、120 秒まったく応答しない上流に対して 3.0.62 は最後まで待った。
#
# では、なぜこのスクリプトが要るのか
# ---------------------------------
# **CPU で動かすときは 300 秒でも足りないから。**
# T4 なら 300 秒は十分すぎるが、GPU が取れず CPU で 12B 級を回すと、
# prefill だけで数分かかる。手順書 §13 の CPU 事前検証レーンでは
# 300 秒に当たる可能性が高い。
#
# したがってこれは「壊れたものを直すパッチ」ではなく「上限を引き上げる調整」。
# 既定値が既に目標値以上なら、何もせずにそう報告して終わる。
#
# ★ npm install -g cline をやり直すとパッチは消える。
#   バージョンを上げたら必ず再適用すること。
#
# 使い方
# ------
#   bash scripts/33_patch_cline_timeout.sh              # 既定 600 秒に引き上げ
#   CLINE_TIMEOUT_MS=1800000 bash scripts/33_patch_cline_timeout.sh
#   bash scripts/33_patch_cline_timeout.sh --show       # 現在値を見るだけ
#   bash scripts/33_patch_cline_timeout.sh --restore    # 退避から戻す

. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ensure_dirs

CLINE_TIMEOUT_MS="${CLINE_TIMEOUT_MS:-600000}"
BACKUP_DIR="$STATEDIR/cline-timeout-patch"
MODE="apply"

case "${1:-}" in
  --show)    MODE="show" ;;
  --restore) MODE="restore" ;;
  "")        ;;
  -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
  *) die "不明なオプション: $1（--help を参照）" ;;
esac

case "$CLINE_TIMEOUT_MS" in
  ''|*[!0-9]*) die "CLINE_TIMEOUT_MS は正の整数（ミリ秒）で指定してください: $CLINE_TIMEOUT_MS" ;;
esac

hdr "1. Cline CLI の場所"
have cline || die "cline がありません。先に 30_cline_cli.sh を実行してください。"
log "版数: $(first_line cline --version)"

# npm root -g が使えないケース（nvm / volta 等）に備え、実行ファイルから
# たどる経路も用意する。
PKG_ROOT=""
if have npm; then
  CAND="$(npm root -g 2>/dev/null)/cline"
  [ -d "$CAND" ] && PKG_ROOT="$CAND"
fi
if [ -z "$PKG_ROOT" ]; then
  BIN="$(command -v cline)"
  BIN="$(readlink -f "$BIN" 2>/dev/null || printf '%s' "$BIN")"
  # .../cline/bin/xxx.js -> .../cline
  CAND="$(cd "$(dirname "$BIN")/.." 2>/dev/null && pwd)"
  [ -n "$CAND" ] && [ -f "$CAND/package.json" ] && PKG_ROOT="$CAND"
fi
[ -n "$PKG_ROOT" ] || die "cline のインストール先を特定できませんでした。
     npm root -g の出力と command -v cline を確認してください。"
ok "パッケージ: $PKG_ROOT"

hdr "2. タイムアウト定数を探す"
# ★ 定数は minify されて `OLLAMA_DEFAULT_TIMEOUT_MS:()=>P0` のように
#   短い記号へ別名化されている。記号名は版ごとに変わるので決め打ちしない。
#   エクスポート名から記号名を引き、その記号への代入を書き換える。
mapfile -t TARGETS < <(grep -rl 'OLLAMA_DEFAULT_TIMEOUT_MS' "$PKG_ROOT" --include=*.js 2>/dev/null | sort)

# ★ 0 件なら黙って進めない。「パッチしたつもりで効いていない」が
#   いちばん困る失敗なので、必ず落とす。
[ "${#TARGETS[@]}" -gt 0 ] || die "OLLAMA_DEFAULT_TIMEOUT_MS を含むファイルが 1 つもありません。
     Cline CLI の実装が変わった可能性があります（現在: $(first_line cline --version)）。
     手順書 §7 を読み直し、このスクリプトを実装し直してください。
     grep -rl OLLAMA_DEFAULT_TIMEOUT_MS '$PKG_ROOT'"

log "対象ファイル: ${#TARGETS[@]} 件"

# ファイルごとに「記号名」と「現在値」を取り出す
declare -a F_PATH F_SYM F_VAL
for f in "${TARGETS[@]}"; do
  sym="$(grep -oE 'OLLAMA_DEFAULT_TIMEOUT_MS:\(\)=>[A-Za-z0-9_$]+' "$f" \
          | head -1 | sed 's/.*=>//')"
  [ -n "$sym" ] || die "$f に OLLAMA_DEFAULT_TIMEOUT_MS はありますが、
     エクスポートの別名（OLLAMA_DEFAULT_TIMEOUT_MS:()=>記号）を読み取れません。
     minify の形が変わったと思われます。手作業で確認してください。"
  val="$(grep -oE "(^|[,;{ ])${sym}=[0-9]+" "$f" | head -1 | grep -oE '[0-9]+$')"
  [ -n "$val" ] || die "$f で記号 $sym への数値代入が見つかりません。
     minify の形が変わったと思われます。手作業で確認してください。"
  F_PATH+=("$f"); F_SYM+=("$sym"); F_VAL+=("$val")
  printf '      %-60s %s=%s\n' "${f#$PKG_ROOT/}" "$sym" "$val"
done

# --- --show / --restore ----------------------------------------------------
if [ "$MODE" = "show" ]; then
  hdr "現在の設定"
  printf '    実効タイムアウト: %s ms (%s 秒)\n' "${F_VAL[0]}" "$((F_VAL[0] / 1000))"
  exit 0
fi

if [ "$MODE" = "restore" ]; then
  hdr "退避から復元"
  [ -d "$BACKUP_DIR" ] || die "退避がありません: $BACKUP_DIR"
  n=0
  for i in "${!F_PATH[@]}"; do
    b="$BACKUP_DIR/$(printf '%s' "${F_PATH[$i]#$PKG_ROOT/}" | tr '/' '_')"
    if [ -f "$b" ]; then
      cp "$b" "${F_PATH[$i]}"; n=$((n + 1))
      ok "戻しました: ${F_PATH[$i]#$PKG_ROOT/}"
    fi
  done
  [ "$n" -gt 0 ] || warn "復元できるファイルがありませんでした"
  exit 0
fi

# --- 適用 ------------------------------------------------------------------
hdr "3. 適用"
CUR="${F_VAL[0]}"
if [ "$CUR" -ge "$CLINE_TIMEOUT_MS" ]; then
  ok "既に ${CUR} ms（$((CUR / 1000)) 秒）で、目標の ${CLINE_TIMEOUT_MS} ms 以上です。何もしません。"
  cat <<EOF

    参考: 3.0.62 の既定は 300000 ms（300 秒）です。手順書 §7 が言う
    「30 秒で切られる」はこの版では起きません（35_cline_timeout_probe.sh で実測）。
    さらに延ばしたい場合:
        CLINE_TIMEOUT_MS=1800000 bash scripts/33_patch_cline_timeout.sh
EOF
  exit 0
fi

mkdir -p "$BACKUP_DIR"
for i in "${!F_PATH[@]}"; do
  f="${F_PATH[$i]}"; sym="${F_SYM[$i]}"; val="${F_VAL[$i]}"
  b="$BACKUP_DIR/$(printf '%s' "${f#$PKG_ROOT/}" | tr '/' '_')"
  [ -f "$b" ] || cp "$f" "$b"

  # 記号への代入だけを狙う。直前の 1 文字（区切り）を保持して置換することで、
  # 別の長い識別子の末尾に一致してしまうのを防ぐ。
  python3 - "$f" "$sym" "$val" "$CLINE_TIMEOUT_MS" <<'PY'
import io, re, sys
path, sym, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src = io.open(path, encoding="utf-8").read()
pat = re.compile(r'(^|[,;{ ])' + re.escape(sym) + r'=' + re.escape(old) + r'(?![0-9])')
out, n = pat.subn(lambda m: m.group(1) + sym + "=" + new, src)
if n != 1:
    print(f"置換件数が 1 ではありません（{n} 件）: {path}", file=sys.stderr)
    sys.exit(1)
io.open(path, "w", encoding="utf-8").write(out)
PY
  ok "${f#$PKG_ROOT/}: $sym を $val -> $CLINE_TIMEOUT_MS"
done

hdr "4. 確認"
for f in "${F_PATH[@]}"; do
  sym="$(grep -oE 'OLLAMA_DEFAULT_TIMEOUT_MS:\(\)=>[A-Za-z0-9_$]+' "$f" | head -1 | sed 's/.*=>//')"
  val="$(grep -oE "(^|[,;{ ])${sym}=[0-9]+" "$f" | head -1 | grep -oE '[0-9]+$')"
  [ "$val" = "$CLINE_TIMEOUT_MS" ] \
    && ok "${f#$PKG_ROOT/} = $val" \
    || die "${f#$PKG_ROOT/} が $val のままです。置換に失敗しました。"
done

cat <<EOF

    退避: $BACKUP_DIR
    戻す: bash scripts/33_patch_cline_timeout.sh --restore

    ${_c_bold}★ npm install -g cline をやり直すとこのパッチは消えます。${_c_reset}
      バージョンを上げたら、もう一度このスクリプトを実行してください。

    効いたかどうかは実測で確かめられます:
        PROBE_DELAY_SEC=$((CLINE_TIMEOUT_MS / 1000 - 10)) bash scripts/35_cline_timeout_probe.sh
EOF
