# 🫘 MameLLM(豆LLM)

メモリの少ないMac(4GB / 8GB)でも動く、ローカルLLMチャットアプリです。
依存ライブラリなしの単一バイナリ(約7MB)で、推論は [llama.cpp](https://github.com/ggml-org/llama.cpp) に任せます。

> このフォルダはリポジトリ本体(YouTube Plus / YTLite)とは独立したアプリです。

## 特長

- **低メモリ前提の設計**
  - 搭載メモリを検出し、モデルごとに「快適 / 動作可 / ぎりぎり / メモリ不足」を表示
  - コンテキスト長をメモリ量から自動決定(4GB→2048、8GB→4096、それ以上→8192)
  - 同時に読み込むモデルは1つだけ。使わない時間が続くと自動でメモリから解放(既定10分)
  - 会話が長くなると古い発言から自動で切り詰め、コンテキスト超過を防止
  - Apple SiliconはMetal(GPU)を自動使用、Intel MacはCPUで動作
- **内蔵カタログ 31モデル**(約100MB〜)。日本語向け(TinySwallow、Sarashina、Gemma 3、Qwen など)を含む
- **ダウンロード元を多数登録済み**。失敗したら次の候補へ自動で切り替え、中断しても続きから再開
- **ダウンロード元もモデルも自分で追加できる**
- 取得後にSHA-256とGGUF形式を検証(非公式ミラー経由でも改変ファイルは採用しない)

## 登録済みのダウンロード元

モデル用(9件。上から順に試行、画面で並べ替え・無効化可):

| 名前 | 種類 | 備考 |
|---|---|---|
| Hugging Face | HF互換 | 公式 |
| HF-Mirror (hf-mirror.com) | HF互換 | ミラー |
| ModelScope (modelscope.cn) | ModelScope | Alibaba系ハブ |
| Ollama Registry (registry.ollama.ai) | Ollama | GGUF本体を直接取得。Ollama本体は不要 |
| Ollama Registry (ollama.com) | Ollama | 別ホスト名 |
| Ollama ミラー (DaoCloud) | Ollama | 非公式 |
| HF-Mirror 予備 (alpha.hf-mirror.com) | HF互換 | 非公式 |
| Sufy HF CDN | HF互換 | 非公式 |
| 直接URL | URL | GPT4All CDN、および自分で登録したURL |

ランタイム(llama.cpp)用(3件): GitHub Releases(公式)、gh-proxy.com、ghproxy.net。
2つのプロキシは実行ファイルを第三者経由で受け取ることになるため**既定では無効**です(GitHubに繋がらない場合のみ有効化してください)。
Homebrew等で導入済みの `llama-server` があれば自動で検出して使います。

### 追加できるもの

- **ダウンロード元**(「ダウンロード元」タブ): Hugging Face互換ミラー / `{repo}`・`{file}` を含むURLテンプレート / Ollama互換レジストリ / ModelScope互換 / GitHubプロキシ
- **モデル**(「モデル」タブ下部): Hugging Face検索(GGUFのみ)/ リポジトリとファイル名の指定 / Ollamaのモデル名(例 `gemma3:1b`)/ GGUFへの直接URL / 手元のGGUFファイル

## 使い方

### 1. 入手

**A. GitHub Actionsでビルドされたものを使う**
Actionsの「Build MameLLM (macOS app)」の成果物 `MameLLM-macos` をダウンロードし、
Apple Siliconなら `MameLLM-macos-arm64.zip`、Intel Macなら `MameLLM-macos-amd64.zip` を展開します。
署名していないため、初回は次のコマンドで隔離属性を外してください。

```sh
xattr -dr com.apple.quarantine MameLLM.app
```

**B. 自分でビルドする**(Go 1.21以上: `brew install go`)

```sh
cd MameLLM
./build.sh          # dist/ に arm64 / Intel 用の MameLLM.app を生成
# または、その場で実行:
go run .
```

### 2. 起動

`MameLLM.app` をダブルクリック(またはターミナルで `MameLLM.app/Contents/MacOS/mamellm`)。
ブラウザで `http://127.0.0.1:11500/` が開きます。Dockには表示されないので、終了は「設定」タブの「MameLLMを終了」から。

### 3. 初回セットアップ

1. 「モデル」タブ上部の **ランタイムをインストール**(llama.cpp公式ビルドを自動取得)
2. モデルを選んで **ダウンロード**(迷ったら Gemma 3 1B か Qwen2.5 1.5B)
3. 「チャット」タブで会話

### メモリ別の目安

| 搭載メモリ | おすすめ |
|---|---|
| 4GB | SmolLM2 360M、Qwen2.5 0.5B、LFM2 350M/700M、Gemma 3 270M(1〜1.5Bはぎりぎり) |
| 8GB | Gemma 3 1B、Qwen2.5 1.5B、TinySwallow 1.5B、Llama 3.2 3B(4Bクラスまで動作可) |
| 16GB〜 | Gemma 3 4B、Qwen3 4B、Mistral 7B、Llama 3.1 8B |

### オプション

```
-port 11500     待ち受けポート(使用中なら次の空きポート)
-data <dir>     保存先(既定: ~/Library/Application Support/MameLLM)
-no-open        ブラウザを自動で開かない
```

## 安全面

- 待ち受けは `127.0.0.1` のみ。他サイトからの操作を防ぐため、Hostヘッダーと書き込みリクエストを検査します
- Hugging Faceトークン(任意)は公式 huggingface.co にのみ送信し、ミラーには送りません
- 非公式ミラー/プロキシは第三者運営です。モデルはSHA-256で照合しますが、気になる場合は「ダウンロード元」タブで無効化できます。
  ランタイム(llama.cpp)はハッシュ照合の対象外なので、GitHubプロキシは既定で無効にしてあります

## 開発

```sh
go vet ./... && go test ./...
```

- `catalog/sources.json` … 組み込みのダウンロード元
- `catalog/models.json` … 組み込みのモデルカタログ(サイズとSHA-256つき)
- 設定とユーザー追加分は `<保存先>/config.json` に保存されます

## 検証状況

Linux上で、実際の各ダウンロード元からの取得(再開・フォールバック・ハッシュ検証を含む)、
ランタイムの導入処理、チャットの中継、異常終了の検知、アイドル時の解放、画面操作を確認しています。
macOS実機での llama.cpp による推論は、開発環境の都合で未確認です。
