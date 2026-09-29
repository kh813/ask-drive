# AskDrive 実装 ToDo リスト

対応仕様書: `ask-drive-spec.md`
作成日: 2026-09-28

全 15 フェーズ / 全 146 タスク。各フェーズは最大 10 タスクで、最終タスクは必ずビルドゲート。

---

## ビルドゲートの定義

**各フェーズの最終タスク。これが通るまで次のフェーズに進まない。**

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix hex.audit
```

| 手順 | |
|---|---|
| 1 | 上記を順に実行する |
| 2 | 警告・エラー・テスト失敗・脆弱性勧告が 1 件でもあれば修正する |
| 3 | 修正したら **1 から全て実行し直す**（部分的な再実行では見落とす） |
| 4 | 全て通ったら `git commit -m "Phase N: <フェーズ名>"` |
| 5 | コミットできた時点でフェーズ完了とする |

`mix compile --warnings-as-errors` を外さないこと。Elixir の警告の大半（未使用変数、到達不能節、非推奨 API）は実バグの前兆であり、後半フェーズで潰すほど高くつく。

---

## Phase 0 — 環境準備

コードは書かない。全てコマンドで確認できる状態にする。

- [x] 0-1 Xcode Command Line Tools と Homebrew を導入する
- [x] 0-2 mise（または asdf）で Elixir 1.20 / Erlang 28 を導入し、`.tool-versions` に固定する
- [x] 0-3 SQLite 3.45+ を確認し、`sqlite3 :memory: "PRAGMA compile_options;"` で FTS5 が有効なことを通す
- [x] 0-4 `sqlite-vec`（Mac ARM64 用拡張）を導入し、`sqlite3 :memory: ".load vec0" "SELECT vec_version();"` を通す
- [x] 0-5 `brew install poppler pandoc` を実行し、`pdftotext -v` と `pandoc -v` を通す
- [x] 0-6 Ollama を**ネイティブ**で導入する（Docker は不可）
- [x] 0-7 `ollama pull bge-m3` と `ollama pull qwen3:4b` を実行する
- [x] 0-8 `/api/embed` に 2 要素の配列を投げ、1024 次元のベクトルが 2 本返ることを確認する
- [x] 0-9 Google Cloud Console でプロジェクト作成 → Drive API 有効化 → OAuth クライアント（ウェブ）作成 → リダイレクト URI `http://localhost:4000/auth/google/callback` 登録 → 同意画面に `drive.readonly` と `userinfo.email` を設定
- [x] 0-10 **検証ゲート**: 0-1〜0-9 の確認コマンドと出力を `docs/env-check.md` に記録する

> ビルドゲートは Phase 1 から。このフェーズはまだ Mix プロジェクトが無い。

**完了条件**: 全ての確認コマンドが再現可能な形で記録されている。

---

## Phase 1 — プロジェクト骨格

