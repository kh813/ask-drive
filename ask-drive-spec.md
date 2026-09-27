# AskDrive 仕様書 v0.5

Google Drive 上の文書を知識源とし、**夜間バッチで回答データを事前生成し、営業時間中はそれを参照して即答する**完全ローカルのチャットボット。

| 項目 | 内容 |
|---|---|
| 文書バージョン | 0.5 |
| 更新日 | 2026-09-28 |
| 主な変更 | アプリケーション名を **AskDrive**（内部識別子: `ask_drive` / `AskDrive`）に変更。DB を SQLite3 + sqlite-vec + FTS5 構成に統一 |
| 名称 | 表示名 **AskDrive** / 内部識別子 `ask_drive`・`AskDrive` |
| 実装スタック | Elixir / Phoenix LiveView / SQLite3 + sqlite-vec + FTS5 / Ollama |
| 想定稼働環境 | Mac mini（初期 RAM 8GB → 将来増設） |

---

## 1. 目的と背景

Google Drive に蓄積されたドキュメントに対して、自然文で質問すると根拠付きで答えが返るチャットボットを、**データを外部に一切送信せずに**運用する。Mac mini を常時稼働させ、ブラウザから社内 LAN 経由でアクセスする。

### 1.1 v0.1 からの方針転換

初版では質問のたびに LLM を呼ぶ構成だったが、RAM 8GB では生成モデルと埋め込みモデルの同時常駐が苦しく、モデルサイズにも強い上限がかかっていた。

本版では処理を時間で分離する。

| | v0.1 | v0.2 |
|---|---|---|
| 営業時間の LLM 生成 | 質問ごとに実行 | **行わない** |
| 営業時間の常駐モデル | 生成 + 埋め込み（約3.7GB） | **埋め込みのみ（約1.2GB）** |
| 生成モデルのサイズ上限 | 応答速度に縛られる | **速度不問。RAM の許す限り** |
| 回答速度 | 5秒以上 | **1秒未満** |
| 未知の質問 | 都度回答できる | **翌朝まで待つ場合がある** |

営業時間中に生成モデルをメモリから完全に降ろせるため、**RAM 制約は昼間の体験にほぼ影響しなくなる**。代わりに制約は「一晩で何件処理できるか」というスループットの問題に移る（9.2 節）。

### 1.2 設計上の最優先事項

1. **完全ローカル** — 文書本文・質問・回答をインターネットに送出しない。外部通信は Drive 取得と OAuth トークン更新のみ。
2. **昼夜の資源分離** — 営業時間中は生成モデルをロードしない。これを設計で保証する。
3. **鮮度の保証** — 事前生成した回答が元文書より古い状態を、検知せず配信しない。
4. **段階的スケール** — RAM 増設時、設定値の変更と再バッチのみで品質が上がる。

---

## 2. スコープ

### 2.1 含むもの

- Google アカウント連携（OAuth 2.0）による Drive 読み取り
- Drive フォルダ／ファイルの取り込みと差分同期
- Google ドキュメント／スプレッドシート／スライド、PDF、Office（docx / xlsx / pptx）、テキスト／Markdown／CSV の本文抽出
- 夜間バッチによる要約・想定質問回答・構造化データの事前生成
- 営業時間中の段階的応答（完全一致 → 想定QA → 原文抜粋 → 未回答記録）
- 未回答質問の記録と、翌夜バッチでの自動解消
- 元文書の更新に連動した事前生成データの無効化
- バッチ実行状況と未回答質問の管理画面

### 2.2 含まないもの

- 営業時間中の LLM による回答生成（設定で例外的に有効化する場合を除く。6.4.5）
- マルチテナント／権限分離（単一ユーザー・単一アカウント前提）
- Drive 側のアクセス権（ACL）の回答への反映
- 文書の書き込み・編集
- 画像・動画・音声の内容理解、OCR
- インターネット公開
- モバイルアプリ

---

## 3. 動作環境

### 3.1 ハードウェア

| 区分 | 初期 | 増設後 |
|---|---|---|
| 機種 | Mac mini（Apple Silicon） | Mac mini / Mac Studio |
| RAM | 8GB | 16GB / 32GB 以上 |
| ストレージ | **空き 100GB 以上** | 空き 200GB 以上 |

ディスクは積極的に使う。事前生成データは元テキストの5〜10倍に膨らむが、これは意図した交換である。

### 3.2 言語・ランタイム

いずれも 2026-09-28 時点で確認済み。`.tool-versions`（asdf / mise）で固定し、開発機と本番機で一致させる。

| 種別 | 確認時点の最新 | 本プロジェクトの指定 | 備考 |
|---|---|---|---|
| Elixir | 1.20.x（2026-06-03 リリース） | **1.20.x** | 1.20 は Erlang/OTP 27 以上を必須とする |
| Erlang/OTP | — | **27 または 28** | Elixir 1.20 の要件に従う |
| SQLite | 3.45+ | **3.45+** | macOS 標準または Homebrew。FTS5（trigram 内蔵）必須 |
| sqlite-vec（拡張） | 0.1.x | **0.1.x** | ベクトル検索用 SQLite C 拡張（Mac ARM64 ビルド） |
| Ollama | — | 最新安定版 | 後述の API 要件を満たすこと |

```
# .tool-versions
elixir 1.20.0-otp-28
erlang 28.x
```

**デーモンレス構成（SQLite3）**：PostgreSQL のような常駐サーバープロセスを持たず、データベースはファイル（`ask_drive_dev.db`, `ask_drive_prod.db`）としてプロセス内で直接動作する。WAL（Write-Ahead Logging）モードを有効にすることで、LiveView からの並行読み込みと Oban / バッチワーカーによる書き込みを両立する。

**ベクトル検索と全文検索**：
- ベクトル検索には `sqlite-vec`（`vec0` 仮想テーブル / コサイン距離関数）を利用する。
- キーワード・全文検索には SQLite 内蔵の `FTS5`（trigram トークナイザ）を利用する。

### 3.3 Hex パッケージ

2026-09-28 時点で hex.pm を確認した結果。`mix.exs` にはこの表の「指定」列をそのまま書く。

| パッケージ | 最新版 | 指定 | 判断 |
|---|---|---|---|
| `phoenix` | 1.8.3（2026-07） | `~> 1.8` | `mix phx.new ask_drive --database sqlite3` の生成値を使う |
| `phoenix_live_view` | 1.2.12（2026-09-16） | **`~> 1.2.9`** | ⚠ 下記の脆弱性のため下限を明示する |
| `ecto_sqlite3` / `jason` / `bandit` ほか | — | phx.new の生成値 | SQLite3 用 Ecto アダプタ（`exqlite` に依存） |
| `oban` | 2.24.1（2026-09-03） | `~> 2.24` | `engine: Oban.Engines.Lite` を指定し SQLite3 上で動作させる |
| `req` | 0.7.3（2026-08-19） | **`~> 0.7`** | ⚠ 0.8.0-rc.0 が存在するが RC のため採用しない |
| `xlsx_reader` | 0.8.9（2025-11-09） | `~> 0.8` | xlsx 読み取り。`saxy` に依存 |

#### 3.3.1 既知の脆弱性

`phoenix_live_view` に 2026 年に 2 件の勧告が出ている。**1.2.9 未満を使ってはならない。**

| ID | 概要 | 影響範囲 | 深刻度 |
|---|---|---|---|
| CVE-2026-64941 | `validate_local_url!/2` のオープンリダイレクト（タブ・LF・CR 経由） | `>= 1.2.0-rc.0 and < 1.2.9` ほか | low (2.1) |
| CVE-2026-58228 | `Phoenix.LiveView.Utils` のスキーム検証バイパスによる `<.link>` からの XSS | `>= 1.2.2 and < 1.2.7` | medium (5.1) |

