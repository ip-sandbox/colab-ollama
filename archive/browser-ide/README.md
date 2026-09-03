# archive/browser-ide — v1.0（もう使いません）

「web ブラウザのコンソールから AI コーディング」を **ブラウザ上の VS Code UI** と
読んで設計した v1.0 の成果物です。要件が「Colab ノートブック UI 付属のターミナル
ウィンドウ」だと判明したため、**この構成は不要になりました。**

廃止の理由は `docs/手順書.md` §2 に書いています。要点は 1 つで、
**Cline には CLI 版があるため、VS Code の UI をブラウザに届ける必要がそもそも無い**、
ということです。それが分かった時点で以下がまとめて消えます。

- code-server の導入と設定
- Open VSX からの拡張導入
- 外部トンネル（Cloudflare / Microsoft dev tunnels）
- Colab ポートプロキシの WebSocket 疎通問題
- 公開 URL のパスワード管理と閉じ忘れ

規約リスクも「高〜最高」から「低〜中」に下がりました。

## それでも残しておく理由

| ファイル | 今も価値がある内容 |
|---|---|
| `43_colab_vscode_note.md` | **Google 公式 Colab VS Code 拡張がなぜ Ollama に届かないか。** ポートフォワードが無いという構造的な話で、今後も有効 |
| `旧手順書_ブラウザIDE版.md` | 4 経路の規約リスク比較。Colab で外部公開を検討する場面が再び来たときの下敷き |
| `11_ws_probe.py` | Colab のポートプロキシが WebSocket を通すかを 2 分で判定するツール。他の用途にも流用できる |
| `40_expose_proxyport.py` | Colab 内蔵プロキシで任意のポートをブラウザに出す最小実装 |
| `41_expose_tunnel.sh` / `42_expose_cloudflared.sh` | 規約リスクを承知で外部公開する場合の実装 |
| `30_code_server.sh` | code-server + 拡張の冪等セットアップ |

これらは v1.0 時点の `scripts/common.sh` を前提に書かれています。
現在の `common.sh` からは `CS_PORT` などの変数が削除されているため、
**そのままでは動きません。** 再利用する場合は変数定義を補ってください。
