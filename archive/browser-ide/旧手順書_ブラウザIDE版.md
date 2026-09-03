> ## ⚠️ この文書は置き換えられました（2026-09-03）
>
> 要件が「web ブラウザのコンソール」= **Colab ノートブック UI 付属のターミナルウィンドウ**
> だと判明したため、ここで検討している 4 経路（code-server / 外部トンネル / 公式 VS Code 拡張）は
> **すべて不要になりました。**
>
> 理由は 1 つで、**Cline には CLI 版があり、VS Code の UI をブラウザに届ける必要がそもそも無い**
> ということです。これにより外部トンネル・公開 URL・WebSocket の問題がまとめて消え、
> 規約リスクも「高〜最高」から「低〜中」に下がりました。
>
> **現行版: `claude/colab-t4-cline-terminal.md`**
>
> 本文書を残しているのは、以下が今も有効だからです。
>
> - §2 経路D の分析 — Google 公式 Colab VS Code 拡張がなぜ Ollama に届かないか（ポートフォワードが無い）
> - §3 規約リスクの比較 — Colab で外部公開を検討する場面が再び来たときの下敷き
> - §5 モデル選定と VRAM 計算 — 現行版でも基本的に有効（ただし推奨モデルは 14B → 7B に変更。理由は現行版 §5.1）

---

# Colab T4 上にローカル LLM を立て、ブラウザの Cline から AI コーディングする

- 版: v1.0
- 作成日: 2026-09-03
- 前提: Google Colab **無料枠** / T4 GPU
- 関連: 既存設計書 `claude/colab-t4-local-llm-design.md`（本書はその §1.3「非目標」に挙げていた構成を、改めて正面から検討したもの）

---

## 0. 先に結論

| 論点 | 結論 |
|---|---|
| 技術的に作れるか | **作れる。** ただし成立するのは 4 経路のうち 2 つ（経路 B は確実、経路 A は要検証） |
| 無料枠の規約に照らして安全か | **安全とは言えない。** 4 経路すべてが無料枠の禁止条項と何らかの緊張関係にある。「これなら大丈夫」と言える経路は存在しない |
| 一番リスクが低い実現可能な形 | **経路 A**（Colab 内蔵ポートプロキシ + code-server）。外部トンネルを 1 本も張らない唯一の経路 |
| 一番動く形 | **経路 B**（VS Code Remote Tunnel → vscode.dev）。Cline が VM 側で動くので設計が素直 |
| Google 公式の Colab VS Code 拡張（経路 D）で解決するか | **しない。** ポートフォワードが無く、手元の Cline から VM の Ollama に届かない |
| モデル | `qwen2.5-coder:14b-instruct-q4_K_M` + `num_ctx=32768` + KV キャッシュ q8_0 |
| 最大の技術的落とし穴 | **`num_ctx` の設定漏れ。** 既定値のままだと Cline は静かに壊れる（§7） |
| 最大の運用上の落とし穴 | 12 時間でセッションごと消える。毎回 9GB のモデル再 DL |

**判断の材料として最も重要な一文:** Colab のよくある質問には、無料枠でのみ追加で禁止される事項として「**SSH シェル、リモートデスクトップなどのリモートコントロール**」「**ノートブック UI をバイパスした、主にウェブ UI を介したやり取り**」が明記されています。ブラウザ IDE を Colab 上で動かす行為は、どう構成してもこの 2 つの記述の射程に入り得ます。以下はそれを承知の上で、リスクの大小を比較するための資料です。

---

## 1. やりたいことの整理

```
ブラウザ（手元）                    Colab VM (T4 16GB)
┌──────────────┐              ┌──────────────────────────────┐
│              │              │                              │
│  VS Code UI  │◄─── ??? ────►│  拡張ホスト                    │
│              │              │   └ Cline 拡張                │
└──────────────┘              │        │ http://127.0.0.1:11434│
                              │        ▼                      │
                              │   Ollama (14B Q4_K_M)         │
                              │        │                      │
                              │   /content/workspace ◄────────┤
                              │   （Cline が読み書きするコード） │
                              └──────────────────────────────┘
```