`req` にも旧版（0.6 系）に対する勧告が 2 件ある。0.7.3 を使えば該当しない。

**実装開始時に `mix deps.audit` または `mix hex.audit` を必ず1回通すこと**（Phase 1 のビルドゲートに含める）。

### 3.4 採用しないライブラリと、その代替

**事前に確認した結果、当初案から 2 つ方針を変えている。** どちらも実装後に気づくと手戻りが大きい。

#### 3.4.1 `ueberauth` / `ueberauth_google` は採用しない

| 確認結果 | |
|---|---|
| 最新版 | 0.12.1 |
| 最終更新 | **2023-11-14（約3年前）** |
| 依存 | `ueberauth ~> 0.10.0` を上限固定 |

3年近く更新が止まっており、かつ `ueberauth` の版を狭く固定している。Phoenix 1.8 / Elixir 1.20 世代との組み合わせで依存解決が詰まる、あるいは詰まらなくても放置されたコードに乗ることになる。

そもそも本アプリに必要なのは**単一アカウントの Drive 読み取り認可**だけであり、複数プロバイダ対応のログイン基盤ではない。認可コードフローを `Req` で直接実装する（およそ 150 行）。

| 得られるもの | |
|---|---|
| 依存が 2 つ減る | `ueberauth` と `oauth2` |
| `access_type=offline` / `prompt=consent` を完全に制御できる | リフレッシュトークン取得の確実性は本アプリの要件（F-103） |
| トークン更新のリトライとエラー分類を自分で書ける | `invalid_grant` の検知（F-106）が素直に書ける |

実装するエンドポイントは 3 つだけ。

```
GET  https://accounts.google.com/o/oauth2/v2/auth   認可画面へのリダイレクト
POST https://oauth2.googleapis.com/token            コード交換 / リフレッシュ
POST https://oauth2.googleapis.com/revoke           接続解除
```

CSRF 対策の `state` はセッションに保存して照合する。

#### 3.4.2 `cloak` / `cloak_ecto` は採用しない

暗号化が必要なのは `google_accounts` の 2 カラム（`access_token` / `refresh_token`）だけである。汎用の鍵ローテーション基盤を持ち込む規模ではない。

OTP 標準の `:crypto.crypto_one_time_aead/7` による AES-256-GCM で、カスタム `Ecto.Type` を約 40 行書く。鍵は環境変数 `ASK_DRIVE_ENCRYPTION_KEY`（32 バイトを Base64 で）から読む。

将来、暗号化対象が増えるか鍵ローテーションが要件になった時点で `cloak_ecto` への移行を検討する。

### 3.5 外部コマンドライン依存

Homebrew でインストールする。バージョンは固定せず、**存在確認と動作確認を起動時に行う**（出力形式が変わっても検知できるようにする）。

| コマンド | パッケージ | 用途 | 無い場合 |
|---|---|---|---|
| `pdftotext` | `poppler` | PDF 本文抽出 | PDF を `skipped` にし、管理画面で案内 |
| `pandoc` | `pandoc` | docx / pptx 本文抽出 | 該当形式を `skipped` にし、案内 |
| `caffeinate` | macOS 標準 | バッチ中のスリープ抑止 | — |

```bash
brew install poppler pandoc
```

起動時に `System.find_executable/1` で存在を確認し、管理画面の「モデル状態」区画に併せて表示する。

### 3.6 Ollama に求める API 要件

Ollama はバージョン番号ではなく**機能で要件を定める**（リリース頻度が高く、バージョン固定が現実的でないため）。

| 要件 | 確認方法 |
|---|---|
| `POST /api/embed` が配列入力に対応 | 起動時に 2 要素の配列を投げて 2 本のベクトルが返ることを確認 |
| `keep_alive` パラメータを受け付ける | `keep_alive: 0` でアンロードできることを確認 |
| `OLLAMA_MAX_LOADED_MODELS` を解釈する | 起動スクリプトで設定 |
| `OLLAMA_KV_CACHE_TYPE` を解釈する | `OLLAMA_FLASH_ATTENTION=1` と併用（片方だけでは効かない） |

> 旧 `POST /api/embeddings`（単数形）は単一文字列しか受け付けない。**必ず `/api/embed`（複数形）を使う。**バッチ投入できるかどうかで取り込み速度が桁で変わる。

> **Ollama を Docker で動かしてはならない。** macOS の Docker は GPU パススルーに対応せず、Metal / MLX が使われないため実用速度が出ない。

### 3.7 バージョン確認の運用

依存の最新版は本仕様の作成時点のものであり、実装着手までに動く。

| ID | 要件 |
|---|---|
| N-001 | 実装着手時に `mix hex.outdated` と `mix hex.audit` を実行し、本章との差分を確認する |
| N-002 | 差分があった場合、本章を更新してから実装に入る（コードを先に書かない） |
| N-003 | `mix.lock` をリポジトリにコミットし、開発機と本番機で同一の依存を使う |
| N-004 | 月次で `mix hex.audit` を実行し、脆弱性勧告を確認する |

### 3.8 macOS 固有の設定

夜間バッチが確実に走るよう、以下を設定する。

- システム設定 → ロック画面 → ディスプレイがオフのときは自動でスリープさせない
- `caffeinate -s` をバッチ実行中に起動し、スリープを抑止する
- 自動アップデートによる再起動を営業時間内に寄せる

---

## 4. 運用モデル

### 4.1 二相運用

```
 00:00    02:00          06:30   07:00        19:00      24:00
   │        │              │       │            │          │
   ├────────┴──────────────┴───────┤            │          │
   │      夜間バッチ相                │            │          │
   │   生成モデル常駐（RAM 大）        │            │          │
   │   誰も待っていない                │            │          │
   │                               ├────────────┤          │
   │                               │  営業時間相   │          │
   │                               │ 埋め込みのみ常駐│          │
   │                               │ 生成モデル不在  │          │
   │                               │ 即答（1秒未満）│          │
   │                               │            ├──────────┤
   │                               │            │  待機相    │
   │                               │            │ 全モデル解放 │
```

| 相 | 時間帯（既定） | 常駐モデル | LLM 生成 |
|---|---|---|---|
| 営業時間相 | 07:00 – 19:00 | 埋め込みのみ | 行わない |
| 待機相 | 19:00 – 02:00 | なし（アイドルで解放） | 行わない |
| 夜間バッチ相 | 02:00 – 06:30 | フェーズごとに1つ | 行う |

時間帯は設定画面で変更可能とする。

### 4.2 相の強制

営業時間中に生成モデルがロードされないことを、運用ではなく**実装で保証する**。

| ID | 要件 |
|---|---|
| R-101 | `AskDrive.Runtime.Mode` が現在の相を保持し、相遷移を一元管理する |
| R-102 | 生成 API の呼び出しは `Mode` のガードを通し、営業時間相では `{:error, :generation_disabled}` を返す |
| R-103 | 営業時間相への遷移時、Ollama に `keep_alive: 0` のダミーリクエストを送り、生成モデルを明示的にアンロードする |
| R-104 | 営業時間相の間、埋め込みモデルは `keep_alive: -1` で常駐させ、初回質問時のロード待ちをなくす |
| R-105 | `OLLAMA_MAX_LOADED_MODELS=1` を設定し、意図しない同時常駐を OS 側でも防ぐ |

---

## 5. システム構成

