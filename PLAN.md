# 作業計画: gemma4:12b-it-qat × Codex CLI と、CPU 事前検証レーンの新設

ブランチ: `feature/colab-cli-remote-control`

## Context — なぜやるか

このリポジトリは Colab T4 上の Ollama にコーディングエージェントをつなぐ手順書 + スクリプト群で、
現在の評価対象は `qwen3:8b` / `gpt-oss:20b` / `qwen2.5-coder:14b`（`docs/手順書.md` §5, §12.7）。
ここに **`gemma4:12b-it-qat`（Gemma 4 12B QAT, 2026-06-03 公開, 約 7.2GB）** を加えたい。

エージェント側は **Codex CLI** を使う。理由は Cline CLI が Ollama へのリクエストを 30 秒で切り、
CLI 側に設定項目が無いため（cline#9182 / #9484、手順書 §7）。Codex は
`stream_idle_timeout_ms` を持つので、この壁を最初から回避できる。
ただし利用者の判断は「タイムアウトしないなら Cline でもよい（パッチを当てるなど）」なので、
**Cline の 30 秒が本当に切れるのかを実測し、切れるならパッチする**ところまでを本計画に含める。

もう一つの動機は **Colab の T4 が取れないことが多い**こと。現状 `scripts/10_preflight.sh` は
`nvidia-smi` が無いと即 `die` し、`scripts/20_ollama.sh` も無条件に `nvidia-smi` を叩くため、
GPU が無い環境では 1 行も先へ進めない。そこで **CPU だけで先に潰せる検証を分離し、
T4 を確保できた時間を「CPU で潰せない項目」だけに使う**構成にする。

### この計画で得たい結論

1. `gemma4:12b-it-qat` は Ollama 経由で **本物の `message.tool_calls` を返すか**（最大の未知数）
2. 返さない場合、既存の修復プロキシ `scripts/32_codex_tool_proxy.py` で吸収できるか
3. Cline CLI の 30 秒は実在するか、パッチで外せるか
4. T4 上での実用速度（prefill / generation / 安全プロンプト長）

---

## 事前に確定させた事実

### Gemma 4 12B QAT

| 項目 | 値 | 出典 |
|---|---|---|
| Ollama タグ | `gemma4:12b-it-qat` | ollama library |
| サイズ | 約 7.2GB (QAT q4_0) | 同上 |
| capabilities | vision / **tools** / thinking / audio | 同上 |
| 構成 | 11.95B params, 48 層, 256K ctx, Dual Attention（局所 1024 + 大域交互、最終層は大域） | Google 公式 |
| ライセンス | Apache 2.0 | 同上 |

`docs/リモート化計画.md` §0.3 は **Gemma 3** を「Ollama のテンプレートに tool calling が入っていない」
として明示的に却下している。Gemma 4 はここが変わったので、**その記述を黙って覆さず、訂正として追記する**。

### ★ Gemma 4 × Ollama のツール呼び出しには既知の不具合が 2 系統ある

このリポジトリが §5.6 / §5.8 / §12.7 で踏んできたのと同じ「`tool_calls` に入らず `content` に漏れる」
クラスの不具合が、Gemma 4 でも報告されている。**修復プロキシを最初から有効にする根拠**になる。

**(1) ollama/ollama#15539** — ollama 0.20.6 / `gemma4:e4b`
`system prompt` + `think:false` + `tools` を同時に送ると、パーサが取りこぼして `content` に生 JSON が落ちる:

```json
{"message":{"role":"assistant","content":"{\n  \"tool_calls\": [\n    {\n      \"function\": \"GetLiveContext\",\n      \"args\": {}\n    }\n  ]\n}\n<channel|>"}}
```

- 形状が既存プロキシの想定（`{"name": ..., "arguments": {...}}`）と**違う**。
  ラッパー `{"tool_calls":[{"function":NAME,"args":{...}}]}` + 末尾に `<channel|>` が付く。
- 回避策は「`think:false` を送らない」。ただし 10 秒以上の遅延と思考トークン漏れを伴う。

