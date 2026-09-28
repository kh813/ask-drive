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

# 1. mix コマンドおよび .env.prod の確認 (未準備なら initial-setup.sh を実行)
if ! command -v mix >/dev/null 2>&1 || [[ ! -f "${SCRIPT_DIR}/.env.prod" ]]; then
  echo -e "${YELLOW}初期環境が未構築のため、初期セットアップ (scripts/initial-setup.sh) を実行します...${NC}"
  bash "${SCRIPT_DIR}/scripts/initial-setup.sh"
  exit 0
fi

# 環境変数を読み込み
set -a
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env.prod"
set +a

# 2. 依存関係の更新
echo -e "\n${YELLOW}[1/4] 依存関係の取得中...${NC}"
mix local.hex --force || true
mix local.rebar --force || true
mix deps.get

# 3. マイグレーション
echo -e "\n${YELLOW}[2/4] データベースマイグレーションの実行中...${NC}"
MIX_ENV=prod mix ecto.create || true
MIX_ENV=prod mix ecto.migrate

# 4. アセットとリリースの再ビルド
echo -e "\n${YELLOW}[3/4] アセットとリリースのビルド中...${NC}"
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

# 5. サービスの再起動
# launchd の常駐サービスとして登録されていれば、そのサービスを再起動する（停止中なら起動）。
# 以前は無条件に `app.sh restart`（フォアグラウンド起動）を先に実行していたため、常駐運用でも
# デプロイ端末にアプリが居座り、Ctrl+C でアプリごと止まっていた。
# 登録されていなければ、従来どおりフォアグラウンドで起動する（稼働中の手動起動プロセスは先に止める）。
SERVICE_NAME="com.askdrive.server"
echo -e "\n${YELLOW}[4/4] サービスの再起動中...${NC}"
if launchctl list "${SERVICE_NAME}" >/dev/null 2>&1; then
  echo "launchd サービス (${SERVICE_NAME}) を再起動します..."
  "${SCRIPT_DIR}/app.sh" service restart
  "${SCRIPT_DIR}/app.sh" service status || true
else
  echo "launchd サービスは未登録のため、フォアグラウンドで起動します（Ctrl+C で停止します）..."
  "${SCRIPT_DIR}/app.sh" restart
fi

echo -e "\n${GREEN}=== デプロイが完了しました ===${NC}"