**要件は 3 つです。**

1. Cline の拡張ホストが **Colab VM 側** で動くこと
   → そうでないと Cline から見た `localhost:11434` が手元の PC になり、Ollama に届かない
2. Cline のターミナル実行が **Colab VM 上** で走ること
   → そうでないと T4 の意味がない
3. その UI が **ブラウザから触れる** こと

`???` の部分をどう埋めるかが唯一の設計上の論点であり、そこが規約リスクの発生源です。

---

## 2. 4 つの経路

### 経路A: Colab 内蔵ポートプロキシ + code-server

Colab のノートブックカーネルが持つ `google.colab.kernel.proxyPort(port)` を使い、
VM 内の code-server を Google 自身のプロキシ経由でブラウザに出します。

```
ブラウザ ──https──> *.colab.googleusercontent.com ──> Colab VM :8080 (code-server)
                     ^ Google 自身のプロキシ                 └ Cline 拡張 ──> :11434 Ollama
```

- **外部トンネルを 1 本も張らない。** ngrok も cloudflared も Microsoft dev tunnels も使わない
- 要件 1〜3 をすべて満たす
- **未検証の急所: WebSocket。** code-server は WebSocket 常時接続が前提で、
  Colab のポートプロキシがこれを通すかは公式に明言されていません。
  通らなければ「パスワードは通るのに `Setting up your workspace...` から進まない」形で失敗します
- `scripts/11_ws_probe.py` を用意しました。標準ライブラリだけの WebSocket エコーサーバを立てて
  プロキシ越しに繋げるので、**2 分でこの経路の成否が分かります**。必ず先に実行してください

### 経路B: VS Code Remote Tunnel → vscode.dev

Microsoft 公式の VS Code CLI を VM 上で `code tunnel` として起動し、
ブラウザの `vscode.dev/tunnel/<name>` から接続します。

```
ブラウザ(vscode.dev) ──> Microsoft dev tunnels ──> Colab VM (code tunnel)
                                                    └ リモート拡張ホスト
                                                        └ Cline ──> :11434 Ollama
```

- **仕組みとして最も素直。** VS Code Remote の正規の使い方そのもので、
  拡張はリモート（= Colab VM）側にインストールされ、ターミナルも VM 上で走ります
- 拡張は本家 VS Code Marketplace から入る（Open VSX の版ずれを気にしなくてよい）
- code-server の WebSocket 問題は起きません
- **代償:** Microsoft が運用するトンネルへ常時アウトバウンド接続する。
  Colab の常時禁止事項「リモートプロキシへの接続」に真正面から当たる読みが自然です
- GitHub / Microsoft アカウントでのデバイス認証が必要

### 経路C: Cloudflare Quick Tunnel + code-server

`cloudflared tunnel --url http://127.0.0.1:8080` で `*.trycloudflare.com` の公開 URL を得ます。

- **一番確実に動きます。** WebSocket も素通りし、アカウント登録も不要
- **規約リスクは最大。** 「リモートプロキシへの接続」に加え、公開 URL でウェブサービスを
  提供する形になるため「Colab との相互作用的コンピューティングに関係のないウェブサービス」
  にも掛かります
- セキュリティ上、パスワード認証は必須（`30_code_server.sh` が自動生成します）

### 経路D: Google 公式 Colab VS Code 拡張

`Google.colab` 拡張（`googlecolab/colab-vscode`）。Colab ランタイムを VS Code の
Jupyter カーネルとして使い、実験的機能として `/content` のファイル閲覧・編集と
「Colab Terminal」も提供します。

**この目的では単独で成立しません。** ポートフォワード機能が無いため、
手元の VS Code で動く Cline から VM の `127.0.0.1:11434` に到達できません。
Cline のターミナル実行も手元の PC で走ります。詳細と根拠は
`scripts/43_colab_vscode_note.md` に分けて書きました。

ノートブック中心の作業では最も筋の良い選択肢なので、**用途が違う**と理解するのが正確です。

---

## 3. 規約リスクの比較

Colab のよくある質問に記載された禁止事項を、経路ごとに当てはめたものです。

