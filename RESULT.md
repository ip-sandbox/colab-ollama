# 検証結果: Codex CLI × Ollama qwen2.5-coder:14b ツール呼び出し修正

`PLAN.md` に基づき、この Colab T4 サンドボックス上で実機構築・検証を行った結果。

## 環境

- GPU: Tesla T4 (15360 MiB VRAM)
- Ollama: 公式インストーラで導入
- モデル: `qwen2.5-coder:14b-instruct-q4_K_M`（9.0GB）
- 派生モデル `cline-coder`: `num_ctx=16384`, `num_predict=8192`,
  `temperature=0.2`, `top_p=0.9`, `top_k=40`, `repeat_penalty=1.05`
- Codex CLI: `codex-cli 0.154.0`（`npm install -g @openai/codex`）
- ビルドコマンド:
  ```bash
  BASE_MODEL=qwen2.5-coder:14b-instruct-q4_K_M NUM_CTX=16384 \
    bash scripts/00_setup_all.sh --with-codex
  ```

VRAM 実測: モデル常駐 9.7GiB、空き 4.8GiB（余裕あり）。
prefill 440 tok/s、generation 10.0 tok/s（Cline CLI の 30 秒予算には収まらないが、
Codex CLI は `stream_idle_timeout_ms=600000` のため問題にならない）。

## 見つかった追加事実: Codex CLI 0.154.0 は `wire_api="chat"` を廃止済み

当初の計画では修復プロキシを Chat Completions (`/v1/chat/completions`) のみ
実装する想定だったが、実機で Codex を起動すると

```
Error loading config.toml: `wire_api = "chat"` is no longer supported.
How to fix: set `wire_api = "responses"` in your provider config.
```

で起動不能だった。既存の `31_alt_agents.sh` の自動判定ロジック（Ollama が
`/v1/responses` を出すかどうかで `chat`/`responses` を選ぶ）は今のバージョンの
Codex には通用しない。**このため、プロキシは `/v1/responses`（Responses API）
を主対応として実装し直した。** `/v1/chat/completions` の修復も残してある
（aider など Chat Completions 系クライアント向け）。

## 再現手順と結果

### 1. プロキシ無し・直結（壊れることの再現）

`/v1/responses` に `tools` 付きで直接 POST すると:

```json
{
  "output": [
    {
      "type": "message",
      "role": "assistant",
      "content": [{"type": "output_text", "text": "{\"name\": \"shell\", \"arguments\": {\"command\": [\"ls\"]}}"}]
    }
  ]
}
```

のように、ツール呼び出しの JSON が `message` type の `output_text` に
プレーンテキストとして落ち、`function_call` type の output item は生成されない。
`/v1/chat/completions` でも同一の壊れ方を確認した（`message.content` に
生 JSON、`message.tool_calls` は空）。openai/codex#2229 で報告されている症状と
完全に一致する。

実際に `codex exec "fizzbuzz.py というファイルを作成し、1から20までのFizzBuzz
を出力するコードを書いて、実行して結果を見せて"` を投げると:

```
codex
{"name": "exec_command", "arguments": {"cmd": "cat fizzbuzz.py", ...}}
{"name": "apply_patch", "arguments": {"command": "apply_patch\n*** Begin Patch...*** End Patch"}}
{"name": "exec_command", "arguments": {"cmd": "chmod +x fizzbuzz.py", ...}}
{"name": "exec_command", "arguments": {"cmd": "./fizzbuzz.py", ...}}
```

がチャットにテキストとして印字されるだけで、`fizzbuzz.py` は一度も作成されなかった
（`ls /content/workspace` に存在しないことを確認）。

### 2. プロキシ経由（修復されることの確認）

同じ `tools` 付きリクエストをプロキシ (`http://127.0.0.1:11435`) 経由で送ると:

```json
{
  "output": [
    {
      "type": "function_call",
      "id": "fc_repaired_0",
      "call_id": "call_repaired_1",
      "name": "shell",
      "arguments": "{\"command\": [\"ls\"]}",
      "status": "completed"
    }
  ]
}
```