```
        ┌──────────────┐
        │  ブラウザ     │  LAN 内
        └──────┬───────┘
               │ WebSocket (LiveView)
   ┌───────────▼──────────────────────────────────────┐
   │  Phoenix アプリケーション (BEAM)                     │
   │                                                  │
   │  ┌─ 営業時間相 ────────────┐ ┌─ 夜間バッチ相 ──────┐ │
   │  │ ChatLive               │ │ Scheduler          │ │
   │  │ Answering（段階的応答）  │ │ Sync   → 抽出・分割  │ │
   │  │ Embed（質問のみ）       │ │ EmbedChunks        │ │
   │  │                        │ │ Generate（要約/QA） │ │
   │  │ 生成 API は封鎖          │ │ EmbedQuestions     │ │
   │  └────────────────────────┘ │ Verify（無効化整理） │ │
   │                             └────────────────────┘ │
   │  Runtime.Mode / Oban / AdminLive                   │
   └───┬──────────────┬───────────────────────┬─────────┘
       │              │                       │
 HTTPS │  In-Process (WAL)                    HTTP │
┌──────▼───────┐ ┌────▼────────┐    ┌─────────▼─────────┐
│ Google Drive │ │ SQLite3     │    │ Ollama :11434     │
│ API v3       │ │ + sqlite-vec│    │ 昼: 埋め込みのみ     │
│（夜間のみ）    │ │ + FTS5      │    │ 夜: 生成モデル       │
└──────────────┘ └─────────────┘    └───────────────────┘
```

### 5.1 レイヤー責務

| レイヤー | 責務 |
|---|---|
| `AskDrive.Runtime` | 相の管理、モデルのロード／アンロード制御 |
| `AskDrive.Drive` | OAuth、Drive API、URL 解析 |
| `AskDrive.Ingest` | 本文抽出、チャンク分割、チャンク埋め込み |
| `AskDrive.Batch` | 夜間バッチのフェーズ制御、予算管理、優先度決定 |
| `AskDrive.Generate` | 要約・想定QA・構造化抽出の生成 |
| `AskDrive.Answering` | 段階的応答、キャッシュ、未回答記録 |
| `AskDrive.Freshness` | 依存関係の追跡と無効化 |
| `AskDrive.LLM` | Ollama クライアント、同時実行数制御 |

---

## 6. 機能要件

### 6.1 Google アカウント連携

| ID | 要件 |
|---|---|
| F-101 | 設定画面から OAuth 2.0 認可フローを開始できる |
| F-102 | 要求スコープは `drive.readonly` と `userinfo.email` に限定する |
| F-103 | `access_type=offline` / `prompt=consent` でリフレッシュトークンを確実に取得する |
| F-104 | アクセストークンは期限の120秒前を過ぎたら自動更新する |
| F-105 | トークンは暗号化してデータベースに保存する |
| F-106 | 再認可が必要な状態を検知し、管理画面に再接続を促す表示を出す |
| F-107 | 「接続を解除」で Google 側のトークンを revoke し、ローカルの資格情報を削除する |
| F-108 | **夜間バッチ開始時にトークンの有効性を事前確認し、無効なら即座に管理者へ通知する**（無人実行のため、朝まで気づかない事態を避ける） |

Google は2回目以降の同意でリフレッシュトークンを返さないことがある。返らなかった場合は既存の値を温存し、上書きで消さないこと。

### 6.2 設定

単一行のレコードとして保持する。

#### 6.2.1 接続設定

| 項目 | 既定値 | 説明 |
|---|---|---|
| `drive_url` | なし | 取り込み対象のフォルダ／ファイル URL |
| `ollama_host` | `http://localhost:11434` | 推論サーバー。機材移行時はここだけ変える |

#### 6.2.2 モデル設定

| 項目 | 既定値 | 説明 |
|---|---|---|
| `embedding_model` | `bge-m3` | **変更時は全件再インデックス** |
| `embedding_dim` | 1024 | 埋め込み次元。モデルと一致必須 |
| `batch_model` | `qwen3:4b` | 夜間バッチの生成モデル |
| `batch_num_ctx` | 8192 | バッチ時のコンテキスト長 |

#### 6.2.3 バッチ設定

| 項目 | 既定値 | 説明 |
|---|---|---|
| `batch_start_at` | `02:00` | バッチ開始時刻 |
| `batch_deadline_at` | `06:30` | この時刻に未完でも生成を打ち切る |
| `business_hours` | `07:00`–`19:00` | 営業時間相 |
| `qa_per_chunk` | 5 | チャンクあたりの想定質問生成数 |
| `summary_enabled` | true | 文書／セクション要約を作るか |
| `extraction_enabled` | true | 構造化抽出を行うか |

#### 6.2.4 応答設定

| 項目 | 既定値 | 説明 |
|---|---|---|
| `tier1_threshold` | 0.90 | 想定QAを即答とみなすコサイン類似度 |
| `tier0_enabled` | true | 完全一致キャッシュを使うか |
| `tier2_enabled` | true | 原文抜粋へのフォールバックを行うか |
| `tier2_excerpt_count` | 3 | 抜粋として返すチャンク数 |
| `serve_stale_qa` | false | 無効化済みQAを警告付きで返すか |
| `allow_daytime_generation` | false | 営業時間中の生成を例外的に許可するか |

#### 6.2.5 バリデーション

- `drive_url` は Drive／Docs の URL 形式、または素の ID として解釈できること
- `batch_start_at < batch_deadline_at`、かつバッチ時間帯と営業時間帯が重ならないこと
- `embedding_model` 変更時は「全チャンクと全QAを削除して再構築します」という確認を挟む
- `batch_model` 変更時は「次回バッチで全件を再生成します」という確認を挟む

### 6.3 夜間バッチ

#### 6.3.1 フェーズ構成

**同一フェーズ内では1種類のモデルしかロードしない。** これによりメモリ使用のピークが「各モデルの合計」ではなく「最大値」になる。8GB 環境ではこの分離が成立の前提条件である。

| # | フェーズ | 常駐モデル | LLM | 内容 |
|---|---|---|---|---|
| 1 | 同期 | なし | 不要 | Drive 差分取得、本文抽出、チャンク分割 |
| 2 | 無効化 | なし | 不要 | 更新文書に依存する生成物を無効化 |
| 3 | チャンク埋め込み | 埋め込み | 不要 | 新規・更新チャンクのベクトル化 |
| 4 | 生成 | **生成** | 必要 | 要約・想定QA・構造化抽出 |
| 5 | 質問埋め込み | 埋め込み | 不要 | 生成された想定質問のベクトル化 |
| 6 | 検証 | なし | 不要 | 整合性確認、インデックス整理、統計記録 |

フェーズ3→4、4→5 の境界で、前フェーズのモデルを `keep_alive: 0` で明示的にアンロードしてから次をロードする。

```
RAM 使用量の推移（8GB / batch_model = qwen3:4b の場合）

 8GB ┤
 6GB ┤                    ┌──────────┐
 4GB ┤          ┌────┐    │  生成 4B   │    ┌────┐
 2GB ┤  ┌────┐  │埋込 │    │  +KV      │    │埋込 │  ┌────┐
 0GB ┼──┤同期 ├──┤1.2G├────┤  3.1G     ├────┤1.2G├──┤検証 ├─
      └──┴────┴──┴────┴────┴───────────┴────┴────┴──┴────┴
         1      2/3        4                5      6
```

#### 6.3.2 処理の優先度

一晩で全件を処理できるとは限らない（9.2 節）。生成フェーズは以下の順に処理し、締切時刻で打ち切る。

| 優先度 | 対象 | 理由 |
|---|---|---|
| 1 | 前日に未回答だった質問に関連するチャンク | 実需が確認されている |
| 2 | 更新により無効化されたQAの再生成 | 鮮度の回復。古い回答は配信できない |
| 3 | 新規追加されたチャンク | カバー範囲の拡大 |
| 4 | 参照回数の多いチャンクの再生成（上位モデルへ更新時） | 品質向上 |
| 5 | 残り全て | |

