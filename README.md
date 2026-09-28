# AskDrive (`ask_drive`)

**Google Drive ドキュメント完全ローカルナレッジ回答ボット**

Apple Silicon Mac (8GB〜) の単一マシン上で、Google Drive 内の共有マニュアル・規定ドキュメントを取り込み、夜間バッチで事前生成した想定 QA・要約・構造化データを用いて、営業時間中の問い合わせに **1秒未満で即答（または原文抜粋を提示）** する完全ローカル動作システムです。

---

## 主な特徴

1. **完全ローカル推論 (Ollama)**:
   - 埋め込み: `bge-m3`
   - 夜間生成: `qwen3:4b`
   - 外部 LLM API への社内データ送信は一切行いません。
2. **二相運用 (Phase-based Residency Control)**:
   - **営業時間相 (07:00〜19:00)**: 埋め込みモデルのみ常駐、LLM 生成 API 封鎖（メモリ圧迫防止）。
   - **待機相 (19:00〜02:00)**: 全モデル解放。
   - **夜間バッチ相 (02:00〜06:30)**: フェーズごとに1モデルのみロードし、RAM ピークを最小化。
3. **段階的応答 (Multi-tier Answering)**:
   - **Tier 0**: 正規化完全一致キャッシュ（数ミリ秒）
   - **Tier 1**: 想定 QA ベクトル検索（1秒未満・類似度 >= 0.90）
   - **Tier 2**: 原文ハイブリッド検索（`sqlite-vec` + FTS5 trigram + RRF 融合）による原文抜粋提示
   - **Tier 3**: 未回答質問の自動ロギングと翌夜バッチでの最優先回答生成
4. **Google Workspace ドメイン制限**:
   - 事前に設定した自社ドメイン（`@company.com`）のアカウントのみアクセスを許可し、部外者のアクセスを遮断。
5. **Web 管理画面 (`/admin`)**:
   - バッチ状況、ナレッジカバレッジ、未回答質問、文書一覧、Drive フォルダ設定、システム設定、メンテナンスモード切り替え。

---

## 必要環境

- **OS**: macOS (Apple Silicon / Intel, Apple Silicon 推奨)
- **管理者権限 (sudo)**: **不要**（`./app.sh setup` がスタンドアロンバイナリおよびローカル環境 `.runtime` に必要なツール群を自動ダウンロード・セットアップします）

---

## インストールと初期セットアップ

### 1. リリースアーカイブ（ZIP）の取得と展開
GitHub Releases から最新版の ZIP をダウンロードして展開します。
```bash
# 例: v0.0.9 の場合
curl -fLO https://github.com/kh813/ask-drive/releases/download/v0.0.9/ask-drive-v0.0.9.zip
unzip ask-drive-v0.0.9.zip -d ask-drive
cd ask-drive
```

### 2. 初期セットアップの実行
統合管理スクリプト `./app.sh setup` を実行します。
```bash
./app.sh setup
```
> **自動実行される処理（管理者権限不要）:**
> 1. **依存ツールの確認 & 自動配置**: `pandoc`, `ollama`, `poppler` (pdftotext), `erlang`, `elixir`, `sqlite-vec` を検出し、未インストールの場合はローカル環境（`.runtime/`）へ自動取得・セットアップ
> 2. **Ollama モデルの自動取得**: ローカル LLM / Embedding モデル（`bge-m3`, `qwen3:4b`）の自動ダウンロード
> 3. **環境設定ファイル生成**: `.env.prod` の自動生成と暗号化キー生成
> 4. **データベース構築 & リリースビルド**: SQLite DB の作成、マイグレーション、プロダクションアセットとリリースの完全ビルド


### 3. アプリケーションの起動

#### フォアグラウンド起動（開発・テスト用）:
```bash
./app.sh start
```

#### launchd 常駐サービス登録・起動（推奨）:
```bash
./app.sh service install
./app.sh service start
```
サービス状態の確認:
```bash
./app.sh service status
```

ブラウザで `http://localhost:4000/` にアクセスします。

---

## 運用・アップデート管理

### 管理スクリプトコマンド一覧 (`./app.sh`)

| コマンド | 説明 |
|---|---|
| `./app.sh start` | アプリケーションをフォアグラウンドで起動 |
| `./app.sh stop` | 実行中プロセスを停止 |
| `./app.sh restart` | アプリケーションを再起動 |
| `./app.sh status` | Ollama, アプリ, launchd, HTTP エンドポイントの稼働状態を表示 |
| `./app.sh setup` | 初回環境構築・DB 初期化・リリースビルド |
| `./app.sh deploy` | 最新コードの依存関係更新・マイグレーション・再ビルド・再起動 |
| `./app.sh update` | Git リモートから最新版へ自己アップデート（確認ダイアログ付き） |
| `./app.sh update --yes` | 確認なしで最新版へ自己アップデート |
| `./app.sh update --ver <tag/hash>` | 指定バージョン（タグやコミット）へアップデートまたはロールバック |
| `./app.sh service install` | macOS launchd サービスを登録 |
| `./app.sh service uninstall` | launchd サービスを解除 |
| `./app.sh service start` | launchd サービスを開始 |
| `./app.sh service stop` | launchd サービスを停止 |
| `./app.sh service restart` | launchd サービスを再起動 |
| `./app.sh service status` | launchd サービス稼働状態およびログ確認 |

---

## 初期設定手順（Web 管理画面）

1. ブラウザで `http://localhost:4000/admin?tab=settings` を開きます。
2. 以下の設定を入力して保存します:
   - **許可 Google Workspace ドメイン**: 自社ドメイン（例: `company.com`）
   - **Google Drive フォルダ ID / URL**: 取り込み対象のマニュアル・文書が格納された共有フォルダの ID または URL
3. `http://localhost:4000/` に戻り、「Google 連携」から指定ドメインの専用 Google アカウントで認可します。
4. 管理画面の「今すぐバッチ実行」を押すか、夜間 02:00 の自動スケジュールにより同期と QA 生成が実行されます。

---

## ライセンス

[MIT License](LICENSE) © 2026 kh813

