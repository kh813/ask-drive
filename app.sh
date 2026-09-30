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

# macOS / Linux の差異（OS 判定、sed -i、Ollama・sqlite-vec の取得等）は platform.sh に集約
# shellcheck source=scripts/lib/platform.sh
source "${SCRIPT_DIR}/scripts/lib/platform.sh"

APP_NAME="ask_drive"
# 常駐サービス: macOS は launchd (ユーザーエージェント)、Linux は systemd (システムサービス)
SERVICE_NAME="com.askdrive.server"
PLIST_FILE="${HOME}/Library/LaunchAgents/${SERVICE_NAME}.plist"
SYSTEMD_UNIT="askdrive.service"
SYSTEMD_UNIT_FILE="/etc/systemd/system/${SYSTEMD_UNIT}"
SUDOERS_FILE="/etc/sudoers.d/askdrive"
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
  repair-ollama      .runtime に Ollama をインストール / 再インストール (あとで Ollama に切り替えるとき・llama-server 欠落の修復)
  admin grant <mail> 指定メールアドレスに管理者への昇格を許可 (ロックアウト時の復旧)
  admin password     管理者パスワードを再設定 (対話入力)
  auth status        ログイン認証・LDAP・管理者アカウントの状態
  auth disable       ログイン認証を無効に戻す (ゲスト・POC。締め出されたときの復旧)
  auth enable [mail…] ログイン認証を有効にする (mail = 管理者に昇格できるアカウント、複数可)
  auth ldap on|off   LDAP でのログインを有効 / 無効にする
  auth oauth on|off  Google ログイン（OAuth）を有効 / 無効にする
  network status     待ち受けポートと、HTTP を受け付けるリバースプロキシの状態
  network proxy-off  リバースプロキシの指定を解除 (HTTP はすべて HTTPS へ転送。締め出されたときの復旧)
  network ports-reset ポートを既定 (HTTP 4000 / HTTPS 4443) に戻して再起動
  ollama <args>      アプリ専用の Ollama を操作 (例: ./app.sh ollama pull <model> / ./app.sh ollama list)
  drive service-account [key.json] [--subject user@example.com]
                     Drive 同期をサービスアカウント認証に設定 (Web 管理画面を使わずに設定)
                     --subject: ドメイン全体の委任でなりすます社内ユーザー (社内限定の共有ドライブ用)

サービス管理 (macOS: launchd / Linux: systemd):
  service install    常駐サービスを登録 (OS 起動時に自動起動。Linux は sudo が必要)
  service uninstall  常駐サービスを解除 (Linux は sudo が必要)
  service start      サービスを開始
  service stop       サービスを停止
  service restart    サービスを再起動
  service status     サービスの稼働状況・ログ確認

ヘルプ:
  --help, -h         このヘルプメッセージを表示
EOF
}

# アプリの URL（ヘルスチェック用）。HTTPS が既定（自己署名証明書のため curl は -k で使う）
app_url() {
  case "${ASK_DRIVE_SSL:-true}" in
    false|0|no|off) echo "http://localhost:$(askdrive_port http)/" ;;
    *) echo "https://localhost:$(askdrive_port https)/" ;;
  esac
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

# 旧バージョンのセットアップは .runtime/bin に ollama 本体だけを置いていた。推論ランナー
# llama-server が無いとモデルのロード時に "llama-server binary not found" で失敗するため、
# 起動のたびに確認し、欠けていれば公式のスタンドアロン tarball を丸ごと展開して補う
# (scripts/initial-setup.sh の install_ollama_runtime と同じ手順)。
repair_ollama_runtime() {
  [[ "$(command -v ollama || true)" == "${RUNTIME_BIN}/ollama" ]] || return 0
  ollama_runtime_complete && return 0

  echo -e "${YELLOW}ollama の推論ランナーが欠落しています。Ollama を再取得します...${NC}"
  if install_ollama_runtime; then
    # 欠落した状態で起動済みの ollama serve は古いバイナリのままなので止めて起動し直させる。
    # cmd_start は PATH 経由で起動するため、argv は "ollama serve" になる。
    pkill -f "^(${RUNTIME_BIN}/)?ollama serve" 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}ollama と推論ランナーを ${RUNTIME_DIR} に配置しました。${NC}"
  else
    echo -e "${RED}Ollama の再取得に失敗しました。ローカル推論は動作しません。${NC}"
  fi
}