優先度1が最重要である。未回答質問が翌朝には答えられるようになる、という循環がこの設計の中心にある。

#### 6.3.3 同期フェーズ（LLM 不要）

```
1. drive_url から対象 ID を解決
2. フォルダなら files.list で再帰列挙（サブフォルダ含む）
3. modifiedTime を既存レコードと突合
4. 新規・更新分のみ取得 → 本文抽出 → 内容ハッシュ計算
5. ハッシュが前回と同一なら以降をスキップ
6. チャンク分割し、旧チャンクを置き換え
7. Drive から消えたファイルのレコードとチャンクを削除
```

| ID | 要件 |
|---|---|
| F-201 | `modifiedTime` が前回と同じファイルはスキップする |
| F-202 | 本文ハッシュが前回と同じ場合、チャンク再生成をスキップする |
| F-203 | Drive 上から削除されたファイルは、チャンク・QA・要約ごと削除する |
| F-204 | 1ファイルの失敗が同期全体を止めない。エラーは文書単位で記録する |
| F-205 | **このフェーズは LLM を使わないため、締切で打ち切らず必ず完走させる**（原文チャンクの鮮度は常に保証される） |

#### 6.3.4 対応ファイル形式と抽出方法

| MIME タイプ | 種別 | 抽出方法 |
|---|---|---|
| `application/vnd.google-apps.document` | Google ドキュメント | `files.export` → `text/plain` |
| `application/vnd.google-apps.spreadsheet` | Google スプレッドシート | `files.export` → xlsx → 全シートをテキスト化 |
| `application/vnd.google-apps.presentation` | Google スライド | `files.export` → `text/plain` |
| `application/pdf` | PDF | `pdftotext -layout` |
| `...wordprocessingml.document` | docx | `pandoc -t plain` |
| `...presentationml.presentation` | pptx | `pandoc -t plain` |
| `...spreadsheetml.sheet` | xlsx | `XlsxReader` で全シート走査 |
| `text/plain`, `text/markdown`, `text/csv`, `application/json` | テキスト系 | そのまま |
| `application/vnd.google-apps.folder` | フォルダ | 再帰対象。本文なし |
| 上記以外 | — | `skipped` として理由を記録 |

**スプレッドシートのテキスト化**：シート名を見出しとし、行ごとに `列名: 値` をタブ区切りで並べる。空行・空列は除去する。

**既知の制約**

- `files.export` は 10MB 上限。超える Google ドキュメントは `skipped` とする
- Google スプレッドシートの数式は計算結果の値として取り込まれる
- スキャン画像のみの PDF からはテキストが取れない
- パスワード保護されたファイルは `failed` とする

#### 6.3.5 チャンク分割

日本語・英語および日英混在文書に対応する分割処理を行う。

1. 見出し（Markdown の `#`、連続改行）で大きく区切る
2. 各ブロックを文末（日本語: `。` `！` `？` `\n`、英語: `[.!?]\s+`）で文に分割
3. 文を `chunk_size`（既定600文字）に達するまで詰める
4. 直前チャンクの末尾 `chunk_overlap`（既定100文字）を次チャンク先頭に重複させる
5. 単独で `chunk_size` を超える文は文字数/単語境界で強制分割する
6. 空白のみ・20字未満のチャンクは捨てる

各チャンクには文書名とセクション見出しを前置し、断片単体でも出典が分かる形にする。

#### 6.3.6 生成フェーズ

生成物は3種類。

**(a) 想定質問と回答（中核）**

チャンクごとに `qa_per_chunk` 件の「このチャンクから答えられる質問」と、その回答を生成する。検索は本文ではなく**この想定質問に対して**行う。
プロンプトでは**抜粋の主要言語（日本語または英語）に合わせて想定質問・回答を生成する**よう指示する（多言語混在文書にも自然に対応）。

```
system: あなたは社内文書から想定質問と回答を作成します。
        与えられた抜粋の主要言語（日本語または英語）に合わせて質問と回答を作成してください。
        与えられた抜粋だけを根拠にしてください。
        抜粋に書かれていない情報を補ってはいけません。
        JSON 配列のみを出力し、前置きやコードブロック記法は付けないでください。

user:   ## 文書名
        {文書名} / {セクション見出し}

        ## 抜粋
        {チャンク本文}

        この抜粋から確実に答えられる質問を {qa_per_chunk} 件作り、
        それぞれに回答を付けてください。
        形式: [{"question": "...", "answer": "..."}]
```

| ID | 要件 |
|---|---|
| F-301 | 出力が JSON として解釈できない場合、1回だけ再試行し、なお失敗ならそのチャンクを `failed` として記録し先へ進む |
| F-302 | 生成された回答が根拠チャンクに含まれない固有名詞・数値を含む場合、警告フラグを立てる（簡易な幻覚検出） |
| F-303 | 重複する想定質問（コサイン類似度 0.97 以上）は1件に統合する |
| F-304 | 各QAに根拠チャンクID、生成モデル名、生成日時を必ず記録する |

**(b) 要約**

文書単位・セクション単位の要約を生成する。

| ID | 要件 |
|---|---|
| F-311 | 要約は検索の絞り込みとUIの文書一覧表示にのみ使う |
| F-312 | **要約を回答の根拠として直接提示しない。** 小規模モデルの要約は数値・条件分岐・例外規定を落とすため、根拠は常に原文チャンクとする |

**(c) 構造化抽出**

チャンクから日付・金額・期間・担当者・型番などを抽出し、列として保存する。「契約日は」「金額はいくら」といった質問に、検索を介さず直接答えられるようにする。抽出スキーマは設定画面で定義可能とする。

#### 6.3.7 予算管理と打ち切り

| ID | 要件 |
|---|---|
| F-321 | 生成フェーズは1件処理するたびに残り時間を確認し、`batch_deadline_at` を過ぎたら新規着手を止める |
| F-322 | 処理中の1件は完了まで待つ（中途半端な生成物を残さない） |
| F-323 | 打ち切り時点の未処理キューは次回バッチに持ち越す |
| F-324 | フェーズ5（質問埋め込み）とフェーズ6（検証）は、打ち切り後も必ず実行する |
| F-325 | 直近5回の実測スループットから所要時間を推定し、開始前に「今夜処理できる見込み件数」を記録する |

#### 6.3.8 手動実行

管理画面から「今すぐバッチを実行」を起動できる。ただし営業時間相の場合は、生成モデルのロードでメモリを圧迫する旨を警告し、明示的な確認を求める。

### 6.4 営業時間中の応答

#### 6.4.1 段階的応答

```
質問
 │
 ├─ Tier 0 ── 正規化文字列の完全一致キャッシュ
 │              ヒット → 即答（埋め込み計算すら不要、数ミリ秒）
 │
 ├─ Tier 1 ── 想定QAへのベクトル検索（類似度 ≧ tier1_threshold）
 │              ヒット → 事前生成された回答を返す（1秒未満）
 │
 ├─ Tier 2 ── 原文チャンクへのハイブリッド検索
 │              ヒット → 該当箇所を抜粋として提示（LLM 生成なし）
 │
 └─ Tier 3 ── 該当なし
                未回答として記録し、翌朝の回答を予告
```

| ID | 要件 |
|---|---|
| F-401 | 各 Tier の判定順を守り、上位でヒットしたら下位を評価しない |
| F-402 | 応答には必ず Tier を示す表示を添える（後述） |
| F-403 | Tier 1 / 2 / 3 の質問は全て `question_log` に記録する |
| F-404 | **営業時間相では、いかなる Tier でも LLM による文章生成を行わない** |

