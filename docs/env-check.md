# Phase 0: 環境検証レポート (env-check.md)

実施日: 2026-09-28
環境: macOS (Apple Silicon ARM64)

## 1. ランタイム & 言語
- **Erlang/OTP**: `Erlang/OTP 29 [erts-17.0.3]`
- **Elixir**: `Elixir 1.20.2`
- **Mix**: `Mix 1.20.2`
- **Phoenix Generator**: `phx_new 1.8.15`

## 2. 外部 CLI ツール
- **Homebrew**: `Homebrew 6.0.19`
- **poppler (pdftotext)**: `pdftotext version 26.09.0`
- **pandoc**: `pandoc 3.11`
- **SQLite3**: `3.53.3` (FTS5 / trigram 有効確認済み)

## 3. SQLite C拡張 (sqlite-vec)
- **バージョン**: `sqlite-vec v0.1.9` (ARM64 loadable dylib)
- **配置先**: `priv/sqlite_vec/vec0.dylib`
- **検証結果**:
```sql
sqlite> .load ./priv/sqlite_vec/vec0
sqlite> SELECT vec_version();
v0.1.9
```

## 4. Ollama & LLM / 埋め込みモデル
- **Ollama**: `v0.34.4` (常駐確認済み)
- **取得済みモデル**:
  - `bge-m3:latest` (1024次元 埋め込みモデル)
  - `qwen3:4b` (夜間バッチ生成用 4B モデル)
- **埋め込み疎通確認 (`/api/embed`)**:
  - 複数テキスト投入に対し 1024 次元の埋め込みベクトル正常返却を確認済み。
