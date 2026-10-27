# AskDrive Roadmap & Future Concepts

This document outlines planned improvements, future concepts, and the technical roadmap for AskDrive.

---

## Current Version: `0.2.13` (MVP: Minimum Viable Product)
- **License**: Changed to [Apache License 2.0](LICENSE) (from MIT) with [NOTICE](NOTICE) file.
- **Prototype (v0.1.x) to MVP (v0.2.0)**: The core feature set has matured from the initial prototype phase into an operational Minimum Viable Product for enterprise internal deployments.
- **Multi-lingual Support (i18n)**: English (default) & Japanese (`en` / `ja`) with browser `Accept-Language` auto-detection and UI switcher. The admin screens (desk and platform) are fully available in English (v0.1.41, Gettext with English source strings); text recorded by background work (batch, health check, certificate renewal, updater) stays Japanese.
- **Multi-app Desk Portal**: Departmental multi-desk routing (`/`, `/:app`, `/:app/admin`).
- **Clear Admin Navigation**: A desk's admin link is named after the desk ("Manage IT-Support"); Platform Admin sits with the admin-mode badge and Release on the right, and each admin screen states whether it applies to one desk or all desks.
- **Google Drive Sync & Ingestion Pipeline**: OAuth & Service Account, OCR & text vector extraction using Oban & SQLite-vec.
- **3-Tier Answering Engine**: Tier 0 (exact match cache), Tier 1 (QA pairs vector search), Tier 2 (hybrid FTS5 + vector search with snippet excerpts & live LLM streaming summary), Tier 3 (unanswered query logging & nightly batch generation).
- **Authentication & Security**: POC guest bypass, Google OAuth, Google Secure LDAP, mTLS client certificate verification gate, Admin sudo-style elevation with auto-expiry — each administrator confirms identity with their own account (LDAP password or a recent sign-in), no shared admin password; a guest-mode warning banner on every screen.
- **Telemetry & Metrics Dashboard**: Token usage, request latency, provider breakdown, rate limiting (429) tracking, and data ingestion token efficiency analytics.
- **Production Operations & Backup Infrastructure**:
  - SQLite online backup (`VACUUM INTO`) across all app databases and platform database with automated retention rotation.
  - WAL checkpointing (`TRUNCATE` mode) integrated into Nightly Batch phase 6.
  - Automated temporary file & OCR cache garbage collection (`AskDrive.Cleanup`).
  - CLI commands (`./app.sh backup`, `./app.sh backup status`, `./app.sh backup checkpoint`).
