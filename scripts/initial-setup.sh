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
#
# ollama は単体のバイナリではなく、推論ランナー llama-server と ggml/llama の dylib 群を
# 同じディレクトリに必要とする。ollama 本体だけを配置すると、モデルのロード時に
#   "error starting llama-server: llama-server binary not found"
# で失敗する。そのため .app の zip から ollama を 1 個だけ抜き出すのではなく、
# 公式のスタンドアロン tarball を丸ごと RUNTIME_BIN へ展開する。
install_ollama_runtime() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  echo "Ollama スタンドアロン配布物 (約 160MB) を取得中..."

  if ! curl -fL --retry 3 -o "${tmp_dir}/ollama-darwin.tgz" "https://ollama.com/download/ollama-darwin.tgz"; then
    echo -e "${RED}Ollama のダウンロードに失敗しました。${NC}"
    rm -rf "${tmp_dir}"
    return 1
  fi

  # tarball は ollama / llama-server / 各種 dylib がフラットに並んだ構成。
  # dylib は実行ファイルからの相対パスで解決されるため、同一ディレクトリへ展開する。
  if ! tar -xzf "${tmp_dir}/ollama-darwin.tgz" -C "${RUNTIME_BIN}"; then
    echo -e "${RED}Ollama の展開に失敗しました。${NC}"
    rm -rf "${tmp_dir}"
    return 1
  fi

  chmod +x "${RUNTIME_BIN}/ollama" "${RUNTIME_BIN}/llama-server" 2>/dev/null || true
  rm -rf "${tmp_dir}"

  if [[ ! -x "${RUNTIME_BIN}/llama-server" ]]; then
    echo -e "${RED}llama-server が見つかりません。Ollama のインストールが不完全です。${NC}"
    return 1
  fi

  echo -e "${GREEN}ollama と llama-server を ${RUNTIME_BIN} にインストールしました。${NC}"
}

OLLAMA_PATH="$(command -v ollama || true)"
if [[ -z "${OLLAMA_PATH}" ]]; then
  echo "ollama が見つかりません。"
  install_ollama_runtime
elif [[ "${OLLAMA_PATH}" == "${RUNTIME_BIN}/ollama" && ! -x "${RUNTIME_BIN}/llama-server" ]]; then
  # 旧バージョンのセットアップが ollama 本体だけを配置した状態。ランナーを補って修復する。
  echo -e "${YELLOW}ollama はありますが推論ランナー (llama-server) が欠落しています。再インストールします。${NC}"
  install_ollama_runtime
else
  echo "ollama: OK (${OLLAMA_PATH})"
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

# 3. .env.prod の生成と初期設定の入力
echo -e "\n${YELLOW}[3/7] 環境設定ファイルの確認中...${NC}"
if [[ ! -f "${SCRIPT_DIR}/.env.prod" ]]; then
  echo ".env.prod を新規作成中..."
  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY="$(openssl rand -base64 48 | tr -d '\n')"
    ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  else
    SECRET_KEY="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
    ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  fi

  # 値は .env.prod への初期値。保存後は管理画面の設定が優先されるため、
  # ここで空欄にしても後からすべて変更できる。
  cat << 'BANNER'

--------------------------------------------------------------------
 初期設定
   ここで入力する内容はすべて後から管理画面で変更できます。
   空欄で Enter を押すと既定値を使います。
