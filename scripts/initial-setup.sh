#!/usr/bin/env bash
# ==============================================================================
# AskDrive 初期セットアップスクリプト (scripts/initial-setup.sh)
# 管理者権限不要 (ユーザー・アプリケーション領域 .runtime への自動インストール対応)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
RUNTIME_BIN="${RUNTIME_DIR}/bin"
RUNTIME_BREW="${RUNTIME_DIR}/homebrew"

mkdir -p "${RUNTIME_BIN}" "${SCRIPT_DIR}/tmp/pids" "${SCRIPT_DIR}/log"

# PATH の優先順位設定
export PATH="${RUNTIME_BIN}:${RUNTIME_BREW}/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${HOME}/.asdf/shims:${HOME}/.asdf/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/share/mise/bin:${PATH}"

# 色設定
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== AskDrive 初期セットアップを開始します ===${NC}"
ARCH="$(uname -m)"
echo "検出アーキテクチャ: ${ARCH}"

# 1. 依存ツールの確認 & ローカルインストール
echo -e "\n${YELLOW}[1/7] 依存ツールの確認および自動セットアップ中...${NC}"

# (A) Pandoc の確認・インストール
if ! command -v pandoc >/dev/null 2>&1; then
  echo "pandoc が見つかりません。スタンドアロンバイナリを取得中..."
  PANDOC_VER="3.6.3"
  if [[ "${ARCH}" == "arm64" ]]; then
    PANDOC_ZIP="pandoc-${PANDOC_VER}-arm64-macOS.zip"
  else
    PANDOC_ZIP="pandoc-${PANDOC_VER}-x86_64-macOS.zip"
  fi
  PANDOC_URL="https://github.com/jgm/pandoc/releases/download/${PANDOC_VER}/${PANDOC_ZIP}"
  TMP_DIR="$(mktemp -d)"
  curl -fL -o "${TMP_DIR}/${PANDOC_ZIP}" "${PANDOC_URL}"
  unzip -q -o "${TMP_DIR}/${PANDOC_ZIP}" -d "${TMP_DIR}"
  PANDOC_BIN_SRC="$(find "${TMP_DIR}" -type f -name pandoc | head -n 1)"
  if [[ -n "${PANDOC_BIN_SRC}" && -f "${PANDOC_BIN_SRC}" ]]; then
    cp "${PANDOC_BIN_SRC}" "${RUNTIME_BIN}/pandoc"
    chmod +x "${RUNTIME_BIN}/pandoc"
    echo -e "${GREEN}pandoc を ${RUNTIME_BIN}/pandoc にインストールしました。${NC}"
  else
    echo -e "${RED}pandoc バイナリの展開に失敗しました。${NC}"
  fi
  rm -rf "${TMP_DIR}"
else
  echo "pandoc: OK ($(command -v pandoc))"
fi

# (B) Ollama の確認・インストール
if ! command -v ollama >/dev/null 2>&1; then
  echo "ollama が見つかりません。スタンドアロンバイナリを取得中..."
  TMP_DIR="$(mktemp -d)"
  curl -fL -o "${TMP_DIR}/Ollama-darwin.zip" "https://ollama.com/download/Ollama-darwin.zip"
  unzip -q -o "${TMP_DIR}/Ollama-darwin.zip" -d "${TMP_DIR}"
  OLLAMA_BIN_SRC="$(find "${TMP_DIR}" -type f -name ollama | head -n 1)"
  if [[ -n "${OLLAMA_BIN_SRC}" && -f "${OLLAMA_BIN_SRC}" ]]; then
    cp "${OLLAMA_BIN_SRC}" "${RUNTIME_BIN}/ollama"
    chmod +x "${RUNTIME_BIN}/ollama"
    echo -e "${GREEN}ollama を ${RUNTIME_BIN}/ollama にインストールしました。${NC}"
  else
    echo -e "${RED}ollama バイナリの展開に失敗しました。${NC}"
  fi
  rm -rf "${TMP_DIR}"
else
  echo "ollama: OK ($(command -v ollama))"
fi

# (C) Homebrew / Poppler (pdftotext) / Erlang & Elixir の確認・インストール
NEED_BREW_PACKAGES=()
if ! command -v pdftotext >/dev/null 2>&1; then
  NEED_BREW_PACKAGES+=("poppler")
fi
if ! command -v erl >/dev/null 2>&1; then
  NEED_BREW_PACKAGES+=("erlang")
fi
if ! command -v elixir >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1; then
  NEED_BREW_PACKAGES+=("elixir")
fi