#### 6.4.2 Tier 2 の位置づけ

Tier 2 は LLM を使わず、検索で見つかった原文チャンクを整形して提示する。文章として整っていないが、**原文そのものなので情報としては常に正確かつ最新**である。同期フェーズは LLM 不要で毎晩必ず完走するため（F-205）、原文チャンクの鮮度は QA より常に新しい。

UI 上は「該当しそうな箇所」として明確に区別し、回答と混同させない。

```
┌────────────────────────────────────────────┐
│ 直接の回答は見つかりませんでした。              │
│ 以下の箇所が関連しそうです。                    │
│                                            │
│ ▸ 営業規程.docx — 第3章 経費精算              │
│   交通費の精算は、実費を原則とし…              │
│   [Drive で開く]                            │
│                                            │
│ この質問を記録しました。明朝までに回答を用意します。│
└────────────────────────────────────────────┘
```

#### 6.4.3 未回答質問の扱い

| ID | 要件 |
|---|---|
| F-411 | Tier 2 / 3 に落ちた質問を、質問文・日時・到達 Tier・検索上位チャンクとともに記録する |
| F-412 | 翌夜のバッチは、これらの質問に関連するチャンクを最優先で処理する |
| F-413 | バッチで回答が生成された質問について、翌朝の管理画面に「解消された質問」として一覧表示する |
| F-414 | 同じ質問が繰り返し未回答になる場合、該当する文書が取り込み対象に含まれていない可能性を管理画面で示唆する |

#### 6.4.4 回答の提示

すべての回答に以下を必ず添える。

- **根拠文書名**と Drive へのリンク
- **回答の生成日時**（例: 「2026-09-24 03:12 時点の情報」）
- **生成に使ったモデル名**（管理画面でのみ表示。一般利用者には出さない）
- 根拠チャンクの展開表示

事前生成された回答を即答する以上、**それがいつの情報かを常に明示する**ことが安全上の要件である。

#### 6.4.5 営業時間中の生成（既定で無効）

`allow_daytime_generation` を有効にすると、Tier 3 の質問に対して管理者が手動で「今すぐ回答を生成」を実行できる。実行時は生成モデルがロードされるため、以下を行う。

- 実行前に必要メモリ量と現在の空きを表示し、確認を求める
- 実行中は他の質問を Tier 0 / 1 のみに制限する
- 完了後、生成モデルを即座にアンロードする

### 6.5 鮮度管理と無効化

事前生成型の最大のリスクは、**元文書が更新されたのに古い回答を自信を持って即答すること**である。素の RAG より危険なため、依存関係を明示的に追跡する。

```
document 更新
   └→ 所属 chunk を再生成（ハッシュ変化時）
        └→ その chunk を根拠とする qa_pairs を invalid に
             └→ その qa_pair を参照していた answer_cache を破棄
        └→ その chunk を含む doc_summaries を invalid に
```

| ID | 要件 |
|---|---|
| F-501 | 全ての生成物は根拠チャンクIDと、そのチャンクの内容ハッシュを保持する |
| F-502 | 同期フェーズでチャンクのハッシュが変化したら、依存する生成物を `stale` にする |
| F-503 | `stale` な QA は既定で Tier 1 から除外し、Tier 2 の原文抜粋にフォールバックさせる |
| F-504 | `serve_stale_qa` が有効な場合のみ、`stale` な QA を明確な警告表示付きで返す |
| F-505 | `stale` な生成物は次回バッチの優先度2で再生成する |
| F-506 | 文書が削除された場合、依存する生成物を即座に削除する（`stale` ではなく削除） |

`stale` を Tier 1 から外すと一時的にカバー率が下がるが、**古い回答を配信するより原文を見せるほうが安全である**という判断に基づく。

### 6.6 チャット画面

- 質問入力欄（Enter 送信、Shift+Enter で改行）
- 回答は即座に全文表示（ストリーミング不要）
- 回答直下に出典リスト（文書名・Drive リンク・展開可能な原文）
- 回答の生成日時を表示
- Tier 2 の場合は「関連しそうな箇所」として明確に区別
- Tier 3 の場合は記録した旨と、翌朝の回答予定を案内
- 「会話をリセット」で履歴を破棄
- Drive 未接続・インデックス0件・前夜のバッチ失敗時は、状況と次にすべきことを表示

会話履歴は文脈補完にのみ使う。直前の質問を参照する代名詞（「それ」「その場合」）の解決は、履歴中の質問文を連結して検索に使う形で行い、LLM は使わない。

### 6.7 管理画面

| 区画 | 内容 |
|---|---|
| バッチ状況 | 直近の実行結果、所要時間、フェーズ別内訳、打ち切りの有無 |
| カバレッジ | 総チャンク数 / QA生成済み / stale / 未処理 の件数と割合 |
| 未回答質問 | 直近の Tier 2・3 の質問一覧、繰り返し発生している質問 |
| 解消された質問 | 前夜のバッチで回答可能になった質問 |
| 文書一覧 | 各文書のステータス、最終同期日時、QA件数、エラー |
| モデル状態 | 現在の相、ロード中のモデル、Ollama 疎通状況 |
| 生成物の世代 | 生成に使ったモデル別の件数（増設後の再生成計画に使う） |

---

## 7. データモデル

```
settings (1行)
google_accounts (1行)

documents ──< chunks ──< qa_pairs
    │           │
    │           └──< extractions
    └──< doc_summaries

answer_cache ──> qa_pairs
question_log
batch_runs ──< batch_phase_stats
```

### 7.1 `settings` / `google_accounts`

6.2 節および 6.1 節の通り。いずれもシングルトン。`access_token` と `refresh_token` は暗号化して保存する。

### 7.2 `documents`

| カラム | 型 | 説明 |
|---|---|---|
| `drive_file_id` | string | Drive ファイルID（unique） |
| `name` | string | ファイル名 |
| `mime_type` | string | MIME タイプ |
| `path` | string | Drive 上のフォルダ階層（表示用） |
| `web_view_link` | string | Drive で開く URL |
| `modified_time` | utc_datetime | Drive 側の更新日時 |
| `content_hash` | string | 抽出本文の SHA-256 |
| `size_bytes` | bigint | サイズ |
| `status` | string | `pending` / `fetching` / `indexed` / `skipped` / `failed` |
| `error` | text | 失敗理由 |
| `synced_at` | utc_datetime | 最終同期日時 |

### 7.3 `chunks`

| カラム | 型 | 説明 |
|---|---|---|
| `document_id` | FK | 親文書。削除時カスケード |
| `position` | integer | 文書内の順序 |
| `heading` | string | セクション見出し |
| `content` | text | チャンク本文 |
| `content_hash` | string | 本文の SHA-256。無効化判定に使う |
| `token_estimate` | integer | 概算トークン数 |
| `embedding` | blob (float32[]) | 埋め込みベクトル（`sqlite-vec` 連携） |
| `reference_count` | integer | 回答の根拠になった回数。優先度4に使う |

### 7.4 `qa_pairs`（中核）

| カラム | 型 | 説明 |
|---|---|---|
| `document_id` | FK | 所属文書（カスケード削除。チャンク再生成時も保持） |
| `chunk_id` | FK (nullable) | 根拠チャンク（ON DELETE SET NULL。チャンク更新時の追跡用） |
| `question` | text | 想定質問 |
| `answer` | text | 事前生成された回答 |
| `question_embedding` | blob (float32[]) | 質問文のベクトル。**検索対象はこれ** |
| `source_hash` | string | 生成時の根拠チャンクのハッシュ |
| `status` | string | `active` / `stale` / `failed` |
| `hallucination_flag` | boolean | 根拠外の固有名詞・数値を含む疑い |
| `generated_by` | string | 生成モデル名 |
| `generated_at` | utc_datetime | 生成日時 |
| `hit_count` | integer | 回答に使われた回数 |

