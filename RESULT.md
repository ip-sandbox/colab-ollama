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
`_find_harmony_tool_calls()` を追加して対応。**実機で A/B 検証済み（§6.5）。**

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

### 6.5 harmony 修復の実機検証（モデル不要）

T4 は `Service Unavailable` で取れず、CPU ランタイム（RAM 約 12.7GB）には
13GB の gpt-oss:20b が載らない。そこで**モデルを使わずに**検証した。

ユニットテストは「テキストから tool_calls を組み立てられるか」までしか見ない。
本当に知りたいのは **Codex が修復後の tool_calls を受け取って実際にツールを
実行するか**で、これは上流をスタブに差し替えれば確かめられる:

```
Codex CLI  ->  32_codex_tool_proxy.py  ->  scripts/test_harmony_e2e_stub.py
```

スタブは実機で観測した「harmony 構文がテキストに漏れた本文」を返す。

**A/B（経路も SSE 包装も同一。変えたのはツール名だけ）:**

| ツール名 | プロキシの判定 | codex exit | ファイル作成 |
|---|---|---:|:--:|
| `exec_command`（実在する） | **repaired** | 0 | **された** |
| `this_tool_does_not_exist` | passthrough | 0 | されない |

修復が発火した側でのみ Codex が実際にコマンドを実行した:

```
/bin/bash -lc 'echo HARMONY_REPAIR_WORKS > /content/workspace/harmony_proof.txt'
```

最初に試した対照（プロキシを外してスタブ直結）は**交絡していた**ので採用しない。
スタブは SSE を喋らず、SSE 包装はプロキシの仕事なので、修復の有無と無関係に
`stream disconnected before completion` になる。元の症状と同じ文言が出るため
紛らわしいが、原因は別。上の A/B はプロキシを通したまま比較している。

**副次的に分かったこと:**

- Codex 0.154.0 が渡すツール: `exec_command` / `write_stdin` /
  `request_user_input` / `view_image` / `multi_agent_v1` / `get_goal` /
  `create_goal` / `update_goal` と `type: web_search`（name 無し）
- **`apply_patch` はツールとして提供されていない。** §6.2 (1) で観測した
  `{"cmd":"apply_patch <<'PATCH' ..."}` は、`exec_command` の `cmd`
  （**string 型**）からシェル経由で apply_patch を呼ぼうとしたもの。
  `cmd` が string である以上、末尾の `]` はモデルの誤りであり、
  ollama#17638 の「array-wrap してしまう」という説明と一致する

**測っていないこと**: gpt-oss の実成功率が 3/5 からどれだけ上がるか。
それには T4 と実モデルが要る。→ §7 で実測した。

---

# 追記 (2026-09-18): T4 実機での 5 回実測（harmony 修復を有効にした状態）

`bash remote/00_all.sh --gpu T4 --retry 5 --profile gpt-oss-20b --eval 5 --stop`
を 1 本流した。T4 は**再試行 1 回目で確保できた**。全体 3402s、VM は自動停止。

## 7.1 結果: 5/5 成功（ベースライン §6.3 は 3/5）

プロンプト・回数・判定基準は §6.3 と同一（`pythonでfizzbuzzを書いてテストして。` × 5）。

| 試行 | 結果 | 所要 | fizzbuzz.py | test_fizzbuzz.py | テスト実行 | トークン |
|---|---|---:|---:|---:|---|---:|
| 1 | OK | 454s | 1058 B | 576 B | `unittest` Ran 1 → OK | 27,782 |
| 2 | OK | 155s | 1067 B | 646 B | `unittest` Ran 4 → OK | 5,982 |
| 3 | OK | 107s | 698 B | 338 B | `unittest` Ran 1 → OK | 4,750 |
| 4 | OK | 589s | 1050 B | 344 B | `pytest` 2 passed | 26,076 |
| 5 | OK | 160s | 1327 B | 452 B | `pytest` 2 passed | 7,316 |

**「テストが通った」という主張は鵜呑みにせず、ログで実行の痕跡を確認した。**
5 回とも実際にテストコマンドを実行し、成功している（モデルの自己申告だけで
OK 判定していない）。ただしテスト件数は 1〜4 件とばらつく。

## 7.2 ★ 5/5 を harmony 修復の成果と読んではいけない

プロキシの発火回数:

| 機構 | 発火 | 内訳 |
|---|---:|---|
| ollama#17638 の再送 | **4 回** | 2 件の事象（1 回で復帰 / 3 回目で復帰）。**取りこぼし 0** |
| harmony 構文の修復 | **0 回** | 一度も発火せず |

**harmony 修復は今回 1 度も発火していない。** したがって 3/5 → 5/5 の差を
この機構に帰属させることはできない。§6.3 のベースラインも**再送は有効**な
状態で測っており、両者の構成上の差は harmony 修復の有無だけ。その唯一の差分が
発火しなかった以上、差は**実行ごとのばらつきとして説明するのが妥当**。