| 禁止事項 | A | B | C | D |
|---|:--:|:--:|:--:|:--:|
| 【常時】リモートプロキシへの接続 | — | **該当** | **該当** | — |
| 【常時】Colab との相互作用的コンピューティングに関係のないウェブサービス | △ | △ | **該当寄り** | — |
| 【無料枠】SSH シェル、リモートデスクトップなどのリモートコントロール | △ | **該当寄り** | **該当寄り** | — |
| 【無料枠】ノートブック UI をバイパスした、主にウェブ UI を介したやり取り | △ | **該当寄り** | **該当寄り** | — |
| **総合リスク** | **中** | **高** | **最高** | **低** |

**この表の読み方について、正直に書いておきます。**

- 経路 A が「中」なのは、外部プロキシを使わない分だけ軽いという相対評価にすぎません。
  ブラウザ IDE を主 UI にして作業する以上、「ノートブック UI をバイパスした、主にウェブ UI
  を介したやり取り」という記述からは逃れられません。**「A なら大丈夫」ではありません。**
- 経路 B は Microsoft の正規機能で、技術的には最も健全です。しかし規約は「技術的な健全さ」
  ではなく「リモートプロキシに繋いだかどうか」を見ています。**技術的な正しさと規約適合は別軸です。**
- これらはいずれも規約文言の解釈であり、Google の公式見解ではありません。
  最終的な判断は自己責任で行ってください。

### 無料枠でリスクを避けたい場合の現実的な選択肢

| 選択肢 | 内容 |
|---|---|
| **Colab Pro / Pro+ にする** | 「SSH シェル…」「ノートブック UI をバイパス…」の 2 条項は**無料枠のみ**の追加禁止事項です。有料枠なら経路 A の懸念はかなり小さくなります（「リモートプロキシ」は常時禁止なので B/C は依然リスクあり）。つまり **Pro + 経路A** が、この構成で最もクリーンな組み合わせです |
| **Colab は計算だけに使う** | 既存設計書 `claude/colab-t4-local-llm-design.md` の構成（Colab CLI + `colab exec` でジョブを流す）に留め、AI コーディングは別環境で行う |
| **別のホストに移す** | AI コーディング環境は常時稼働・外部公開が前提の用途です。既存の AWS g6 (L4) 構成のほうが素直に目的に合致します。L4 は sm_89 で bf16 も FlashAttention2 も使えるため、モデル選択の幅も広がります |

---

## 4. 推奨する進め方

```
  10_preflight.sh          前提確認（GPU / VRAM / ディスク / 疎通）
        │
  11_ws_probe.py           ★ 経路A が成立するかを 2 分で判定
        │
        ├─ OK  ──> 経路A
        └─ NG  ──> 経路B（規約リスクを受け入れられない場合はここで中止）
        │
  20_ollama.sh             Ollama 導入 + モデル取得 + num_ctx 焼き込み + 実測
        │
        ├─ 経路A/C ──> 30_code_server.sh ──> 40_expose_proxyport.py
        │                                  または 42_expose_cloudflared.sh
        └─ 経路B   ──> 41_expose_tunnel.sh
        │
  （ブラウザで Cline を設定：§6）
        │
  90_healthcheck.sh        切り分け用
  99_teardown.sh           片付け（特に経路C は必須）
```

`notebooks/colab_cline.ipynb` はこの流れをそのままセルにしたものです。
Colab で開いて上から実行すれば済みます。

---

## 5. モデル選定と VRAM の計算

### 5.1 T4 の制約

| 項目 | 値 | 影響 |
|---|---|---|
| VRAM | 16GB（実効 約 14.6GiB） | 重み + KV キャッシュ + 計算バッファがここに収まる |
| Compute Capability | 7.5 (Turing) | **bf16 非対応**。vLLM は `--dtype half` 必須、新しいモデルは動かないことが多い |
| FlashAttention 2 | 非対応（sm_80 以上が必要） | 長コンテキストで不利 |
| メモリ帯域 | 約 320GB/s | 生成速度の律速 |

→ **Ollama (llama.cpp / GGUF) 一択**。既存設計書 §2.5 の結論と同じです。

