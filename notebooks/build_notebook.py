#!/usr/bin/env python3
"""notebooks/colab_cline.ipynb を生成する。ノートブックを直接編集せずここを直すこと。"""

import json
import pathlib

REPO = "https://github.com/YOUR_ACCOUNT/colab-cline.git"  # 自分の置き場に書き換える


def md(src: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": src.strip("\n").splitlines(True)}


def code(src: str) -> dict:
    return {
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": src.strip("\n").splitlines(True),
    }


cells = [
    md(
        """
# Colab T4 + ローカル LLM + Cline CLI

Colab のノートブック UI だけで完結する AI コーディング環境。
**外部トンネルも公開 URL も使いません。**

```
ブラウザ（Colab ノートブック UI）
  ├ ターミナルウィンドウ  cline              ← 本命。全ユーザー無料（2025-06-23〜）
  └ セルから直接        !bash scripts/50_run.sh "..."   ← 自動化向け
        │
        └ Colab VM (T4 16GB)
            ├ Ollama 127.0.0.1:11434
            └ Cline CLI  ──> /content/workspace
```

**始める前に:**

1. ランタイムのタイプを **T4 GPU** にする（ランタイム > ランタイムのタイプを変更）
2. `docs/手順書.md` の **§7（30 秒の壁）** を読む — この構成の実用性を決める最大の要因です

所要時間の目安: 初回 12〜20 分
"""
    ),
    md("## 0. スクリプトの配置"),
    code(
        f"""
# --- 方法1: git から取得（推奨） ---
# !git clone {REPO} /content/colab-cline

# --- 方法2: ノートブック UI から zip をアップロード ---
#   左のファイルペインにドラッグ&ドロップ、または:
# from google.colab import files; files.upload()
# !unzip -oq colab-cline.zip -d /content/

# --- 方法3: VS Code の Colab 拡張から ---
#   Explorer で zip を右クリック > "Upload to Colab" のあと、ここを実行:
# !cd /content && unzip -oq colab-cline.zip
#   ※ files.upload() は Colab のフロントエンド JS に依存するため
#      VS Code 拡張経由では動きません

import os, pathlib
ROOT = "/content/colab-cline"
assert pathlib.Path(ROOT, "scripts", "common.sh").exists(), \\
    f"{{ROOT}}/scripts が見つかりません。上のいずれかの方法で配置してください。"
os.chdir(ROOT)
!chmod +x scripts/*.sh
print("OK:", ROOT)
"""
    ),
    md(
        """
## 1. 前提条件チェック

GPU・VRAM・ディスク・Node・ターミナルの入手手段をまとめて確認します。
ここで NG が出たら先に進んでも時間を捨てるだけです。
"""
    ),
    code("!bash scripts/10_preflight.sh"),
    md(
        """
## 2. Ollama とモデルの構築

**このセルが構成の中心です。** 2 つのことをやります。

1. `num_ctx` を焼き込んだモデルを作る — これを怠ると Cline は静かに壊れます
2. **prefill ベンチマーク** — Cline CLI は Ollama へのリクエストを 30 秒で
   タイムアウトします（[cline#9182](https://github.com/cline/cline/issues/9182)）。
   VS Code 拡張と違って CLI 側に設定項目がありません。
   したがって「30 秒で何トークン処理できるか」がこの構成の実用上限を決めます。

出力の **「安全に投げられるプロンプト長」** と **「判定」** を必ず見てください。

| 判定 | 意味 |
|---|---|
| OK | そのまま進んでよい |
| WARN | 動くが 1 ファイルずつの小さいタスクに限定する |
| NG | この組み合わせでは実用にならない。モデルを小さくする |

モデルを変えたい場合は下の変数を書き換えてから実行します。

| 空き VRAM | BASE_MODEL | NUM_CTX |
|---|---|---|
| 13GB 以上 | `qwen2.5-coder:14b-instruct-q4_K_M` | 16384〜32768 |
| 7〜13GB | `qwen2.5-coder:7b-instruct-q4_K_M`（既定） | 32768 |
| prefill が遅すぎる | `qwen2.5-coder:3b-instruct-q4_K_M` | 16384 |
"""
    ),
    code(
        """
import os
os.environ["BASE_MODEL"]  = "qwen2.5-coder:7b-instruct-q4_K_M"
os.environ["NUM_CTX"]     = "32768"
os.environ["CLINE_MODEL"] = "cline-coder"

# モデル DL に 3〜10 分かかります。無音になっても待つこと。
!bash scripts/20_ollama.sh
"""
    ),
    md(
        """
## 3. Cline CLI の導入とローカル接続

Node 22 を入れて `npm i -g cline`、そのうえで **ローカルの Ollama に向けます。**

> **注意:** Cline CLI は何も設定しないと「無料の Cline アカウント」を使います。
> つまり Colab の T4 ではなくクラウドに投げます。
> このセルの出力にある `cline config` の結果を **必ず目視で確認**してください。
> 反映されていなければ、次のセルで対話設定します。
"""
    ),
    code("!bash scripts/30_cline_cli.sh"),
    md(
        """
### 設定が反映されていなかった場合

`cline auth` は対話式なので、セルからは動きません。ターミナル（§5）で実行してください。
ターミナルを使わない場合は、`cline config set` を直接叩きます。
"""
    ),
    code(
        """
# 個別に叩き直す例（キー名は CLI のバージョンで変わりうる）
!cline config set act-mode-api-provider=ollama
!cline config set act-mode-ollama-model-id=cline-coder
!cline config set act-mode-ollama-base-url=http://127.0.0.1:11434
!cline config
"""
    ),
    md(
        """
### 任意: タイムアウトを設定できる代替エージェント

Cline CLI の 30 秒制限は **Cline 固有の実装上の制約**です。
`--timeout` を設定できるエージェントがあります（手順書 §7.1 に比較表）。

| エージェント | タイムアウト設定 | 性格 |
|---|---|---|
| Codex CLI | `stream_idle_timeout_ms` | **Cline に最も近い自律エージェント** |
| Qwen Code | `generationConfig.timeout`（ms、ローカルには 300000 推奨） | 自律エージェント寄り |
| aider | `--timeout` / `AIDER_TIMEOUT`（秒、既定は無制限） | ペアプログラマ型 |
| Cline CLI | **無し** | 自律エージェント |

選ぶ軸は **1 ターンに送るプロンプト量**です。T4 では prefill が律速なので、
送る量が少ないほど速い。

```
送る量: aider < Qwen Code < Codex CLI ≒ Cline
```

**「Cline に近い」ことは長所であると同時に短所です。** Codex はタイムアウトの問題は
解決しますが、Cline と同じ理由で重いので**遅さの問題は解決しません**。

§2 のベンチ判定で選んでください:

| 安全プロンプト長 | 薦める順 |
|---|---|
| 20,000 以上 | Codex CLI → Qwen Code → aider |
| 12,000〜20,000 | Qwen Code → Codex CLI → aider |
| 6,000〜12,000 | **aider 一択** |
| 6,000 未満 | エージェント以前の問題。モデルを小さくする |

> タイムアウトを伸ばすのは対症療法です。30 秒待っていたものが 600 秒待てるように
> なるだけで、体感は良くなりません。§2 のベンチ判定が NG なら、
> エージェントを替えても解決しません。
"""
    ),
    code(
        """
# 入れる場合だけ実行
# !bash scripts/31_alt_agents.sh          # 全部
# !bash scripts/31_alt_agents.sh codex    # Codex CLI だけ（Cline に一番近い）
# !bash scripts/31_alt_agents.sh aider    # aider だけ（導入に 3〜6 分）
"""
    ),
    md(
        """
## 4. ターミナル用の下準備

**ターミナルはノートブックのカーネルとは別のシェルです。**
セルで設定した環境変数は引き継がれません。
`~/.bashrc` に Ollama の設定と作業ディレクトリを仕込んでおきます。
"""
    ),
    code("!bash scripts/40_terminal_setup.sh"),
    md(
        """
## 5. 使う — ターミナルから（本命）

**ノートブック下部のツールバーにある「ターミナル」ボタン**を押してください。
Colab ランタイムに繋がったシェルが開きます。

> **2025 年 6 月 23 日から、ターミナルは全ユーザーが無料で使えます。**
> （[Colab 公式アナウンス](https://medium.com/google-colab/colab-terminal-is-now-free-for-all-users-9a10eaef2ca8)）
> 以前は Pro 限定でしたが、今は違います。`colab-xterm` などの回避策は不要です。

```bash
cd /content/workspace
cline                 # 対話セッション
cline -p "..."        # Plan モードで開始
cline --yolo "..."    # 承認をスキップ
cline config          # ★ローカルの Ollama を向いているか確認
```

手元の VS Code を使いたい場合は、`Google.colab` 拡張の
コマンドパレット → `Colab: Open Terminal` でも同じ VM のシェルが取れます。
"""
    ),
    md(
        """
## 6. 使う — セルから（自動化向け）

ターミナルを開かずに走らせます。ノートブックに実行履歴が残るので、
**同じタスクを繰り返す**場合や**手順を人に渡す**場合はこちらが向いています。

`--yolo`（承認スキップ）が既定です。対話承認したい場合は `AUTO_APPROVE=0` を付けます。
"""
    ),
    code(
        """
!bash scripts/50_run.sh "fizzbuzz.py を作って、1〜30 の FizzBuzz を出力して、実際に実行して結果を見せて"
"""
    ),
    code(
        """
# Plan モード（まず方針だけ立てさせる）
# !bash scripts/50_run.sh -p "このリポジトリの構成を調べて、改善案を3つ挙げて"

# 機械可読出力（NDJSON）
# !bash scripts/50_run.sh --json "TODO コメントを列挙して"

# 承認を対話で行う
# !AUTO_APPROVE=0 bash scripts/50_run.sh "README を書き直して"
"""
    ),
    md("## 7. 状態確認・切り分け"),
    code("!bash scripts/90_healthcheck.sh"),
    md(
        """
## 8. 片付け

外部公開が無いので旧構成ほど切実ではありませんが、VRAM を空けたいときに。
"""
    ),
    code(
        """
!bash scripts/99_teardown.sh          # モデルを VRAM から降ろす
# !bash scripts/99_teardown.sh --all  # Ollama も止める
"""
    ),
    md(
        """
---

## セッションが切れたら

無料枠は最長 12 時間、アイドルでも切れます。**VM 上のものは全部消えます。**

```python
# 作業の区切りごとに必ず実行する
!cd /content/workspace && git add -A && git commit -m "wip" && git push
```

再開はこのノートブックを上から流し直すだけですが、モデルの再 DL が毎回発生します（7B で約 4.7GB）。
対策は `docs/手順書.md` §8 を参照してください。
"""
    ),
]

nb = {
    "cells": cells,
    "metadata": {
        "accelerator": "GPU",
        "colab": {"gpuType": "T4", "provenance": [], "toc_visible": True},
        "kernelspec": {"display_name": "Python 3", "name": "python3"},
        "language_info": {"name": "python"},
    },
    "nbformat": 4,
    "nbformat_minor": 0,
}

out = pathlib.Path(__file__).parent / "colab_cline.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("wrote", out)