> **チャンク更新と stale の整合性**：
> 文書同期時にチャンクが再分割・再生成された場合、`chunk_id` は一時的に null になるか新チャンクに再突合されるが、`qa_pairs` レコード自体は削除されず `status = 'stale'` となる。文書自体が Drive から削除された場合のみ、`document_id` のカスケードにより `qa_pairs` も物理削除される。

### 7.5 `answer_cache`

| カラム | 型 | 説明 |
|---|---|---|
| `normalized_question` | string | 正規化した質問文（unique）。Tier 0 の鍵 |
| `qa_pair_id` | FK | 参照した QA（削除時カスケード） |
| `hit_count` | integer | ヒット回数 |
| `last_hit_at` | utc_datetime | 最終ヒット日時 |

### 7.6 `question_log`

| カラム | 型 | 説明 |
|---|---|---|
| `question` | text | 質問文 |
| `question_embedding` | blob (float32[]) | ベクトル。類似質問の集約に使う |
| `tier_reached` | integer | 0〜3 |
| `candidate_chunk_ids` | json (integer[]) | 検索上位のチャンク。バッチの優先処理対象 |
| `resolved_at` | utc_datetime | バッチで回答可能になった日時 |
| `resolved_qa_id` | FK | 解消に使われた QA |
| `asked_at` | utc_datetime | 質問日時 |

### 7.7 `doc_summaries` / `extractions`

| `doc_summaries` | 型 | 説明 |
|---|---|---|
| `document_id` | FK | 対象文書（削除時カスケード） |
| `scope` | string | `document` / `section` |
| `heading` | string | セクション名 |
| `summary` | text | 要約本文 |
| `source_hashes` | json (string[]) | 根拠チャンクのハッシュ群 |
| `status` | string | `active` / `stale` |
| `generated_by` | string | 生成モデル名 |

| `extractions` | 型 | 説明 |
|---|---|---|
| `document_id` | FK | 対象文書（削除時カスケード） |
| `chunk_id` | FK (nullable) | 根拠チャンク（ON DELETE SET NULL） |
| `key` | string | 項目名（例: `contract_date`） |
| `value` | string | 値 |
| `value_type` | string | `date` / `money` / `text` / `number` |
| `status` | string | `active` / `stale` |

### 7.8 `batch_runs` / `batch_phase_stats`

| `batch_runs` | 型 |
|---|---|
| `started_at` / `finished_at` | utc_datetime |
| `status` | `running` / `completed` / `deadline_reached` / `failed` |
| `model_used` | string |
| `chunks_processed` / `qa_generated` / `qa_invalidated` | integer |
| `questions_resolved` | integer |
| `queue_remaining` | integer |
| `error` | text |

`batch_phase_stats` はフェーズ別の所要時間と件数を保持し、F-325 の所要時間推定に使う。

### 7.9 インデックスと仮想テーブル

```sql
-- 1. ベクトル検索仮想テーブル (sqlite-vec)
-- 想定質問ベクトル検索（主経路）
CREATE VIRTUAL TABLE vec_qa_pairs USING vec0(
  qa_pair_id INTEGER PRIMARY KEY,
  question_embedding float[1024] distance_metric=cosine
);

-- Tier 2 原文チャンクベクトル検索
CREATE VIRTUAL TABLE vec_chunks USING vec0(
  chunk_id INTEGER PRIMARY KEY,
  embedding float[1024] distance_metric=cosine
);

-- 2. 全文・キーワード検索仮想テーブル (SQLite FTS5 trigram)
CREATE VIRTUAL TABLE chunks_fts USING fts5(
  content,
  heading,
  content=chunks,
  content_rowid=id,
  tokenize='trigram'
);

-- 3. B-Tree インデックス
-- Tier 0
CREATE UNIQUE INDEX answer_cache_normalized_question_idx ON answer_cache (normalized_question);
CREATE INDEX answer_cache_qa_pair_id_idx ON answer_cache (qa_pair_id);

-- 無効化の追跡
CREATE INDEX qa_pairs_document_id_status_idx ON qa_pairs (document_id, status);
CREATE INDEX qa_pairs_chunk_id_status_idx ON qa_pairs (chunk_id, status);
CREATE INDEX qa_pairs_status_generated_by_idx ON qa_pairs (status, generated_by);

-- バッチの優先度決定
CREATE INDEX question_log_resolved_at_asked_at_idx ON question_log (resolved_at, asked_at);
```

`qa_pairs` の検索時は `vec_qa_pairs` から KNN 近傍検索を行い、`qa_pairs` テーブルと JOIN して `status = 'active'` のもののみを即答として採用する。これにより `stale` な QA が回答に混入するのを防ぐ。

---

## 8. 外部インターフェース

### 8.1 Google Drive API v3

| 用途 | エンドポイント |
|---|---|
| ファイル列挙 | `GET /drive/v3/files?q='<ID>' in parents and trashed=false` |
| メタデータ取得 | `GET /drive/v3/files/<ID>?fields=id,name,mimeType,modifiedTime,size,webViewLink` |
| バイナリ取得 | `GET /drive/v3/files/<ID>?alt=media` |
| Workspace 形式の変換取得 | `GET /drive/v3/files/<ID>/export?mimeType=<変換先>` |
| トークン更新 | `POST https://oauth2.googleapis.com/token` |
| トークン失効 | `POST https://oauth2.googleapis.com/revoke` |

列挙時は `pageSize=1000` でページングし、`supportsAllDrives=true` と `includeItemsFromAllDrives=true` を付ける。429 と 5xx は指数バックオフ（初回1秒、最大5回、ジッター付き）で再試行する。ダウンロードや export は並列実行されるため、Client 層でレート制限（最大並列度4、過密リクエスト抑制）を施す。

**Drive API を呼ぶのは夜間バッチの同期フェーズのみ**であり、営業時間中に外部通信は発生しない。

### 8.2 Ollama API

| 用途 | エンドポイント | 使用フェーズ |
|---|---|---|
| 埋め込み生成 | `POST /api/embed` | 昼（質問）/ 夜（チャンク・想定質問） |
| 回答生成 | `POST /api/generate` | 夜のみ |
| モデル一覧 | `GET /api/tags` | 設定画面 |
| 疎通確認 | `GET /api/version` | 常時 |

**モデルのロード制御**

| 目的 | 方法 |
|---|---|
| 常駐させる | `keep_alive: -1` を指定してリクエスト |
| 即アンロード | `keep_alive: 0` の空リクエストを送る |
| 同時常駐の抑止 | 環境変数 `OLLAMA_MAX_LOADED_MODELS=1` |

生成フェーズでは `stream: false` で一括受信する。ストリーミングの行バッファ処理が不要になり、実装が単純化する。また長文コンテキスト生成時のタイムアウトを防ぐため、HTTP クライアント（Req）の `receive_timeout` は 180 秒（3分）に設定する。

---

## 9. 非機能要件

### 9.1 メモリ配分

**営業時間相**

| 用途 | 8GB | 16GB | 32GB 以上 |
|---|---|---|---|
| macOS | 3〜4GB | 3〜4GB | 3〜4GB |
| SQLite3 + BEAM | 0.3〜0.7GB | 0.8〜1.5GB | 1〜2GB |
| 埋め込みモデル（bge-m3） | 1.2GB | 1.2GB | 1.2GB |
| **合計** | **約5GB** | 約6〜7GB | 約7〜8GB |

デーモンレスな SQLite3 のため常駐 DB プロセスのメモリ消費がなく、8GB 環境でもさらに余裕が生まれる。

