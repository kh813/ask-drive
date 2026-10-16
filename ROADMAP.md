# AskDrive Roadmap & Future Concepts

This document outlines planned improvements, future concepts, and the technical roadmap for AskDrive.

---

## Current Version: `0.2.0` (MVP: Minimum Viable Product)
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
- **LLM プロバイダ**: Ollama / LM Studio / Gemini / Google Agent Platform（旧 Vertex AI。API キー、生成のみ。v0.1.44〜）/ Claude / OpenAI。夜間バッチ・チャット要約・埋め込みを個別に設定し、選んだ側（ローカル LLM / クラウド API）の欄と接続情報だけをそのすぐ下に表示。クラウド API のモデル名はプロバイダのモデル一覧から選ぶ（Gemini の一覧を取れないとき・Agent Platform は公式マニュアルのモデルを候補に表示）。保存済みの API キーは伏せ字で表示
- **チャット要約の回答スタイル**（v0.1.36〜）: 窓口ごとに 簡潔 / 対話調 / 詳しく / やさしく から選ぶ（抜粋だけを根拠にする規則はどれでも同じ）
- **Ollama と外部プログラムの管理を全体管理に集約**（v0.1.45〜0.1.49）: 「インストールとアップデート」タブの「Ollama（ローカル推論）」カードでインストール（`./app.sh install-ollama`）・起動、モデルの一覧・取得・まとめて取得・削除。窓口は取得済みのモデルから選ぶだけで、自動取得はしない
- **HTTPS の運用**: Let's Encrypt の証明書をバリュードメインの DNS API（DNS-01）でアプリ自身が取得・夜間に自動更新（v0.1.37〜）。API ゲートウェイ（さくらのクラウド + Google ログイン）を前段に置く構成に対応（秘密ヘッダー `X-Apigw-Secret`、v0.1.38〜）
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