### 5.2 KV キャッシュの実測式

「モデルは載ったのに長いファイルを読ませたら落ちた」の原因はほぼ全部これです。

```
KV バイト/トークン = 2(K,V) × 層数 × KVヘッド数 × head_dim × 精度バイト数
```

| モデル | 層数 | KVヘッド | head_dim | KV/token (f16) |
|---|---:|---:|---:|---:|
| Qwen2.5-Coder-14B | 48 | 8 | 128 | 0.188 MiB |
| Qwen2.5-Coder-7B | 28 | 4 | 128 | 0.055 MiB |

### 5.3 T4 16GB での成立表

`OLLAMA_KV_CACHE_TYPE=q8_0` を有効にすると KV が約半分になります。

| モデル | 重み | num_ctx | KV(f16) | KV(q8_0) | 合計(q8_0)＋計算バッファ | 判定 |
|---|---:|---:|---:|---:|---:|:--:|
| 14B q4_K_M | 8.4 GiB | 16384 | 3.0 | 1.5 | **約 10.8 GiB** | ◎ 余裕 |
| 14B q4_K_M | 8.4 GiB | 32768 | 6.0 | 3.0 | **約 12.5 GiB** | ○ **推奨** |
| 14B q4_K_M | 8.4 GiB | 65536 | 12.0 | 6.0 | 約 15.8 GiB | ✕ OOM |
| 7B q4_K_M | 4.4 GiB | 32768 | 1.75 | 0.9 | **約 6.1 GiB** | ◎ 安全牌 |
| 7B q5_K_M | 5.1 GiB | 32768 | 1.75 | 0.9 | 約 6.8 GiB | ◎ 品質寄り |
| Devstral 24B q4_K_M | 13.0 GiB | — | — | — | 重みだけで枠を食い切る | ✕ 不適 |
| Qwen3-Coder 30B-A3B q4_K_M | 17.7 GiB | — | — | — | 載らない | ✕ 不適 |

**推奨: `qwen2.5-coder:14b-instruct-q4_K_M` + `num_ctx=32768` + KV q8_0。**

- 16GB VRAM 帯で Cline のようなエージェント用途に耐える最大級のモデルです
- 32K は Qwen2.5-Coder の**ネイティブコンテキスト長です**。これを超える値を設定すると
  YaRN 等の外挿になり品質が落ちるので、7B でも 32768 以上には上げないでください
- 空き VRAM が 13GB 未満と出たら、迷わず 7B に落としてください。
  Cline は「速くて素直」なモデルのほうが、遅くて OOM する大きいモデルより実用的です

### 5.4 T4 で不適な選択肢（検討した上で外したもの）

| 候補 | 外した理由 |
|---|---|
| Devstral Small 24B | エージェント性能は最良クラス（SWE-bench Verified 高スコア）だが、q4_K_M で 14GB。KV の置き場が残らない |
| Qwen3-Coder 30B-A3B | Ollama の最小タグが q4_K_M 19GB。MoE で active 3B と軽いが、Colab 無料枠は RAM も約 12.7GB しかなく CPU オフロードも苦しい |
| gpt-oss:20b (MXFP4) | T4 では MXFP4 の専用カーネルが効かない。vLLM では T4 でのビルド自体が通らない報告あり |
| vLLM 全般 | bf16 非対応で `--dtype half` 必須。加えて起動が遅く、使い捨て VM と相性が悪い |

---

## 6. Cline の設定値（ここを間違えると動かない）

拡張の設定は Cline 側の状態 DB に入るため、**スクリプトからは投入できません。**
ブラウザで Cline のサイドバーを開き、歯車アイコンから手で設定します。

| 項目 | 値 | 理由 |
|---|---|---|
| API Provider | `Ollama` | |
| Base URL | `http://127.0.0.1:11434` | Cline が VM 側で動いているので localhost で届く |
| Model ID | `cline-coder` | `20_ollama.sh` が作る、num_ctx を焼き込んだ派生モデル |
| Context Window | `32768` | `NUM_CTX` と必ず揃える。ずれると Cline の残量計算が狂う |
| **Request Timeout** | `180000` | **既定 30000 のままだと T4 では必ずタイムアウトします**（§7） |
| API Key | 空欄 | ローカルの Ollama / LM Studio では不要 |
| **Use Compact Prompt** | **ON** | Cline 公式が小さいローカルモデル向けに推奨。システムプロンプトを圧縮する |