に正しく組み替えられることを確認した。

実際の Codex CLI での確認（シンプルなタスク）:

```
$ codex exec --skip-git-repo-check "シェルコマンドで echo hello world > hello.txt を実行してください。"
...
exec
/bin/bash -lc "echo 'hello world' > hello.txt" in /content/workspace
 succeeded in 0ms:
codex
ファイル `hello.txt` に "hello world" が書き込まれました。
```

`hello.txt` の中身が実際に `hello world` になっていることを確認した
（再現性確認のため `hello2.txt` で同一手順をもう一度実行し、同じ結果を得た）。
プロキシのログにはそれぞれ

```
[codex-tool-proxy] POST /v1/responses -> repaired (tools=7, stream_requested=True)
```

が記録されている。

### 3. 残った別問題（プロキシの対象外・§5.7 と同種）

`fizzbuzz.py` タスク（ファイル作成＋実行）をプロキシ有効で再実行すると、
ツール呼び出し自体は正しく `function_call` として Codex のツールルータへ渡る
ところまで進んだが、以下の 2 種類の**モデル側の信頼性問題**に阻まれた:

1. モデルが `exec_command` を呼ぶ際に `justification` 引数だけを付けて
   `sandbox_permissions` を省略することがあり、Codex 0.154 の
   `exec_command` はこれを「エスカレーション要求」とみなして
   `approval_policy = "never"` により拒否する
   （`error=`justification` requires an explicit `sandbox_permissions`...`）。
2. モデルが宣言されたツール名ではなく `apply_patch`（実際には存在しない。
   ファイル編集は `exec_command` 経由で `apply_patch` コマンドを実行する
   設計）や `Run`（`shell` の誤り）など、存在しない・不正確なツール名を
   使うことがある。

修復プロキシは「リクエストで宣言されたツール名と一致する場合のみ」修復する
設計にしているため、(2) のような存在しないツール名は意図的に修復対象外とした
（誤ったツールへの書き換えは、本物のテキスト回答を誤って書き換えるのと同種の
リスクであり、範囲外とするのが安全と判断した）。

これは `docs/手順書.md` §5.7 で既に整理されている「プロトコル準拠」と
「実タスク完走の信頼性」が別軸である、という教訓の再確認である。
**今回のタスクで解決すべき「ツール呼び出しの JSON が構造化フィールドに
載らない」という問題（ユーザー報告・参考3URL・openai/codex#2229 の症状）は
修復プロキシで解決した。** 14B 量子化モデル自身の tool-calling 信頼性
（ツール名や引数を毎回正しく組み立てられるか）は別課題として残る。

## 変更したファイル

- 新規: `scripts/32_codex_tool_proxy.py`（Responses API / Chat Completions
  両対応の修復プロキシ）
- 変更: `scripts/common.sh`（`CODEX_TOOL_REPAIR` / `CODEX_PROXY_PORT` /
  `CODEX_PROXY_BASE_URL` を追加）
- 変更: `scripts/31_alt_agents.sh`（プロキシ起動、`wire_api="responses"` 固定）
- 変更: `scripts/99_teardown.sh` / `scripts/90_healthcheck.sh`
  （プロキシの停止・監視を追加）
- 変更: `docs/手順書.md`（§5.8 新設、§7.1 の `wire_api` 記述を実態に合わせて修正）
- 変更: `README.md`（一行追記）

## 追記: 後片付けスクリプト (`scripts/99_teardown.sh`) の動作確認とバグ修正

「プロキシなどの停止方法はあるか」という質問を受け、既存の
`bash scripts/99_teardown.sh --all`（ollama と codex-tool-proxy を両方
`stop_bg` で止める設計）を実機で実行して確認したところ、

```
/content/colab-ollama/scripts/common.sh: line 193: name: unbound variable
```

で失敗した。原因は `scripts/common.sh` の `stop_bg()` が