**夜間バッチ相（生成フェーズ）**

| 用途 | 8GB | 16GB | 32GB 以上 |
|---|---|---|---|
| macOS | 3〜4GB | 3〜4GB | 3〜4GB |
| SQLite3 + BEAM | 0.3〜0.7GB | 0.8〜1.5GB | 1〜2GB |
| 生成モデル | **4B/Q4 約2.5GB** | 8B/Q4 約4.7GB | 14〜32B |
| KV キャッシュ | 約0.6GB | 約1.2GB | 2GB 以上 |
| **合計** | **約7〜8GB** | 約10〜11GB | 余裕あり |

> **訂正**：前回の検討で「8GB でも夜間は 8B が使える」と述べたが、macOS 自体の消費を加味すると 8B（約4.7GB）では合計が 9.5GB 前後となり、スワップが発生して実用にならない。**8GB では夜間も 4B クラスが上限**とする。8B 以上は 16GB 以降。

**KV キャッシュの削減**

生成フェーズでは以下を設定する。

```bash
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0   # KV キャッシュを約半分に
export OLLAMA_NUM_PARALLEL=1       # 並列数ぶん KV が倍増するため
export OLLAMA_MAX_LOADED_MODELS=1
```

### 9.2 バッチのスループット予算

**これが本アーキテクチャにおける実質的な制約である。**

前提: 1チャンクあたり想定QA5件＋要約で、出力約900トークン。

| 生成モデル | 生成速度（目安） | 4.5時間で処理できるチャンク数 |
|---|---|---|
| 4B / Q4（8GB） | 約15 tok/s | **250〜350** |
| 8B / Q4（16GB） | 約8 tok/s | 130〜180 |
| 14B / Q4（32GB） | 約5 tok/s | 80〜120 |

大きいモデルほど一晩の処理量は減る。**初回構築は小さいモデルで全件を広くカバーし、その後アクセスの多い文書だけ大きいモデルで作り直す**、という二段構えを推奨する。

| ID | 要件 |
|---|---|
| N-201 | 初回構築時、全件処理に要する夜数を見積もって管理画面に表示する |
| N-202 | 全チャンクの生成が完了するまで、カバレッジを割合で表示する |
| N-203 | 生成物にモデル名を保持し、上位モデルでの選択的再生成を可能にする |

### 9.3 性能目標

| 指標 | 目標 |
|---|---|
| Tier 0 応答 | 50ms 以内 |
| Tier 1 応答 | 500ms 以内 |
| Tier 2 応答 | 1秒以内 |
| 営業時間中の同時利用者数 | 10名（生成がないため制約が緩い） |
| 同期フェーズ（1000ファイル） | 60分以内 |

### 9.4 品質目標

| 指標 | 目標 | 測定 |
|---|---|---|
| Tier 0+1 到達率 | 運用3ヶ月で 70% 以上 | `question_log` の集計 |
| stale QA の滞留 | 24時間以内に解消 | 無効化から再生成までの時間 |
| 幻覚フラグ率 | 5% 未満 | F-302 の集計 |

Tier 0+1 到達率は運用とともに上がる。未回答質問が翌夜に解消される循環が機能しているかの主要な指標となる。

### 9.5 並列度

| 対象 | 8GB | 16GB 以上 | 制御方法 |
|---|---|---|---|
| Drive ダウンロード | 4 | 8 | Oban キュー |
| 本文抽出（外部コマンド） | 2 | 4 | Oban キュー |
| チャンク埋め込み | 1 | 2 | `LLM.Semaphore` |
| 生成（夜間） | 1 | 1 | `LLM.Semaphore` |
| `OLLAMA_NUM_PARALLEL` | 1 | 1 | 環境変数 |

生成の並列化は行わない。KV キャッシュが並列数ぶん倍増し、スループットは向上しないため。

### 9.6 セキュリティ

| ID | 要件 |
|---|---|
| N-601 | 文書本文・質問・回答をインターネットに送出しない |
| N-602 | OAuth トークンを暗号化して保存する |
| N-603 | クライアントシークレットは環境変数から読み、リポジトリに含めない |
| N-604 | LAN 内アクセスを前提とし、外部公開時は別途認証を前段に置く |
| N-605 | Drive の要求スコープを `drive.readonly` に限定する |
| N-606 | ログに文書本文・トークン・質問文を出力しない |
| N-607 | 管理画面と一般利用画面を分離し、`question_log` の閲覧を管理者に限定する |

---

## 10. エラー処理

| 状況 | 挙動 | 表示 |
|---|---|---|
| Ollama 未起動（昼） | Tier 0 のみ動作 | 起動コマンドを添えて案内 |
| Ollama 未起動（夜） | バッチを失敗として記録 | 翌朝の管理画面に警告 |
| モデル未取得 | バッチ開始前に検知して中止 | `ollama pull <モデル名>` を案内 |
| 生成モデルが OOM | バッチを中止し、生成済み分は保持 | より小さいモデルへの変更を促す |
| バッチが締切超過 | 生成を打ち切り、後続フェーズは実行 | 未処理件数と持ち越しを表示 |
| Drive 未接続 | 同期を開始しない | 接続ボタンへ誘導 |
| リフレッシュトークン失効 | バッチ開始前に検知して中止 | 再接続を促す |
| Drive API 429 / 5xx | 指数バックオフで最大5回再試行 | 進捗に「再試行中」 |
| 個別ファイルの抽出失敗 | その文書のみ `failed`、同期は継続 | 文書一覧に理由を表示 |
| JSON 生成の失敗 | 1回再試行後、該当チャンクを `failed` | 管理画面に件数表示 |
| バッチが2夜連続で失敗 | 回答の鮮度が落ちる旨を利用者側にも表示 | チャット画面上部に帯表示 |
| Mac がスリープしてバッチ未実行 | 未実行を検知 | スリープ設定の確認を案内 |

---

## 11. 既知の制約

1. **未知の質問には当日中に答えられない。** Tier 2 の原文抜粋が当日の最大の応答であり、完成した回答は翌朝になる。
2. **一晩の処理量に上限がある。** 8GB / 4B で 250〜350 チャンク程度。初回構築には文書量に応じて複数夜を要する。
3. **Drive のアクセス権は反映されない。** 取り込んだ文書はチャットにアクセスできる全員が読める。機密文書を含むフォルダを指定しないこと。
4. **事前生成の品質は生成時のモデルに固定される。** 8GB 期間に 4B で作った QA は、増設して再生成するまでその品質のままである。
5. **スキャン PDF は読めない。** OCR は対象外。
6. **表の理解は限定的。** スプレッドシートはテキスト化して渡すため、複雑な集計や大きな表では精度が落ちる。
7. **日本語キーワード検索の特性。** SQLite FTS5 の trigram トークナイザは部分一致に強いが、短文クエリ（1〜2文字）ではインデックスが効きにくいため LIKE 部分一致等のフォールバックで補う。
8. **画像・図表の内容は失われる。**
---

## 12. デプロイと運用手順

Mac mini（Apple Silicon / macOS）へのデプロイおよび運用管理は、統一管理スクリプト **`./app.sh`** を通じて行います。

### 12.1 統合管理スクリプト（`app.sh`）

`./app.sh` を引数なしで実行するとヘルプが表示されます。