# ollama serve は起動直後(特に再取得した直後の初回起動)に数秒〜十数秒応答しないことがある。
# 固定の sleep で済ませると AskDrive の起動時ヘルスチェックやモデルのプリウォームが
# タイムアウトするため、/api/version が応答するまで最大 60 秒待つ。
wait_for_ollama() {
  local host="$1" i
  for ((i = 0; i < 60; i++)); do
    if curl -s --max-time 2 "${host}/api/version" >/dev/null 2>&1; then
      echo "Ollama の応答を確認しました (${i} 秒)。"
      return 0
    fi
    sleep 1
  done
  echo -e "${YELLOW}Ollama が 60 秒以内に応答しませんでした。${SCRIPT_DIR}/log/ollama.log を確認してください:${NC}"
  tail -n 20 "${SCRIPT_DIR}/log/ollama.log" 2>/dev/null || true
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

  repair_ollama_runtime

  # Ollama サーバーの稼働確認と自動起動
  local ollama_host="${OLLAMA_HOST:-http://localhost:11434}"
  if ! curl -s "${ollama_host}/api/tags" >/dev/null 2>&1; then
    if command -v ollama >/dev/null 2>&1; then
      echo "Ollama サービスが停止しているため、バックグラウンド起動します..."
      ollama serve > "${SCRIPT_DIR}/log/ollama.log" 2>&1 &
      wait_for_ollama "${ollama_host}"
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
  load_env
  echo -e "${BLUE}=== AskDrive システムステータス ===${NC}"
  echo "インストール済みバージョン: v$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*/\1/p' "${SCRIPT_DIR}/mix.exs" | head -n 1)（稼働中のバージョンは管理画面の見出し横に表示）"
  
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

  # 3. 常駐サービスの状態（macOS: launchd / Linux: systemd）
  if is_linux; then
    echo -n "systemd サービス (${SYSTEMD_UNIT}): "
    if systemd_registered; then
      local state pid
      state="$(systemctl is-active "${SYSTEMD_UNIT}" 2>/dev/null || true)"
      pid="$(systemctl show -p MainPID --value "${SYSTEMD_UNIT}" 2>/dev/null || echo 0)"
      if [[ "${state}" == "active" ]]; then
        echo -e "${GREEN}常駐稼働中 (PID: ${pid})${NC}"
      else
        echo -e "${YELLOW}登録済み (${state:-停止中})${NC}"
      fi
    else
      echo -e "${BLUE}未登録${NC}"
    fi
  else
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
  fi

  # 5. 初回セットアップ（spec 6.12）: 未完了ならセットアップコードを表示する
  local setup_code_file
  setup_code_file="$(dirname "${DATABASE_PATH:-${SCRIPT_DIR}/ask_drive_prod.db}")/setup_code"
  if [[ -f "${setup_code_file}" ]]; then
    echo -e "${YELLOW}初回セットアップ: 未完了です。ブラウザで AskDrive を開き、次のセットアップコードを入力してください。${NC}"
    echo -e "  セットアップコード: ${GREEN}$(cat "${setup_code_file}")${NC}"
  fi

  # 4. HTTP(S) ヘルスチェック。既定は HTTPS（4443）。ASK_DRIVE_SSL=false のときは HTTP（PORT）
  local url
  url="$(app_url)"
  echo -n "Web エンドポイント: "
  if curl -sk -o /dev/null "${url}" > /dev/null 2>&1; then
    echo -e "${GREEN}応答あり (${url})${NC}"
  else
    echo -e "${YELLOW}接続不可 (${url})${NC}"
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
  if ! install_ollama_runtime; then
    echo -e "${RED}Ollama の再インストールに失敗しました。${NC}"
    exit 1
  fi
  echo -e "${GREEN}ollama と推論ランナーを ${RUNTIME_DIR} に再インストールしました。${NC}"
  echo "稼働中の Ollama があれば再起動してください: ./app.sh restart"
  cmd_deploy
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

# 待ち受けポートとリバースプロキシ（F-1013）: 管理画面で変えた設定を戻すための復旧用。
# 設定は ssl/listen.json。プロキシの解除は再起動なしで反映、ポートは再起動で反映する。
cmd_network() {
  load_env
  cd "${SCRIPT_DIR}"

  case "${1:-}" in
    status|proxy-off)
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.network "$@"
      ;;
    ports-reset)
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.network ports-reset
      echo "再起動して反映します..."
      if service_registered; then service_restart; else cmd_restart; fi
      ;;
    *)
      echo -e "${RED}使用方法: ./app.sh network status | proxy-off | ports-reset${NC}"
      exit 1
      ;;
  esac
}