--------------------------------------------------------------------
BANNER

  echo -e "\n${BLUE}[LLM プロバイダの選択]${NC}"
  echo "  1) ollama    - ローカル推論（既定・完全ローカル、追加費用なし）"
  echo "  2) lmstudio  - LM Studio のローカルサーバー（OpenAI 互換）"
  echo "  3) gemini    - Google Gemini API"
  echo "  4) anthropic - Anthropic Claude API"
  echo "  5) openai    - OpenAI API"
  echo -e "  ${YELLOW}※ 3〜5 を選ぶと、文書本文と質問が外部 API に送信されます。${NC}"

  provider_from_choice() {
    case "$1" in
      2) echo "lmstudio" ;;
      3) echo "gemini" ;;
      4) echo "anthropic" ;;
      5) echo "openai" ;;
      *) echo "ollama" ;;
    esac
  }

  default_gen_model_for() {
    case "$1" in
      gemini) echo "gemini-2.5-flash" ;;
      anthropic) echo "claude-sonnet-5" ;;
      openai) echo "gpt-5" ;;
      lmstudio) echo "" ;;
      *) echo "qwen3:4b" ;;
    esac
  }

  default_embed_model_for() {
    case "$1" in
      gemini) echo "gemini-embedding-001" ;;
      openai) echo "text-embedding-3-small" ;;
      lmstudio) echo "text-embedding-nomic-embed-text-v1.5" ;;
      *) echo "bge-m3" ;;
    esac
  }

  default_embed_dim_for() {
    case "$1" in
      gemini) echo "768" ;;
      openai) echo "1536" ;;
      lmstudio) echo "768" ;;
      *) echo "1024" ;;
    esac
  }

  read -r -p "回答生成に使うプロバイダ [1-5] (既定: 1): " GEN_CHOICE
  LLM_PROVIDER="$(provider_from_choice "${GEN_CHOICE:-1}")"
  DEFAULT_GEN_MODEL="$(default_gen_model_for "${LLM_PROVIDER}")"
  read -r -p "生成モデル名 (既定: ${DEFAULT_GEN_MODEL:-ロード中のモデル}): " LLM_MODEL
  LLM_MODEL="${LLM_MODEL:-${DEFAULT_GEN_MODEL}}"

  echo ""
  echo "  ※ 埋め込みは Claude API 非対応のため選択肢から除外されます。"
  echo "  ※ 埋め込みを変更すると全ドキュメントの再インデックスが必要です。ローカルのままを推奨します。"
  read -r -p "埋め込みに使うプロバイダ [1,2,3,5] (既定: 1): " EMB_CHOICE
  EMBED_PROVIDER="$(provider_from_choice "${EMB_CHOICE:-1}")"
  if [[ "${EMBED_PROVIDER}" == "anthropic" ]]; then
    echo -e "${YELLOW}Claude API は埋め込みに対応していません。ollama を使用します。${NC}"
    EMBED_PROVIDER="ollama"
  fi
  DEFAULT_EMBED_MODEL="$(default_embed_model_for "${EMBED_PROVIDER}")"
  read -r -p "埋め込みモデル名 (既定: ${DEFAULT_EMBED_MODEL}): " EMBED_MODEL
  EMBED_MODEL="${EMBED_MODEL:-${DEFAULT_EMBED_MODEL}}"
  DEFAULT_EMBED_DIM="$(default_embed_dim_for "${EMBED_PROVIDER}")"
  read -r -p "埋め込み次元 (既定: ${DEFAULT_EMBED_DIM}): " EMBED_DIM
  EMBED_DIM="${EMBED_DIM:-${DEFAULT_EMBED_DIM}}"

  # API キーは入力中に画面へ出さない。
  ANTHROPIC_KEY=""
  GEMINI_KEY=""
  OPENAI_KEY=""
  for needed in "${LLM_PROVIDER}" "${EMBED_PROVIDER}"; do
    case "${needed}" in
      anthropic)
        if [[ -z "${ANTHROPIC_KEY}" ]]; then
          read -r -s -p "Anthropic API キー: " ANTHROPIC_KEY; echo ""
        fi
        ;;
      gemini)
        if [[ -z "${GEMINI_KEY}" ]]; then
          read -r -s -p "Google Gemini API キー: " GEMINI_KEY; echo ""
        fi
        ;;
      openai)
        if [[ -z "${OPENAI_KEY}" ]]; then
          read -r -s -p "OpenAI API キー: " OPENAI_KEY; echo ""
        fi
        ;;
    esac
  done

  echo -e "\n${BLUE}[Google 連携とアクセス制御]${NC}"
  read -r -p "Google OAuth クライアント ID (後から設定可): " GOOGLE_ID
  read -r -s -p "Google OAuth クライアント シークレット (後から設定可): " GOOGLE_SECRET; echo ""
  read -r -p "許可する Google Workspace ドメイン (例: company.com): " ALLOWED_DOMAIN
  read -r -p "管理者へ昇格できるアカウント（カンマ区切り、複数可）: " ADMIN_EMAILS

  # 管理者パスワードは sudo 相当。未入力なら初回昇格時に画面から設定させる。
  ADMIN_PASSWORD=""
  while true; do
    read -r -s -p "管理者パスワード（管理画面へ昇格する際に入力・8文字以上・空欄可）: " ADMIN_PASSWORD; echo ""
    if [[ -z "${ADMIN_PASSWORD}" ]]; then
      echo -e "${YELLOW}未設定のまま進みます。初回の昇格時にブラウザから設定できます。${NC}"
      break
    fi
    if [[ "${#ADMIN_PASSWORD}" -lt 8 ]]; then
      echo -e "${RED}8 文字以上にしてください。${NC}"
      continue
    fi
    read -r -s -p "管理者パスワード（確認）: " ADMIN_PASSWORD_CONFIRM; echo ""
    if [[ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]]; then
      echo -e "${RED}一致しません。もう一度入力してください。${NC}"
      continue
    fi
    break
  done

  cat << EOF > "${SCRIPT_DIR}/.env.prod"