**(2) ollama/ollama#15798** — ollama 0.21.1 / `gemma4-64k`
チャットテンプレートの特殊トークンが本文にそのまま漏れる:
`<|tool_call|>` / `<|"|>` / `<|channel|>` / `<|tool_response|>`、`call:` プレフィックス、
文字列引数が `"` ではなく `<|"|>...<|"|>` で囲まれる。`finish_reason` は `stop` になるため
クライアントは「普通に喋っただけ」と解釈してターンを終える。**Closed as not planned**（上流の修正見込み無し）。

いずれも `12b-it-qat` での報告ではない（`e4b` / `gemma4-64k` = コミュニティタグ）。
**本計画の最初の作業は「12b-it-qat で実際にどうなるか」を証拠付きで確定させること**であって、
いきなり修復コードを書くことではない。

### 検証環境のネットワーク制約（本セッションで実測）

Claude on the web のコンテナは 4 vCPU / RAM 15GB / ディスク空き 30GB / Node v22.22.2 / Python 3.11。
**RAM もディスクも足りている**が、egress ポリシーが重みの取得を塞いでいる:

| ホスト | 結果 |
|---|---|
| `registry.ollama.ai`, `ollama.com` | CONNECT に **403**（ポリシー拒否） |
| `huggingface.co`, `xethub.hf.co`, `modelscope.cn` | 到達不可 |
| `registry.npmjs.org`, `pypi.org` | 200 |
| `github.com` リリースアセット | 206（レンジ取得可） |

→ **利用者の判断: `ollama.com` / `registry.ollama.ai` を許可したネットワークポリシーで環境を作り直し、
出直す。** したがって本セッションの成果物は「ポリシーが緩んだ次のセッションでそのまま走る検証系一式」で、
重みを必要としない作業（修復プロキシの形状追加とその単体テスト、Cline タイムアウトの実測とパッチ、
CPU 対応、ドキュメント）は今すぐ実装・コミットする。

---

## 3 層の検証レーン

| レーン | 場所 | 何を確定できるか | コスト |
|---|---|---|---|
| **L1: モデル不要** | Claude on the web（今すぐ） | Codex→プロキシ→スタブの配線、`tool_calls` 修復ロジック、Cline 30 秒の実測とパッチ | 数分・無料 |
| **L2: CPU 実モデル** | Claude on the web（ポリシー緩和後） | gemma4 の Ollama テンプレートが本当に `tool_calls` を返すか、漏れるならその生の形 | 数十分〜数時間・GPU 枠を消費しない |
| **L3: T4 実機** | Colab T4（`remote/00_all.sh`） | 実用速度、安全プロンプト長、実タスク完走率 | GPU 枠・課金 |

L1 は既存の `scripts/test_harmony_e2e_stub.py`（モデル無しで Codex→プロキシ→スタブを通す仕掛け）の
拡張で成立する。L2 で得た**生の応答**が L1 のスタブとテストの入力になる、という往復を想定する。

---

## 作業項目

### 1. `gemma4-12b-qat` モデルプロファイル

**`scripts/common.sh`** — `MODEL_PROFILE` の `case` に追加:

```
gemma4-12b-qat)
  _p_base="gemma4:12b-it-qat"; _p_ctx=16384; _p_repair=1; _p_rules=minimal; _p_kv=<要実測>
  _p_note="Gemma 4 12B QAT。tool calling に既知の不具合あり（ollama#15539/#15798）→ 修復プロキシ既定 ON"
  ;;
```

- `_p_repair=1` の理由は上記 2 系統の既知不具合。既存の `gpt-oss-20b` が
  「本来の用途ではなく上流不具合の回避のため 1」と書いているのと同じ体裁でコメントを残す。
- `_p_kv`（KV MiB/token）は **今は確定できない**。Gemma 4 は局所 1024 の sliding window と大域を
  交互に使うため、既存プロファイルの「層数 × KV ヘッド × head_dim」式がそのままでは過大評価になる。
  HF の `config.json` は egress で読めないので、**L2 で `ollama show --modelfile` / GGUF メタデータから
  実値を取り、そこで確定する**。それまでは安全側の暫定値を置き、コメントに「未実測」と明記する。