さらに運用上のコツ:

- **Plan モードで方針を固めてから Act に移る。** ローカルモデルは文脈が埋まるほど劣化が速い
- **タスクは小さく切る。** 「このエンドポイントにページングを足してテストも更新して」くらいの粒度
- **会話が長くなったら新しいタスクを始める。** 文脈を伸ばすより捨てるほうが結果が良い

---

## 7. 最重要の落とし穴: `num_ctx`

**Ollama の既定 `num_ctx` は小さく、超えた分は静かに切り捨てられます。**
エラーは出ません。その代わりこう見えます。

- 直前に出した指示を忘れる
- 読んだはずのファイルの内容を捏造する
- 同じツール呼び出しを無限に繰り返す
- diff 適用が毎回失敗する

Cline は毎リクエストで「システムプロンプト + 環境情報 + ディレクトリ構造 + ファイル内容 + 会話履歴」
を送るため、普通のチャット用途とは桁が違う量になります。

**対策は Modelfile に焼き込むこと。** `20_ollama.sh` がこれをやっています。

```
FROM qwen2.5-coder:14b-instruct-q4_K_M
PARAMETER num_ctx 32768
PARAMETER num_predict 8192
PARAMETER temperature 0.2
```

```bash
ollama create cline-coder -f Modelfile
```

確認方法:

```bash
ollama show cline-coder --parameters   # num_ctx 32768 が出ること
```

### タイムアウトも同根

Cline の Request Timeout 既定値は 30 秒です。T4 で 14B に 20K トークンのプロンプトを
投げると、**プロンプト処理（prefill）だけで 30 秒を超えます**。生成が始まる前に切れるので、
症状は「何も返ってこない」になります。180000（180 秒）に上げてください。

`20_ollama.sh` は warmup で **prompt eval の tok/s** を出します。ここが体感速度を支配するので、
数字を見てタイムアウト値を決めてください。

---

## 8. セッション消滅への備え

Colab 無料枠は最長 12 時間、アイドルでも切れます。**VM 上のものは全部消えます。**

| 消えるもの | 対策 |
|---|---|
| 書いたコード | **git push する。** これが唯一まともな答えです。`/content/workspace` を git リポジトリにして、こまめに push する |
| Ollama のモデル（約 9GB） | 毎回再 DL。`colab drivemount` して `OLLAMA_MODELS` を Drive 上に置く手もあるが、無料 Drive は 15GB 上限で I/O も遅く、初回ロードが逆に遅くなる可能性がある。**まず実測してから決めること** |
| code-server の拡張と設定 | 再インストール（数十秒）。`30_code_server.sh` が冪等なので流し直すだけ |
| Cline の設定と会話履歴 | 再設定が必要。`~/.cline/` を Drive に逃がせば残せるが、未検証 |
| 公開 URL | 毎回変わる |

**設計原則: VM はステートレスとみなす。** 12 時間で消えるものに大事なものを置かない。

---

## 9. トラブルシュート

まず `bash scripts/90_healthcheck.sh` を実行してください。以下は症状別です。

