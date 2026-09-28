#!/usr/bin/env bash
# ==============================================================================
# AskDrive デプロイ・更新スクリプト (scripts/deploy.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== AskDrive デプロイ処理を開始します ===${NC}"
cd "${SCRIPT_DIR}"

# 1. 依存関係の更新
echo -e "\n${YELLOW}[1/4] 依存関係の取得中...${NC}"
mix deps.get

# 2. マイグレーション
echo -e "\n${YELLOW}[2/4] データベースマイグレーションの実行中...${NC}"
MIX_ENV=prod mix ecto.migrate

# 3. アセットとリリースの再ビルド
echo -e "\n${YELLOW}[3/4] アセットとリリースのビルド中...${NC}"
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

# 4. サービスの再起動
echo -e "\n${YELLOW}[4/4] サービスの再起動中...${NC}"
"${SCRIPT_DIR}/app.sh" restart || "${SCRIPT_DIR}/app.sh" service restart || true

echo -e "\n${GREEN}=== デプロイが完了しました ===${NC}"