```bash
local name="$1" pidfile="$STATEDIR/$name.pid" pid
```

と 1 つの `local` 文で `name` と `pidfile` を同時に宣言していたこと。
bash は `local` の右辺をコマンドライン全体として先に展開してから代入するため、
`$STATEDIR/$name.pid` の `$name` は同じ文で後から定義される `name` ではなく
呼び出し元スコープの（未定義の）`name` を参照してしまい、`set -u` の下で
`unbound variable` になる。すぐ上の `start_bg()` は `local name=... ; local
pidfile=...` と 2 文に分けており同じ問題を踏んでいない。

このバグは今回の Codex プロキシ対応以前から存在していた（`99_teardown.sh` は
以前から `stop_bg ollama` を呼んでいた）が、実機で `--all`/`--purge` を
伴う teardown を初めて実行したことで顕在化した。

`stop_bg()` を `start_bg()` と同じパターン（`local name="$1"` を独立した
`local` 文にする）に直し、再度 `bash scripts/99_teardown.sh --all` を実行して
以下を確認した:

```
=== Ollama の停止 ===
[   OK] ollama を停止しました (pid=9350)

=== ツール呼び出し修復プロキシの停止 ===
[   OK] codex-tool-proxy を停止しました (pid=17848)

=== 現在の状態 ===
[DOWN] ollama
[DOWN] codex-tool-proxy
```

`pgrep -af 'ollama serve|codex_tool_proxy'` でプロセスが実際に残っていない
ことも確認済み。新しい後片付けスクリプトを追加する必要は無く、既存の
`scripts/99_teardown.sh --all` がそのまま使える。

## 結論

- `CODEX_TOOL_REPAIR=1`（既定）で `qwen2.5-coder:14b-instruct-q4_K_M` を
  Codex CLI から実際に使える状態にできた（プロキシ無効時は再現通り動かない
  ことも実機で確認済み）。
- Codex CLI 0.154.0 では `wire_api="chat"` が使えないという、当初の計画には
  無かった実装上の制約が見つかり、プロキシを Responses API 対応に作り直した。
- 修復プロキシはツール呼び出しの **形式** の問題を解決するものであり、
  14B モデル自身の tool-calling **信頼性**（ツール名・引数の正確性）は
  別問題として残ることを実機で確認・記録した。

---

# 追記 (2026-09-17): colab CLI によるリモート制御と gpt-oss:20b の実測

計画: [`docs/リモート化計画.md`](docs/リモート化計画.md) / 手順: 手順書 §12

## 環境

- 手元: Ubuntu / colab CLI **0.7.1**（git から導入。PyPI は 0.6.0 止まりで `colab ssh` が無い）
- VM: Colab 無料枠 **Tesla T4** (15360 MiB, 空き 14913 MiB), driver 580.82.07
- Python 3.13.15 / RAM 12GB / disk 113GB

## 1. 経路: `colab ssh` は使えた

`colab ssh` は **v0.7.0 (2026-09-03) で追加**されたが **PyPI には 0.6.0 までしか
出ていない**（2026-09-17 時点。git tag は v0.7.1）。git から入れれば使える。

`--proxy-mode` が OpenSSH の `ProxyCommand` 互換なので、生成した `.ssh_config`
経由で `ssh` / `scp` / `tar | ssh` がそのまま通ることを実機で確認した。
0.6.0 前提で必要だった「`colab exec` に Python を渡して `subprocess` でシェルを
回す」「既定 30 秒の timeout を避けるためデタッチしてログをポーリングする」
という迂回は**すべて不要になった**。

## 2. ★最大の落とし穴: SSH では Ollama が黙って CPU に落ちる

Colab のノートブックカーネルは `LD_LIBRARY_PATH=/usr/lib64-nvidia` を設定するが、
**素の SSH ログインには引き継がれない**。`/dev/nvidia0` は見えているのに:

```
NVIDIA-SMI couldn't find libnvidia-ml.so library in your system
```

