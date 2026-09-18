#!/usr/bin/env python3
"""pull する前に、レジストリだけでモデルの素性を調べる（VM 不要・課金ゼロ）。

なぜ必要か
----------
このリポジトリは新しいモデルを評価対象に入れるたびに、同じところで詰まってきた:

  - capabilities に "tools" と書いてあっても、実際に tool_calls を返すとは限らない
    （§5.6 qwen2.5-coder:7b / §5.8 同 14b / §12.7 gpt-oss / §5.10 gemma4）
  - KV キャッシュの実寸が分からず、KV_MIB_PER_TOKEN を勘で置いていた
  - それらを確かめるのに T4 を確保して 6〜15GB を pull していた

しかし **その多くは pull 前に分かる**。Ollama のマニフェストは数 KB で、
GGUF のメタデータ（チャットテンプレートとアーキテクチャ）はブロブの**先頭**にある。
Range リクエストで先頭だけ取れば、6.5 GiB を落とさずに読める。

実際、gemma4:12b-it-qat については これで次が確定した（2026-09-18）:

  - chat_template が tool call を吐く形（<|tool_call>call:NAME{...}<tool_call|>）
    → 文章から起こしていた修復プロキシの実装が**外れていた**ことが分かった
  - KV の幾何（48 層 = SWA 40 + 大域 8、KV ヘッド 8/1、window 1024）
  - projector 層の存在（vram_precheck.py が数えていなかった）

分かること / 分からないこと
---------------------------
分かる   : テンプレートがツール呼び出しを**どう書くことになっているか**、
           層数・KV ヘッド・key/value 長・sliding window、層構成とサイズ
分からない: **モデルが実際に何を吐くか**、Ollama のパーサがそれを
           tool_calls に入れられるか、KV を実際にどう確保するか
           → それは scripts/34_toolcall_probe.sh（実機）の仕事

使い方
------
    python3 scripts/36_registry_probe.py gemma4:12b-it-qat
    python3 scripts/36_registry_probe.py qwen3:8b --out /content/.cline-env/registry-probe
    python3 scripts/36_registry_probe.py gemma4:12b-it-qat --max-mib 160
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import struct
import sys
import urllib.error
import urllib.request

REGISTRY = "https://registry.ollama.ai/v2"
MANIFEST_ACCEPT = "application/vnd.docker.distribution.manifest.v2+json"

# GGUF のスカラ型 -> (バイト数, struct 書式)
_SCALAR = {
    0: (1, "<B"), 1: (1, "<b"), 2: (2, "<H"), 3: (2, "<h"),
    4: (4, "<I"), 5: (4, "<i"), 6: (4, "<f"), 7: (1, "<?"),
    10: (8, "<Q"), 11: (8, "<q"), 12: (8, "<d"),
}
_TYPE_STRING, _TYPE_ARRAY = 8, 9

# テンプレートに出たら「ツール呼び出しを構造化出力でなくテキストで出す」疑いがある印。
# 素の JSON を出すモデルもあるので、JSON らしさも見る。
_SUSPECT_TOKENS = re.compile(r"<\|[a-z_\"]+\|?>|<[a-z_]+\|>")


def split_ref(model: str) -> tuple[str, str]:
    name, _, tag = model.partition(":")
    return (name if "/" in name else "library/" + name), (tag or "latest")


def fetch_manifest(model: str) -> dict:
    name, tag = split_ref(model)
    req = urllib.request.Request(f"{REGISTRY}/{name}/manifests/{tag}",
                                 headers={"Accept": MANIFEST_ACCEPT})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"      マニフェストを引けませんでした (HTTP {e.code})。タグを確認してください: {model}")
    except Exception as e:
        sys.exit(f"      レジストリに到達できませんでした: {e}")


def fetch_blob_head(name: str, digest: str, max_bytes: int) -> bytes:
    req = urllib.request.Request(f"{REGISTRY}/{name}/blobs/{digest}",
                                 headers={"Range": f"bytes=0-{max_bytes - 1}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def parse_gguf_metadata(buf: bytes) -> dict:
    """GGUF の先頭からメタデータ KV を読む。届かなかった分は黙って打ち切る。"""
    f = io.BytesIO(buf)
    if f.read(4) != b"GGUF":
        raise ValueError("GGUF ではありません")
    (version,) = struct.unpack("<I", f.read(4))
    n_tensor, n_kv = struct.unpack("<QQ", f.read(16))

    def rd_str() -> str:
        (n,) = struct.unpack("<Q", f.read(8))
        return f.read(n).decode("utf-8", "replace")

    def rd_val(vtype: int, keep: int = 128):
        if vtype == _TYPE_STRING:
            return rd_str()
        if vtype == _TYPE_ARRAY:
            etype, count = struct.unpack("<IQ", f.read(12))
            out = []
            # ★ 全要素を読み切ること。途中で止めるとストリームがずれ、
            #   以降のキーが全部化ける（実際に踏んだ）。
            for i in range(count):
                v = rd_val(etype, keep=0)
                if i < keep:
                    out.append(v)
            return out
        size, fmt = _SCALAR[vtype]
        return struct.unpack(fmt, f.read(size))[0]

    meta = {"__version__": version, "__tensor_count__": n_tensor, "__kv_count__": n_kv}
    for _ in range(n_kv):
        try:
            key = rd_str()
            (vtype,) = struct.unpack("<I", f.read(4))
            meta[key] = rd_val(vtype)
        except Exception:
            meta["__truncated__"] = True
            break
    return meta


def kv_geometry(meta: dict, arch: str) -> dict | None:
    """層ごとの KV 形状から、1 トークンあたりの KV サイズを出す。"""
    def g(*names):
        for n in names:
            if f"{arch}.{n}" in meta:
                return meta[f"{arch}.{n}"]
        return None

    kvh = g("attention.head_count_kv")
    if kvh is None:
        return None
    if not isinstance(kvh, list):
        kvh = [kvh] * (g("block_count") or 0)
    swa_pat = g("attention.sliding_window_pattern")
    window = g("attention.sliding_window")
    k_len, v_len = g("attention.key_length"), g("attention.value_length")
    # ★ 古いアーキテクチャ（qwen2 系など）は key_length / value_length を
    #   メタデータに持たない。head_dim = embedding_length / head_count で
    #   暗黙に決まるため。ここで諦めると既存プロファイルの検算ができない。
    #   実際 qwen2.5-coder:14b はこれで読めず、フォールバックを入れて
    #   0.09375 MiB/token（プロファイルの 0.094）と一致した。
    if k_len is None or v_len is None:
        emb, nhead = g("embedding_length"), g("attention.head_count")
        if emb and nhead:
            head_dim = emb // nhead
            k_len = k_len if k_len is not None else head_dim
            v_len = v_len if v_len is not None else head_dim
    k_swa = g("attention.key_length_swa") or k_len
    v_swa = g("attention.value_length_swa") or v_len
    if k_len is None or v_len is None or not kvh:
        return None
    if not isinstance(swa_pat, list):
        swa_pat = [False] * len(kvh)

    out = {"layers": len(kvh), "swa_layers": sum(1 for x in swa_pat if x),
           "global_layers": sum(1 for x in swa_pat if not x), "window": window}
    for label, nbytes in (("f16", 2), ("q8_0", 1)):
        per_tok = sum(h * (k_len + v_len) * nbytes
                      for h, sw in zip(kvh, swa_pat) if not sw)
        fixed = sum(h * (k_swa + v_swa) * nbytes * (window or 0)
                    for h, sw in zip(kvh, swa_pat) if sw)
        # SWA を頭打ちにしない実装だった場合の上限
        per_tok_nocap = sum(h * ((k_swa + v_swa) if sw else (k_len + v_len)) * nbytes
                            for h, sw in zip(kvh, swa_pat))
        out[label] = {
            "capped_mib_per_token": per_tok / 1024 ** 2,
            "capped_fixed_mib": fixed / 1024 ** 2,
            "uncapped_mib_per_token": per_tok_nocap / 1024 ** 2,
        }
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="pull せずにモデルの素性を調べる")
    ap.add_argument("model", help="例: gemma4:12b-it-qat")
    ap.add_argument("--out", default=os.environ.get("STATEDIR", ".") + "/registry-probe")
    ap.add_argument("--max-mib", type=int, default=96,
                    help="ブロブ先頭を何 MiB 取るか（既定 96）。"
                         "語彙の大きいモデルは chat_template が後ろにあり、"
                         "足りないと届かない")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    name, _ = split_ref(args.model)

    print(f"=== 1. マニフェスト: {args.model} ===")
    manifest = fetch_manifest(args.model)
    layers, model_digest = {}, None
    for layer in manifest.get("layers", []):
        mt = layer.get("mediaType", "").rsplit(".", 1)[-1]
        layers[mt] = layers.get(mt, 0) + layer.get("size", 0)
        if layer.get("mediaType", "").endswith("image.model"):
            model_digest = layer["digest"]
    for mt, size in sorted(layers.items(), key=lambda kv: -kv[1]):
        print(f"      {mt:12} {size / 1024 ** 2:9.0f} MiB")
    print(f"      {'合計':12} {sum(layers.values()) / 1024 ** 2:9.0f} MiB")
    if "projector" in layers:
        print("      ※ projector があります（マルチモーダル）。これもメモリに載ります。")
    if "template" not in layers:
        print("      ※ template レイヤはありません。GGUF のメタデータ側にあります。")
    if not model_digest:
        sys.exit("      image.model レイヤがありません。判定できません。")

    print(f"\n=== 2. GGUF メタデータ（先頭 {args.max_mib} MiB だけ取得）===")
    buf = fetch_blob_head(name, model_digest, args.max_mib * 1024 ** 2)
    meta = parse_gguf_metadata(buf)
    arch = meta.get("general.architecture", "?")
    print(f"      architecture = {arch}   (GGUF v{meta['__version__']}, "
          f"tensors={meta['__tensor_count__']}, kv={meta['__kv_count__']})")
    if meta.get("__truncated__"):
        print(f"      ※ 先頭 {args.max_mib} MiB では KV を読み切れませんでした。"
              f"--max-mib を増やしてください。")
    for k in sorted(k for k in meta if k.startswith(f"{arch}.")):
        v = meta[k]
        if isinstance(v, list):
            v = f"{v[:8]}{'...' if len(v) > 8 else ''} (全{len(v)})"
        print(f"      {k} = {v}")

    print("\n=== 3. KV キャッシュの実寸 ===")
    geo = kv_geometry(meta, arch)
    if not geo:
        print("      形状を読み取れませんでした（メタデータが届いていない可能性）")
    else:
        print(f"      層 {geo['layers']}（SWA {geo['swa_layers']} / 大域 "
              f"{geo['global_layers']}）  window={geo['window']}")
        for label in ("f16", "q8_0"):
            d = geo[label]
            print(f"      [{label}]")
            print(f"        SWA を頭打ちにする実装なら: "
                  f"{d['capped_mib_per_token']:.4f} MiB/token + 固定 "
                  f"{d['capped_fixed_mib']:.0f} MiB")
            print(f"        頭打ちにしない実装なら    : "
                  f"{d['uncapped_mib_per_token']:.4f} MiB/token")
        print("      ★ どちらかは実機で測るまで分かりません。KV_MIB_PER_TOKEN には")
        print("        安全側（頭打ちにしない方）を置いてください。")

    print("\n=== 4. チャットテンプレートとツール呼び出し ===")
    tpl = meta.get("tokenizer.chat_template")
    if not tpl:
        print(f"      先頭 {args.max_mib} MiB には含まれていませんでした。"
              f"--max-mib を増やして再実行してください。")
    else:
        path = os.path.join(args.out, "chat_template.jinja")
        with open(path, "w", encoding="utf-8") as f:
            f.write(tpl)
        print(f"      {len(tpl):,} 文字 -> {path}")
        if "tool" not in tpl:
            print("      ★ テンプレートに tool の記述がありません。"
                  "このモデルはツール呼び出しに使えません（§5.6 と同じ罠）。")
        else:
            toks = sorted(set(_SUSPECT_TOKENS.findall(tpl)))
            print(f"      特殊トークン: {', '.join(toks) if toks else '（無し）'}")
            for label, pat in (("tool call を吐く行", r"tool_call>|<\|tool_call"),
                               ("引数の引用", r'<\|"\|>')):
                hits = len(re.findall(pat, tpl))
                print(f"      {label}: {hits} 箇所")
            if re.search(r'<\|"\|>', tpl):
                print("      ★ 引数を **JSON でない独自表記** で書くテンプレートです")
                print("        （文字列を <|\"|> で囲む）。Ollama のパーサが")
                print("        tool_calls に入れられず content に漏れると、素の JSON を")
                print("        期待する修復では読めません（§5.10 / ollama#15798）。")
            else:
                print("      ※ 引数は JSON らしい書き方です（<|\"|> を使っていない）。")
            print("        chat_template.jinja で 'tool_call' を grep して、")
            print("        実際の区切り記号を目で確かめてください。")

    with open(os.path.join(args.out, "metadata.json"), "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in meta.items()
                   if not k.startswith("tokenizer.ggml.")}, f,
                  indent=1, ensure_ascii=False)
    print(f"\n      メタデータ: {os.path.join(args.out, 'metadata.json')}")
    print("      次: 実際に何を吐くかは scripts/34_toolcall_probe.sh（実機が要ります）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