- [x] 1-1 `mix phx.new ask_drive --database sqlite3` でプロジェクトを生成する
- [x] 1-2 `mix.exs` に `oban ~> 2.24` / `req ~> 0.7` / `xlsx_reader ~> 0.8` を追加する（`ecto_sqlite3` は標準同梱）
- [x] 1-3 `phoenix_live_view` の下限を `~> 1.2.9` に引き上げる（CVE-2026-64941 / CVE-2026-58228 対策）
- [x] 1-4 `mix hex.outdated` を実行し、仕様書 3.3 節との差分を確認する。差分があれば**仕様書を先に更新**する
- [x] 1-5 Repo の接続時フック（`after_connect` または config）を設定し、`sqlite-vec` 拡張の自動ロードと WAL モード有効化を構成する
- [x] 1-6 Oban を supervision tree に追加し、`engine: Oban.Engines.Lite` とキュー `sync` / `extract` / `embed` / `generate` を定義する
- [x] 1-7 `runtime.exs` で `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `ASK_DRIVE_ENCRYPTION_KEY` / `OLLAMA_HOST` を読む。未設定なら起動時に明示的に落とす
- [x] 1-8 `AskDrive.HealthCheck` GenServer の骨格を作る（Ollama `/api/version`、`pdftotext`、`pandoc`、`sqlite-vec` の動作確認）
- [x] 1-9 `README.md` に Phase 0 のセットアップ手順を転記する
- [x] 1-10 **ビルドゲート**

**完了条件**: `mix phx.server` が起動し、`/` が表示され、ヘルスチェックのログが出る。

---

## Phase 2 — データモデル

- [x] 2-1 マイグレーション: `sqlite-vec` 仮想テーブル（`vec_qa_pairs` / `vec_chunks` float[1024] cosine）と FTS5 仮想テーブル（`chunks_fts` tokenize='trigram'）
- [x] 2-2 マイグレーション: `settings`（シングルトン）/ `google_accounts`
- [x] 2-3 マイグレーション: `documents` / `chunks`（`content_hash`、親文書カスケード削除、embedding BLOB）
- [x] 2-4 マイグレーション: `qa_pairs`（`document_id` カスケード、`chunk_id` nullable/ON DELETE SET NULL、`question_embedding` BLOB、`source_hash`、`status`、`generated_by`）
- [x] 2-5 マイグレーション: `answer_cache`（`qa_pair_id` カスケード）/ `question_log`
- [x] 2-6 マイグレーション: `doc_summaries` / `extractions` / `batch_runs` / `batch_phase_stats`
- [x] 2-7 マイグレーション: 仕様書 7.9 節の B-Tree インデックス一式（`answer_cache` ユニークインデックス、無効化追跡インデックス含む）
- [x] 2-8 Ecto スキーマを全テーブル分作る（float32 BLOB 相互変換ヘルパー含む）
- [x] 2-9 `AskDrive.Settings` コンテキスト（シングルトン取得と更新、バリデーション）と seeds
- [x] 2-10 **ビルドゲート**

**完了条件**: `mix ecto.reset` が通り、`chunks` / `vec_chunks` にダミーのベクトルを insert してコサイン距離で近傍検索できる。

---

## Phase 3 — 暗号化と Google OAuth

`ueberauth` は使わない（仕様書 3.4.1）。

- [x] 3-1 `AskDrive.Encrypted.Binary` カスタム `Ecto.Type` を実装する（AES-256-GCM / `:crypto.crypto_one_time_aead`）
- [x] 3-2 鍵生成用の Mix タスク `mix ask_drive.gen.key` を作る
- [x] 3-3 `google_accounts` のトークン 2 カラムに暗号化型を適用し、往復テストを書く
- [x] 3-4 `AskDrive.Drive.OAuth.authorize_url/1` を実装する（`access_type=offline`、`prompt=consent`、`state`）
- [x] 3-5 認可開始とコールバックのコントローラ・ルートを作り、`state` をセッションで照合する
- [x] 3-6 `exchange_code/1`（コード → トークン）を実装する
- [x] 3-7 `refresh/1` を実装し、期限 120 秒前で自動更新する。リフレッシュトークンが返らない場合は既存値を温存する
- [x] 3-8 `invalid_grant` を専用のエラーとして分類し、再認可要求フラグを立てる
- [x] 3-9 `revoke/0`（接続解除）を実装する
- [x] 3-10 **ビルドゲート**

**完了条件**: ブラウザで Google 認可を通し、`google_accounts` に暗号化されたリフレッシュトークンが保存される。DB を直接見て平文でないことを確認する。

---

## Phase 4 — Drive 同期フェーズ

- [x] 4-1 `AskDrive.Drive.Url.parse/1`（仕様書 6.2.5 の全 URL 形式）とテスト
- [x] 4-2 `AskDrive.Drive.Client` の基盤（トークン注入、`supportsAllDrives=true`、並列度・過密リクエスト制御）
- [x] 4-3 429 / 5xx の指数バックオフ（初回 1 秒・最大 5 回・ジッター）
- [x] 4-4 `list_files/1`（`pageSize=1000` のページング、サブフォルダ再帰、`path` の組み立て）
- [x] 4-5 `get_metadata/1` と `download/1`（`alt=media`）
- [x] 4-6 `export/2`（Workspace 形式の変換取得、10MB 超の検知）
- [x] 4-7 `AskDrive.Batch.SyncWorker`（Oban）: 列挙 → `modifiedTime` 突合 → 差分のみ後続へ
- [x] 4-8 Drive から消えたファイルのレコードとチャンク・QAを削除する
- [x] 4-9 ファイル単位の失敗を `documents.status = failed` に記録し、同期全体は継続する
- [x] 4-10 **ビルドゲート**

**完了条件**: テスト用 Drive フォルダを指定して同期を走らせ、`documents` に全ファイルが登録される。2 回目の実行で全件スキップされる。

---

## Phase 5 — 本文抽出

- [x] 5-1 `AskDrive.Ingest.Extractor` ビヘイビアと MIME ディスパッチャ
- [x] 5-2 Google ドキュメント / スライド（`export` → `text/plain`）
- [x] 5-3 Google スプレッドシート（`export` → xlsx → `XlsxReader` で全シート）
- [x] 5-4 スプレッドシートのテキスト化（シート名を見出し、`列名: 値` のタブ区切り、空行・空列除去）
- [x] 5-5 PDF（`pdftotext -layout`）。外部コマンドはタイムアウト付きで呼ぶ
- [x] 5-6 docx / pptx（`pandoc -t plain`）
- [x] 5-7 xlsx（`XlsxReader`）とテキスト系（そのまま）
- [x] 5-8 未対応 MIME を `skipped` にし、理由を記録する。外部コマンド欠如も `skipped` として案内文を残す
- [x] 5-9 抽出本文の SHA-256 を `content_hash` に保存し、同一ならチャンク再生成をスキップする
- [x] 5-10 **ビルドゲート**

**完了条件**: 全 7 形式のサンプルを用意し、それぞれから本文が取れることをテストで確認する。

---

## Phase 6 — チャンク分割と埋め込み

- [x] 6-1 `AskDrive.Ingest.Chunker`（見出し分割 → 日英対応文分割 `。！？` / `[.!?]\s+` → 詰め → オーバーラップ）
- [x] 6-2 長文の強制分割と、20 字未満チャンクの破棄
- [x] 6-3 各チャンクへの文書名・セクション見出しの前置
- [x] 6-4 日英および日英混在サンプルでのチャンカーのテスト（句点・ピリオド・改行・記号の境界）
- [x] 6-5 `AskDrive.LLM.Ollama.embed/2`（`/api/embed` に配列を投げる。単数形の旧 API は使わない。適切なタイムアウト設定）
- [x] 6-6 `AskDrive.LLM.Semaphore`（同時実行数制御、待ち行列、待機通知）
- [x] 6-7 `AskDrive.Batch.EmbedChunksWorker`（バッチ投入、部分失敗のリトライ）
- [x] 6-8 チャンクの差し替えをトランザクションで行う（旧チャンク削除 → 新挿入。既存 QA は `qa_pairs.document_id` で維持）
- [x] 6-9 埋め込み次元が `settings.embedding_dim` と一致するかを検証し、不一致なら明示的に落とす
- [x] 6-10 **ビルドゲート**

**完了条件**: 同期 → 抽出 → 分割 → 埋め込みが通しで動き、`chunks` にベクトルが入る。

---

## Phase 7 — Tier 2 検索とチャット画面

ここまでで「原文検索が使える社内検索」として実用価値が出る。

- [x] 7-1 `AskDrive.Retrieval.vector_search/2`（`sqlite-vec` / `vec_chunks` コサイン距離。bge-m3 による日英クロスリンガル対応）
- [x] 7-2 `AskDrive.Retrieval.keyword_search/2`（SQLite FTS5 `chunks_fts` trigram。短文クエリ対策として LIKE 部分一致フォールバックを含む）
- [x] 7-3 RRF による統合（k=60）と、同一文書から最大 3 件までの制限
- [x] 7-4 `AskDrive.Answering` の Tier 判定骨格（この時点では Tier 2 / 3 のみ）
- [x] 7-5 `ChatLive`: 質問入力、Enter 送信 / Shift+Enter 改行
- [x] 7-6 Tier 2 の表示（「関連しそうな箇所」として回答と明確に区別、Drive リンク、原文の展開）
- [x] 7-7 Tier 3 の表示（記録した旨と翌朝の回答予定）
- [x] 7-8 `question_log` への記録（質問文・埋め込み・到達 Tier・候補チャンク ID）
- [x] 7-9 空状態の案内（Drive 未接続 / インデックス 0 件 / Ollama 未起動）
- [x] 7-10 **ビルドゲート**

**完了条件**: ブラウザから質問して、関連する原文チャンクが出典付きで返る。

---

## Phase 8 — 生成フェーズ

- [x] 8-1 `AskDrive.LLM.Ollama.generate/2`（`/api/generate`、`stream: false`、`receive_timeout: 180_000`）
- [x] 8-2 `AskDrive.Generate.QA`: 想定質問・回答の生成プロンプト（主要言語追従: 日英対応）と JSON パース
- [x] 8-3 JSON パース失敗時に 1 回だけ再試行し、なお失敗ならチャンクを `failed` にする
- [x] 8-4 根拠外の固有名詞・数値の簡易検出と `hallucination_flag`
- [x] 8-5 重複想定質問（類似度 0.97 以上）の統合
- [x] 8-6 `AskDrive.Generate.Summary`（文書 / セクション要約）。**回答の根拠には使わない**
- [x] 8-7 `AskDrive.Generate.Extraction`（日付・金額・型番などの構造化抽出）
- [x] 8-8 生成物への `generated_by` / `generated_at` / `source_hash` の記録
- [x] 8-9 `AskDrive.Batch.EmbedQuestionsWorker`（想定質問のベクトル化）
- [x] 8-10 **ビルドゲート**

**完了条件**: 1 文書分の QA が生成され、`qa_pairs` に質問ベクトル付きで保存される。

---

## Phase 9 — 相制御とスケジューラ

- [x] 9-1 `AskDrive.Runtime.Mode` GenServer（営業時間相 / 待機相 / バッチ相の保持と遷移）
- [x] 9-2 生成 API 呼び出しへのガード（営業時間相では `{:error, :generation_disabled}`）とテスト
- [x] 9-3 相遷移時のモデル明示アンロード（`keep_alive: 0`）
- [x] 9-4 営業時間相での埋め込みモデル常駐（`keep_alive: -1`）
- [x] 9-5 起動スクリプトへの `OLLAMA_MAX_LOADED_MODELS=1` / `OLLAMA_NUM_PARALLEL=1` / `OLLAMA_FLASH_ATTENTION=1` / `OLLAMA_KV_CACHE_TYPE=q8_0` の設定
- [x] 9-6 `AskDrive.Batch.Scheduler`（Oban Cron）: 同期 → 無効化 → チャンク埋め込み → 生成 → 質問埋め込み → 検証の 6 フェーズ直列実行
- [x] 9-7 フェーズ境界でのモデル切り替えと、切り替え完了の確認
- [x] 9-8 締切管理（`batch_deadline_at` で生成のみ打ち切り、後続フェーズは必ず実行）
- [x] 9-9 `batch_runs` / `batch_phase_stats` への記録と、所要時間推定
- [x] 9-10 **ビルドゲート**

**完了条件**: バッチを手動起動し、フェーズごとに常駐モデルが切り替わることを `ollama ps` で確認する。ピーク RAM が想定内に収まる。

---

## Phase 10 — Tier 0 / 1 と鮮度管理

- [x] 10-1 質問文の正規化（全角半角・空白・記号・英字小文字化）と `answer_cache` による Tier 0
- [x] 10-2 `qa_pairs` へのベクトル検索による Tier 1（閾値 `tier1_threshold`）
- [x] 10-3 Tier 0 → 1 → 2 → 3 の判定順の実装とテスト
- [x] 10-4 回答への生成日時・根拠文書・Drive リンクの必須表示
- [x] 10-5 `AskDrive.Freshness`: チャンクのハッシュ変化から依存生成物を辿る
- [x] 10-6 ハッシュ変化時に `qa_pairs` / `doc_summaries` / `extractions` を `stale` にする
- [x] 10-7 `stale` に依存する `answer_cache` エントリを即座に破棄する
- [x] 10-8 文書削除時は `stale` ではなく生成物ごと削除する
- [x] 10-9 `stale` を Tier 1 から除外し、Tier 2 へフォールバックさせる（`serve_stale_qa` が有効な場合のみ警告付きで返す）
- [x] 10-10 **ビルドゲート**

**完了条件**: Drive 上の文書を更新して同期すると、その文書由来の QA が `stale` になり、Tier 1 に出なくなる。

---

## Phase 11 — 未回答の循環と管理画面

- [x] 11-1 バッチの優先度キュー（未回答質問 → stale 再生成 → 新規 → 高参照 → 残り）
- [x] 11-2 未回答質問に関連するチャンクの特定と最優先投入
- [x] 11-3 生成後の `question_log.resolved_at` / `resolved_qa_id` の更新
- [x] 11-4 繰り返し未回答になる質問の検出（類似質問のクラスタリング）
- [x] 11-5 `AdminLive`: バッチ状況（直近の実行、フェーズ別内訳、打ち切りの有無）
- [x] 11-6 `AdminLive`: カバレッジ（総チャンク / QA 生成済み / stale / 未処理）
- [x] 11-7 `AdminLive`: 未回答質問と、前夜に解消された質問の一覧
- [x] 11-8 `AdminLive`: 文書一覧（ステータス・最終同期・QA 件数・エラー）とモデル状態
- [x] 11-9 設定画面（接続 / モデル / バッチ / 応答）と、埋め込みモデル変更時の再構築確認ダイアログ
- [x] 11-10 **ビルドゲート**

**完了条件**: Tier 3 に落ちた質問が、翌夜のバッチ後に Tier 1 で答えられるようになる。

---

## Phase 12 — 運用整備

- [x] 12-1 同期フェーズ開始前の OAuth トークン有効性確認（F-108）
- [x] 12-2 バッチ開始前のモデル存在確認（`/api/tags`）
- [x] 12-3 仕様書 10 章のエラー表示を全て実装する
- [x] 12-4 バッチ 2 夜連続失敗時のチャット画面への帯表示
- [x] 12-5 スリープによるバッチ未実行の検知と案内
- [x] 12-6 `caffeinate -s` によるバッチ中のスリープ抑止
- [x] 12-7 ログから文書本文・トークン・質問文を除外する
- [x] 12-8 管理画面と一般画面のアクセス分離
- [x] 12-9 統合管理スクリプト（`app.sh`）、初期セットアップ（`scripts/initial-setup.sh`）、更新デプロイ（`scripts/deploy.sh`）、launchd 常駐設定を整備し、README にデプロイ・運用手順を書く
- [x] 12-10 **ビルドゲート**

**完了条件**: Mac を再起動しても自動で立ち上がり、夜間バッチが無人で完走する。

---

## Phase 13 — RAM 増設後の調整

増設が完了してから着手する。

- [ ] 13-1 `batch_model` を 8B クラスに変更し、メモリ実測を取る
- [ ] 13-2 `batch_num_ctx` と `OLLAMA_KV_CACHE_TYPE` を再調整する
- [ ] 13-3 並列度（Oban キュー / Semaphore）を仕様書 9.5 節の増設後の値に上げる
- [ ] 13-4 `generated_by` 別の件数を管理画面で確認し、再生成計画を立てる
- [ ] 13-5 参照回数上位のチャンクから選択的に再生成する
- [ ] 13-6 再生成前後の回答品質を、既存の `question_log` から抽出した質問で比較する
- [ ] 13-7 Tier 0+1 到達率が目標（70%）に届いているか測定する
- [ ] 13-8 Tier 2 の精度が問題なら形態素解析拡張（MeCab / Lindera 等の SQLite 拡張）への差し替えを検討する
- [ ] 13-9 新しいスループット実測値で仕様書 9.2 節を更新する
- [ ] 13-10 **ビルドゲート**

**完了条件**: 上位モデルでの再生成が回り、回答品質の改善が測定値で確認できる。


---

## Phase 14 — LLM マルチプロバイダ

仕様書 3.6 / 6.8 / 8.3〜8.6 節に対応。**既定値は変えない**（`ollama` + `bge-m3` + 1024 次元）。

- [ ] 14-1 マイグレーション: `settings` にプロバイダ設定列を追加（`llm_provider` / `embed_provider` / `embedding_dim` / `llm_max_tokens` / `llm_temperature` / `ollama_host` / 各 `*_api_key`（暗号化）/ 各 `*_base_url`）
- [ ] 14-2 `AskDrive.LLM.Provider` ビヘイビアを定義する（`generate/3` `embed/3` `list_models/1` `health/1` `local?/0` `supports_embedding?/0`）
- [ ] 14-3 既存の `AskDrive.LLM.Ollama` をビヘイビア実装に整え、`base_url` を opts で受け取れるようにする
- [ ] 14-4 `AskDrive.LLM.Providers.OpenAI` と `.LMStudio`（OpenAI 互換。`max_completion_tokens` と `max_tokens` の差、`dimensions` の送出条件に注意）
- [ ] 14-5 `AskDrive.LLM.Providers.Anthropic`（`x-api-key` / `anthropic-version` / `max_tokens` 必須 / `content[].text` 連結。埋め込み非対応を `supports_embedding?/0` で表明）
- [ ] 14-6 `AskDrive.LLM.Providers.Gemini`（`:generateContent` / `:batchEmbedContents`、`x-goog-api-key` ヘッダ、`outputDimensionality`）
- [ ] 14-7 `AskDrive.LLM` ファサード（設定からプロバイダ・資格情報を解決、環境変数フォールバック、429/5xx の指数バックオフ、エラー分類）。全呼び出し元（`Answering` / `Generate.*` / `Batch.*` / `Runtime.Mode`）を差し替える
- [ ] 14-8 `Runtime.Mode` と `HealthCheck` をプロバイダ対応にする（R-106 / R-107: リモートなら相による生成封鎖とモデル常駐制御を行わない）
- [ ] 14-9 `AdminLive` 設定画面に LLM プロバイダ区画を追加（プロバイダ選択、モデル、API キー（末尾4文字のみ表示・空欄なら既存値維持）、接続テスト、`embedding_dim` 変更時の再インデックス確認）
- [ ] 14-10 **ビルドゲート**

**完了条件**: 設定画面で生成プロバイダを Claude API に切り替え、埋め込みを Ollama のまま維持した状態で夜間バッチが完走する。API キーが DB 上で平文でないことを確認する。

---

## Phase 15 — 認証と権限昇格

仕様書 6.9 / 9.6 節に対応。**常時の管理者ロールは作らない。** 全員が一般ユーザーとしてログインし、管理者パスワードでセッション単位に昇格する（sudo 方式）。

- [ ] 15-1 マイグレーション: `users`（`email` unique / `name` / `picture_url` / `admin_eligible` / `status` / `last_login_at` / `last_elevated_at`）と `admin_elevation_logs`（`user_id` は `ON DELETE SET NULL`、`email` を非正規化保持）
- [ ] 15-2 マイグレーション: `settings` に `admin_password_hash` / `admin_session_minutes` / `admin_max_attempts` / `admin_lockout_minutes` を追加
- [ ] 15-3 `AskDrive.Accounts.AdminAccess`: PBKDF2-HMAC-SHA512 でのハッシュ生成と定数時間照合、ロックアウト判定、監査ログ書き込み（N-613 / N-614 / N-615）
- [ ] 15-4 `AskDrive.Accounts` の利用者関数（`upsert_from_oauth/1`、`list_users/0`、`set_admin_eligible/3`、`update_status/3`、最後の昇格可能アカウントを保護する検証）
- [ ] 15-5 `AuthController` を 2 フロー対応にする（`flow=login` は `openid email profile`、`flow=drive` は `drive.readonly`。コールバック URI は共用し、セッションの `oauth_flow` で判別）
- [ ] 15-6 `AskDriveWeb.UserAuth`（`fetch_current_user/2`、`require_authenticated_user/2`、`require_admin_session/2`、`log_in_user/3`、`log_out_user/1`、昇格状態の保持と期限切れ判定、ログイン時・昇格時のセッション ID 再生成）
- [ ] 15-7 `/login`・`/logout`・`/admin/elevate`（パスワード入力と初回設定）・`/admin/release`（降格）と、LiveView 用 `on_mount` フック（`:mount_current_user` / `:require_authenticated` / `:require_admin_session`）、ルータの `live_session` 分離
- [ ] 15-8 ロール決定ロジック（`ASK_DRIVE_ADMIN_EMAILS` は毎回 `admin_eligible` を再付与、昇格可能が 0 件なら初回ログイン者に付与）と `mix ask_drive.grant_admin <email>` / `mix ask_drive.set_admin_password`
- [ ] 15-9 `ChatLive` の更新（ログイン中ユーザー表示、昇格中バッジと残り時間、昇格・解除の導線、外部 API 利用時の送信先表示）
- [ ] 15-10 `AdminLive` に「ユーザー管理」「昇格履歴」「管理者パスワード変更」を追加。`scripts/initial-setup.sh` に昇格可能アカウントと管理者パスワードの対話入力を追加。**ビルドゲート**

**完了条件**: 一般ユーザーでログインすると `/admin` に到達できない。昇格可能アカウントはパスワード入力で管理画面に入れ、その成功・失敗が昇格履歴に残る。制限時間の経過で自動的に降格する。

---

## Phase 16 — Drive 同期のサービスアカウント対応

仕様書 6.1 節に対応。OAuth 方式が抱える `redirect_uri` の制約（F-109 / F-110: 生の IP・`.local` を Google が拒否する）を、ブラウザ認可が不要なサービスアカウント方式で回避する。**社員ログインの OAuth フローは対象外**（別途対応）。

- [x] 16-1 マイグレーション: `settings` に `drive_auth_mode`（既定 `oauth`）/ `drive_service_account_json`（暗号化）を追加
- [x] 16-2 `AskDrive.Drive.ServiceAccount`: JSON キーの解析、RS256 JWT の組み立てと署名（`:public_key` / `:crypto`、追加ライブラリなし）、`token_uri` への交換、GenServer によるトークンキャッシュ（キー内容が変われば即無効化）
- [x] 16-3 `AskDrive.Settings.Setting` の changeset にモード切り替えとサービスアカウント JSON のバリデーションを追加
- [x] 16-4 `AskDrive.Accounts.get_valid_access_token/0` を認証方式で分岐。`drive_connected?/0` / `drive_identity/0` / `disconnect_service_account/0` を追加し、OAuth 専用だった箇所（`SyncWorker`、`ChatLive`、`AdminLive`）を両方式に対応させる
- [x] 16-5 `AdminLive` 設定画面に認証方式の切り替えタブ、JSON キー貼り付けフォーム、接続テスト、削除ボタンを追加
- [x] 16-6 サービスアカウントの JWT 署名を実鍵で検証するテスト（`:public_key.verify/4` で署名を実際に検証）。**ビルドゲート**

**完了条件**: サービスアカウントの JSON キーを貼り付けて保存すると、LAN の IP・ホスト名に関わらず接続テストが成功し、夜間バッチが Drive 同期を完走する。

### Phase 16b — ドメイン全体の委任（社内限定の共有ドライブ対応）

仕様書 6.1.1 節 F-121〜F-123 に対応。同期対象の共有ドライブが「組織内のユーザーのみ」に制限されており、サービスアカウント（組織外扱い）を共有に追加できない事象（2026-09-28）への対応。

- [x] 16b-1 マイグレーション: `settings.drive_impersonate_email` を追加
- [x] 16b-2 `ServiceAccount`: JWT の `sub` クレーム、キーとユーザーの組み合わせでのトークンキャッシュ、`unauthorized_client` / `invalid_grant` の具体的なエラーメッセージ
- [x] 16b-3 管理画面: なりすましユーザー入力欄、`client_id` の表示、JSON キー欄を空欄で保存したら既存キーを維持、接続テストで同期フォルダの読み取りまで確認
- [x] 16b-4 CLI: `--subject` オプション（`./app.sh drive service-account` 経由でも可）
- [ ] 16b-5 Workspace 特権管理者に、サービスアカウントの `client_id` への `drive.readonly` のドメイン全体の委任を依頼する
- [ ] 16b-6 同期専用の社内ユーザーを用意して共有ドライブのメンバーに追加し、なりすましユーザーに設定する
- [ ] 16b-7 実機で接続テスト成功 → 手動バッチで Drive 同期が完走することを確認する。**ビルドゲート**

### Phase 16c — バッチのファイル別ログ

仕様書 6.3.9 節（F-326〜F-329）に対応。同期は4件成功したのに取り込みが0件で、理由が画面にもログにも出なかった事象（2026-09-28）への対応。

- [x] 16c-1 マイグレーション: `batch_item_logs`
- [x] 16c-2 `SyncWorker` / `EmbedChunksWorker` がバッチ ID を受け取り、ファイルごとの結果・理由・所要時間を記録。サーバーログにも1行ずつ出力
- [x] 16c-3 管理画面: 取り込み成功文書数・チャンク数・失敗件数、ファイル別ログ一覧
- [x] 16c-4 実機で手動バッチを実行し、ファイル別ログから取り込み失敗の原因を特定・修正する（原因: 閲覧者のダウンロード禁止 `cannotDownloadFile`。同期ユーザーの権限変更で解消。4文書・258チャンク取り込み済み）

### Phase 16d — バッチ中もチャットが応答する

仕様書 6.4.2 節（F-405〜F-408）に対応。日中の手動バッチが生成フェーズでローカルモデルを占有し、チャットの質問埋め込みが 30秒×3回 待たされて応答が返らなかった事象（2026-09-28）への対応。

- [x] 16d-1 質問の埋め込みを 10秒・再試行なしに。失敗時はキーワード検索のみで Tier 2
- [x] 16d-2 キーワード検索: 質問文から検索語を取り出して順位付け
- [x] 16d-3 `chunks_fts` を同期するトリガーを追加し、既存チャンクで再構築（それまで全文検索インデックスが空だった）
- [x] 16d-4 チャット画面の非同期化（「回答を検索しています…」表示）
- [x] 16d-5 起動時に `running` のまま残ったバッチを `aborted` に更新
- [x] 16d-6 日中の手動実行で「取り込みのみ（生成なし）」を選べるようにする（F-331）
- [x] 16d-7 夜間バッチの自動起動（それまで起動処理が無かった）とローカル時刻への修正、`night_batch` の固着解消、同時実行の防止（F-330 / F-332 / F-333）
- [x] 16d-8 Tier 2 抜粋のハイライトと窓表示、PDF 抽出ゴミの除去、語を多く含むチャンクの優先（F-409 / F-410）
- [ ] 16d-9 今夜の自動バッチで QA 生成が完走するか確認する（ローカル生成モデルでの所要時間を実測）
- [x] 16d-11 PDF チャンクのページ番号と「Drive で開く（p.N）」（F-411）、処理バージョンによる一度だけの再取り込み（F-337）
- [ ] 16d-12 Drive のビューアで `#page=N` が効くか実機で確認する。効かない場合、Google ドキュメントの見出しリンク（Docs API のスコープ追加が必要）や AskDrive 内ビューアを検討する
- [x] 16d-13 チャットの AI 要約（回答生成プロバイダ使用・ストリーミング表示・[n] 引用リンク・引用元一覧）（仕様 6.4.6 F-415〜F-420）
- [x] 16d-13b チャット要約のプロバイダ・モデルを夜間バッチと別に設定可能に（夜間はローカル、チャットはクラウド）（F-415）
- [x] 16d-15 夜間バッチの実行方法（ローカル LLM / クラウド API）の切り替え（F-821〜F-823）。Elixir 1.20 のコンパイル警告の解消、デプロイ後に起動を待ってからステータスを表示
- [x] 16d-16 QA 即答（Tier 1）のしきい値を専用設定 `tier1_threshold`（既定 0.90）に。それまでは存在しない項目を参照して `similarity_threshold`（0.65）で動いていた（F-421）
- [x] 16d-17 要約の長さ（日本語 250 字 / 英語 150 語、num_predict 450）と回答言語の固定（F-424）
- [x] 16d-19 推論モデルの思考過程を要約から分離し、折りたたみ表示に。表示上限での生成停止、qwen3 への `/no_think`（F-425）
- [x] 16d-21 夜間枠を 0:00〜7:00 に変更（既定値と既存設定 21 → 0）、手動実行を「その夜の実行済み」に数えない、中断バッチの所要時間を非表示（F-330）
- [x] 16d-20 夜間バッチの自動実行状態と履歴の表示、起動方法（手動/自動）の記録、開始前クラッシュの記録（F-338）
- [x] 16d-22 推論モデルの思考を Ollama の thinking フィールドで分離、分離できない・言語違いの場合は結論だけを再生成（F-426）
- [x] 16d-24 モデルをアプリが取得（起動時・設定保存時・管理画面・`./app.sh ollama`）、チャット要約モデルを instruct 版へ自動切り替え（未取得の間は夜間バッチのモデルで代替）（F-827）
- [x] 16d-23 チャット要約のモデルを `qwen3:4b-instruct-2507-q4_K_M` に切り替えて実機で確認する（2026-09-29: 日本語の質問に対する回答精度の向上を確認）
- [ ] 16d-25 夜間バッチ（QA 生成）のモデルも instruct 版に切り替え、所要時間・生成 QA 数・JSON 解析失敗を `qwen3:4b` と比較する
- [ ] 16d-26 英語など日本語以外の質問で、同じ言語・字数上限内で回答するか実機で確認する
- [ ] 16d-27 自動バッチが「自動」として履歴に記録され、完走するか確認する
  - 2026-09-29 06:43: アップデート後の再起動で自動実行が起動し「自動」として記録（#8）。07:00 の締め切りで時間切れ（16分30秒・取り込み 4文書 / 208チャンク・生成 QA 67件・失敗 0）。自動起動は確認済み
  - 残り: 2026-09-30 0:00〜の自動実行で QA 生成が完走するか（所要時間・生成 QA 数）