- `case` の `*)` にあるエラーメッセージのプロファイル一覧にも追加する。
- `model_profile_banner()` は変更不要。

**`remote/00_all.sh`** — 手元側のプロファイル名検証 `case`（`--profile` の妥当性チェック）に
`gemma4-12b-qat` を追加。ここを忘れると VM 確保後に typo 扱いで落ち、10 分と課金を無駄にする
（このチェックが存在する理由そのもの）。`usage()` の説明文の一覧も同時に更新。

**`remote/03_setup.sh`** — VM へ渡す環境変数のホワイトリストは `MODEL_PROFILE` を既に含むので変更不要
（確認のみ）。

**検証**: `MODEL_PROFILE=gemma4-12b-qat bash -c '. scripts/common.sh; model_profile_banner'`
と `bash remote/00_all.sh --profile gemma4-12b-qat --help` が通ること。

### 2. CPU モード（`nvidia-smi` が無くても走る）

**`scripts/common.sh`** — アクセラレータ種別を 1 か所で決める:

```
export ACCEL="${ACCEL:-$(have nvidia-smi && echo gpu || echo cpu)}"
```

（`have()` の定義より後ろに置く。`set -e` 下でのコマンド置換の扱いに注意。）
CPU のときは `OLLAMA_FLASH_ATTENTION` / `OLLAMA_KV_CACHE_TYPE` が CUDA 前提の設定なので既定を変える
（それぞれ 0 / 未設定）。理由をコメントに書く。

**`scripts/10_preflight.sh`** — 冒頭の `die "nvidia-smi がありません"` を分岐に変える。
`ACCEL=cpu` なら GPU 節と Compute Capability 節を飛ばし、判定サマリでは VRAM の代わりに RAM を見る。
「§7 ネットワーク疎通」の `ollama.com` 到達チェックは CPU 検証でも重要なのでそのまま残す。

**`scripts/20_ollama.sh`** — `nvidia-smi` を叩く 2 か所（pull 前の空き VRAM 取得と、末尾の VRAM 実測）を
`ACCEL` で分岐。CPU では:
- 空きメモリを `free -m` の available から取る
- 事前チェックは VRAM ではなく RAM に対して行う
- 末尾の VRAM 実測節は RAM 実測に差し替える
- ベンチの 30 秒判定は CPU では意味を成さないので、**判定を消さずに「CPU 実行時の参考値」と明示**する
  （数字自体は L2 の進捗把握に使える）

**`scripts/vram_precheck.py`** — ロジックを複製せず、**表示ラベルだけ引数化**する。
第 7 引数（省略可）に `VRAM` / `RAM` を取り、`usage` と出力文字列・NG 時の対策文言を切り替える。
マニフェスト取得部（`fetch_weights_mib`）は無改造。

★ **出力 JSON のパスとキーは変えないこと。** e82d035 で `20_ollama.sh` の pull 前の警告が
`$STATEDIR/vram-precheck.json` の `weights_mib` を読んで「重みは約 N GB」と出すようになった。
ラベルだけの変更に留め、CPU モードでも同じパス・同じキーで書き出す。

**`scripts/90_healthcheck.sh`** — 既に `nvidia-smi` 不在を握りつぶす作りになっている
（`|| echo "nvidia-smi 不可"`）ので CPU 対応としての変更は不要。ただし項目 5 のパッチ状態表示を足す。

**検証**: このコンテナ（GPU 無し）で `bash scripts/10_preflight.sh` が `die` せず完走すること。
`python3 scripts/vram_precheck.py` を引数不足で叩いて usage が新形式になっていること。

### 3. ツール呼び出しの実挙動プローブ（L2 の中核・証拠を先に取る）

**新規 `scripts/34_toolcall_probe.sh`** — 修復コードを書く**前**に、生の応答を保存する。