| 症状 | 原因と対処 |
|---|---|
| ブラウザで開くとパスワードは通るが `Setting up your workspace...` から進まない / 左下に `Disconnected` が出続ける | **WebSocket が通っていない。** 経路A の典型的な失敗。DevTools > Network > WS で 101 になっていないことを確認し、経路B か C に切り替える |
| proxyPort が 403 / 404 を返す | ノートブックのタブを開き直し、`40_expose_proxyport.py` のセルを再実行。プロキシ URL はセッションと出力に紐づく |
| Cline が「何も返さない」まま止まる | Request Timeout が 30000 のまま。180000 に上げる（§6） |
| Cline が指示を忘れる / 無いファイルを捏造する | `num_ctx` が足りていない。`ollama show cline-coder --parameters` で確認（§7） |
| `ollama serve` 起動直後に落ちる | `cat /content/logs/ollama.log`。ポート競合か VRAM 不足がほとんど |
| 推論中に CUDA out of memory | `NUM_CTX` を 32768 → 16384 に下げるか、`BASE_MODEL` を 7B に。`20_ollama.sh` を再実行すれば作り直される |
| `Bfloat16 is only supported on GPUs with compute capability of at least 8.0` | vLLM を使おうとしている。T4 では Ollama (GGUF) を使う。どうしても vLLM なら `--dtype half` |
| Cline 拡張が Open VSX から入らない | `curl -I https://open-vsx.org/api/saoudrizwan/claude-dev/latest` で疎通確認。手動 vsix 導入の手順は `30_code_server.sh` のエラーメッセージに出る |
| 経路B で Cline を入れたのに Ollama に繋がらない | 拡張が**ローカル側**に入っている。拡張パネルで `Install in <tunnel-name>` と表示される方を選ぶ |
| 生成が極端に遅い（5 tok/s 未満） | モデルが VRAM に載り切らず CPU にオフロードされている。`nvidia-smi` と `/content/logs/ollama.log` の `offloaded N/M layers to GPU` を確認 |
| ランタイムが勝手に切れる | 無料枠のアイドルタイムアウト。ブラウザのタブを開いたままにする。それでも 12 時間で切れる |

---

## 10. 実機で潰すべき検証項目

設計を確定させる前に、以下を最小コストで確かめてください。**V-1 と V-2 が最優先です。**

| ID | 検証内容 | 判定基準 | 変わりうる設計 | 手段 |
|---|---|---|---|---|
| **V-1** | Colab のポートプロキシが WebSocket を通すか | ブラウザで `OK - WebSocket works` | 経路A の採否（→ B/C へ） | `scripts/11_ws_probe.py`（2 分） |
| **V-2** | 無料枠で T4 が取れるか | `nvidia-smi` に Tesla T4 | 計画全体 | `scripts/10_preflight.sh` |
| **V-3** | 14B q4_K_M + num_ctx 32768 が 14.6GiB に収まるか | warmup 後の空き VRAM > 1.5GiB | モデル規模 / num_ctx | `scripts/20_ollama.sh` の §6 出力 |
| **V-4** | T4 で `OLLAMA_FLASH_ATTENTION=1` + KV q8_0 が効くか | ollama.log にエラーが出ず VRAM が理論値どおり | V-3 の成立条件 | `20_ollama.sh` 実行後に `nvidia-smi` |
| **V-5** | prompt eval の実効速度 | 20K トークンの prefill が Request Timeout 内 | タイムアウト値 / モデル規模 | `20_ollama.sh` の warmup 出力 |
| **V-6** | Cline が実タスクを完走するか | 「fizzbuzz を作って実行して見せて」が通る | モデル選定そのもの | ブラウザで実行 |
| **V-7** | セッション作成〜Cline 稼働までの所要時間 | 12 時間枠に対して許容できるか | モデル永続化方針（§8） | 通しで計測 |
| **V-8** | 経路B のトンネルが Colab のアイドル検知をどう扱うか | 放置後もセッションが生きているか | 運用手順 | 実測 |

---

## 11. ファイル構成

```
colab-cline/
├── docs/
│   └── 手順書.md                     ← 本書
├── notebooks/
│   ├── colab_cline.ipynb             ← Colab で開いて上から実行する
│   └── build_notebook.py             ← ipynb の生成元。編集はこちらを直す
└── scripts/
    ├── common.sh                     設定と共通関数（環境変数はここに集約）
    ├── 10_preflight.sh               前提確認
    ├── 11_ws_probe.py                ★ 経路A の成否判定（V-1）
    ├── 20_ollama.sh                  Ollama + モデル + num_ctx（冪等）
    ├── 30_code_server.sh             code-server + Cline 拡張（冪等）
    ├── 40_expose_proxyport.py        経路A: Colab 内蔵プロキシ
    ├── 41_expose_tunnel.sh           経路B: VS Code Remote Tunnel
    ├── 42_expose_cloudflared.sh      経路C: Cloudflare Quick Tunnel
    ├── 43_colab_vscode_note.md       経路D: なぜ成立しないかの説明
    ├── 90_healthcheck.sh             切り分け
    └── 99_teardown.sh                片付け
```

