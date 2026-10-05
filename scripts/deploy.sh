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

# 管理画面からのアップデート（F-1502）: 稼働中のサーバーとバッチはそのままビルドだけ行う。
# リリースは稼働中のものの隣（ask_drive.next）に作り、次の起動（./app.sh start）で切り替える。
# マイグレーションは新しいリリースの起動時に実行されるため、ここでは行わない（稼働中の古いコードの
# 下でスキーマを変えない）。再起動は管理画面（サーバー自身）が行う。
BUILD_ONLY="${ASK_DRIVE_DEPLOY_BUILD_ONLY:-}"
REL_DIR="${SCRIPT_DIR}/_build/prod/rel"

# 1. mix コマンドおよび .env.prod の確認 (未準備なら initial-setup.sh を実行)
if ! command -v mix >/dev/null 2>&1 || [[ ! -f "${SCRIPT_DIR}/.env.prod" ]]; then
  if [[ -n "${BUILD_ONLY}" ]]; then
    echo "初期環境が未構築です（mix または .env.prod がありません）。サーバーで ./app.sh setup を実行してください。"
    exit 1
  fi
  echo -e "${YELLOW}初期環境が未構築のため、初期セットアップ (scripts/initial-setup.sh) を実行します...${NC}"
  bash "${SCRIPT_DIR}/scripts/initial-setup.sh"
  exit 0
fi

# 環境変数を読み込み
set -a
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env.prod"
set +a

# 1b. ZIP で更新した環境: 新しいリリースで削除されたファイルを消す
# unzip は上書きするだけなので、リリースから消えたソース（例: 廃止した mix タスク）が残り、
# コンパイルされて警告やエラーになる。リリースに同梱のファイル一覧（RELEASE_MANIFEST）にない
# ファイルを、アプリのソースのディレクトリに限って削除する（.env.prod・DB・証明書などには触れない）。
# 照合は並び順に依存しない完全一致（grep -Fx）で行う。v0.1.10 は sort + comm で照合していたため、
# ロケールによる並び順の違いで、残すべきファイルまで削除してしまった。
# 安全のため、一覧が不完全に見える場合や、削除が多すぎる場合は何も削除しない。
prune_removed_files() {
  local manifest="${SCRIPT_DIR}/RELEASE_MANIFEST"
  [[ ! -d "${SCRIPT_DIR}/.git" && -f "${manifest}" ]] || return 0

  if ! grep -qx "mix.exs" "${manifest}" || ! grep -qx "lib/ask_drive/application.ex" "${manifest}"; then
    echo -e "${YELLOW}  RELEASE_MANIFEST が不完全なため、削除済みファイルの整理を省略します。${NC}"
    return 0
  fi

  local stale_list dir
  stale_list="$(mktemp)"
  for dir in lib config priv/repo priv/gettext assets/js assets/css scripts; do
    [[ -d "${SCRIPT_DIR}/${dir}" ]] || continue
    (cd "${SCRIPT_DIR}" && find "${dir}" -type f) | grep -Fxv -f "${manifest}" >> "${stale_list}" || true
  done

  local count
  count="$(grep -c . "${stale_list}" || true)"
  if [[ "${count}" -gt 20 ]]; then
    echo -e "${YELLOW}  リリースにないファイルが ${count} 件あり多すぎるため、削除を省略します（想定外の状態）。${NC}"
  elif [[ "${count}" -gt 0 ]]; then
    local stale
    while IFS= read -r stale; do
      echo -e "${YELLOW}  リリースから削除されたファイルを削除: ${stale}${NC}"
      rm -f "${SCRIPT_DIR:?}/${stale:?}"
    done < "${stale_list}"
  fi
  rm -f "${stale_list:?}"
}
prune_removed_files

# 2. 依存関係の更新
echo -e "\n${YELLOW}[1/4] 依存関係の取得中...${NC}"
mix local.hex --force || true
mix local.rebar --force || true
mix deps.get

# 3. マイグレーション
if [[ -n "${BUILD_ONLY}" ]]; then
  echo -e "\n${YELLOW}[2/4] データベースマイグレーションは新しいバージョンの起動時に実行します${NC}"
else
  echo -e "\n${YELLOW}[2/4] データベースマイグレーションの実行中...${NC}"
  MIX_ENV=prod mix ecto.create || true
  MIX_ENV=prod mix ecto.migrate
fi

# 4. アセットとリリースの再ビルド
echo -e "\n${YELLOW}[3/4] アセットとリリースのビルド中...${NC}"
MIX_ENV=prod mix assets.deploy
# 前回の管理画面からのアップデートで、切り替えられずに残ったビルドは使わない
rm -rf "${REL_DIR}/ask_drive.next"
if [[ -n "${BUILD_ONLY}" ]]; then
  MIX_ENV=prod mix release --overwrite --path "${REL_DIR}/ask_drive.next"
  echo -e "\n${GREEN}=== ビルドが完了しました（${REL_DIR}/ask_drive.next）。次の起動で切り替わります ===${NC}"
  exit 0
fi
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
    false|0|no|off) app_url="http://localhost:$(askdrive_port http)/" ;;
    *) app_url="https://localhost:$(askdrive_port https)/" ;;
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