§6.3 の失敗 2 件はどちらも「トークン切れ」であって harmony 漏れではない。
harmony 修復はそもそもこの失敗様式には効かない。

- n=5 対 n=5 は、3/5 と 5/5 を区別するには小さすぎる
- harmony 修復の有効性は §6.5 のモデル不要 A/B で別途確認済み。
  今回の結果はそれを補強も反証もしない（発火していないため）

**再送のほうは実際に仕事をしている。** 2 件の 500 を拾って両方とも復帰させた。
3 回目でようやく通った事象があるので、`TOOLCALL_RETRIES=3` という既定は妥当。

## 7.3 再現性: ベンチは前回とほぼ一致

| 項目 | 今回 (09-18) | 前回 (09-17) |
|---|---:|---:|
| prefill | 854 tok/s | 652–880 |
| generation | 32.2 tok/s | 27.0–34.5 |
| VRAM 使用 | 12,537 MiB | 12,499 MiB |
| VRAM 空き | 2,376 MiB | 2,414 MiB |
| 安全プロンプト長 | 約 12,345 tok | 7,491–13,645 |

pull 前の VRAM 事前チェックも意図どおり通過した（必要 13.86 GiB /
空き 14.56 GiB / **余裕 +725 MiB**）。

所要時間は 107s〜589s と 5 倍以上ばらつく。試行 4 は 600s の timeout に
**11 秒差**まで迫っており、生成 32.2 tok/s では長い応答が時間切れと
隣り合わせであることを裏づけている。

## 7.4 ★ `remote/03_setup.sh` が 30 分ハングした（修正済み）

セットアップ自体は 541s で正常終了（OK=7 / NG=0）していたのに、手元側が
先へ進まなかった。原因は追従の書き方:

```bash
rsh "tail -n +1 -f '$SETUP_LOG'" | sed "/$SENTINEL/q"   # ← これが悪い
```

`sed` はセンチネル行を出力して**正しく終了していた**。問題は左側で、
**SIGPIPE は「次に書き込んだとき」にしか配送されない**。セットアップが
終わればログは静かになるので、`ssh`/`tail -f` は二度と書き込まず、
シグナルを受け取る機会がないまま待ち続ける。
**ログが流れ続ける状況でしか成立しない書き方だった。**

対処: VM 側でポーリングし、センチネルを見たら**リモート側から**抜ける。
ssh の終了がリモートコマンドの終了で決まるので SIGPIPE に依存しない。
`SETUP_WAIT_MAX`（既定 5400s）で無限待ちも塞いだ。追従の遅れは最大 2 秒。

同じ罠は `tail -f | head -1` や `tail -f | grep -m1` にもある。

## 7.5 ついでに直した表示の不備

- `scripts/10_preflight.sh` が `memory.**used**` をヘッダ無し CSV で出していた。
  `remote/01_new.sh` は同じ並びで `memory.**free**` を出すため、
  **`0 MiB` を「空きゼロ」と読み違えた**（実際に読み違えた）。項目名を併記した
- `scripts/20_ollama.sh` の pull 前の警告が「14B q4_K_M で約 9GB」という
  **モデル決め打ちの固定文言**で、gpt-oss:20b を落としている最中に 14B の
  話が出ていた。事前チェックが JSON に残す実測値から生成するようにした

## 7.6 残る課題

- **harmony 修復の実効果は実機では未確認のまま。** 発火させるには漏れが
  起きる条件を引く必要があり、今回は引けなかった
- 再送の寄与を分離するなら `CODEX_PROXY_TOOLCALL_RETRIES=0` で対照を取る
- n を増やさない限り 3/5 と 5/5 の差は判定できない

---

# 追記 (2026-09-18): Cline の 30 秒タイムアウトは無くなっていた／gemma4 と CPU 検証レーン

計画: [`PLAN.md`](PLAN.md) / 手順: 手順書 §5.10・§7 の訂正・§13

## 環境

- 実行場所: Claude on the web のコンテナ（**GPU 無し**）
- 4 vCPU / RAM 15GB / ディスク空き 30GB / Node v22.22.2 / Python 3.11.15
- Cline CLI **3.0.62**（`npm install -g cline`）
- ★ egress ポリシーで `registry.ollama.ai` と `ollama.com` が **403**、
  `huggingface.co` も到達不可。`registry.npmjs.org` / `pypi.org` /
  GitHub のリリースアセットは到達可

したがって **実モデル（gemma4:12b-it-qat）はこのセッションでは動かせていない**。
以下はすべて「モデルを必要としない検証」の結果である。

## 1. ★ Cline CLI の 30 秒タイムアウトは 3.0.62 では起きない