設定はすべて `common.sh` の環境変数で上書きできます。

```bash
BASE_MODEL=qwen2.5-coder:7b-instruct-q4_K_M NUM_CTX=32768 bash scripts/20_ollama.sh
```

---

## 参考資料

**Colab**
- [Google Colab よくある質問（禁止事項・制限）](https://research.google.com/colaboratory/faq.html?hl=ja)
- [Colab 有料サービスに関する利用規約](https://research.google.com/colaboratory/intl/ja/tos_v2.html)
- [googlecolab/colab-vscode Wiki — User Guide](https://github.com/googlecolab/colab-vscode/wiki/User-Guide)
- [Google Colab is Coming to VS Code — Google Developers Blog](https://developers.googleblog.com/google-colab-is-coming-to-vs-code/)
- [Issue #231: Support Local File Access for Colab in VS Code Extension](https://github.com/googlecolab/colab-vscode/issues/231)
- [googlecolab/google-colab-cli](https://github.com/googlecolab/google-colab-cli)
- [colabtools Issue #4738: ProxyPort URL is broken](https://github.com/googlecolab/colabtools/issues/4738)

**ブラウザ IDE**
- [coder/code-server Discussion #2084: VS Code (code-server) on Google Colab / Kaggle](https://github.com/coder/code-server/discussions/2084)
- [abhishekkrthakur/colabcode](https://github.com/abhishekkrthakur/colabcode)
- [Developing with Remote Tunnels — VS Code Docs](https://code.visualstudio.com/docs/remote/tunnels)
- [vscode-colab — PyPI](https://pypi.org/project/vscode-colab/)
- [Google Colab上でVS Codeを動かしてブラウザでアクセス — webbigdata](https://webbigdata.jp/post-7278/)
- [code-serverをGoogle Colaboratory上で起動する — Qiita](https://qiita.com/naru-T/items/77e00cc6fd2c5284d0c5)

**Cline**
- [Cline — Open VSX Registry (saoudrizwan.claude-dev)](https://open-vsx.org/extension/saoudrizwan/claude-dev)
- [Running Models Locally — Cline Docs](https://docs.cline.bot/running-models-locally/read-me-first)
- [How to Run Cline in code-server for Remote Development — Fastio](https://fast.io/resources/run-cline-in-code-server/)
- [How to Use Cline with Ollama for Local AI Coding — Fastio](https://fast.io/resources/cline-ollama-setup/)
- [Cline Ollama Request Timed Out After 30 Seconds Fixed — LocalLLM.in](https://localllm.in/blog/cline-ollama-timeout-fix)
- [Cline + Ollama (2026): Run the VS Code Coding Agent on Local Models — LLM Configurator](https://llmconfigurator.com/en/guides/coding-agents/cline-with-local-llms)

**モデル / 推論**
- [ollama.com/library/qwen2.5-coder/tags](https://ollama.com/library/qwen2.5-coder/tags)
- [ollama.com/library/qwen3-coder/tags](https://ollama.com/library/qwen3-coder/tags)
- [ollama.com/library/devstral/tags](https://ollama.com/library/devstral/tags)
- [Best Coding LLM for 16GB VRAM (2026) — localaimaster](https://localaimaster.com/vram/best-coding-llm-16gb-vram)
- [Best Local Coding Models 2026 — Ranked by VRAM Tier — LLM Configurator](https://llmconfigurator.com/en/guides/coding-agents/best-local-coding-models)
- [vLLM Issue #1157: Bfloat16 is only supported on GPUs with compute capability of at least 8.0](https://github.com/vllm-project/vllm/issues/1157)
- [Build issues when serving gpt-oss-20B on Tesla T4 GPUs with vLLM](https://discuss.vllm.ai/t/build-issues-when-serving-gpt-oss-20b-on-tesla-t4-gpus-with-vllm/1673)