- [x] 16d-28 打ち切り時刻を開始可能時間と分離（既定 開始 0:00〜7:00 / 打ち切り 8:00）（F-339）
- [x] 16d-29 Gemini の実運用対応: チャット要約の推論オフ（thinkingBudget 0）、thought パーツの除外、SSE ストリーミング、429 の retryDelay に従う再試行（F-828）
- [ ] 16d-30 実際の Gemini API キーで、チャット要約と夜間バッチ（クラウドモード）を確認する（モデル名・所要時間・料金）
- [ ] 16d-18 省メモリ・高性能モデル（PrismML Bonsai 1-bit 等）を、実際の質問セットで qwen3:4b と比較評価する（Ollama 対応状況の確認、非対応なら llama.cpp サーバーを LM Studio プロバイダ経由で接続）
- [ ] 16d-14 実機で要約の所要時間を実測する（POC はローカル）。本番移行時に「チャット要約プロバイダ」を Gemini に切り替え、API キーとモデル名を設定する
- [x] 16d-10 差分取り込み: ファイル（modifiedTime / md5Checksum）→ 本文ハッシュ → チャンク単位の再利用で、変更のない部分の取り込み・埋め込み・QA 生成を省く（F-334〜F-336）

### Phase 23 — Google Secure LDAP でのログイン

