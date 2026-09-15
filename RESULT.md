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

## 結論

- `CODEX_TOOL_REPAIR=1`（既定）で `qwen2.5-coder:14b-instruct-q4_K_M` を
  Codex CLI から実際に使える状態にできた（プロキシ無効時は再現通り動かない
  ことも実機で確認済み）。
- Codex CLI 0.154.0 では `wire_api="chat"` が使えないという、当初の計画には
  無かった実装上の制約が見つかり、プロキシを Responses API 対応に作り直した。
- 修復プロキシはツール呼び出しの **形式** の問題を解決するものであり、
  14B モデル自身の tool-calling **信頼性**（ツール名・引数の正確性）は
  別問題として残ることを実機で確認・記録した。
