#!/usr/bin/env bash
# ==============================================================================
# AskDrive 管理・運用スクリプト (app.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
RUNTIME_BIN="${RUNTIME_DIR}/bin"
RUNTIME_BREW="${RUNTIME_DIR}/homebrew"

# PATH の優先順位設定
export PATH="${RUNTIME_BIN}:${RUNTIME_BREW}/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${HOME}/.asdf/shims:${HOME}/.asdf/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/share/mise/bin:${PATH}"

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
  update [options]   Git/Release から自己アップデート (--yes, --ver <version>)
  repair-ollama      .runtime の Ollama を再インストール (llama-server 欠落の修復)
  admin grant <mail> 指定メールアドレスに管理者への昇格を許可 (ロックアウト時の復旧)
  admin password     管理者パスワードを再設定 (対話入力)
  drive service-account <key.json>
                     Drive 同期をサービスアカウント認証に設定 (Web 管理画面を使わずに設定)

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

  # Ollama サーバーの稼働確認と自動起動
  local ollama_host="${OLLAMA_HOST:-http://localhost:11434}"
  if ! curl -s "${ollama_host}/api/tags" >/dev/null 2>&1; then
    if command -v ollama >/dev/null 2>&1; then
      echo "Ollama サービスが停止しているため、バックグラウンド起動します..."
      ollama serve > "${SCRIPT_DIR}/log/ollama.log" 2>&1 &
      sleep 2
    fi
  fi

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

# .runtime の Ollama には ollama 本体だけでなく推論ランナー llama-server と
# ggml/llama の dylib 群が必要。旧セットアップは本体のみを配置していたため、
# モデルのロード時に "llama-server binary not found" で失敗する。
cmd_repair_ollama() {
  echo -e "${YELLOW}.runtime の Ollama を再インストールします...${NC}"
  mkdir -p "${RUNTIME_BIN}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  echo "Ollama スタンドアロン配布物 (約 160MB) を取得中..."
  if ! curl -fL --retry 3 -o "${tmp_dir}/ollama-darwin.tgz" "https://ollama.com/download/ollama-darwin.tgz"; then
    echo -e "${RED}ダウンロードに失敗しました。${NC}"
    exit 1
  fi

  if ! tar -xzf "${tmp_dir}/ollama-darwin.tgz" -C "${RUNTIME_BIN}"; then
    echo -e "${RED}展開に失敗しました。${NC}"
    exit 1
  fi

  chmod +x "${RUNTIME_BIN}/ollama" "${RUNTIME_BIN}/llama-server" 2>/dev/null || true

  if [[ ! -x "${RUNTIME_BIN}/llama-server" ]]; then
    echo -e "${RED}llama-server を配置できませんでした。${NC}"
    exit 1
  fi

  echo -e "${GREEN}ollama と llama-server を ${RUNTIME_BIN} に再インストールしました。${NC}"
  echo "稼働中の Ollama があれば再起動してください: ./app.sh restart"
}

cmd_admin() {
  local sub="${1:-}"
  shift || true

  load_env
  cd "${SCRIPT_DIR}"

  case "${sub}" in
    grant)
      local email="${1:-}"
      if [[ -z "${email}" ]]; then
        echo -e "${RED}使用方法: ./app.sh admin grant <email>${NC}"
        exit 1
      fi
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.grant_admin "${email}"
      ;;
    password)
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.set_admin_password
      ;;
    *)
      echo -e "${RED}使用方法: ./app.sh admin grant <email> | ./app.sh admin password${NC}"
      exit 1
      ;;
  esac
}

# Drive 同期の認証設定は管理画面（ログイン + 昇格が必要）からだけでなく、
# CLI からも直接できるようにする。初回セットアップ直後や、社員ログインの
# OAuth がまだ通っていない状況でも Drive 同期だけは先に設定できる。
cmd_drive() {
  local sub="${1:-}"
  shift || true

  load_env
  cd "${SCRIPT_DIR}"

  case "${sub}" in
    service-account)
      local key_path="${1:-}"
      if [[ -z "${key_path}" ]]; then
        echo -e "${RED}使用方法: ./app.sh drive service-account <path-to-key.json>${NC}"
        exit 1
      fi
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.set_drive_service_account "${key_path}"
      ;;
    *)
      echo -e "${RED}使用方法: ./app.sh drive service-account <path-to-key.json>${NC}"
      exit 1
      ;;
  esac
}

cmd_deploy() {
  if ! command -v mix >/dev/null 2>&1; then
    echo -e "${YELLOW}mix が見つからないため、初期セットアップ (setup) を実行します...${NC}"
    cmd_setup
    return 0
  fi

  if [[ -f "${SCRIPT_DIR}/scripts/deploy.sh" ]]; then
    bash "${SCRIPT_DIR}/scripts/deploy.sh"
  else
    echo -e "${RED}scripts/deploy.sh が見つかりません。${NC}"
    exit 1
  fi
}

