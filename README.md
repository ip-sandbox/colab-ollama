# colab-cline

Google Colab の T4 上にローカル LLM (Ollama) と **Cline CLI** を置き、
Colab のノートブック UI の中から AI コーディングをするための手順書とスクリプト。

**外部トンネルも公開 URL も使いません。** すべて VM の中で完結します。

```
手元のシェル                              ブラウザ（Colab ノートブック UI）
  └ remote/*.sh                             ├ ターミナルウィンドウ  cline
     （colab CLI + ssh）                     └ セルから  !bash scripts/50_run.sh "..."
        │                                        │
        └────────────┬───────────────────────────┘
                     │
                  Colab VM (T4 16GB)
                     ├ Ollama 127.0.0.1:11434  (num_ctx はモデル依存)
                     ├ Cline CLI  ──> /content/workspace
                     └ Codex CLI  ──> /content/workspace
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

   ```bash
   cd /content && git clone https://github.com/ip-sandbox/colab-ollama.git colab-cline
   ```

   リポジトリ名は `colab-ollama`、配置先は `colab-cline` で別物です。綴りを間違えると
   public でも 404 になり、git がパスワードを聞いてきます。
3. [`notebooks/colab_cline.ipynb`](notebooks/colab_cline.ipynb) を開いて上から実行する

ノートブックを開かず、ターミナル（ノートブック下部の「ターミナル」ボタン、
Colab VS Code 拡張の `Colab: Open Terminal`、または SSH）だけで進める場合は
一括スクリプトが使えます（内容は下の個別スクリプトを順番に呼ぶだけ）:

```bash
cd /content && git clone https://github.com/ip-sandbox/colab-ollama.git colab-cline
cd colab-cline
bash scripts/00_setup_all.sh                       # 前提確認〜Ollama〜Cline CLI〜切り分けを一括実行
# bash scripts/00_setup_all.sh --with-codex         # 任意: Codex CLI も入れる（--timeout を設定できる代替）
# bash scripts/00_setup_all.sh --with-alt-agents    # 任意: Codex CLI / aider / Qwen Code を全部入れる
# bash scripts/00_setup_all.sh --help
```

個別に進める / 途中から再実行する場合:

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

## 手元のシェルから操作する（リモート制御）

ノートブックを開かず、**手元から VM を立てて操作する**経路もあります。
モデルを差し替えて何度も評価を回すならこちらが速いです。

**→ 手順は [`docs/リモート運用ガイド.md`](docs/リモート運用ガイド.md) を見てください。**
準備から Codex で使うところまで、この 1 本で通せます。
設計の背景は [`docs/手順書.md` §12](docs/手順書.md)、検討の経緯は
[`docs/リモート化計画.md`](docs/リモート化計画.md)。

**`colab ssh` を使うので、colab CLI は git から入れてください。**
v0.7.0 で追加された機能ですが、PyPI には 0.6.0 までしか出ていません（2026-09-17 時点）。

```bash
uv tool install --force "git+https://github.com/googlecolab/google-colab-cli@v0.7.1"
```

```bash
# 一括（推奨）。T4 が空くまで待って構築し、そのまま codex に入る
bash remote/00_all.sh --gpu T4 --retry 3 --profile gpt-oss-20b --attach
bash remote/09_stop.sh       # ★終わったら必ず

