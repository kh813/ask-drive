#!/usr/bin/env bash
# ==============================================================================
# AskDrive デプロイ・更新スクリプト (scripts/deploy.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
RUNTIME_BIN="${RUNTIME_DIR}/bin"
RUNTIME_BREW="${RUNTIME_DIR}/homebrew"

# PATH の優先順位設定
export PATH="${RUNTIME_BIN}:${RUNTIME_BREW}/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${HOME}/.asdf/shims:${HOME}/.asdf/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/share/mise/bin:${PATH}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== AskDrive デプロイ処理を開始します ===${NC}"
cd "${SCRIPT_DIR}"

# mix の存在確認 (未インストール時は初回セットアップを実行)
if ! command -v mix >/dev/null 2>&1; then
  echo -e "${YELLOW}mix が見つかりません。初回セットアップ (scripts/initial-setup.sh) を自動実行します...${NC}"
  bash "${SCRIPT_DIR}/scripts/initial-setup.sh"
  exit 0
fi

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