```bash
# ヘルプ表示（引数なし / --help）
./app.sh

# アプリケーション直接起動・停止・状態確認
./app.sh start              # フォアグラウンド起動（非デーモン）
./app.sh stop               # 停止
./app.sh restart            # 再起動
./app.sh status             # Ollama・プロセス・launchd・HTTPステータス確認

# デプロイ・初期設定
./app.sh setup              # 初期環境構築（scripts/initial-setup.sh 実行）
./app.sh deploy             # 最新コード取得・マイグレーション・再ビルド（scripts/deploy.sh 実行）

# macOS 常駐サービス管理（launchd）
./app.sh service install    # launchd plist 登録・常駐化
./app.sh service start      # launchd サービス開始
./app.sh service stop       # launchd サービス停止
./app.sh service restart    # launchd サービス再起動
./app.sh service status     # launchd サービス稼働確認
./app.sh service uninstall  # launchd 登録解除
```

### 12.2 デプロイ方式の概要

```
[開発機 / リポジトリ]
       │
       │ git push
       ▼
[本番機 Mac mini]
  1. git clone <repo_url> ask-drive && cd ask-drive
  2. ./app.sh setup                  # 初期依存確認、mise、Ollamaモデル、DB初期化
  3. .env.prod に機密情報（OAuth・暗号化キー）を設定
  4. ./app.sh service install        # launchd 登録＆常駐自動起動
```

### 12.3 初回セットアップフロー（`scripts/initial-setup.sh` / `./app.sh setup`）

初回セットアップスクリプトが行う処理：

1. **システム必須ツールの検証・導入**:
   - Homebrew の存在確認
   - 抽出用 CLI の導入（`poppler` [pdftotext], `pandoc`, `sqlite3`）
   - `sqlite-vec`（Mac ARM64 用 dynamic library / `vec0.dylib`）の配置確認
2. **言語ランタイムのセットアップ**:
   - `mise` または `asdf` を介して `.tool-versions` の Erlang/OTP 28 および Elixir 1.20 をインストール
3. **Ollama ランタイム & モデルの準備**:
   - Ollama サービスの起動確認
   - 必要モデルの事前取得: `ollama pull bge-m3` および `ollama pull qwen3:4b`
4. **環境設定ファイルのテンプレート生成**:
   - `.env.prod.example` から `.env.prod` を生成（`SECRET_KEY_BASE` や `ASK_DRIVE_ENCRYPTION_KEY` の自動生成ヘルパー呼び出し）
5. **Elixir ビルド & DB マイグレーション**:
   - `mix deps.get --only prod`
   - `MIX_ENV=prod mix assets.deploy`
   - `MIX_ENV=prod mix ecto.setup`（DB テーブル作成、sqlite-vec 仮想テーブル構築、初期 seed）
   - `MIX_ENV=prod mix release`（Mix Release による単体実行バイナリ生成）

### 12.4 日常の更新・再デプロイフロー（`scripts/deploy.sh` / `./app.sh deploy`）

コード修正やバージョンアップ時の更新手順：

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> 最新コードの取得"
git pull origin main

echo "==> 依存関係の更新とアセットビルド"
mix deps.get --only prod
MIX_ENV=prod mix assets.deploy

echo "==> DB マイグレーション"
MIX_ENV=prod mix ecto.migrate

echo "==> リリースのビルド"
MIX_ENV=prod mix release --overwrite

echo "==> サービスの再起動"
./app.sh service restart

echo "==> ヘルスチェック確認"
sleep 3
curl -f http://localhost:4000/api/health || exit 1
echo "デプロイが正常に完了しました。"
```

### 12.5 環境変数管理（`.env.prod`）

本番稼働に必要な環境変数は、リポジトリに含めず `.env.prod` または launchd の `EnvironmentVariables` に定義する。

| 環境変数名 | 説明 | 例 / 生成方法 |
|---|---|---|
| `PHX_SERVER` | Phoenix HTTP サーバの起動フラグ | `true` |
| `PORT` | 待ち受けポート番号（社内 LAN 向け） | `4000` |
| `PHX_HOST` | ホスト名または LAN 内 IP | `ask-drive.local` または `192.168.x.x` |
| `SECRET_KEY_BASE` | Phoenix セッション署名鍵 | `mix phx.gen.secret` で生成 |
| `ASK_DRIVE_ENCRYPTION_KEY` | OAuth トークン暗号化用 256bit 鍵 | `mix ask_drive.gen.key` で生成（Base64） |
| `GOOGLE_CLIENT_ID` | Google Cloud OAuth クライアント ID | `xxx.apps.googleusercontent.com` |
| `GOOGLE_CLIENT_SECRET` | Google Cloud OAuth クライアントシークレット | `GOCSPX-xxx` |
| `OLLAMA_HOST` | Ollama API エンドポイント | `http://localhost:11434` |
| `DATABASE_PATH` | SQLite DB ファイルパス | `/Users/username/data/ask_drive_prod.db` |

### 12.5 macOS 常駐（launchd）とスリープ管理

1. **常駐 plist の設定例（`com.askdrive.server.plist`）**:
   - 標準出力・標準エラーログを `log/ask_drive.log` にローテーション出力
   - プロセス停止時の自動再起動
2. **夜間バッチ中のスリープ抑止**:
   - バッチ実行中（21:00〜）は `caffeinate -s` を GenServer 経由で呼び出し、処理完了までシステムスリープを一時抑止する。
3. **バックアップ運用**:
   - SQLite3 のオンラインバックアップ機能を利用し、日次で DB スナップショットを退避（`sqlite3 /path/to/ask_drive_prod.db ".backup /path/to/backups/ask_drive_$(date +%Y%m%d).db"`）。

---

## 13. 構築計画

ToDo リスト（`ask-drive-todo.md`）の全 14 フェーズ（Phase 0〜13）と対応。

| フェーズ | 内容 | 完了条件 |
|---|---|---|
| 0 | 環境準備 | 各種 CLI / SQLite3 / sqlite-vec / Ollama の稼働と動作検証 |
| 1 | プロジェクト骨格 | Phoenix・SQLite3・Oban（Lite）が起動し疎通する |
| 2 | データモデル | マイグレーションとスキーマ作成、sqlite-vec 連携確認 |
| 3 | 暗号化と Google OAuth | トークン暗号化保存と OAuth 認可フロー完走 |
| 4 | Drive 同期 | ファイル列挙、差分検知、ダウンロード・エクスポート |
| 5 | 本文抽出 | 各形式（Doc, Sheet, Slide, PDF, Office, Text）の本文抽出 |
| 6 | チャンク分割と埋め込み | チャンク分割と bge-m3 によるベクトル化保存 |
| 7 | Tier 2 検索とチャット画面 | ハイブリッド検索（sqlite-vec + FTS5）と LiveView チャット UI |
| 8 | 生成フェーズ | Ollama 4B による想定QA・要約生成と保存 |
| 9 | 相制御とスケジューラ | 昼夜相の強制、モデル切り替え、Oban バッチ制御 |
| 10 | Tier 0 / 1 と鮮度管理 | キャッシュ即答、想定QA検索、stale 無効化追跡 |
| 11 | 未回答の循環と管理画面 | 未回答質問の優先解消ループ、AdminLive 管理UI |
| 12 | 運用整備 | launchd 常駐、スリープ抑止（caffeinate）、本番リリーススクリプト |
| 13 | 増設後の調整 | RAM 増設時の上位モデル（8B/14B）移行と品質測定 |

Phase 7 完了時点で「原文検索が使える社内検索」として実運用を開始し、実際の質問ログを収集しながら Phase 8 以降へ進む構成になっている。

---

## 14. 拡張候補

- キーワード検索の形態素解析（MeCab / Lindera 等の SQLite 拡張）検討
- 回答への評価（良い／悪い）の蓄積と、低評価QAの優先再生成
- 想定質問のクラスタリングによる、文書のカバー漏れ検出
- 構造化抽出スキーマのUIからの定義
- Slack / メールなど Drive 以外の知識源の追加
- スキャン PDF の OCR 対応
- バッチ結果の日次サマリーメール通知