# 個別に実行する場合
bash remote/00_doctor.sh     # 手元側の前提確認（VM は作らない＝課金しない）
bash remote/01_new.sh        # VM 確保 + ssh 経路の検証
bash remote/02_deploy.sh     # 作業ツリーを VM へ同期
bash remote/03_setup.sh      # Ollama + Cline + Codex（10〜20 分）
bash remote/04_attach.sh codex   # codex TUI に入る
bash remote/09_stop.sh       # ★成果物を回収して停止
```

無料枠の T4 は取り合いで `Service Unavailable` が普通に返るため、
`--retry 3`（既定 300 秒間隔で再試行）を付けると通りやすくなります。
**長時間の張り込みは避けてください**（Colab の不正利用検知は公表されておらず、
短い間隔で叩き続けるとレート制限を招きます。手順書 §3.5）。
GPU が取れないときは `--gpu cpu` で退避できます（大きいモデルは載りません）。

`--proxy-mode` が OpenSSH の `ProxyCommand` 互換なので、生成される
`remote/.ssh_config` を使えば `ssh` / `scp` / VS Code Remote-SSH もそのまま通ります。

**停止忘れが最大のリスクです。** `colab stop` しない限りキープアライブが
24 時間回り続けます。`09_stop.sh` は停止前に成果物を `artifacts/` に回収します。

### モデルの差し替え

`MODEL_PROFILE` 1 つで `BASE_MODEL` / `NUM_CTX` / 修復プロキシ / `AGENTS.md` の
中身がまとめて切り替わります（未指定なら従来どおりの挙動）。

```bash
MODEL_PROFILE=gpt-oss-20b bash remote/03_setup.sh
```

| プロファイル | モデル | T4 (14.5GiB 空き) |
|---|---|:--:|
| `qwen3-8b` | `qwen3:8b`（現行既定） | ◎ |
| `qwen3-14b` | `qwen3:14b` | ◎ |
| `gpt-oss-20b` | `gpt-oss:20b`（MXFP4 MoE） | ○ 余裕 +725MiB |
| `gemma4-12b-qat` | `gemma4:12b-it-qat`（Gemma 4 12B QAT, 重み実測 6653 MiB） | ◎ 余裕 +5982MiB (ctx=32768) |
| `qwen25-coder-14b` | `qwen2.5-coder:14b`（不具合再現用） | ◎ |

`scripts/vram_precheck.py` が **pull する前に**レジストリのマニフェストだけを見て
載るかどうかを判定するので、13〜15GB を無駄に落とさずに済みます。
Devstral Small 2 24B Q4 は T4 に **1.5GB 足りず載りません**（無料枠では L4 も
引けないため、このリポジトリでは評価対象外）。

`gemma4-12b-qat` は tool calling に既知の不具合があり
（[ollama#15539](https://github.com/ollama/ollama/issues/15539) /
[#15798](https://github.com/ollama/ollama/issues/15798)）、修復プロキシ既定 ON で
始めます。詳細は手順書 §5.10。

## GPU が取れないとき

無料枠の T4 は取り合いで、確保できないことのほうが多くあります。
一方で、この構成で確かめたいことの**半分は GPU を必要としません**
（ツール呼び出しが成立するか / エージェントが何秒で切るか / 配線が正しいか）。

```bash
# GPU 無しの環境でも走ります（10_preflight.sh はもう die しません）
MODEL_PROFILE=gemma4-12b-qat bash scripts/60_cpu_verify.sh