cmd_update() {
  local auto_yes="false"
  local target_ver=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        auto_yes="true"
        shift
        ;;
      --ver|-v)
        target_ver="${2:-}"
        shift 2 || true
        ;;
      *)
        echo -e "${RED}未知の update オプション: '$1'${NC}"
        echo "使用方法: ./app.sh update [--yes] [--ver <version>]"
        exit 1
        ;;
    esac
  done

  echo -e "${BLUE}=== AskDrive 自己アップデート ===${NC}"
  cd "${SCRIPT_DIR}"

  local repo_url="https://github.com/kh813/ask-drive"

  if [[ ! -d "${SCRIPT_DIR}/.git" ]]; then
    # 非 Git (ZIP 展開環境) でのアップデート
    echo "ZIP インストール環境を検出しました。GitHub Release から更新を取得します..."
    local download_ver="${target_ver}"
    if [[ -z "${download_ver}" ]]; then
      # 最新リリースタグの取得 (macOS BSD sed および Linux GNU sed 互換)
      download_ver="$(curl -sL "https://api.github.com/repos/kh813/ask-drive/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' || echo "")"
    fi

    # 先頭の v / V を除去して正規化
    download_ver="${download_ver#v}"
    download_ver="${download_ver#V}"

    if [[ -z "${download_ver}" ]]; then
      echo -e "${RED}最新バージョン情報を取得できませんでした。ネットワーク接続または '--ver <version>' で明示してください。${NC}"
      exit 1
    fi

    echo "対象バージョン: v${download_ver}"
    if [[ "${auto_yes}" != "true" ]]; then
      read -rp "バージョン v${download_ver} をダウンロードしてアップデートを実行しますか？ (y/N): " answer
      if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
        echo "アップデートを中止しました。"
        return 0
      fi
    fi

    local zip_url="${repo_url}/releases/download/v${download_ver}/ask-drive-v${download_ver}.zip"
    local tmp_zip="/tmp/ask-drive-v${download_ver}.zip"
    echo -e "${YELLOW}==> ${zip_url} をダウンロード中...${NC}"
    curl -fL -o "${tmp_zip}" "${zip_url}"

    echo -e "${YELLOW}==> アーカイブを展開中...${NC}"
    unzip -o -q "${tmp_zip}" -d "${SCRIPT_DIR}"
    rm -f "${tmp_zip}"
    chmod +x "${SCRIPT_DIR}/app.sh" "${SCRIPT_DIR}/scripts"/*.sh 2>/dev/null || true
  else
    # Git 環境でのアップデート
    if [[ -n "${target_ver}" ]]; then
      echo "指定バージョン: ${target_ver}"
      if [[ "${auto_yes}" != "true" ]]; then
        read -rp "バージョン ${target_ver} に切り替えてアップデート/ロールバックを実行しますか？ (y/N): " answer
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
          echo "アップデートを中止しました。"
          return 0
        fi
      fi

      echo -e "${YELLOW}==> バージョン ${target_ver} をチェックアウト中...${NC}"
      git fetch --tags --all || true
      git checkout "${target_ver}"
    else
      echo "最新バージョンへの更新を確認中..."
      git fetch origin || true
      local local_hash upstream_hash
      local_hash="$(git rev-parse HEAD 2>/dev/null || echo "")"
      upstream_hash="$(git rev-parse '@{u}' 2>/dev/null || echo "")"

      if [[ -n "${local_hash}" && -n "${upstream_hash}" && "${local_hash}" == "${upstream_hash}" ]]; then
        echo -e "${GREEN}既に最新のバージョンです (${local_hash:0:7})。${NC}"
        if [[ "${auto_yes}" != "true" ]]; then
          read -rp "再ビルドとマイグレーションを再実行しますか？ (y/N): " answer
          if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            return 0
          fi
        fi
      else
        if [[ "${auto_yes}" != "true" ]]; then
          read -rp "最新コードを取得してアップデートを実行しますか？ (y/N): " answer
          if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            echo "アップデートを中止しました。"
            return 0
          fi
        fi
        echo -e "${YELLOW}==> 最新コードを取得中 (git pull)...${NC}"
        git pull --rebase origin "$(git branch --show-current)"
      fi
    fi
  fi

  # デプロイスクリプトの実行
  cmd_deploy
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
        <string>${SCRIPT_DIR}/.runtime/bin:${SCRIPT_DIR}/.runtime/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/share/mise/shims:${HOME}/.asdf/shims</string>
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
  update)
    cmd_update "$@"
    ;;
  repair-ollama)
    cmd_repair_ollama "$@"
    ;;
  admin)
    cmd_admin "$@"
    ;;
  drive)
    cmd_drive "$@"
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