MIX_ENV=prod
PHX_SERVER=true
PORT=4000
PHX_HOST=localhost
SECRET_KEY_BASE=${SECRET_KEY}
ASK_DRIVE_ENCRYPTION_KEY=${ENCRYPTION_KEY}
DATABASE_PATH=${SCRIPT_DIR}/ask_drive_prod.db

# --- Google 連携とアクセス制御 ---
GOOGLE_CLIENT_ID=${GOOGLE_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_SECRET}
ASK_DRIVE_ALLOWED_DOMAIN=${ALLOWED_DOMAIN}
ASK_DRIVE_ADMIN_EMAILS=${ADMIN_EMAILS}
# 起動時にハッシュ化して DB へ保存される。保存後この値は参照されない。
ASK_DRIVE_ADMIN_PASSWORD=${ADMIN_PASSWORD}

# --- LLM プロバイダ ---
ASK_DRIVE_LLM_PROVIDER=${LLM_PROVIDER}
ASK_DRIVE_LLM_MODEL=${LLM_MODEL}
ASK_DRIVE_EMBED_PROVIDER=${EMBED_PROVIDER}
ASK_DRIVE_EMBED_MODEL=${EMBED_MODEL}
ASK_DRIVE_EMBEDDING_DIM=${EMBED_DIM}
OLLAMA_HOST=http://localhost:11434
LMSTUDIO_BASE_URL=http://localhost:1234/v1
ANTHROPIC_API_KEY=${ANTHROPIC_KEY}
GEMINI_API_KEY=${GEMINI_KEY}
OPENAI_API_KEY=${OPENAI_KEY}
EOF
  chmod 600 "${SCRIPT_DIR}/.env.prod"
  echo -e "${GREEN}.env.prod を生成しました（パーミッション 600）。${NC}"
fi

# 生成した .env.prod を以降の手順（モデル取得・マイグレーション）でも使う。
set -a
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env.prod"
set +a

# 4. Ollama モデルの確認とダウンロード
# 生成・埋め込みのどちらも外部 API を使う構成なら、数 GB のモデルを落とす意味がない。
if [[ "${ASK_DRIVE_LLM_PROVIDER:-ollama}" == "ollama" || "${ASK_DRIVE_EMBED_PROVIDER:-ollama}" == "ollama" ]]; then
  echo -e "\n${YELLOW}[4/7] Ollama サービスとモデルの確認中...${NC}"
  OLLAMA_PID=""
  if ! curl -s "${OLLAMA_HOST:-http://localhost:11434}/api/tags" >/dev/null 2>&1; then
    echo "Ollama サーバーを一時起動中..."
    ollama serve > "${SCRIPT_DIR}/log/ollama_setup.log" 2>&1 &
    OLLAMA_PID=$!
    sleep 3
  fi

  if [[ "${ASK_DRIVE_EMBED_PROVIDER:-ollama}" == "ollama" ]]; then
    EMBED_PULL="${ASK_DRIVE_EMBED_MODEL:-bge-m3}"
    echo "埋め込みモデル ${EMBED_PULL} を確認・ダウンロード中..."
    ollama pull "${EMBED_PULL}" || true
  fi

  if [[ "${ASK_DRIVE_LLM_PROVIDER:-ollama}" == "ollama" ]]; then
    GEN_PULL="${ASK_DRIVE_LLM_MODEL:-qwen3:4b}"
    echo "生成モデル ${GEN_PULL} を確認・ダウンロード中..."
    ollama pull "${GEN_PULL}" || ollama pull qwen2.5:3b || true
  fi

  if [[ -n "${OLLAMA_PID}" ]]; then
    echo "一時起動した Ollama サーバーを停止中..."
    kill -TERM "${OLLAMA_PID}" 2>/dev/null || true
  fi
else
  echo -e "\n${YELLOW}[4/7] 生成・埋め込みともに外部 API のため、Ollama モデルの取得をスキップします。${NC}"
fi

# 5. Elixir 依存関係の取得とコンパイル
echo -e "\n${YELLOW}[5/7] Elixir 依存関係の取得中...${NC}"
cd "${SCRIPT_DIR}"
mix local.hex --force || true
mix local.rebar --force || true
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