仕様書 6.13 節に対応。

- [x] 23-1 `AskDrive.Ldap`（LDAPS + クライアント証明書、mail で検索 → ユーザー DN でバインド、空パスワードの拒否、接続テスト）
- [x] 23-2 ログイン画面のメールアドレス・パスワード欄と `POST /login/ldap`、ロック（アカウント 5 回・接続元 20 回 / 15 分、`login_failures`）
- [x] 23-3 全体設定の「Google Secure LDAP でのログイン」（証明書・鍵のアップロードと検証、暗号化保存、接続テスト）
- [x] 23-4 Linux CI で OpenLDAP（LDAPS・クライアント証明書必須）に対する結合テスト
- [x] 23-6 ロックの閾値を変更（アカウント: 5 分に 5 回 → 15 分、接続環境〈端末 Cookie / IP+UA〉: 24 時間に 10 回 → 24 時間）、ロック中の一覧と管理者による解除
- [ ] 23-5 Google 管理コンソールで LDAP クライアントを作成し、証明書を登録して実機でログインを確認する

### Phase 22 — バッチの進捗表示

仕様書 F-340 に対応。

- [x] 22-1 `batch_runs` に進捗（ステップ・完了 / 全体・処理中の項目・内側の状況・ステップ開始時刻）を記録（`AskDrive.Batch.Progress`）
- [x] 22-2 管理画面: 全体の目安 %・ステップ・件数・処理中のファイル・残り時間、打ち切りに間に合わない見込みの表示、履歴行とバナーの %
- [ ] 22-3 実機の手動バッチで表示と残り時間の推定を確認する
- [x] 22-4 QA 生成（Ollama・非ストリーミング）で `think: false` を送る・出力上限 1,536 トークン（F-427。qwen3:4b の思考で生成が極端に遅かった）
- [ ] 22-5 実機で 1 チャンクあたりの生成時間を修正前後で比べる（進捗表示の「残り時間」で確認）
- [x] 22-6 実行中のバッチの停止（F-341。`stop_requested_at`、項目の区切りで停止、状態「停止（手動）」）
- [ ] 22-7 実機で実行中のバッチを停止し、次のバッチが続きから処理することを確認する
- [x] 22-9 QA 生成の出力の揺れに耐える（単一オブジェクト・包んだ配列・欠けた項目）、1 チャンクの例外でバッチ全体を失敗させない、失敗理由を管理画面に表示（F-428）
- [ ] 22-10 実機で #11 の失敗理由を確認し（管理画面に表示される）、フル実行が最後まで完了することを確認する
- [x] 22-11 続きから再実行（F-342）: チャンクごとの生成失敗の記録（3 回で除外・後回し）、残りの表示と「続きから再実行」、除外中チャンクの一覧と「生成の対象に戻す」
- [ ] 22-12 実機で失敗・停止後に「続きから再実行」し、済んだチャンクが再生成されないことを確認する
- [x] 22-13 Favicon が本番で表示されない不具合を修正（`~p` が本番でダイジェスト付きのパスになり、Plug.Static の `only` で配信されなかった）。CI の本番ビルドでアイコンの配信を確認
- [x] 22-14 稼働中のバージョンを管理画面の見出し横に表示、`./app.sh status` にインストール済みバージョン、リリース時に mix.exs のバージョンとタグの一致を検査
- [x] 22-15 「続きから再実行（残り N チャンク）」を管理画面上部にも表示（直近のバッチが途中で終わり、残りがある場合）
- [x] 22-8 Favicon: ヘッダーのアプリアイコン（インディゴの角丸に白の「AD」）から `favicon.svg`・`favicon.ico`（16/32/48）・`apple-touch-icon.png`（180）を作成