if [[ ${#NEED_BREW_PACKAGES[@]} -gt 0 ]]; then
  echo "不足しているパッケージを検出しました: ${NEED_BREW_PACKAGES[*]}"
  
  # Homebrew がない場合はユーザー領域 (.runtime/homebrew) にセットアップ
  if ! command -v brew >/dev/null 2>&1; then
    if [[ ! -x "${RUNTIME_BREW}/bin/brew" ]]; then
      echo "Homebrew をローカル領域 (.runtime/homebrew) にセットアップ中 (管理者権限不要)..."
      git clone --depth=1 https://github.com/Homebrew/brew.git "${RUNTIME_BREW}"
    fi
    export PATH="${RUNTIME_BREW}/bin:${PATH}"
  fi

  echo "Homebrew 経由で ${NEED_BREW_PACKAGES[*]} をインストール中..."
  brew install "${NEED_BREW_PACKAGES[@]}" || {
    echo -e "${YELLOW}警告: Homebrew の自動インストールで一部スキップされました。${NC}"
  }
fi

echo "pdftotext: $(command -v pdftotext || echo '未検出')"
echo "erl: $(command -v erl || echo '未検出')"
echo "mix: $(command -v mix || echo '未検出')"

# 2. sqlite-vec 拡張ライブラリの確認
echo -e "\n${YELLOW}[2/7] sqlite-vec 拡張ライブラリの確認中...${NC}"
VEC_EXT="${SCRIPT_DIR}/priv/sqlite_vec/vec0.dylib"
if [[ ! -f "${VEC_EXT}" ]]; then
  echo "sqlite-vec (vec0.dylib) をダウンロードして配置中..."
  mkdir -p "${SCRIPT_DIR}/priv/sqlite_vec"
  TMP_DIR="$(mktemp -d)"
  if [[ "${ARCH}" == "arm64" ]]; then
    VEC_URL="https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-loadable-macos-aarch64.tar.gz"
  else
    VEC_URL="https://github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-loadable-macos-x86_64.tar.gz"
  fi
  curl -fL -o "${TMP_DIR}/sqlite-vec.tar.gz" "${VEC_URL}"
  tar -xzf "${TMP_DIR}/sqlite-vec.tar.gz" -C "${TMP_DIR}"
  if [[ -f "${TMP_DIR}/vec0.dylib" ]]; then
    cp "${TMP_DIR}/vec0.dylib" "${VEC_EXT}"
  fi
  rm -rf "${TMP_DIR}"
  echo -e "${GREEN}sqlite-vec (vec0.dylib) を配置しました。${NC}"
else
  echo "sqlite-vec: OK (${VEC_EXT})"
fi

# 3. Ollama モデルの確認とダウンロード
echo -e "\n${YELLOW}[3/7] Ollama サービスとモデルの確認中...${NC}"
OLLAMA_PID=""
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "Ollama サーバーを一時起動中..."
  ollama serve > "${SCRIPT_DIR}/log/ollama_setup.log" 2>&1 &
  OLLAMA_PID=$!
  sleep 3
fi

echo "モデル bge-m3 を確認・ダウンロード中..."
ollama pull bge-m3 || true

echo "モデル qwen3:4b を確認・ダウンロード中..."
ollama pull qwen3:4b || ollama pull qwen2.5:3b || true

if [[ -n "${OLLAMA_PID}" ]]; then
  echo "一時起動した Ollama サーバーを停止中..."
  kill -TERM "${OLLAMA_PID}" 2>/dev/null || true
fi

# 4. .env.prod の生成確認
echo -e "\n${YELLOW}[4/7] 環境設定ファイルの確認中...${NC}"
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

# 5. Elixir 依存関係の取得とコンパイル
echo -e "\n${YELLOW}[5/7] Elixir 依存関係の取得中...${NC}"
cd "${SCRIPT_DIR}"
mix deps.get

# 6. データベースマイグレーション
echo -e "\n${YELLOW}[6/7] データベースマイグレーションの実行中...${NC}"
MIX_ENV=prod mix ecto.create || true
MIX_ENV=prod mix ecto.migrate

# 7. プロダクションリリースのビルド
echo -e "\n${YELLOW}[7/7] プロダクションリリースのビルド中...${NC}"
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

echo -e "\n${GREEN}=== 初期セットアップが完了しました！ ===${NC}"
echo "起動方法:"
echo "  ./app.sh start              (直接実行)"
echo "  ./app.sh service install    (OS 常駐サービス登録)"
echo "  ./app.sh service start      (常駐サービス開始)"