**問題は `nvidia-smi` が落ちることではない。Ollama が CUDA を検出できず、
エラーも出さずに CPU へフォールバックすること。** 気付かなければ推論が一桁遅くなり、
ベンチの数字が丸ごと無意味になっていた。

環境変数ではなく **ldconfig で直す**（Ollama をどう起動しても効かせるため）:

```bash
echo /usr/lib64-nvidia > /etc/ld.so.conf.d/colab-nvidia.conf && ldconfig
```

`remote/common.sh` の `vm_bootstrap_env()` が `01_new.sh` から自動実行する。
効いていることの確認は `ollama.log` のこの行:

```
msg="inference compute" library=CUDA compute=7.5 name=CUDA0 description="Tesla T4"
```

他に踏んだ罠は手順書 §12.5 に記録した
（`A && B & echo $!` の `&` の係り方、`pgrep -f` の ssh 越し自己マッチ）。

## 3. ★gpt-oss:20b は T4 で動き、qwen3:8b より速い

**当初の懸念（MXFP4 が sm_75 / Turing で成立するか）は杞憂だった。**

```
llama_model_loader: - type mxfp4:   72 tensors
load_tensors: offloaded 25/25 layers to GPU
ollama ps -> PROCESSOR: 100% GPU
```

CPU オフロードは一切無し。num_ctx=16384 で VRAM 使用 12499 MiB / 空き 2414 MiB。

### ベンチ比較（同一 VM・同一条件）

| | qwen3:8b (ctx 32768) | **gpt-oss:20b (ctx 16384)** |
|---|---:|---:|
| prefill | 956 tok/s | 880 tok/s |
| generation | 23.6 tok/s | **34.5 tok/s** |
| 安全プロンプト長 | 8,410 tok | **13,645 tok** |
| 判定 | WARN | **OK** |
| VRAM | 7,501 MiB | 12,499 MiB |

**20B なのに 8B より生成が 1.46 倍速い。** MoE（活性 3.6B）なので当然ではあるが、
T4 のような狭い環境ではこの差がそのままエージェントの実用性に効く。

### 実タスク E-1（fizzbuzz を作って実行）: 完走

`codex exec` で 1 発完走。qwen2.5-coder:14b で繰り返し起きていた
「宣言だけして何も書かない」「コマンドを提示してユーザーに実行を頼む」
（§5.8.1 および 2026-09-16 の追試）は**再現しなかった**。

- 中身のある `fizzbuzz.py` (324 bytes) を実際に書いた
- **`ls -la fizzbuzz.py && cat fizzbuzz.py` で自己確認した**（AGENTS.md の指示に従っている）
- `python3 fizzbuzz.py` を自分で実行し、出力を報告した
- 報告は日本語。中国語への切り替わりも無し

修復プロキシは**経由していない**（`base_url = http://127.0.0.1:11434/v1` 直結）。
`MODEL_PROFILE=gpt-oss-20b` が `CODEX_TOOL_REPAIR=0` を設定するため。

## 4. VRAM 事前チェックの精度

`scripts/vram_precheck.py` はレジストリのマニフェストだけで判定する（pull 不要）。

| モデル | 事前チェックの予測 | 実測 | 判定 |
|---|---:|---:|:--:|
| gpt-oss:20b | 必要 14,188 MiB / 余裕 +725 | 使用 12,499 MiB / 空き 2,414 | OK（安全側に外した） |
| devstral-small-2:24b-q4_K_M | 必要 16,392 MiB / 余裕 **-1,479** | （pull せず） | **NG** |

予測は安全側に 1.7GB ほど過大だった（マニフェストの重みサイズには VRAM に
載らない分も含まれる、KV も実測 0.013 MiB/token に対し 0.024 で見積もった）。
**過大評価は「載るものを弾く」方向に効くので、閾値は今後ゆるめる余地がある。**
Devstral は 1.5GB の不足で、過大評価を割り引いても載らない。

## 5. 結論