### Phase 21 — Linux（x64）対応

仕様書 12.6 節に対応。

- [x] 21-1 `scripts/lib/platform.sh`（OS・アーキテクチャ判定、`sed_inplace` による GNU / BSD sed の使い分け、pandoc・Ollama・sqlite-vec・OTP/Elixir の OS 別導入）
- [x] 21-2 `initial-setup.sh` の Linux 分岐（apt パッケージは初回のみ sudo、Homebrew は macOS のみ）
- [x] 21-3 `app.sh service *` を systemd システムサービスに対応（unit と sudoers の生成・検証、`sudo -n` による start/stop/restart）、`deploy.sh` は OS を問わず登録済みサービスを再起動
- [x] 21-4 GitHub Actions の Linux CI（mix test・導入・systemd 登録・HTTPS 応答・deploy による再起動）
- [ ] 21-5 実機の Ubuntu / Debian サーバーで `app.sh setup` → `service install` → 初回セットアップ画面を確認する

### Phase 20 — 初回セットアップ（Web）

仕様書 6.12 節に対応。

- [x] 20-1 `/setup`（セットアップコード・管理者パスワード・ドメイン・最初の窓口名）と、未完了時の全ページ転送
- [x] 20-2 セットアップコード（起動ログ・`./app.sh status`・`setup_code` ファイル、失敗回数による一時停止、完了時に削除）
- [x] 20-3 `initial-setup.sh` から管理者パスワード・ドメイン・OAuth の質問を外す
- [x] 20-4 全体設定に「組織（Google Workspace）」カード、なりすましユーザーのドメイン確認
- [ ] 20-5 新規環境で `app.sh setup` → 初回セットアップ画面の流れを実機で確認する