取得するもの（すべて `$STATEDIR/probe/` に生 JSON で保存し、最後に要約表を出す）:
- `ollama show $BASE_MODEL`（capabilities に `tools` があるか）、`--template`、`--parameters`、`--modelfile`
  — テンプレートは `<|tool_call|>` 等の特殊トークンの有無を見るため。`--modelfile` は KV 見積りの根拠
- `/api/chat` に `tools` 付き
- `/v1/chat/completions` に `tools` 付きで、**組み合わせ行列**:
  `system prompt` 有/無 × `think` 未指定/`false` × `stream` false/true
  — ollama#15539 の発火条件がまさにこの組み合わせなので、1 点だけ見て結論を出さない
- `/v1/responses` に `tools` 付き（Codex CLI 0.15x はこちらしか喋らない）

判定は「`message.tool_calls`（または `output[].type=="function_call"`）が埋まったか」の 2 値で、
埋まらなかったケースは `content` を**そのまま**保存する。この生文字列が項目 4 のテストデータになる。

### 4. 修復プロキシに Gemma 4 の形状を追加

**`scripts/32_codex_tool_proxy.py`** — 項目 3 の結果を見てから、必要な分だけ追加する。
既存構造（`_HARMONY_CALL_RE` と `_find_harmony_tool_calls()` の対）に倣い:

- `_GEMMA_TOKEN_CALL_RE` — `<|tool_call|>` … `<|channel|>` / `<|tool_response|>` 漏れ（#15798）を拾う。
  `<|"|>...<|"|>` で囲まれた文字列引数を正しい JSON 文字列へ正規化する補助関数が要る。
  `call:` プレフィックスの除去も同じ関数の担当にする。
- ラッパー形状 `{"tool_calls":[{"function":NAME,"args":{...}}]}`（#15539）を
  `{"name":..., "arguments":...}` に読み替える。**コードを読んで確認済みの要点**:
  - 末尾の `<channel|>` は問題にならない。`_extract_json_objects()` は `json.JSONDecoder.raw_decode`
    を使うので、正しい JSON オブジェクトの終端で止まり、後続のゴミを無視する（前処理は不要）
  - 一方 `_find_tool_calls_in_text()`（`scripts/32_codex_tool_proxy.py:170-200`）は
    トップレベルに `name` と `arguments` があるオブジェクトしか拾わない。このラッパーは
    どちらも持たないので**現状は素通りする**。ここが埋めるべき穴
  - `_extract_json_objects()` は成功時に `i = end` まで進むため、外側を読んだ時点で
    内側の `{"function":...}` は消費される。よって「外側を認識して展開する」処理が要る
- **誤爆防止は既存方針を踏襲**: 抽出したツール名がリクエストの有効なツール名集合に無ければ無変更で通す。

**新規 `scripts/test_tool_proxy_gemma4.py`** — 既存 2 本と同じ体裁（stdlib のみ / VM 不要 / ネットワーク不要 /
モジュール名が数字始まりなので `importlib.util.spec_from_file_location` で読む）。
入力文字列は**項目 3 で実機から採取した生文字列**を使う。採取前は issue 記載の形から起こし、
採取後に実測値へ差し替える（`test_tool_proxy_harmony.py` が実機採取文字列を使っているのと同じ流儀）。

**検証**: `python3 scripts/test_tool_proxy_gemma4.py` および既存 2 本が緑のまま。

### 5. Cline CLI の 30 秒タイムアウト — 実測してからパッチする

**まず実測（モデル不要）。** `scripts/test_harmony_e2e_stub.py` に `STUB_DELAY_SEC` を追加し、
応答前に指定秒だけ待たせる（既定 0 で現行動作を維持）。これで
「45 秒かかる上流に対して Cline がいつ切るか」をモデル無しで測れる。
CPU 環境はむしろこの検証に向いている（遅いことが保証されている）。