- **リモート制御の足場は完成し、実機で一通り通した**
  （`00_doctor` → `01_new` → `02_deploy` → `03_setup` → `04_attach` → `09_stop`）
- **評価対象の第一候補 `gpt-oss:20b` は T4 で成立し、現行既定 qwen3:8b より速い。**
  実タスクのツール呼び出しも安定していた
- 残: `qwen3:14b` の測定、評価ハーネス `scripts/60_eval.sh`（E-2〜E-4）の実装

## 6. 追試 (2026-09-17 後半): qwen3:14b と gpt-oss のツール呼び出し不具合

### 6.1 qwen3:14b は T4 では実用にならない

| | qwen3:8b | gpt-oss:20b | **qwen3:14b** |
|---|---:|---:|---:|
| prefill | 956 tok/s | 652〜880 | **422 tok/s** |
| generation | 23.6 tok/s | 27.0〜34.5 | **9.7 tok/s** |
| 安全プロンプト長 | 8,410 | 7,491〜13,645 | **0** |
| 判定 | WARN | OK〜WARN | **NG** |
| VRAM | 7,501 MiB | 12,499 MiB | 10,083 MiB |

`100% GPU` で CPU オフロードは無い。**dense な 14B（全パラメータが活性）と
MoE の gpt-oss（活性 3.6B）の差**がそのまま出ている。
実タスクは 2 回中 1 回成功（127s で失敗 / 109s で成功）、3 回目は VM 回収で消失。

**「大きいモデルほど遅い」は成り立たない。** 20B の gpt-oss が 14B の
qwen3 より 3 倍近く速い。T4 のような狭い環境では MoE の優位がそのまま効く。

### 6.2 gpt-oss の 2 つのツール呼び出し不具合（手順書 §12.7 に詳細）

**(1) ollama/ollama#17638** — Ollama が自分の出力をパースできず 500 を返す。
未修正、手元の 0.34.1 で再現。非決定的。修復プロキシに**この 500 限定の再送**を
入れた。実測で 16 回発火・15 回救済、`stream disconnected` は再現しなくなった。

**(2) harmony 構文の漏れ** — 再送で (1) を潰しても 5 回中 2 回は別理由で失敗した。
`to=functions.apply_patch <|constrain|>json<|message|>{...}` を**本文にテキストと
して書き出し**、ツール呼び出しを発行しないまま悩んで出力トークンを使い切る
（上限 8192 に対し 9,196 / 12,936 使用）。§5.6 / §5.8 と同系統だが、harmony は
**ツール名が JSON の外側**にあるため既存の修復では拾えなかった。
`_find_harmony_tool_calls()` を追加して対応（ユニットテストのみ。実機未検証）。

### 6.3 実測（プロンプト: `pythonでfizzbuzzを書いてテストして。` × 5、再送のみ）

| 試行 | fizzbuzz.py | test_fizzbuzz.py | 原因 |
|---|---:|---:|---|
| 1 | なし | なし | (2) トークン切れ |
| 2 | 1394 B | 333 B | ✓ |
| 3 | 7 B | なし | (2) トークン切れ |
| 4 | 1146 B | 504 B | ✓ |
| 5 | 962 B | 475 B | ✓ |

### 6.4 踏んだ運用上の罠: `colab ssh` は黙って VM を作る

走らせていた T4 が **Colab 側に回収された**（無料枠は予告なく reclaim される）。
状況確認のつもりで ssh したところ、`colab ssh` がセッション不在を検知して
**新しい VM を自動作成した**。しかも `--gpu` 未指定なので **CPU ランタイム**で、
前の VM のログも成果物も無い別マシンに繋がり課金だけ増えた。

`colab ssh` 側に自動作成を止めるフラグは無いため、`remote/proxycommand.sh` を
ProxyCommand に挟み、**接続前にセッションの存在を確認して無ければ繋がずに失敗**
させるようにした。VM を作るのは `remote/01_new.sh` だけの役目にする。