- **管理画面からのアップデート**（v0.1.30〜）: 全体管理の「アップデート」タブで最新版を確認し、サーバーとバッチを動かしたまま裏でビルドして、短い再起動で切り替える。実行中のバッチは区切りで一時停止し、再起動後に続きから再開。再起動中は全画面に「アップデート中」を表示。毎晩の確認と自動アップデート（夜間枠の開始時のみ）の設定。アップデートの開始・完了（正常に稼働）・失敗を Google Chat に通知
- **LLM プロバイダ & クラウドモデル選択**（v0.1.44〜、v0.2.1）: Ollama / LM Studio / Gemini / Google Agent Platform（旧 Vertex AI。API キー、生成のみ）/ Claude / OpenAI。夜間バッチ・チャット要約・埋め込みを個別に設定。Agent Platform では公式ドキュメント・Model Garden に基づくモデル一覧をプルダウンで選択可能にし（手入力への切り替えも対応）、最適な `gemini-2.5-flash` をデフォルト化。未検証クラウド API（Gemini, Claude, OpenAI）には「(実験的)」を明示。保存済みの API キーは伏せ字で表示
- **チャット要約の回答スタイル**（v0.1.36〜）: 窓口ごとに 簡潔 / 対話調 / 詳しく / やさしく から選ぶ（抜粋だけを根拠にする規則はどれでも同じ）
- **Ollama と外部プログラムの管理を全体管理に集約**（v0.1.45〜0.1.49）: 「インストールとアップデート」タブの「Ollama（ローカル推論）」カードでインストール（`./app.sh install-ollama`）・起動、モデルの一覧・取得・まとめて取得・削除。窓口は取得済みのモデルから選ぶだけで、自動取得はしない
- **HTTPS の運用**: Let's Encrypt の証明書をバリュードメインの DNS API（DNS-01）でアプリ自身が取得・夜間に自動更新（v0.1.37〜）。API ゲートウェイ（さくらのクラウド + Google ログイン）を前段に置く構成に対応（秘密ヘッダー `X-Apigw-Secret`、v0.1.38〜）
- **インデックス対象は文書だけ**（v0.2.4）: Google ドキュメント / スプレッドシート / スライド、PDF、Word・Excel・PowerPoint、テキスト、Markdown、CSV、HTML の許可リスト。バッチ・プログラム・ソースコードなどは対象外。旧形式の .doc / .xls / .ppt は LibreOffice で変換して取り込む
- **メールアドレス補完の高速化**（v0.2.5）: Secure LDAP のユーザー一覧を毎晩取得して全体の DB に保存し、入力中の候補と保存時の存在確認をその一覧で行う（一覧にない人だけディレクトリに問い合わせ）
- **画像付きの手順書の効率スコア**（v0.2.5）: PDF はページあたりの文字数で評価し、スクリーンショットの多い手順書を「要改善」にしない。画像への言及を見分けて、画像内の文字は検索対象外である旨を案内
- **窓口管理者向けの「API利用量・ログ」**（v0.2.6）: 質問数と解決数、質問の処理と夜間バッチのトークン、返答速度（良好／ふつう／やや遅い）。API エラーは直近 7 日間を表示し「確認済み」で非表示に、利用ログは 90 日で削除
- **チャットの「解決した」ボタン**（v0.2.6）: 押すと解決として記録（取り消し可）。「この回答に追加で質問」は前の回答を未解決として扱い、QA で答えた質問でも管理画面の未解決の一覧に載せる
- **ドキュメント一覧の絞り込み**（v0.2.6）: 名前・状態・ファイル形式（拡張子）・トークン効率で絞り込み、効率順などで並べ替え、表示中の平均トークン/KB と評価ごとの件数
- **Drive の認証は Google アカウント認証が基本**（v0.2.7）: 新しい窓口の初期値を Google アカウント認証にし、サービスアカウントは「詳細設定」に（担当者の異動・退職に左右されない運用向け）
- **数の表示と FAQ**（v0.2.7）: 3 桁ごとの区切り、カードの大きな数は「12.3 万」「1.2 億」に短縮。窓口管理者向けのよくある質問 [docs/FAQ.md](docs/FAQ.md)
- **夜間バッチの対象外の指定**（v0.2.8）: 窓口管理者が、同期フォルダ内の旧版・下書き・名簿などのファイルやフォルダを「ドキュメント」タブで対象外に（指定した時点でインデックスから外し、Drive の ID で管理）
- **チャットの複数行入力と待ち受けポートの限定**（v0.2.8）: 質問欄で Shift+Enter で改行。AskDrive は管理画面で設定した HTTP / HTTPS のポートだけで待ち受け、汎用の `PORT` や Erlang の分散用ポートで同じ Mac の別の Web アプリを妨げない
- **利用状況タブ**（v0.2.9）: 窓口の管理画面に、よく使うユーザー（質問回数・トークン・解決率）とよくある質問。全体管理に、ユーザーごとの全窓口の合計（窓口別の内訳つき）。ユーザーごとの記録に質問の文面は持たず、90 日で削除。全体管理の「API利用量・ログ」を全窓口の合計に
- **クラウド API の窓口は夜間バッチの生成を同時に**（v0.2.10）: 同じ API キー（Vertex はプロジェクト）を使う窓口は同時実行数を分け合い、429 で自動的に減らして戻す。窓口の設定に「同時に生成する数」（1〜32、既定 4）。ローカル LLM の窓口と取り込みは従来どおり 1 つずつ
- **規則に当てはめて答える AI 要約と全体管理のタブの並び**（v0.2.11）: 「この名前は命名規則に沿っていますか？」のような質問に、抜粋の規則を当てはめて答える（名前そのものが文書に無くても）。全体管理のタブは「API利用量・ログ」「利用状況」「全体設定」を左に
- **AI 要約に渡す抜粋を増やす**（v0.2.12）: クラウド API なら最大 8 件（ローカル LLM は 4 件）、最も関係の深い文書は見つかった部分の前後も渡す。回答の後に付いた「資料からは確認できませんでした」と、存在しない番号の引用を取り除く
- **考えて答える回答**（v0.2.13）: クラウド API では、規則に沿っているかの確認や、文面の奥に目的がある質問だと判断したとき、関係する文書を丸ごと渡して思考させ、規則の目的に照らした判定・直し方の例・目的に合う別の方法を答える。FAQ にその質問と回答があれば FAQ を基に。一問一答の質問とローカル LLM は従来どおり。README に FAQ 文書の書き方
- **管理画面の保存と有効化の分離**（v0.1.39〜）: 「保存」は値の保存だけ、機能ごとの有効・無効はスイッチですぐに反映

---

## Future Enhancements & Roadmap Candidates (0.2.0+)

### 1. UI / UX & Internationalization (i18n)
- **Dark Mode / Theme Customization**:
  - Seamless system/light/dark theme switching and customizable branding per desk (custom logo and color accent).

### 2. Connector & Data Source Expansions
- **Additional Enterprise Knowledge Sources**:
  - Ingestion connectors for Notion, Slack channels, Confluence spaces, and local filesystem folders alongside Google Drive.
- **User Feedback Loops**:
  - Direct 👍 / 👎 answer rating in chat UI, automatically feeding low-rated answers to administrators for Tier 1 FAQ curation.

### 3. Advanced Networking & Architecture
- **アップデート通知の Slack・Microsoft Teams 対応**:
  - 現在は Google Chat の Webhook に対応。Google Drive を使う組織でもチャットは Slack や Teams という場合を想定し、通知先を選べるようにする（いずれも Incoming Webhook に JSON を POST する方式）。
- **コードだけの更新の再起動なし適用（ホットパッチ）**:
  - マイグレーション・依存関係・プロセス構成の変更がない更新に限り、変更されたモジュールを稼働中のサーバーに読み込み、営業時間中でも利用者を中断せずに更新する。安全に適用できない場合は現在の再起動方式に切り替える。
- **DNS & Network Telemetry**:
  - DNS request logging and intranet latency analysis for air-gapped or restricted enterprise networks.
- **Distributed Ingestion Workers**:
  - Ability to scale ingestion workers across multiple compute nodes for high-volume enterprise document repositories.