**新規 `scripts/35_cline_timeout_probe.sh`** — スタブを上げ、`CLINE_PROVIDER` を
`ollama` と `openai-compatible` の両方に切り替えて `cline -p "..."` を投げ、
打ち切りまでの実秒数と終了コードを表にする。手順書 §7 の「V-4: /v1 経由なら 30 秒制限を回避できる可能性」は
未検証のまま残っている項目で、ここで白黒つける。

**新規 `scripts/33_patch_cline_timeout.sh`** — 実測で「切れる」と確定した場合のみ意味を持つ。
- `npm root -g` から `cline` のインストール先を特定する
- タイムアウト定数を grep で探す（`30000` / `30_000` / `timeout` 近傍）。
  **候補が 0 個、または 2 個以上見つかったら黙って進めず `die` する** — CLI の版が変わって
  定数の形が変わったことを見逃すと、パッチしたつもりで効いていない状態になる
- `.bak` を取ってから置換。既にパッチ済みなら何もしない（冪等）
- 適用後に `35_cline_timeout_probe.sh` を再実行して、実際に延びたことを確認する
- **`npm install -g cline` を再実行するとパッチは消える**ことを、スクリプトの出力と手順書の両方に明記する

**検証**: パッチ前後で `35_cline_timeout_probe.sh` の実測秒数が変わること。
パッチ済みの状態で再実行しても二重適用されないこと。

### 6. CPU 検証の入口スクリプト

**新規 `scripts/60_cpu_verify.sh`** — L1/L2 を 1 本で通す（番号は `50_run.sh` と `90_healthcheck.sh` の間）。

順に: `10_preflight.sh`（CPU モード）→ `20_ollama.sh`（CPU / gemma4 pull + create）→
`34_toolcall_probe.sh` → Codex CLI 導入と小さな実タスク 1 本 → `35_cline_timeout_probe.sh` →
結果を `$STATEDIR/cpu-verify-report.md` に書き出す。

要件:
- **再実行可能**（各段は既存スクリプト同様に冪等）
- **レジストリが塞がれている場合は、pull で長時間ハングせず即座に理由を出して止まる**
  （`10_preflight.sh` の疎通チェックの結果を使い、「この環境のネットワークポリシーが
  `registry.ollama.ai` を許可していない」と名指しで言う）
- CPU なので Codex に投げるタスクは**最小**にする（生成 1 ファイル・短いプロンプト）。
  ここで測りたいのは速度ではなく「ツール呼び出しが成立するか」

### 7. ドキュメント

- **`docs/手順書.md`**
  - `§5.10` 新設: `gemma4:12b-it-qat` + Codex CLI。既知不具合 2 系統（#15539 / #15798）、
    プローブ結果、修復の有無、実測値。§5.8 と同じ構成（症状 → 原因 → 解決策 → 実機結果）で書く
  - `§13` 新設: GPU が取れないときの CPU 事前検証レーン（L1/L2/L3 の表と、何をどこで潰すか）
  - `§7` / `§7.1` に Cline 30 秒の**実測結果**を追記し、V-4 の未検証マークを外す
- **`docs/リモート化計画.md`** — §0.3 の Gemma 却下記述に**訂正を追記**する。
  「Gemma 3 は tools 非対応だったが、Gemma 4 では capabilities に tools が入った。
  ただし別種の不具合（#15539/#15798）があるため修復プロキシ前提で採用する」。元の記述は消さない
- **`README.md`** — モデルプロファイル表に `gemma4-12b-qat` の行、ファイル一覧に新規スクリプト、
  「GPU が取れないとき」の 1 節
- **`RESULT.md`** — 既存の追記スタイルをそのまま踏襲する:
  `---` 区切り → `# 追記 (2026-09-xx): gemma4:12b-it-qat と CPU 事前検証レーン` →
  `## 環境`（手元 / VM / 版数）→ 番号付きの発見 → 末尾に **`**測っていないこと**:`** を必ず置く
  （既存の追記 2 本がどちらもこの形で、「何が未確認か」を明示する習慣になっている）

### 8. コミット順

コードを先に永続化してから遅い検証に入る（`PLAN.md` の既存の流儀）。各段で
`git push -u origin feature/colab-cli-remote-control`。

