#!/usr/bin/env bash
# ==============================================================================
# AskDrive 管理・運用スクリプト (app.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ask_drive"
SERVICE_NAME="com.askdrive.server"
PLIST_FILE="${HOME}/Library/LaunchAgents/${SERVICE_NAME}.plist"
PID_FILE="${SCRIPT_DIR}/tmp/pids/app.pid"
ENV_FILE="${SCRIPT_DIR}/.env.prod"

# 色設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ヘルプ表示
show_help() {
  cat << EOF
AskDrive 管理スクリプト

使用方法:
  ./app.sh <command> [subcommand]

コマンド一覧:
  start              フォアグラウンドでアプリケーションを起動 (開発/直接実行)
  stop               起動中のプロセスを停止
  restart            アプリケーションを再起動
  status             アプリケーションおよび依存サービスの稼働状態を確認
  setup              初回セットアップを実行 (依存ツール確認、DB初期化、ビルド)
  deploy             最新コードを取得し、マイグレーションと再ビルド・再起動を実行

サービス管理 (launchd 常駐デーモン):
  service install    launchd 常駐サービスを登録 (OS 起動時自動起動)
  service uninstall  launchd 常駐サービスを解除
  service start      launchd サービスを開始
  service stop       launchd サービスを停止
  service restart    launchd サービスを再起動
  service status     launchd サービスの稼働状況・ログ確認

ヘルプ:
  --help, -h         このヘルプメッセージを表示
EOF
}

# 環境変数の読み込み
load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  elif [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
  fi
}

# ディレクトリ準備
ensure_dirs() {
  mkdir -p "${SCRIPT_DIR}/tmp/pids"
  mkdir -p "${SCRIPT_DIR}/log"
}

# --- アプリケーション制御 ---

cmd_start() {
  ensure_dirs
  load_env
  echo -e "${GREEN}==> AskDrive をフォアグラウンドで起動します...${NC}"
  
  # Ollama 実行時環境変数の最適化設定 (9-5)
  export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
  export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
  export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
  export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"

  if [[ -f "${SCRIPT_DIR}/_build/prod/rel/ask_drive/bin/ask_drive" ]]; then
    export MIX_ENV=prod
    export PHX_SERVER=true
    "${SCRIPT_DIR}/_build/prod/rel/ask_drive/bin/ask_drive" start
  else
    mix phx.server
  fi
}

cmd_stop() {
  echo -e "${YELLOW}==> AskDrive プロセスを停止します...${NC}"
  
  # PID ファイルの確認
  if [[ -f "${PID_FILE}" ]]; then
    PID="$(cat "${PID_FILE}")"
    if ps -p "${PID}" > /dev/null 2>&1; then
      kill -TERM "${PID}" || true
      echo -e "${GREEN}PID ${PID} を停止しました。${NC}"
      rm -f "${PID_FILE}"
      return 0
    fi
    rm -f "${PID_FILE}"
  fi

  # Release / Phoenix プロセス検索による停止
  local pids
  pids="$(pgrep -f "beam.*ask_drive" || true)"
  if [[ -n "${pids}" ]]; then
    echo "該当プロセス (PID: ${pids}) を停止中..."
    kill -TERM ${pids} 2>/dev/null || kill -9 ${pids} 2>/dev/null || true
    echo -e "${GREEN}停止完了しました。${NC}"
  else
    echo "稼働中のプロセスは見つかりませんでした。"
  fi
}

cmd_restart() {
  cmd_stop
  sleep 2
  cmd_start
}

cmd_status() {
  echo -e "${BLUE}=== AskDrive システムステータス ===${NC}"
  
  # 1. Ollama の確認
  echo -n "Ollama 状態: "
  if curl -s http://localhost:11434/api/version > /dev/null 2>&1; then
    local ollama_version
    ollama_version="$(curl -s http://localhost:11434/api/version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
    echo -e "${GREEN}稼働中 (v${ollama_version})${NC}"
  else
    echo -e "${RED}停止中 または 未応答 (http://localhost:11434)${NC}"
  fi

  # 2. AskDrive プロセス状態
  echo -n "AskDrive プロセス: "
  local pids
  pids="$(pgrep -f "beam.*ask_drive" || true)"
  if [[ -n "${pids}" ]]; then
    echo -e "${GREEN}稼働中 (PID: ${pids})${NC}"
  else
    echo -e "${YELLOW}停止中${NC}"
  fi

  # 3. launchd サービス状態
  echo -n "launchd サービス (${SERVICE_NAME}): "
  if launchctl list "${SERVICE_NAME}" > /dev/null 2>&1; then
    local status_code
    status_code="$(launchctl list "${SERVICE_NAME}" | awk '/"LastExitStatus"/ {print $3}' | tr -d ';')"
    local pid
    pid="$(launchctl list "${SERVICE_NAME}" | awk '/"PID"/ {print $3}' | tr -d ';')"
    if [[ -n "${pid}" && "${pid}" != "0" ]]; then
      echo -e "${GREEN}常駐稼働中 (PID: ${pid})${NC}"
    else
      echo -e "${YELLOW}登録済み (停止中 / 最終終了コード: ${status_code:-0})${NC}"
    fi
  else
    echo -e "${BLUE}未登録${NC}"
  fi

  # 4. HTTP ヘルスチェック (ポート 4000)
  echo -n "HTTP エンドポイント: "
  local port="${PORT:-4000}"
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/" > /dev/null 2>&1; then
    echo -e "${GREEN}応答あり (http://localhost:${port}/)${NC}"
  else
    echo -e "${YELLOW}接続不可${NC}"
  fi
}