### Phase 19 — マルチアプリ（複数の窓口）

仕様書 6.11 節に対応。

- [x] 19-1 窓口ごとのデータベース（dynamic repo）、登録テーブル、起動時の起動・マイグレーション、最初の窓口は既存 DB を使用
- [x] 19-2 全体共通（ユーザー・昇格・夜間の時間帯・Ollama・HTTPS・Google ログイン）と窓口ごとの設定の分離
- [x] 19-3 URL 方式の UI: ポータル、`/<窓口>` のチャット、`/<窓口>/admin`、`/admin` の全体管理（窓口の追加・編集・削除）、ヘッダーの窓口切り替え
- [x] 19-4 夜間バッチを窓口ごとに順番に実行、全窓口での同時実行防止、Drive OAuth の窓口対応
- [ ] 19-5 実機で 2 つ目の窓口（例: HR）を作成し、別の Drive フォルダ・Gemini キーで取り込み・チャット・夜間バッチを確認する
- [ ] 19-6 （将来）窓口ごとの管理者、窓口ごとの利用者の制限

### Phase 18 — HTTPS（SSL）

仕様書 6.10 節に対応。将来の外部公開と Google ログインの有効化に備える。

- [x] 18-1 HTTPS 専用の待ち受け（4443）と HTTP（4080・従来の 4000）からの転送
- [x] 18-2 初回起動時の自己署名証明書の生成（`ssl/active/`）
- [x] 18-3 管理画面からの独自証明書（PEM）のアップロード・検証（鍵の対応・期限・チェーン・ホスト名・TLS 接続テスト）・適用（HTTPS の再起動、失敗時は元に戻す）・自己署名への復帰
- [x] 18-4 HSTS（独自証明書のときのみ）、リバースプロキシ用の `ASK_DRIVE_TRUST_FORWARDED`、`ASK_DRIVE_SSL=false` による HTTP 運用
- [ ] 18-5 実機で HTTPS 化を確認する（ブラウザでの警告と続行、4000/4080 からの転送、LiveView の接続）
- [ ] 18-6 外部公開の前に: 正規の証明書を設定し、管理画面の認証を有効化し、セッション Cookie を `secure` にする。Google Cloud Console のリダイレクト URI を HTTPS に更新する
- [ ] 18-7 （検討）Let's Encrypt による証明書の自動取得・更新