# ログイン認証（F-1308）: 管理画面に入れなくなったときの復旧用。稼働中のサービスは
# リクエストごとに設定を読むため、再起動なしで反映される。
cmd_auth() {
  load_env
  cd "${SCRIPT_DIR}"

  case "${1:-}" in
    status|disable|enable|ldap|oauth)
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.auth "$@"
      ;;
    *)
      echo -e "${RED}使用方法: ./app.sh auth status | disable | enable [email ...] | ldap on|off | oauth on|off${NC}"
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
      # 引数なし、またはファイルが無い場合は JSON を対話的に貼り付けるモードへ
      # 自動的にフォールバックする（mix タスク側で処理する）。--subject もそのまま渡す。
      MIX_ENV="${MIX_ENV:-prod}" mix ask_drive.set_drive_service_account "$@"
      ;;
    *)
      echo -e "${RED}使用方法: ./app.sh drive service-account [path-to-key.json] [--subject user@example.com]${NC}"
      echo "  パスを省略すると、JSON の中身を貼り付けて設定できます。"
      exit 1
      ;;
  esac
}

# アプリ専用の Ollama（.runtime/bin）をそのまま操作する。
# 例: ./app.sh ollama pull qwen3:4b-instruct-2507-q4_K_M / ./app.sh ollama list
# 通常はアプリが起動時・管理画面から必要なモデルを取得するため、手動操作は不要。
cmd_ollama() {
  load_env
  if ! command -v ollama >/dev/null 2>&1; then
    echo -e "${RED}ollama が見つかりません（${RUNTIME_BIN}）。scripts/initial-setup.sh を実行してください。${NC}"
    exit 1
  fi
  ollama "$@"
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

launchd_install() {
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

launchd_uninstall() {
  echo -e "${YELLOW}==> launchd サービスを解除します...${NC}"
  if [[ -f "${PLIST_FILE}" ]]; then
    launchctl unload -w "${PLIST_FILE}" 2>/dev/null || true
    rm -f "${PLIST_FILE}"
    echo -e "${GREEN}サービス設定ファイルを削除しました。${NC}"
  else
    echo "plist ファイルは存在しません。"
  fi
}

launchd_start() {
  echo -e "${GREEN}==> launchd サービスを開始します...${NC}"
  if [[ ! -f "${PLIST_FILE}" ]]; then
    echo -e "${YELLOW}サービスが登録されていません。service install を先に実行します。${NC}"
    launchd_install
  fi
  launchctl start "${SERVICE_NAME}"
  echo -e "${GREEN}開始コマンドを送信しました。${NC}"
}

launchd_stop() {
  echo -e "${YELLOW}==> launchd サービスを停止します...${NC}"
  launchctl stop "${SERVICE_NAME}" || true
  echo -e "${GREEN}停止コマンドを送信しました。${NC}"
}

launchd_restart() {
  echo -e "${GREEN}==> launchd サービスを再起動します...${NC}"
  launchctl kickstart -k "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || {
    launchd_stop
    sleep 2
    launchd_start
  }
  echo -e "${GREEN}再起動完了しました。${NC}"
}


# --- systemd サービス管理 (Linux) ---
#
# システムサービス (/etc/systemd/system/askdrive.service) として、このスクリプトを実行している
# 一般ユーザーの権限で動かす。登録（install）と解除（uninstall）には sudo が必要。
# 登録時に /etc/sudoers.d/askdrive を置き、このユーザーが askdrive サービスの
# start / stop / restart だけをパスワードなしで実行できるようにする。これにより、以降の
# ./app.sh deploy（再起動を含む）は管理者の介在なしに実行できる。

systemd_registered() {
  systemctl list-unit-files "${SYSTEMD_UNIT}" --no-legend 2>/dev/null | grep -q "${SYSTEMD_UNIT}"
}

systemd_install() {
  ensure_dirs
  local user group systemctl_bin unit_tmp sudoers_tmp
  user="$(id -un)"
  group="$(id -gn)"
  systemctl_bin="$(command -v systemctl)"
  unit_tmp="$(mktemp)"
  sudoers_tmp="$(mktemp)"

  echo -e "${GREEN}==> systemd サービスを登録します: ${SYSTEMD_UNIT_FILE}（sudo が必要です）${NC}"

  systemd_unit_content "${SCRIPT_DIR}" "${user}" "${group}" "${HOME}" > "${unit_tmp}"
  systemd_sudoers_content "${user}" "${systemctl_bin}" "${SYSTEMD_UNIT}" > "${sudoers_tmp}"

  if ! sudo visudo -cf "${sudoers_tmp}" >/dev/null; then
    echo -e "${RED}sudoers の検証に失敗しました。登録を中止します。${NC}"
    rm -f "${unit_tmp}" "${sudoers_tmp}"
    return 1
  fi

  sudo install -m 0644 "${unit_tmp}" "${SYSTEMD_UNIT_FILE}"
  sudo install -m 0440 "${sudoers_tmp}" "${SUDOERS_FILE}"
  rm -f "${unit_tmp}" "${sudoers_tmp}"

  sudo systemctl daemon-reload
  sudo systemctl enable --now "${SYSTEMD_UNIT}"
  echo -e "${GREEN}systemd サービス (${SYSTEMD_UNIT}) を登録・起動しました。サーバー起動時に自動で開始します。${NC}"
}

systemd_uninstall() {
  echo -e "${YELLOW}==> systemd サービスを解除します（sudo が必要です）...${NC}"
  if systemd_registered; then
    sudo systemctl disable --now "${SYSTEMD_UNIT}" || true
  fi
  sudo rm -f "${SYSTEMD_UNIT_FILE}" "${SUDOERS_FILE}"
  sudo systemctl daemon-reload
  echo -e "${GREEN}サービスを解除しました。${NC}"
}

# start / stop / restart は sudoers で許可済み（-n: パスワードを求めず、未許可なら即失敗）
systemd_ctl() {
  local action="$1"
  if ! systemd_registered; then
    echo -e "${YELLOW}サービスが登録されていません。./app.sh service install を先に実行してください。${NC}"
    return 1
  fi
  sudo -n "$(command -v systemctl)" "${action}" "${SYSTEMD_UNIT}" || {
    echo -e "${RED}systemctl ${action} に失敗しました（sudo の許可設定がない場合は ./app.sh service install をやり直してください）。${NC}"
    return 1
  }
}

# --- 常駐サービス（OS ごとに launchd / systemd へ振り分け）---

service_install() { if is_linux; then systemd_install; else launchd_install; fi; }
service_uninstall() { if is_linux; then systemd_uninstall; else launchd_uninstall; fi; }
service_start() { if is_linux; then systemd_ctl start; else launchd_start; fi; }
service_stop() { if is_linux; then systemd_ctl stop; else launchd_stop; fi; }

service_restart() {
  if is_linux; then
    echo -e "${GREEN}==> systemd サービスを再起動します...${NC}"
    systemd_ctl restart && echo -e "${GREEN}再起動しました。${NC}"
  else
    launchd_restart
  fi
}

# デプロイ等から使う: 常駐サービスとして登録済みか
service_registered() {
  if is_linux; then
    systemd_registered
  else
    launchctl list "${SERVICE_NAME}" >/dev/null 2>&1
  fi
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
  auth)
    cmd_auth "$@"
    ;;
  network)
    cmd_network "$@"
    ;;
  drive)
    cmd_drive "$@"
    ;;
  ollama)
    cmd_ollama "$@"
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
      registered)
        # 終了コードで返す（scripts/deploy.sh が使う）: 0 = 常駐サービスとして登録済み
        service_registered
        ;;
      *)
        echo -e "${RED}未知の service サブコマンド: '${SUB_COMMAND}'${NC}"
        echo "利用可能: install, uninstall, start, stop, restart, status, registered"
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
