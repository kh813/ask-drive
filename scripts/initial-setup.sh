#!/usr/bin/env bash
# ==============================================================================
# AskDrive 初期セットアップスクリプト (scripts/initial-setup.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 色設定
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== AskDrive 初期セットアップを開始します ===${NC}"

# 1. 外部ツールの確認
echo -e "\n${YELLOW}[1/6] 依存ツールの確認中...${NC}"
for cmd in git sqlite3 curl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo -e "${RED}エラー: ${cmd} がインストールされていません。${NC}"
    exit 1
  fi
done

# Homebrew 依存
if ! command -v pdftotext >/dev/null 2>&1 || ! command -v pandoc >/dev/null 2>&1; then
  echo -e "${YELLOW}警告: poppler (pdftotext) または pandoc が見つかりません。${NC}"
  echo "Homebrew でインストールを推奨します: brew install poppler pandoc"
else
  echo "pdftotext / pandoc: OK"
fi

# 2. sqlite-vec 拡張ライブラリの確認
echo -e "\n${YELLOW}[2/6] sqlite-vec 拡張ライブラリの確認中...${NC}"
VEC_EXT="${SCRIPT_DIR}/priv/sqlite_vec/vec0.dylib"
if [[ ! -f "${VEC_EXT}" ]]; then
  echo "sqlite-vec (vec0.dylib) をダウンロードして配置中..."
  mkdir -p "${SCRIPT_DIR}/priv/sqlite_vec"
  curl -L -o "${SCRIPT_DIR}/priv/sqlite_vec/vec0.dylib" \
    "https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-v0.1.9-loadable-macos-aarch64.tar.gz" 2>/dev/null || true
fi

# 3. .env.prod の生成確認
echo -e "\n${YELLOW}[3/6] 環境設定ファイルの確認中...${NC}"
if [[ ! -f "${SCRIPT_DIR}/.env.prod" ]]; then
  echo ".env.prod を新規作成中..."
  SECRET_KEY="$(mix phx.gen.secret)"
  ENCRYPTION_KEY="$(mix ask_drive.gen.key)"

  cat << EOF > "${SCRIPT_DIR}/.env.prod"
MIX_ENV=prod
PHX_SERVER=true
PORT=4000
PHX_HOST=localhost
SECRET_KEY_BASE=${SECRET_KEY}
ASK_DRIVE_ENCRYPTION_KEY=${ENCRYPTION_KEY}
DATABASE_PATH=${SCRIPT_DIR}/ask_drive_prod.db
OLLAMA_HOST=http://localhost:11434
EOF
  echo -e "${GREEN}.env.prod を生成しました。${NC}"
fi

# 4. Elixir 依存関係の取得とコンパイル
echo -e "\n${YELLOW}[4/6] Elixir 依存関係の取得中...${NC}"
cd "${SCRIPT_DIR}"
mix deps.get

# 5. アセットのビルドとマイグレーション
echo -e "\n${YELLOW}[5/6] データベースマイグレーションの実行中...${NC}"
MIX_ENV=prod mix ecto.create || true
MIX_ENV=prod mix ecto.migrate

echo -e "\n${YELLOW}[6/6] プロダクションリリースのビルド中...${NC}"
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

echo -e "\n${GREEN}=== 初期セットアップが完了しました！ ===${NC}"
echo "起動方法:"
echo "  ./app.sh start              (直接実行)"
echo "  ./app.sh service install    (OS 常駐サービス登録)"
echo "  ./app.sh service start      (常駐サービス開始)"
