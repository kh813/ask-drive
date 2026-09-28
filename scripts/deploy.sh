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

# macOS / Linux の差異（PATH に .runtime の Erlang/Elixir を含める等）
# shellcheck source=scripts/lib/platform.sh
source "${SCRIPT_DIR}/scripts/lib/platform.sh"

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
# 常駐サービス（macOS: launchd / Linux: systemd）として登録されていれば、そのサービスを再起動する。
# 以前は無条件に `app.sh restart`（フォアグラウンド起動）を先に実行していたため、常駐運用でも
# デプロイ端末にアプリが居座り、Ctrl+C でアプリごと止まっていた。
# 登録されていなければ、従来どおりフォアグラウンドで起動する（稼働中の手動起動プロセスは先に止める）。
echo -e "\n${YELLOW}[4/4] サービスの再起動中...${NC}"
if "${SCRIPT_DIR}/app.sh" service registered; then
  echo "常駐サービスを再起動します..."
  "${SCRIPT_DIR}/app.sh" service restart

  # kickstart は起動を待たずに戻るため、直後にステータスを出すと Ollama・AskDrive とも
  # 「停止中」と表示されてしまう。HTTP が応答するまで最大 120 秒待ってから表示する。
  case "${ASK_DRIVE_SSL:-true}" in
    false|0|no|off) app_url="http://localhost:${PORT:-4000}/" ;;
    *) app_url="https://localhost:${ASK_DRIVE_HTTPS_PORT:-4443}/" ;;
  esac
  echo -n "AskDrive の起動を待っています (${app_url})"
  for _ in $(seq 1 120); do
    if curl -sk -o /dev/null "${app_url}" 2>/dev/null; then
      echo " 起動しました。"
      break
    fi
    echo -n "."
    sleep 1
  done
  if ! curl -sk -o /dev/null "${app_url}" 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}120 秒以内に応答しませんでした。ログを確認してください:${NC}"
    echo "  ${SCRIPT_DIR}/log/ask_drive_stdout.log / ask_drive_stderr.log"
    tail -n 20 "${SCRIPT_DIR}/log/ask_drive_stderr.log" 2>/dev/null || true
  fi
  "${SCRIPT_DIR}/app.sh" service status || true
else
  echo "常駐サービスは未登録のため、フォアグラウンドで起動します（Ctrl+C で停止します）..."
  "${SCRIPT_DIR}/app.sh" restart
fi

echo -e "\n${GREEN}=== デプロイが完了しました ===${NC}"