---

## Phase 17 — 社員ログイン(各ユーザー認証)の恒久対応 【将来 ToDo・未着手】

仕様書 6.9.5 節に対応。**現在はチャット（`/`）をログインなしで開放した POC 運用中**（2026-09-28 時点、社内 LAN 限定。v0.0.24 以降は管理画面も既定で認証なし）。本番相当の運用に入る前に、このフェーズでチャットもログイン必須に戻す。

- [ ] 17-1 一般ユーザーの Google ログインが「Access blocked: Authorisation error」で失敗する事象の根本原因を特定する。エラー詳細（`redirect_uri_mismatch` / 組織制限 / その他）を確認し、原因ごとに対処する
  - 生の IP・`.local` ホスト名を使っている場合 → README ステップ1の手順に従い、公開 TLD を持つ安定したホスト名を社内 DNS または `hosts` ファイルで割り当てる
  - OAuth 同意画面が「内部」でユーザーの組織が一致しない場合 → 同意画面の設定と対象ユーザーの所属組織を確認する
- [ ] 17-2 管理者パスワードを実際に設定する（`./app.sh admin password` または管理画面）
- [ ] 17-3 `router.ex` のチャット（`/`）を `:require_authenticated_user` / `:require_authenticated` に戻し、ログイン必須にする
- [ ] 17-3b `config/config.exs` の `auth_disabled_by_default` を `false` に戻し、管理画面をログイン + 昇格必須に戻す（仕様 6.9.6。それまでは `.env.prod` の `ASK_DRIVE_DISABLE_AUTH=false` で個別に有効化できる）
- [ ] 17-4 戻した状態で、一般ユーザー・管理者それぞれのログイン〜昇格までを実機で再検証する。**ビルドゲート**

