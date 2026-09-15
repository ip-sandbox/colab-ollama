# 作業計画: Codex CLI × Ollama qwen2.5-coder:14b ツール呼び出し修正

## 背景・目的

`qwen2.5-coder:14b-instruct-q4_K_M` を Ollama 上で構築し、Codex CLI から使えるようにする。

Codex CLI + Ollama の組み合わせでは、モデルがツール呼び出し用の JSON を組み立てても、
Ollama がそれを OpenAI 互換の `tool_calls` 構造として返さず、プレーンテキストの
`content` に生の JSON を吐いてしまう不一致が知られている。

参考:
- https://blog.mocobeta.dev/posts/20260406-qwen3-coder-codex/
- https://note.com/zephel01/n/nd7ea543ab654
- https://github.com/openai/codex/issues/2229

この不一致は本リポジトリ自身がすでに実機検証済みの現象と同根である
(`docs/手順書.md` §5.6: `qwen2.5-coder:7b-instruct-q4_K_M` は Ollama のテンプレートが
要求する `<tool_call>{...}</tool_call>` ラッパーを付けずに生 JSON を返す →
Ollama サーバのパーサーが `message.tool_calls` を埋められず `message.content` に
丸ごと落ちる → エージェント側はテキストとして解釈しツールを実行しない)。
GitHub issue #2229 のコメント（BigMitchGit 氏）も同じ原因説明をしている。

14b 量子化版でも同様に壊れる可能性が高い（issue #2229 はまさに 14b での報告）。
今回は単に「使えないモデル」として退けるのではなく、参考記事が示す
**修復プロキシ方式**を実装し、qwen2.5-coder:14b を実際に Codex CLI から
使える状態にする。

## 方針

### 1. 原因の実機再現
プロキシ無しで直結し、
- curl で `/v1/chat/completions` に `tools` 付きリクエストを直接送り、
  `message.content` に生 JSON が落ちることを確認
- `codex exec` 経由の実タスクでファイルが作られないことを確認

### 2. 修復プロキシ (`scripts/32_codex_tool_proxy.py`)
Python 標準ライブラリのみで実装する、Codex CLI と Ollama の間に立つ透過プロキシ。

- `127.0.0.1:$CODEX_PROXY_PORT`（既定 11435）で待受
- `POST /v1/chat/completions`:
  - リクエストの `tools[].function.name` から有効なツール名集合を作る
  - 上流 Ollama へは常に `stream:false` で転送
  - レスポンスの `message.content` が `<tool_call>` タグ / ```` ```json ```` フェンス /
    素の JSON のいずれかで `{"name": <有効なツール名>, "arguments": {...}}` 形状を
    含む場合、正しい `message.tool_calls` に組み替える（誤爆防止のため、ツール名が
    有効集合に無ければ無変更で通す）
  - クライアントが `stream:true` を要求していた場合は、修復後の内容を
    OpenAI 互換 SSE 1チャンク + `[DONE]` として返す
- 判定結果（repaired / passthrough）をログに残す

### 3. 配線変更
- `scripts/common.sh` に `CODEX_PROXY_PORT` / `CODEX_PROXY_BASE_URL` /
  `CODEX_TOOL_REPAIR`（既定 1=有効、0で旧来の直結に戻せる）を追加
- `scripts/31_alt_agents.sh` の Codex ブロックでプロキシを起動し、
  `config.toml` の `base_url` をプロキシに向け、`wire_api="chat"` に固定
- `scripts/99_teardown.sh` / `scripts/90_healthcheck.sh` にプロキシの停止・監視を追加

### 4. ドキュメント
- `docs/手順書.md` に新節を追加（14b + Codex の再現結果、原因、解決方法、実測結果）
- `README.md` に一行追記

### 5. 実機構築・検証（この Colab T4 サンドボックス上）

```
BASE_MODEL=qwen2.5-coder:14b-instruct-q4_K_M NUM_CTX=16384 \
  bash scripts/00_setup_all.sh --with-codex
```

1. `CODEX_TOOL_REPAIR=0` で直結し、壊れることを再現
2. `CODEX_TOOL_REPAIR=1` でプロキシ経由にし、修復されて実タスクが完走することを確認
3. 結果を `RESULT.md` に記録

## 手順（ステップごとに commit + push）

1. ブランチ作成: `feature/qwen25-coder-14b-codex-tool-proxy`
2. 本 `PLAN.md` を commit + push
3. コード変更一式を実装し、commit + push（実機検証の前に永続化）
4. 実機構築・壊れ確認（プロキシ無効）
5. プロキシ有効化・修復確認
6. `RESULT.md` を書き、commit + push
7. GitHub 上で PR を作成