1. `PLAN.md` を本計画で差し替え
2. CPU モード対応（`common.sh` の `ACCEL` / `10_preflight.sh` / `20_ollama.sh` / `vram_precheck.py`）
3. `gemma4-12b-qat` プロファイル（`common.sh` + `remote/00_all.sh`）
4. プローブ `34_toolcall_probe.sh` と入口 `60_cpu_verify.sh`
5. スタブの `STUB_DELAY_SEC` 拡張 + `35_cline_timeout_probe.sh`（← ここまではモデル不要で今すぐ検証可能）
6. Cline 実測結果を反映した `33_patch_cline_timeout.sh`
7. 【要: ネットワークポリシー緩和】L2 実行 → 生応答を採取 → 修復プロキシの gemma4 形状 + `test_tool_proxy_gemma4.py`
8. `KV_MIB_PER_TOKEN` の実測値確定
9. ドキュメント一式 + `RESULT.md`
10. 【要: T4】L3 実行 → 実測値を手順書と `RESULT.md` に反映

---

## 検証方法

**今すぐ（モデル不要・このコンテナ）**
```bash
python3 scripts/test_tool_proxy_harmony.py
python3 scripts/test_tool_proxy_retry.py
python3 scripts/test_tool_proxy_gemma4.py       # 新規
bash scripts/10_preflight.sh                     # CPU で die しないこと
MODEL_PROFILE=gemma4-12b-qat bash -c '. scripts/common.sh; model_profile_banner'
bash remote/00_all.sh --profile gemma4-12b-qat --help
bash scripts/35_cline_timeout_probe.sh           # スタブ相手に 30 秒問題を実測
```

**ネットワークポリシー緩和後（このコンテナ・CPU 実モデル）**
```bash
MODEL_PROFILE=gemma4-12b-qat bash scripts/60_cpu_verify.sh
cat /content/.cline-env/cpu-verify-report.md
```

**T4 確保後（手元から）**
```bash
bash remote/00_all.sh --gpu T4 --retry 3 --profile gemma4-12b-qat --eval 5 --stop
```

---

## リスクと未確定事項

| リスク | 影響 | 対処 |
|---|---|---|
| `12b-it-qat` でも `tool_calls` が壊れ、漏れ方が #15539/#15798 のどちらとも違う | Codex が一切ツールを実行しない | 項目 3 のプローブで**先に生応答を取る**。修復コードはその後 |
| 漏れ方が非決定的で、修復しきれない | 完走率が安定しない | `--eval N` の複数回実行で発火率を測り、数字ごと記録する（§12.7 の gpt-oss と同じ扱い） |
| thinking がレイテンシを食う（#15539 の回避策が「think:false を送らない」） | T4 でも 30 秒予算を超える | ベンチの `<think>` 検出は既に実装済み。プローブ行列で think の有無と tool_calls 成否のトレードオフを表にする |
| `KV_MIB_PER_TOKEN` が暫定値のため VRAM 事前チェックが誤判定 | 載るのに NG、または載らないのに OK | 暫定は安全側に倒し、`FORCE_VRAM=1` の逃げ道は既存。L2 で実測値に置換 |
| CPU での 12B は生成 1〜3 tok/s 程度 | L2 の実タスクが数十分かかる | L2 のタスクは最小に固定。速度の評価は L3 の仕事と割り切る |
| Cline の定数の形が版で変わる | パッチが空振り | 候補が 1 個でなければ `die`。パッチ後は必ず再実測して確認 |
| `npm i -g cline` でパッチが消える | 気付かないまま 30 秒に戻る | スクリプト出力と手順書に明記。`90_healthcheck.sh` にパッチ適用状態の表示を足すか検討 |
| ネットワークポリシーが緩和されない | L2 が丸ごと実行できない | L1（項目 1,2,4,5,6 のコード）は今すぐ完了できる。L2 は Colab CPU ランタイムでも代替可能（`remote/00_all.sh --gpu cpu`） |