手順書 §7 が長らく「最大の壁」として扱ってきた前提が崩れた。

遅延を秒単位で指定できるスタブ上流（`scripts/test_slow_upstream_stub.py`）を立て、
`scripts/35_cline_timeout_probe.sh` で測った。

| 上流の応答時間 | プロバイダ | 経過 | exit | 結果 |
|---:|---|---:|---:|---|
| 45s | `ollama` | 47s | 0 | 完走 |
| 45s | `openai-compatible` | 47s | 0 | 完走 |
| 120s | `ollama` | 122s | 0 | 完走 |
| 120s | `openai-compatible` | 122s | 0 | 完走 |
| 340s | `ollama` | **302s** | 1 | `Ollama request timed out after 300 seconds` |

**タイムアウトの仕組み自体は残っているが、既定値が 30 秒ではなく 300 秒**である。
実装にも該当の定数がある:

```
@cline/llms/dist/providers.js   OLLAMA_DEFAULT_TIMEOUT_MS = 300000
@cline/llms/dist/index.js       同上
```

さらに `O0(e)` がプロバイダ設定の `timeoutMs` を読む実装になっているので、
**「CLI 側に設定項目が無い」という記述も正確ではない**。

**「モデルを使わずに測った」ことが効いている。** 実モデルでは 300 秒ちょうどを
狙って遅延を作れないので、この境界は出せない。スタブなら 340 秒を指定して
302 秒での中断を再現できる。GPU も要らない。

### 未検証だった V-4 の決着

§7 の対策 6 番「`CLINE_PROVIDER=openai-compatible` なら 30 秒制限を回避できる
可能性（未検証）」は **意味を失った**。120 秒の遅延に対して両プロバイダとも
完走し、差は観測されなかった。そもそも回避すべき 30 秒が存在しない。

### ★ 測定を 1 度汚染した（記録として残す）

最初に 310 秒で測ったとき **258 秒で中断**し、`The operation timed out.` という
別のメッセージが出た。原因は**自分で測定中にパッチスクリプトを適用・復元したこと**。
`OLLAMA_DEFAULT_TIMEOUT_MS` を 300000 → 600000 → 300000 と動かしている最中に
計測が走っていた。リクエストログにも、その時だけ余計な `/api/tags` が
`+214.5s` に現れている。

パッケージを 300000 に戻し、実行中に一切触らずに測り直した結果が上の 302 秒
（`Ollama request timed out after 300 seconds`）。**計測中に計測対象を変更しない。**

## 2. Cline の設定ファイルの場所が変わっていた

`scripts/30_cline_cli.sh` は

```
$CLINE_DATA_DIR/data/settings/providers.json
```

を決め打ちしていたが、3.0.62 が実際に書くのは

```
$CLINE_DATA_DIR/settings/providers.json
```

だった。このため **設定は正しく書けているのに**「providers.json がありません。
cline auth が失敗した可能性があります」と誤警告していた。
両方を見る `cline_providers_json()` を `common.sh` に置いて解決。

## 3. GPU が無くても走るようにした（ACCEL）

`10_preflight.sh` は `nvidia-smi` が無ければ即 `die` していたので、
GPU が取れないだけで CPU でも潰せる検証まで止まっていた。

`ACCEL`（`gpu` / `cpu`、既定は `nvidia-smi` の有無で自動判定）を `common.sh` に
置き、`10_preflight.sh` / `20_ollama.sh` を分岐させた。
`vram_precheck.py` は判定ロジックを 1 本のまま、表示ラベルだけ引数化した
（出力 JSON のパスとキーは据え置き。e82d035 で `20_ollama.sh` が
`weights_mib` を読み始めているため）。

GPU 無しのこのコンテナで `10_preflight.sh` が `die` せず完走することを確認した。

## 4. レジストリが塞がれている環境で pull を試みない

`ollama.com`（インストーラ）と `registry.ollama.ai`（重み）は**別のホスト**で、
後者だけが塞がれている環境が実在する（この環境がそう）。この場合、
ollama のインストールまで通ってから pull だけが失敗する。

`10_preflight.sh` が両方を独立にチェックして
`$STATEDIR/net-registry-ok` に残し、`60_cpu_verify.sh` がそれを読んで
**4 秒で理由を名指しして止まる**ことを実測で確認した（pull を試みない）。

## 5. gemma4:12b-it-qat を評価対象に入れた（実挙動は未確認）

`docs/リモート化計画.md` §0.3 は Gemma を「Ollama のテンプレートに
tool calling が入っていない」として却下していた。これは **Gemma 3** の話で、
Gemma 4 では capabilities に `tools` が入っている
（`gemma4:12b-it-qat` は vision / tools / thinking / audio、約 7.2GB）。

