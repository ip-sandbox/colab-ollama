# 経路D: Google 公式 Colab VS Code 拡張

> ## ⚠️ 結論が変わりました（2026-09-03 追記）
>
> 以下の「成立しない」という結論は、**Cline を VS Code 拡張として動かす前提**での話です。
> **Cline CLI を使うなら成立します。**
>
> この拡張には実験的機能として「Colab Terminal」（`Colab: Open Terminal`）があり、
> **Colab ランタイムに繋がったターミナル**が開きます。そこで `cline` を起動すれば
> Cline は VM 上のプロセスなので、`127.0.0.1:11434` は VM の Ollama そのものです。
> ポートフォワードは要りません。
>
> 下の「成立しない理由」で書いた図は、Cline が手元の PC の拡張ホストで動く場合にのみ
> 当てはまります。**VM 側にターミナルが取れるという事実のほうが重要でした。**
>
> 現行版: `claude/colab-t4-cline-terminal.md` §2 / §4（T3）

以下は v1.0 時点の記述です（Cline を VS Code 拡張として使う場合の分析として読んでください）。

## この拡張ができること

`Google.colab`（リポジトリ: `googlecolab/colab-vscode`）は Google 公式の VS Code 拡張です。
User Guide によると、以下ができます。

| 機能 | 状態 |
|---|---|
| Colab ランタイムを Jupyter カーネルとして使う | 正式 |
| マシンタイプ（GPU）の選択 | 正式 |
| Colab サーバの `/content` をエクスプローラで閲覧・編集・作成・削除 | 実験的 (Contents view / server mounting) |
| Colab ランタイムに繋がったターミナル | 実験的 (Colab Terminal) |
| Google Drive のマウント | 正式 |

「ファイルも触れてターミナルもある」ので、一見これで足りそうに見えます。

## 成立しない理由

**ポートフォワードが無い。**

拡張が繋いでいるのは Jupyter のカーネル/コンテンツ API であって、
汎用のトンネルではありません。つまり:

```
[手元のPC]                          [Colab VM (T4)]
  VS Code                             Ollama :11434  ← 到達できない
   └ Cline 拡張  ← ここで動く            └ 127.0.0.1 でしか listen していない
   └ Colab 拡張 ──── Jupyter API ────→ /content (ファイル)
                                      └ ターミナル
```

- **Cline は手元の PC の拡張ホストで動く。** リモート拡張ホスト（VS Code Remote の
  ような仕組み）ではないため、Cline から見た `localhost:11434` は手元の PC です。
  Colab の Ollama には届きません。
- **Cline のターミナル実行も手元の PC で走ります。** Cline が `python train.py` を
  実行しても T4 は使われません。
- `googlecolab/colab-vscode` の Issue #231（→ #223 に統合）は、ローカルファイルと
  Colab ランタイムの間のファイルアクセスに関する要望が未対応であることを示しています。

## それでも使う価値がある場面

- **ノートブック中心の作業。** GPU でセルを回す用途では、この拡張が最も筋が良く、
  規約上の懸念もありません（Google 自身の製品です）。
- **経路 B/C の補助。** ファイルの確認や Drive マウントだけをこの拡張でやり、
  AI コーディングは経路 B/C 側で行う、という併用は可能です。

## 無理に成立させる場合（非推奨）

Ollama のポートを外に出すトンネルを別途 1 本張れば、手元の Cline から
Colab の LLM を叩けます。ただしその瞬間に、

- 規約上のリスクは経路 C とまったく同じになる（むしろ「LLM API の外部公開」は
  「Colab との相互作用的コンピューティングに関係のないウェブサービス」に
  より近い読みになる）
- なのに Cline のターミナルは手元で走るので、経路 B より不便

という、**リスクは最大で利点は最小**の構成になります。やるなら経路 B を選ぶべきです。

## 参考

- [Google Colab is Coming to VS Code — Google Developers Blog](https://developers.googleblog.com/google-colab-is-coming-to-vs-code/)
- [User Guide · googlecolab/colab-vscode Wiki](https://github.com/googlecolab/colab-vscode/wiki/User-Guide)
- [Issue #231: Support Local File Access for Colab in VS Code Extension](https://github.com/googlecolab/colab-vscode/issues/231)