**完了条件**: チャットをログイン必須に戻した状態で、一般ユーザーが Google ログインでチャットを利用でき、管理者が Google ログイン + 管理者パスワードで管理画面に昇格できる。

---

## 進捗管理

| Phase | 名称 | 状態 | 完了日 |
|---|---|---|---|
| 0 | 環境準備 | ☑ | 2026-09-28 |
| 1 | プロジェクト骨格 | ☑ | 2026-09-28 |
| 2 | データモデル | ☑ | 2026-09-28 |
| 3 | 暗号化と OAuth | ☑ | 2026-09-28 |
| 4 | Drive 同期 | ☑ | 2026-09-28 |
| 5 | 本文抽出 | ☑ | 2026-09-28 |
| 6 | 分割と埋め込み | ☑ | 2026-09-28 |
| 7 | Tier 2 とチャット | ☑ | 2026-09-28 |
| 8 | 生成フェーズ | ☑ | 2026-09-28 |
| 9 | 相制御とスケジューラ | ☑ | 2026-09-28 |
| 10 | Tier 0/1 と鮮度管理 | ☑ | 2026-09-28 |
| 11 | 未回答の循環と管理画面 | ☑ | 2026-09-28 |
| 12 | 運用整備 | ☑ | 2026-09-28 |
| 13 | 増設後の調整 | ☐ | （将来運用） |
| 14 | LLM マルチプロバイダ | ☐ | |
| 15 | 認証と権限昇格 | ☐ | |
| 16 | Drive 同期のサービスアカウント対応 | ☑ | 2026-09-28 |
| 16b | ドメイン全体の委任（社内限定の共有ドライブ） | ☐ | 実装済み・管理者設定待ち |
| 17 | 社員ログインの恒久対応（将来 ToDo） | ☐ | （POC後に対応） |

**Phase 7 完了時点で一度止めて実運用に出すことを勧める。** 原文検索だけでも社内で使ってもらえば、Phase 8 以降で「実際に聞かれる質問」が `question_log` に溜まった状態で生成を始められる。想定質問を当てずっぽうで作るより、実需に沿った生成ができる。