ただし **capabilities は今回も保証にならない**見込みが高い。
「tool_calls に入らず content に漏れる」不具合が 2 系統報告されている:

| issue | 環境 | 漏れ方 |
|---|---|---|
| [#15539](https://github.com/ollama/ollama/issues/15539) | 0.20.6 / `gemma4:e4b` | `system prompt` + `think:false` + `tools` が揃うと `{"tool_calls":[{"function":N,"args":{}}]}` + `<channel|>` が content に落ちる |
| [#15798](https://github.com/ollama/ollama/issues/15798) | 0.21.1 / `gemma4-64k` | `<\|tool_call\|>` 等の特殊トークンが本文に漏れる。`finish_reason` は `stop`。**Closed as not planned** |

どちらも既存の修復ロジック（トップレベルの `{"name":..,"arguments":..}` を探す）
では拾えない形なので、`32_codex_tool_proxy.py` に両方を足した。
単体テスト `test_tool_proxy_gemma4.py` は 17 ケース全て緑、既存の
`test_tool_proxy_harmony.py` (10) と `test_tool_proxy_retry.py` (6) も緑のまま。

**#15798 の実装は issue の記述から起こしたもので、逐語のサンプルが無い。**
#15539 は issue 本文の逐語サンプルをそのまま使っている。

## 測っていないこと

このセッションは GPU も実モデルも使えていないので、以下は**まったく分かっていない**:

- **`gemma4:12b-it-qat` が実際に `tool_calls` を返すかどうか。** 最大の未知数。
  `scripts/34_toolcall_probe.sh` で証拠を採るところから
- 足した Gemma 4 用の修復が、実機の漏れ方に本当に噛み合うか
  （特に #15798 は形を推定で書いている）
- `KV_MIB_PER_TOKEN` の実値。今は安全側の暫定値 0.05
- T4 での実用速度 / 安全プロンプト長 / 実タスクの完走率
- Codex CLI 側のタイムアウト挙動（今回測ったのは Cline のみ）

次の一手は、`registry.ollama.ai` を許可したネットワークポリシーで環境を作り直し、

```bash
MODEL_PROFILE=gemma4-12b-qat bash scripts/60_cpu_verify.sh
```

を回して `$STATEDIR/probe/*.content.txt` を採ること。

---

# 追記 (2026-09-18 その 2): 別マシンでの実測 — 重みサイズ確定と、疎通判定のバグ 2 件

前の追記は Claude on the web のコンテナ（レジストリが egress で塞がれた環境）での
作業だった。**レジストリに到達できる別マシン**（2 vCPU / RAM 7GB / GPU 無し、
`colab` CLI 導入済みの操作用マシン）へ移ったので、そこでしか確かめられないことを測った。

## 1. gemma4:12b-it-qat の重みを実測し、num_ctx を 32768 に上げた

レジストリのマニフェストから実測:

| 項目 | 値 |
|---|---|
| 重み | **6653 MiB = 6.50 GiB** |
| ollama.com の表示 | 約 7.2GB（10 進の GB なのでほぼ一致） |

T4 の空き 14913 MiB に対する成立表（`scripts/vram_precheck.py` を実行）:

| num_ctx | KV 見積り | 余裕 | 判定 |
|---:|---:|---:|:--:|
| 16384 | 0.05 MiB/tok | +6801 MiB | OK |
| 32768 | 0.05 MiB/tok | +5982 MiB | OK |
| **32768** | **0.15 MiB/tok**（3 倍の悲観値） | **+2705 MiB** | **OK** |
| 65536 | 0.15 MiB/tok | -2210 MiB | NG |

`KV_MIB_PER_TOKEN` はまだ暫定値なので「3 倍に見積もっても載るか」で決めた。
**`_p_ctx` を 16384 から 32768 に上げた。** §5.3 と `20_ollama.sh` が言うとおり
「32768 未満だと Cline はまともに動かない」ので、載るのに 16384 に落とす理由が無い。
前の追記の時点で 16384 にしていたのは、重みを web の表示値でしか知らなかったため。

## 2. ★ 疎通判定が「pull できる環境」を「届きません」と誤判定していた

前の追記で入れた `10_preflight.sh` のレジストリ疎通チェックに **バグが 2 件**あった。
どちらも **「pull できるのに L2 を丸ごと飛ばす」** という最悪の方向に倒れる。

**(1) HTTP ステータスで判定していた**

```bash
curl -fsS --max-time 8 -o /dev/null "https://$host"   # ← 誤り
```

`registry.ollama.ai` は **ルートに GET すると 404 を返すのが正常**
（`/v2/<name>/manifests/<tag>` しか生えていない）。`curl -f` は 404 で失敗するので、
**マニフェストを実際に取得できている機械で「到達不可」と出た。**
このマシンで `vram_precheck.py` が同じホストから重みを取れているのだから、
届いていないはずがない、という形で気付いた。

欲しいのは「egress ポリシーに塞がれていないか」なので、**応答が返ったか**だけを見る。
塞がれている場合は CONNECT が失敗して `http_code` が `000` になる。
200 でも 401 でも 404 でも、応答が返る時点でホストには届いている。

**(2) フォールバックが連結して "000000" になっていた**

(1) を直す過程で入れた

```bash
code="$(curl -sS ... -w '%{http_code}' ... || echo 000)"   # ← 誤り
```

も間違いだった。**curl は失敗時にも `-w` の書式を評価して `000` を stdout に出す**ので、
`|| echo 000` が連結されて `000000` になる。これは `!= "000"` をすり抜けるため、
**到達不可を到達可と誤報する**（(1) と逆方向の誤りで、こちらのほうが危ない）。

終了コードは捨て、出力が空のときだけ `000` を補う形にした。

3 通り（到達可・名前解決不可・到達不能 IP）で確認済み:

```
  OK  registry.ollama.ai          到達可 (HTTP 404)
 WARN registry.ollama.ai.invalid  到達不可
 WARN 10.255.255.1                到達不可
```

**教訓**: 「到達性」を HTTP ステータスで測らない。そして
**フォールバックを足す前に、失敗時にそのコマンドが何を出力するかを確かめる。**

## 3. このマシンでも実モデルは動かせない（理由が違う）

レジストリには届くが、**RAM 7GB / 空き 6GB** に対して重みだけで 6.5GiB なので載らない
（事前チェックも `余裕 -2112 MiB` で NG を返す）。ディスクも `/home` の空きが 2.1GB。
このマシンは `colab` CLI でリモートの VM を操作するための**操作用マシン**であって、
推論ホストではない。

## 測っていないこと

**実モデルは依然として一度も動かせていない。** 前の追記から変わっていない:

- `gemma4:12b-it-qat` が実際に `tool_calls` を返すかどうか（最大の未知数）
- 足した Gemma 4 用の修復が実機の漏れ方に噛み合うか（特に #15798 は形を推定で実装）
- `KV_MIB_PER_TOKEN` の実値（今回上げた 32768 も、この暫定値の上に乗っている）
- T4 での実用速度 / 安全プロンプト長 / 完走率

次の一手は変わらず、**重みが載る環境で** 次を回して
`$STATEDIR/probe/*.content.txt` を採ること:

```bash
MODEL_PROFILE=gemma4-12b-qat bash scripts/60_cpu_verify.sh    # RAM 8GB 以上の CPU 環境
bash remote/00_all.sh --gpu T4 --retry 3 --profile gemma4-12b-qat --eval 5 --stop
```

---

# 追記 (2026-09-18 その 3): L2 実機 — gemma4 の tool calling は正しく動いた

計画: [`PLAN.md`](PLAN.md) の L2 / 手順: 手順書 §5.10・§7・§13

## 環境

- 手元: 操作用マシン（2 vCPU / RAM 7GB / GPU 無し、colab CLI 0.7.1）
- VM: **Colab CPU ランタイム**（2 コア / RAM 12,975 MiB / ディスク 89GB）
- Ollama **0.34.2** / `gemma4:12b-it-qat`（重み 6,653 MiB + projector 167 MiB）
- `bash remote/00_all.sh --gpu cpu --profile gemma4-12b-qat`
- **VM は検証後に停止済み（`remote/09_stop.sh`、サーバ側の一覧が空であることを確認）**

## 1. ★ 最大の未知数の答え: tool_calls は正しく返る

3 経路すべてで正しい `tool_calls` が返り、`content` への漏出はゼロだった。

| 経路 | `tool_calls` | `content` |
|---|---|---|
| `/api/chat`（`think` 既定） | `[write_file]` | 空 |
| `/api/chat`（`think:false`）← ollama#15539 の発火条件 | `[write_file]` | 空 |
| `/v1/responses`（Codex CLI の経路） | `[write_file]` | 空 |

引数も正しい: `{"content":"hi","path":"hello.txt"}`。
キーが辞書順なのは chat_template の `| dictsort` どおりで、
ネイティブパーサがテンプレートと同じ規則で組み立てていることの傍証になる。

**ollama#15539 も #15798 もこの版では再現しなかった。** 理由は Modelfile にあった:

```
TEMPLATE {{ .Prompt }}
RENDERER gemma4
PARSER gemma4
```

Ollama 0.30.5+ は gemma4 を Jinja ではなく**ネイティブ実装**で扱う。
テンプレートが 13 文字の素通しに見えるのはそのためで、異常ではない。

### 一度リポジトリのバグと誤認した

`cline-coder` のテンプレートが 13 文字しかないのを見て、
`20_ollama.sh` の Modelfile がテンプレートを潰していると疑った。
ベースモデル `gemma4:12b-it-qat` 自体を `/api/show` で確認したら同じだったので、
**誤りと分かった**。派生モデルは RENDERER / PARSER を正しく継承している。
疑ったこと自体は無駄ではなく、ネイティブパーサの存在に辿り着く道筋になった。

### 結果としてプロファイルを変更した

`CODEX_TOOL_REPAIR` を **1 → 0** にした。壊れていないモデルに修復プロキシを
噛ませても益は無く、ストリーミング表示を 1 チャンクに潰す副作用だけが残る
（qwen3 系・gpt-oss と同じ判断）。修復コードは残してある。

**前回のセッションで書いた Gemma 4 用の修復（テンプレート実物に合わせたパーサ）は、
現時点では一度も発火しない。** harmony 修復と同じ立場になった。

## 2. KV の実測

`/api/ps` の `size` から重み 6,820 MiB を引いた値（CPU なので f16）:

| num_ctx | 合計 | KV+バッファ |
|---:|---:|---:|
| 2,048 | 8,106 MiB | 1,286 MiB |
| 8,192 | 8,817 MiB | 1,997 MiB |
| 32,768 | 10,450 MiB | 3,630 MiB |

傾きは 0.066〜0.116 MiB/token。頭打ち無しの理論値（f16 で 0.328）より大幅に低く、
安全側に置いた `KV_MIB_PER_TOKEN=0.164` は**実際より多めに見積もる方向**なので妥当。
**`num_ctx=32768` が RAM 12GB の機械で実際に載った**ことも確認できた。

## 3. CPU の速度と、ベンチが完走しない問題（修正済み）

| 項目 | 実測 |
|---|---:|
| prefill | 4.0 tok/s |
| generation | **1.04 tok/s** |

**`20_ollama.sh` のベンチが `curl --max-time 900` を超えて落ち、
`00_setup_all.sh` ごと失敗した。** 約 4,000 トークンの prefill と 256 トークン
生成は、この速度では 15 分に収まらない。

修正: ベンチの上限を `ACCEL` 依存（CPU は 3600s）にし、
**超えてもセットアップ全体は失敗させない**。モデルもエージェントも揃っているのに
全部やり直しになるのは損失が大きい。ベンチは速度を知るための計測であって、
環境構築の必須段ではない。

また `num_predict=16` で試すと**応答本文が空**になった。16 トークンすべてが
思考トークンに消える。thinking モデルを CPU で測るときは、生成長を
小さくしすぎるとツール呼び出しに到達しない（プローブは 512 にしてある）。

## 測っていないこと

- **T4 での速度・安全プロンプト長・実タスクの完走率**（次の L3）
- **Codex CLI を通した実タスク**。CPU では prefill だけで十数分かかるため
  意図的に飛ばした。T4 の `--eval 5` で測る
- `num_ctx` の実上限。32768 までは確認したが、65536 以上は未確認
- 修復プロキシの Gemma 4 用パーサは**一度も発火していない**。
  上流の版が変われば必要になるかもしれないが、現時点では未検証のまま

---

# 追記 (2026-09-18 その 4): L3 T4 実機 — gemma4 + Codex は 5/5 完走した

計画: [`PLAN.md`](PLAN.md) の L3 / 手順: 手順書 §5.10

## 環境

- `bash remote/00_all.sh --gpu T4 --retry 3 --profile gemma4-12b-qat --eval 5 --stop`
- **T4 は再試行 1 回目で確保できた**。Tesla T4 15,360 MiB（空き 14,913）, driver 580.82.07
- `gemma4:12b-it-qat` / `num_ctx=32768` / `CODEX_TOOL_REPAIR=0`
- 全体 815s（うちセットアップ 442s）。**VM は自動停止済み（課金停止を確認）**

## 1. 実タスク 5/5 完走

プロンプト・判定基準は §6.3 / §7.1 と同一（`pythonでfizzbuzzを書いてテストして。` × 5）。

| 試行 | 結果 | 所要 | 生成物 | テスト実行の痕跡 |
|---|---|---:|---|---|
| 1 | OK | 91s | fizzbuzz.py(277B) + test_fizzbuzz.py(574B) | `Ran 1 test ... OK` |
| 2 | OK | 37s | fizzbuzz.py(297B) | テストファイル無し |
| 3 | OK | 51s | fizzbuzz.py(277B) + test_fizzbuzz.py(362B) | `All tests passed!` |
| 4 | OK | 92s | fizzbuzz.py(279B) + test_fizzbuzz.py(585B) | `Ran 1 test ... OK` |
| 5 | OK | 47s | fizzbuzz.py(277B) + test_fizzbuzz.py(392B) | `Ran 1 test ... OK` |

**正確な内訳: 5/5 が fizzbuzz.py を完成、4/5 がテストも生成、3/5 に実行痕跡。**
モデルの自己申告ではなくログで確認した（§7.1 と同じ流儀）。

**修復プロキシは使っていない**（`CODEX_TOOL_REPAIR=0`）。L2 で tool calling が
正常と確認できたため。それでこの完走率なので、gemma4 に修復は要らない。

## 2. 速度と VRAM

| 項目 | 実測 |
|---|---:|
| prefill | **618 tok/s** |
| generation | **13.9 tok/s** |
| 層のオフロード | **49/49 layers to GPU**（100% GPU） |
| VRAM 使用 | **7,681 MiB** / 空き 7,232 MiB |

比較（同一 T4、§7.3 の gpt-oss:20b）: prefill 854 tok/s / generation 32.2 tok/s。
**gemma4 は gpt-oss より遅い**（生成で 2.3 倍の差）。ただし完走率は 5/5 対 5/5 で並ぶ。

### ★ 事前チェックは大幅に安全側だった

`vram_precheck.py` の見積もりは **12,834 MiB**、実際は **7,681 MiB**。
5GB 以上の過大評価で、これは `KV_MIB_PER_TOKEN=0.164`（SWA 頭打ち無しの安全側）を
使っているため。L2 の CPU 実測と同じ傾向が GPU でも出た。

重み 6,820 MiB を引くと **KV+バッファは約 861 MiB**（ctx=32768 / q8_0）。
空きが 7,232 MiB 残っているので、**num_ctx はまだかなり上げられる**。
安全側の見積もりを維持するなら現状の 32768 が妥当で、
上げたい場合は `FORCE_VRAM=1` か `KV_MIB_PER_TOKEN` の実測値への置き換えが要る。

## 3. ★ ベンチの判定基準が古く、実測と矛盾していた（修正済み）

同じ実行の中で、ベンチは **「判定: NG / この構成では実用になりません」** と出した。
一方で実タスクは **5/5 完走**している。矛盾している。

原因は `CLINE_REQUEST_BUDGET_SEC` の既定値が **30** のままだったこと。

```
出力 500 トークンを前提にすると:
  生成に      35.9s        ← 13.9 tok/s なので 30 秒を超える
  prefill に   0.0s
★ 安全に投げられるプロンプト長 : 約 0 トークン  -> NG
```

しかし §7 の訂正のとおり、Cline CLI 3.0.62 の実際の上限は **300 秒**である
（実測済み）。30 という数字はもう根拠が無い。

**`CLINE_REQUEST_BUDGET_SEC` を 300 に変更した。** 同じ実測値で計算し直すと:

```
生成 500 tok: 36.0s / prefill に使える 264.0s
★ 安全プロンプト長: 約 163,000 tok  -> 判定 OK（num_ctx=32,768 を使い切っても収まる）
```

これなら実測の 5/5 完走と整合する。あわせて NG 時の文言から、
否定済みの「30 秒制限」「openai-compatible で回避」への言及を削り、
「この判定は机上の値なので `--eval` で実測せよ」と添えた。

## まとめ: gemma4:12b-it-qat は Codex CLI の土台として使える

- tool calling は正常（L2）。修復プロキシ不要
- T4 に 100% 載る。VRAM 7,681 MiB で 7GB 以上の余裕
- 実タスク 5/5 完走
- 生成は gpt-oss より遅い（13.9 対 32.2 tok/s）が、実用上は問題にならなかった

## 測っていないこと

- **`num_ctx` の実上限。** 32768 までしか試していない。VRAM には 7GB 以上の
  余裕があるので、65536 や 131072 も載る可能性が高いが未確認
- **Cline CLI からの実タスク。** 今回測ったのは Codex CLI 経由のみ。
  30 秒の壁が無いことは実証済みなので動くはずだが、実タスクでは未確認
- n=5 では 5/5 と 4/5 の差は判定できない（§7.2 と同じ限界）
- 修復プロキシの Gemma 4 用パーサは**依然として一度も発火していない**

---

# 追記 (2026-09-18 その 5): Cline での実タスク — 5/5 完走、ただし致命的な設定バグを 1 件発見

手順: 手順書 §6.1 の訂正 / §5.10

## 環境

- T4（再試行 1 回目で確保）/ `gemma4:12b-it-qat` / `num_ctx=32768`
- Cline CLI **3.0.62**、`CLINE_PROVIDER=ollama`
- プロンプト・回数・判定基準は Codex の `--eval` と**完全に同一**
  （`pythonでfizzbuzzを書いてテストして。` × 5、`fizzbuzz.py` が 50B 以上かつ exit 0）
- **VM は検証後に停止済み（サーバ側の一覧が空であることを確認）**

## 1. ★ `50_run.sh` はローカルの Ollama を使えていなかった

最初の 5 回は **5/5 が 3〜7 秒で失敗**した。

```
error: Unauthorized: Please make sure you're using the latest version of
       Cline and re-authenticate your Cline account.
```

`providers.json` は正しかった:

```json
{"version":1,"lastUsedProvider":"ollama","modes":{},
 "providers":{"ollama":{"settings":{"provider":"ollama","apiKey":"ollama","model":"cline-coder"}}}}
```

原因は `cline --help` にあった:

```
-P, --provider <id>    Provider id (default: cline)
```

**セッションの既定プロバイダは `cline`（クラウド）で、`lastUsedProvider` は
参照されない。** `cline auth -p ollama ...` は設定を書くだけで、実行時に `-P` を
渡さなければローカルには繋がらない。

`-P ollama -m cline-coder` を足して同じ条件で投げたら、**64 秒で完走**した。

### なぜ厄介か

手順書 §6.1 は「既定はクラウド — ここを必ず確認する」と警告しており、
方向は正しかった。しかし対策として書いていた「`providers.json` を目視確認する」
では**この問題は防げない**。設定ファイルは正しいまま、実行時にクラウドへ行く。

しかも症状が「認証エラー」なので、プロバイダ選択の問題だと気づきにくい。
モデルもポートも正常で、3〜7 秒で即座に終わる。

`scripts/50_run.sh` を直し、`-P` / `-m` を必ず渡すようにした。
手順書 §6.1 に訂正を入れ、手で叩く場合も `-P` が要ることを明記した。

## 2. 修正後: 5/5 完走、テスト実行も 5/5

| 試行 | 結果 | 所要 | 生成物 | テスト実行 |
|---|---|---:|---|---|
| 1 | OK | 61s | fizzbuzz.py(277B) + test_fizzbuzz.py(528B) | `Ran 1 test ... OK` |
| 2 | OK | 62s | fizzbuzz.py(277B) + test_fizzbuzz.py(528B) | `Ran 1 test ... OK` |
| 3 | OK | 58s | fizzbuzz.py(413B) + test_fizzbuzz.py(615B) | `Ran 2 tests ... OK` |
| 4 | OK | 67s | fizzbuzz.py(287B) + test_fizzbuzz.py(795B) | `Ran 4 tests ... OK` |
| 5 | OK | 237s | fizzbuzz.py(401B) + test_fizzbuzz.py(839B) | `Ran 4 tests ... OK` |

**5/5 完走、5/5 でテストも実際に実行された**（ログで確認、自己申告ではない）。

### Codex との比較（同一 T4・同一プロンプト・同一判定）

| | Codex CLI | Cline CLI |
|---|---|---|
| 完走 | 5/5 | 5/5 |
| テスト生成 | 4/5 | **5/5** |
| テスト実行の痕跡 | 3/5 | **5/5** |
| 所要 | 37〜92s | 58〜237s |

**Cline のほうが成果物の質は高い**（テストを必ず書いて実行する）。
所要は Cline のほうが長く、試行 5 は 237 秒かかった。

## 3. ★ 30 秒タイムアウトが存在しないことの実地証明

試行 5 の **237 秒**が、§7 の訂正を実タスクで裏づけている。
30 秒制限が生きていれば、この試行は途中で切られていたはずである。
5 回中 5 回が 58 秒以上かかっており、**すべて旧来の 30 秒予算を超えている**。

## 4. ベンチ判定が実測と一致するようになった

`CLINE_REQUEST_BUDGET_SEC` を 300 に直した効果が出た。今回のセットアップでは:

```
prompt eval : 13181 tok / 19.8s = 666 tok/s
generation  : 256 tok / 15.9s = 16.1 tok/s
★ 安全に投げられるプロンプト長 : 約 179,092 トークン
判定: OK
```

前回（30 のまま）は同じ構成で「安全プロンプト長 約 0 トークン / 判定 NG」だった。
実タスクが 5/5 完走する構成に対して OK が出るようになり、矛盾が解消した。

## 5. providers.json のパス修正に漏れがあった（修正済み）

`90_healthcheck.sh` だけ旧パス（`data/settings/`）決め打ちのままで、
`/root/.cline/data/settings/providers.json が無い` と誤報していた。
`cline_providers_json()` を使うように直した。

## 測っていないこと

- **`num_ctx` の実上限。** 32768 までしか試していない（VRAM に 7GB 以上の余裕あり）
- `CLINE_PROVIDER=openai-compatible` 経路での実タスク。`-P openai-compatible` で
  動くはずだが未確認
- n=5 では Codex と Cline の差（3/5 対 5/5 のテスト実行率）は統計的に判定できない
- 修復プロキシの Gemma 4 用パーサは**依然として一度も発火していない**
