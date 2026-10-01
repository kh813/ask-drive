# AskDrive Roadmap & Future Concepts

This document outlines planned improvements, future concepts, and the technical roadmap for AskDrive.

---

## Current Version: `0.1.26`
- **Multi-lingual Support (i18n)**: English (default) & Japanese (`en` / `ja`) with browser `Accept-Language` auto-detection and UI switcher.
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

---

## Future Enhancements & Roadmap Candidates (0.2.0+)

### 1. UI / UX & Internationalization (i18n)
- **Granular Admin UI Localization**:
  - Full translation coverage across all specialized low-level Platform Admin troubleshooting and LDAP/mTLS diagnostics tabs.
- **Dark Mode / Theme Customization**:
  - Seamless system/light/dark theme switching and customizable branding per desk (custom logo and color accent).

### 2. Connector & Data Source Expansions
- **Additional Enterprise Knowledge Sources**:
  - Ingestion connectors for Notion, Slack channels, Confluence spaces, and local filesystem folders alongside Google Drive.
- **User Feedback Loops**:
  - Direct 👍 / 👎 answer rating in chat UI, automatically feeding low-rated answers to administrators for Tier 1 FAQ curation.

### 3. Advanced Networking & Architecture
- **DNS & Network Telemetry**:
  - DNS request logging and intranet latency analysis for air-gapped or restricted enterprise networks.
- **Distributed Ingestion Workers**:
  - Ability to scale ingestion workers across multiple compute nodes for high-volume enterprise document repositories.
