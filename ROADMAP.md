# AskDrive Roadmap & Future Concepts

This document outlines planned improvements, future concepts, and the technical roadmap for AskDrive.

---

## Current Version: `0.1.1`
- **Multi-lingual Support (i18n)**: English (default) & Japanese (`en` / `ja`) with browser `Accept-Language` auto-detection and UI switcher.
- **Multi-app Desk Portal**: Departmental multi-desk routing (`/`, `/:app`, `/:app/admin`).
- **Google Drive Sync & Ingestion Pipeline**: OAuth & Service Account, OCR & text vector extraction using Oban & SQLite-vec.
- **3-Tier Answering Engine**: Tier 0 (exact match cache), Tier 1 (QA pairs vector search), Tier 2 (hybrid FTS5 + vector search with snippet excerpts & live LLM streaming summary), Tier 3 (unanswered query logging & nightly batch generation).
- **Authentication & Security**: POC guest bypass, Google OAuth, Google Secure LDAP, mTLS client certificate verification gate, Admin sudo-style elevation with auto-expiry.
- **Telemetry & Metrics Dashboard**: Token usage, request latency, provider breakdown, and data ingestion token efficiency analytics.

---

## Future Enhancements & Roadmap Candidates (0.2.0+)

### 1. Production Operations & Infrastructure
- **SQLite Automated Backup**:
  - Implement online backup (`VACUUM INTO` or LiteFS / cron snapshot scripts) for SQLite DB and `sqlite-vec` embeddings.
  - WAL checkpoint monitoring and disk usage threshold alerts.
- **External API Rate Limiting & Quota Management**:
  - Automatic exponential backoff and error-budget alert notifications when encountering HTTP 429 (Too Many Requests) or provider quota limits.
- **Temporary Cache Cleanup**:
  - Automated retention policies and periodic garbage collection for downloaded Drive files and OCR processing temp storage.

### 2. UI / UX & Internationalization (i18n)
- **Granular Admin UI Localization**:
  - Full translation coverage across all specialized low-level Platform Admin troubleshooting and LDAP/mTLS diagnostics tabs.
- **Dark Mode / Theme Customization**:
  - Seamless system/light/dark theme switching and customizable branding per desk (custom logo and color accent).

### 3. Connector & Data Source Expansions
- **Additional Enterprise Knowledge Sources**:
  - Ingestion connectors for Notion, Slack channels, Confluence spaces, and local filesystem folders alongside Google Drive.
- **User Feedback Loops**:
  - Direct 👍 / 👎 answer rating in chat UI, automatically feeding low-rated answers to administrators for Tier 1 FAQ curation.

### 4. Advanced Networking & Architecture
- **DNS & Network Telemetry**:
  - DNS request logging and intranet latency analysis for air-gapped or restricted enterprise networks.
- **Distributed Ingestion Workers**:
  - Ability to scale ingestion workers across multiple compute nodes for high-volume enterprise document repositories.