# 重みも要らない範囲だけ
SKIP_MODEL=1 bash scripts/60_cpu_verify.sh
```

`registry.ollama.ai` に到達できない環境では、`ollama pull` を試みずに
理由を名指しして止まります。3 層の検証レーンの考え方は手順書 §13。

## 構成の要点

- **推論エンジンは Ollama。** T4 は compute capability 7.5 で bf16 非対応、vLLM は不利
- **既定モデルは qwen3:8b。** `qwen2.5-coder:7b-instruct-q4_K_M` は「賢さ」も
  prefill 速度も十分だが、Ollama の tool-calling（`<tool_call>` ラッパー）に
  実機で確認した限り一切従わず、Cline からはファイルを 1 つも書けない
  （チャットで説明するだけで終わる）。qwen3:8b は同条件で `<tool_call>` 形式は
  守るが、`editor` の引数を安定して組み立てられず無限ループに陥ることがある
  （既知の症状、手順書 §5.6・§5.7）
- **`num_ctx` を Modelfile に焼き込む。** 既定のままだと Cline は静かに壊れる
- **Cline CLI は既定でクラウドに投げる。** `providers.json` の中身を必ず目視確認する
  （`cline config` は CLI 3.x で対話専用になり、TTY が無いと使えない）
- **日本語プロンプトは引数ではなく標準入力で渡す。** Cline CLI 3.x はコマンドライン
  引数に非 ASCII 文字（日本語含む）が入ると `Unknown command or unquoted prompt`
  で必ず失敗するバグがある。`50_run.sh` は標準入力経由に変更済み。手順書 §7.2
- **VM はステートレスとみなす。** 12 時間で全部消える。コードは git push する

## ファイル

```
docs/手順書.md                  設計・規約・モデル選定・トラブルシュート
notebooks/colab_cline.ipynb    Colab で上から実行する
notebooks/build_notebook.py    ipynb の生成元（編集はこちら）
scripts/common.sh              設定と共通関数
scripts/00_setup_all.sh        ノートブック無しで一括実行するラッパ（10〜90 を順番に呼ぶ）
scripts/10_preflight.sh        GPU/VRAM/ディスク/Node/ターミナル手段の確認
scripts/20_ollama.sh           Ollama + モデル + num_ctx + prefill ベンチ
scripts/30_cline_cli.sh        Node 22 + Cline CLI + ローカル接続設定
scripts/31_alt_agents.sh       任意: Codex CLI / aider / Qwen Code
scripts/32_codex_tool_proxy.py Codex 用ツール呼び出し修復プロキシ（手順書 §5.8・§5.10）
scripts/33_patch_cline_timeout.sh Cline の Ollama タイムアウト上限を上げる（§7）
scripts/34_toolcall_probe.sh   tool_calls が本当に返るかを証拠付きで確かめる（§5.10）
scripts/35_cline_timeout_probe.sh Cline が何秒で切るかをモデル無しで実測する（§7）
scripts/36_registry_probe.py    pull せずにテンプレートと KV の実寸を調べる（§5.10）
scripts/40_terminal_setup.sh   ターミナル用の ~/.bashrc 整備
scripts/50_run.sh              セルから Cline を走らせるラッパ
scripts/60_cpu_verify.sh       GPU 無しで潰せる検証を一括で通す（手順書 §13）
scripts/90_healthcheck.sh      切り分け + 30 秒予算の実測
scripts/99_teardown.sh         片付け
scripts/vram_precheck.py       pull 前にメモリに載るか判定（手順書 §12.4）
scripts/test_*.py              修復プロキシの単体テストと、検証用のスタブ上流
scripts/agents/                AGENTS.md のテンプレート（モデル別）
remote/                        手元から VM を操作する層（手順書 §12）
archive/browser-ide/           v1.0（code-server / トンネル構成）。手順書 §2 に廃止理由
```

設定は `scripts/common.sh` の環境変数で上書きできます。

```bash
BASE_MODEL=qwen2.5-coder:14b-instruct-q4_K_M NUM_CTX=16384 bash scripts/20_ollama.sh
CLINE_PROVIDER=openai-compatible bash scripts/30_cline_cli.sh   # 30秒制限の回避を試す
```

`BASE_MODEL` を qwen2.5-coder 系に戻す場合は、Cline が実際にファイルを書けるか
（チャットで説明するだけで終わっていないか）を必ず実タスクで確認してください。
手順書 §5.6 を参照。

Codex CLI で qwen2.5-coder 系（例: `14b-instruct-q4_K_M`）を使う場合、
`--with-codex` は既定でツール呼び出し修復プロキシ（`CODEX_TOOL_REPAIR=1`）を
経由させます。手順書 §5.8 を参照。

```bash
BASE_MODEL=qwen2.5-coder:14b-instruct-q4_K_M NUM_CTX=16384 \
  bash scripts/00_setup_all.sh --with-codex
```

これを実行しても、Codex CLI の起動画面や `/model` の選択肢に
`qwen2.5-coder:14b-instruct-q4_K_M` という名前はそのまま出てきません。
`20_ollama.sh` が `BASE_MODEL` を土台に `num_ctx`/`num_predict` などを
焼き込んだラッパーモデル **`$CLINE_MODEL`（既定 `cline-coder`）** を
`ollama create` で作り、`~/.codex/config.toml` の `model = "$CLINE_MODEL"`
もこの名前を指すからです。**Codex で選ぶべきモデル名は常に `cline-coder`
（`CLINE_MODEL` を上書きした場合はその値）** で、`BASE_MODEL` を変えても
Codex 側の表示名は変わりません。`ollama show cline-coder` で実体
（`FROM qwen2.5-coder:14b-instruct-q4_K_M` など）を確認できます。

qwen2.5-coder はさらに、`apply_patch` の diff 形式を安定して組み立てられず
「〜します」と宣言だけして何も書かない・中身が空のファイルを作る、という
不具合もあります（手順書 §5.8.1）。`--with-codex` は対策として
`$WORKSPACE/AGENTS.md` に運用ルール（heredoc でファイル全体を書き直す・
先に宣言せずツールを呼ぶ・書いたら自分で確認する、など）を自動配置します。
毎回プロンプトで注意書きを書く必要はありません。詳細は手順書 §5.9。
