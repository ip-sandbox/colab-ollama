#!/usr/bin/env python3
"""pull する前に、そのモデルが VRAM に載るかを判定する。

なぜ必要か
----------
20_ollama.sh の VRAM 確認は、もともと「モデルをロードした後」にしか無かった。
これだと 15GB のモデルを落としきってから「載りません」と分かることになる。
実際 devstral-small-2:24b-instruct-2512-q4_K_M は重みだけで 14.0 GiB あり、
T4 の空き（実測 14913 MiB ≒ 14.56 GiB）に対して KV とバッファを足すと必ず
あふれる。回線と時間の無駄なので、pull の前に止める。

どうやるか
----------
Ollama のレジストリからマニフェストだけを引いて、重みレイヤのサイズを得る。
マニフェストは数 KB なので、14GB を落とさずに判定できる。

KV キャッシュのサイズはモデルの層数 / KV ヘッド数 / head_dim で決まるが、
マニフェストからは分からない。そのため 1 トークンあたりの MiB を外から渡す
（プロファイルごとの実測値、既定は 8〜24B 級の安全側の値）。

終了コード
----------
  0 … 載る（WARN も 0。余裕が少ないだけで進める）
  1 … 載らない
  2 … モデル名を解決できない（タグの綴り間違いなど）
  3 … 判定不能（レジストリに届かない等）。呼び出し側は続行してよい
"""

import json
import sys
import urllib.error
import urllib.request

REGISTRY = "https://registry.ollama.ai/v2"
# マニフェストの中で「重みの実体」を指すレイヤの mediaType
MODEL_LAYER_SUFFIX = "image.model"
# 余裕がこれ未満なら WARN（進めるが、長い文脈で OOM しうる）
WARN_MARGIN_MIB = 512


def split_ref(model: str) -> tuple[str, str]:
    """"qwen3:8b" -> ("library/qwen3", "8b") / "user/m:t" -> ("user/m", "t")"""
    name, _, tag = model.partition(":")
    tag = tag or "latest"
    if "/" not in name:
        name = "library/" + name
    return name, tag


def fetch_weights_mib(model: str) -> float:
    """レジストリのマニフェストから重みの合計サイズ (MiB) を返す。"""
    name, tag = split_ref(model)
    url = f"{REGISTRY}/{name}/manifests/{tag}"
    req = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.docker.distribution.manifest.v2+json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            manifest = json.load(r)
    except urllib.error.HTTPError as e:
        print(f"      マニフェストを引けませんでした (HTTP {e.code})")
        print(f"      URL: {url}")
        print("      タグ名が正しいか確認してください（ollama.com/library で確認できます）")
        sys.exit(2)
    except Exception as e:  # ネットワーク不通など
        print(f"      レジストリに到達できませんでした: {e}")
        sys.exit(3)

    total = sum(
        layer.get("size", 0)
        for layer in manifest.get("layers", [])
        if layer.get("mediaType", "").endswith(MODEL_LAYER_SUFFIX)
    )
    if not total:
        print("      マニフェストに重みレイヤがありません。判定できません。")
        sys.exit(3)
    return total / (1024**2)


def main() -> int:
    if len(sys.argv) != 7:
        print(
            "usage: vram_precheck.py <model> <free_mib> <num_ctx> "
            "<kv_mib_per_token> <compute_buf_mib> <out_json>",
            file=sys.stderr,
        )
        return 2

    model = sys.argv[1]
    free_mib = int(sys.argv[2])
    num_ctx = int(sys.argv[3])
    kv_per_tok = float(sys.argv[4])
    compute_buf = int(sys.argv[5])
    out_path = sys.argv[6]

    weights_mib = fetch_weights_mib(model)
    kv_mib = num_ctx * kv_per_tok
    need_mib = weights_mib + kv_mib + compute_buf
    margin = free_mib - need_mib

    print(f"      モデル       : {model}")
    print(f"      重み         : {weights_mib:8.0f} MiB ({weights_mib / 1024:.2f} GiB)")
    print(f"      KV (ctx={num_ctx:,}) : {kv_mib:8.0f} MiB  @ {kv_per_tok} MiB/token")
    print(f"      計算バッファ : {compute_buf:8.0f} MiB")
    print("      " + "-" * 45)
    print(f"      必要量       : {need_mib:8.0f} MiB ({need_mib / 1024:.2f} GiB)")
    print(f"      空き VRAM    : {free_mib:8.0f} MiB ({free_mib / 1024:.2f} GiB)")
    print(f"      余裕         : {margin:+8.0f} MiB")
    print()

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "model": model,
                "weights_mib": weights_mib,
                "kv_mib": kv_mib,
                "compute_buf_mib": compute_buf,
                "need_mib": need_mib,
                "free_mib": free_mib,
                "margin_mib": margin,
            },
            f,
        )

    if margin < 0:
        print(f"      判定: NG — {-margin:.0f} MiB 足りません。")
        print("      対策: (1) NUM_CTX を下げる")
        print("            (2) より小さい量子化 / より小さいモデルにする")
        print("            (3) VRAM の大きい GPU を使う（無料枠では T4 のみ）")
        return 1

    if margin < WARN_MARGIN_MIB:
        print(f"      判定: WARN — 余裕が {margin:.0f} MiB しかありません。")
        print("      長い文脈を投げた瞬間に OOM する可能性があります。")
        return 0

    print("      判定: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