cmd_setup() {
  if [[ -f "${SCRIPT_DIR}/scripts/initial-setup.sh" ]]; then
    bash "${SCRIPT_DIR}/scripts/initial-setup.sh"
  else
    echo -e "${RED}scripts/initial-setup.sh が見つかりません。${NC}"
    exit 1
  fi
}

cmd_deploy() {
  if [[ -f "${SCRIPT_DIR}/scripts/deploy.sh" ]]; then
    bash "${SCRIPT_DIR}/scripts/deploy.sh"
  else
    echo -e "${RED}scripts/deploy.sh が見つかりません。${NC}"
    exit 1
  fi
}

# --- launchd サービス管理 ---

service_install() {
  ensure_dirs
  echo -e "${GREEN}==> launchd サービスを生成・登録します: ${PLIST_FILE}${NC}"
  
  mkdir -p "${HOME}/Library/LaunchAgents"
  
  cat << EOF > "${PLIST_FILE}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_DIR}/app.sh</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/log/ask_drive_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/log/ask_drive_stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/share/mise/shims:${HOME}/.asdf/shims</string>
        <key>MIX_ENV</key>
        <string>prod</string>
        <key>PHX_SERVER</key>
        <string>true</string>
        <key>OLLAMA_MAX_LOADED_MODELS</key>
        <string>1</string>
        <key>OLLAMA_NUM_PARALLEL</key>
        <string>1</string>
        <key>OLLAMA_FLASH_ATTENTION</key>
        <string>1</string>
        <key>OLLAMA_KV_CACHE_TYPE</key>
        <string>q8_0</string>
    </dict>
</dict>
</plist>
EOF

  launchctl unload "${PLIST_FILE}" 2>/dev/null || true
  launchctl load -w "${PLIST_FILE}"
  echo -e "${GREEN}launchd サービス (${SERVICE_NAME}) を登録・有効化しました。${NC}"
}

service_uninstall() {
  echo -e "${YELLOW}==> launchd サービスを解除します...${NC}"
  if [[ -f "${PLIST_FILE}" ]]; then
    launchctl unload -w "${PLIST_FILE}" 2>/dev/null || true
    rm -f "${PLIST_FILE}"
    echo -e "${GREEN}サービス設定ファイルを削除しました。${NC}"
  else
    echo "plist ファイルは存在しません。"
  fi
}

service_start() {
  echo -e "${GREEN}==> launchd サービスを開始します...${NC}"
  if [[ ! -f "${PLIST_FILE}" ]]; then
    echo -e "${YELLOW}サービスが登録されていません。service install を先に実行します。${NC}"
    service_install
  fi
  launchctl start "${SERVICE_NAME}"
  echo -e "${GREEN}開始コマンドを送信しました。${NC}"
}

service_stop() {
  echo -e "${YELLOW}==> launchd サービスを停止します...${NC}"
  launchctl stop "${SERVICE_NAME}" || true
  echo -e "${GREEN}停止コマンドを送信しました。${NC}"
}

service_restart() {
  echo -e "${GREEN}==> launchd サービスを再起動します...${NC}"
  launchctl kickstart -k "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || {
    service_stop
    sleep 2
    service_start
  }
  echo -e "${GREEN}再起動完了しました。${NC}"
}

service_status() {
  cmd_status
}

# --- コマンドディスパッチ ---

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

COMMAND="$1"
shift || true

case "${COMMAND}" in
  start)
    cmd_start "$@"
    ;;
  stop)
    cmd_stop "$@"
    ;;
  restart)
    cmd_restart "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  setup)
    cmd_setup "$@"
    ;;
  deploy)
    cmd_deploy "$@"
    ;;
  service)
    SUB_COMMAND="${1:-}"
    shift || true
    case "${SUB_COMMAND}" in
      install)
        service_install "$@"
        ;;
      uninstall)
        service_uninstall "$@"
        ;;
      start)
        service_start "$@"
        ;;
      stop)
        service_stop "$@"
        ;;
      restart)
        service_restart "$@"
        ;;
      status)
        service_status "$@"
        ;;
      *)
        echo -e "${RED}未知の service サブコマンド: '${SUB_COMMAND}'${NC}"
        echo "利用可能: install, uninstall, start, stop, restart, status"
        exit 1
        ;;
    esac
    ;;
  --help|-h|help)
    show_help
    exit 0
    ;;
  *)
    echo -e "${RED}未知のコマンド: '${COMMAND}'${NC}"
    show_help
    exit 1
    ;;
esac
