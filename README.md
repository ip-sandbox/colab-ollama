# colab-cline

Google Colab の T4 上にローカル LLM (Ollama) と **Cline CLI** を置き、
Colab のノートブック UI の中から AI コーディングをするための手順書とスクリプト。

**外部トンネルも公開 URL も使いません。** すべて VM の中で完結します。

```
ブラウザ（Colab ノートブック UI）
  ├ ターミナルウィンドウ  cline              ← 本命。全ユーザー無料（2025-06-23〜）
  └ セルから直接        !bash scripts/50_run.sh "..."   ← 自動化向け
        │
        └ Colab VM (T4 16GB)
            ├ Ollama 127.0.0.1:11434  (7B Q4_K_M / num_ctx=32768)
            └ Cline CLI  ──> /content/workspace
```

## まず読むもの

**[`docs/手順書.md`](docs/手順書.md)**

着手前に必ず目を通してほしいのは **§7 30 秒の壁** と **§7.1 エージェント比較** です。

Cline CLI は Ollama へのリクエストを 30 秒でタイムアウトし、
**CLI 側に設定項目がありません**（[cline#9182](https://github.com/cline/cline/issues/9182) /
[#9484](https://github.com/cline/cline/issues/9484)）。
これは Cline 固有の制約で、**Codex CLI / Qwen Code / aider なら設定で伸ばせます**（§7.1）。
Cline に一番近いのは Codex CLI ですが、送るプロンプトも Cline 並みに大きいので
T4 では速くなりません。ベンチ判定で選んでください。
ただしタイムアウトを伸ばすのは対症療法で、本命は prefill を速くすることです。

## 使い方

1. Colab で新しいノートブックを開き、ランタイムのタイプを **T4 GPU** にする
2. このリポジトリを `/content/colab-cline` に配置する
   - VS Code の Colab 拡張: Explorer で右クリック → **`Upload to Colab`**、その後 `unzip`
   - ノートブック UI: 左のファイルペインにドラッグ&ドロップ
   - 継続して使うなら `git clone` が結局いちばん楽（§3.4）
3. [`notebooks/colab_cline.ipynb`](notebooks/colab_cline.ipynb) を開いて上から実行する

CLI で進める場合:

```bash
cd /content/colab-cline
bash scripts/10_preflight.sh                       # 前提確認
bash scripts/20_ollama.sh                          # LLM 構築 + prefill ベンチ ★
bash scripts/30_cline_cli.sh                       # Cline CLI 導入 + ローカル接続
bash scripts/31_alt_agents.sh                      # 任意: Codex CLI / aider / Qwen Code
bash scripts/40_terminal_setup.sh                  # ターミナル用の ~/.bashrc 整備
bash scripts/50_run.sh "fizzbuzz.py を作って実行して"  # セルから実行する場合
bash scripts/90_healthcheck.sh                     # 切り分け
```

あとはノートブック下部の**「ターミナル」ボタン**を開いて `cline` を叩くだけです。
Colab VS Code 拡張の `Colab: Open Terminal` でも同じ VM のシェルが取れます。

## 構成の要点

- **推論エンジンは Ollama。** T4 は compute capability 7.5 で bf16 非対応、vLLM は不利
- **既定モデルは 7B。** CLI の 30 秒制限下では「賢さ」より「prompt eval の速さ」が
  実用性を決める。14B を使うかは `20_ollama.sh` のベンチ判定を見てから決める
- **`num_ctx` を Modelfile に焼き込む。** 既定のままだと Cline は静かに壊れる
- **Cline CLI は既定でクラウドに投げる。** `cline config` の出力を必ず目視確認する
- **VM はステートレスとみなす。** 12 時間で全部消える。コードは git push する

## ファイル

```
docs/手順書.md                  設計・規約・モデル選定・トラブルシュート
notebooks/colab_cline.ipynb    Colab で上から実行する
notebooks/build_notebook.py    ipynb の生成元（編集はこちら）
scripts/common.sh              設定と共通関数
scripts/10_preflight.sh        GPU/VRAM/ディスク/Node/ターミナル手段の確認
scripts/20_ollama.sh           Ollama + モデル + num_ctx + prefill ベンチ
scripts/30_cline_cli.sh        Node 22 + Cline CLI + ローカル接続設定
scripts/40_terminal_setup.sh   ターミナル用の ~/.bashrc 整備
scripts/50_run.sh              セルから Cline を走らせるラッパ
scripts/90_healthcheck.sh      切り分け + 30 秒予算の実測
scripts/99_teardown.sh         片付け
archive/browser-ide/           v1.0（code-server / トンネル構成）。手順書 §2 に廃止理由
```

設定は `scripts/common.sh` の環境変数で上書きできます。

```bash
BASE_MODEL=qwen2.5-coder:14b-instruct-q4_K_M NUM_CTX=16384 bash scripts/20_ollama.sh
CLINE_PROVIDER=openai-compatible bash scripts/30_cline_cli.sh   # 30秒制限の回避を試す
```
