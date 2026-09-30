# shellcheck shell=bash
# ==============================================================================
# AskDrive platform helpers (spec 12.8): macOS (arm64/x86_64) and Linux (Ubuntu/Debian,
# x86_64/arm64). Sourced by app.sh, scripts/initial-setup.sh and scripts/deploy.sh after
# they set SCRIPT_DIR / RUNTIME_DIR / RUNTIME_BIN.
#
# Everything the app needs at runtime goes into .runtime/ (no root), except on Linux the
# few system packages installed once with sudo (poppler-utils for pdftotext, zstd, build
# tools) — see ensure_linux_packages.
# ==============================================================================

case "$(uname -s)" in
  Darwin) ASKDRIVE_OS="macos" ;;
  Linux) ASKDRIVE_OS="linux" ;;
  *) ASKDRIVE_OS="unknown" ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) ASKDRIVE_ARCH="arm64" ;;
  x86_64 | amd64) ASKDRIVE_ARCH="x86_64" ;;
  *) ASKDRIVE_ARCH="$(uname -m)" ;;
esac

# Erlang/OTP and Elixir installed into .runtime on Linux (install_beam_linux)
export PATH="${RUNTIME_DIR}/elixir/bin:${RUNTIME_DIR}/otp/bin:${PATH}"

ASKDRIVE_PANDOC_VERSION="${ASKDRIVE_PANDOC_VERSION:-3.6.3}"
ASKDRIVE_SQLITE_VEC_VERSION="${ASKDRIVE_SQLITE_VEC_VERSION:-0.1.9}"
ASKDRIVE_OTP_MAJOR="${ASKDRIVE_OTP_MAJOR:-28}"
ASKDRIVE_ELIXIR_VERSION="${ASKDRIVE_ELIXIR_VERSION:-1.19.5}"

is_macos() { [[ "${ASKDRIVE_OS}" == "macos" ]]; }
is_linux() { [[ "${ASKDRIVE_OS}" == "linux" ]]; }

# sed -i: BSD sed (macOS) requires a backup-suffix argument (an empty one: -i ''), GNU sed
# (Linux) takes the suffix glued to -i and would read '' as the script. Always use this.
#   sed_inplace 's/a/b/' file
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# --- pandoc -------------------------------------------------------------------

install_pandoc() {
  local ver="${ASKDRIVE_PANDOC_VERSION}" asset tmp
  if is_macos; then
    [[ "${ASKDRIVE_ARCH}" == "arm64" ]] && asset="pandoc-${ver}-arm64-macOS.zip" || asset="pandoc-${ver}-x86_64-macOS.zip"
  else
    [[ "${ASKDRIVE_ARCH}" == "arm64" ]] && asset="pandoc-${ver}-linux-arm64.tar.gz" || asset="pandoc-${ver}-linux-amd64.tar.gz"
  fi

  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "${tmp}/${asset}" "https://github.com/jgm/pandoc/releases/download/${ver}/${asset}" || { rm -rf "${tmp}"; return 1; }
  case "${asset}" in
    *.zip) unzip -q -o "${tmp}/${asset}" -d "${tmp}" ;;
    *) tar -xzf "${tmp}/${asset}" -C "${tmp}" ;;
  esac

  local bin
  bin="$(find "${tmp}" -type f -name pandoc -perm -u+x | head -n 1)"
  [[ -z "${bin}" ]] && bin="$(find "${tmp}" -type f -name pandoc | head -n 1)"
  if [[ -n "${bin}" ]]; then
    mkdir -p "${RUNTIME_BIN}"
    cp "${bin}" "${RUNTIME_BIN}/pandoc"
    chmod +x "${RUNTIME_BIN}/pandoc"
  fi
  rm -rf "${tmp}"
  [[ -x "${RUNTIME_BIN}/pandoc" ]]
}

# --- Ollama -------------------------------------------------------------------
#
# ollama needs its inference runner (llama-server) and ggml/llama libraries next to it.
#   macOS: ollama-darwin.tgz, a flat set of files         -> .runtime/bin/
#   Linux: ollama-linux-<arch>.tar.zst, bin/ + lib/ollama/ -> .runtime/ (bin/ollama, lib/ollama)

ollama_runtime_complete() {
  if is_macos; then
    [[ -x "${RUNTIME_BIN}/ollama" && -x "${RUNTIME_BIN}/llama-server" ]]
  else
    [[ -x "${RUNTIME_BIN}/ollama" && -d "${RUNTIME_DIR}/lib/ollama" ]]
  fi
}

install_ollama_runtime() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${RUNTIME_BIN}"

  if is_macos; then
    curl -fL --retry 3 -o "${tmp}/ollama.tgz" "https://ollama.com/download/ollama-darwin.tgz" &&
      tar -xzf "${tmp}/ollama.tgz" -C "${RUNTIME_BIN}" &&
      chmod +x "${RUNTIME_BIN}/ollama" "${RUNTIME_BIN}/llama-server" 2>/dev/null
  else
    local arch="amd64"
    [[ "${ASKDRIVE_ARCH}" == "arm64" ]] && arch="arm64"
    if ! command -v zstd >/dev/null 2>&1; then
      echo "zstd が必要です（sudo apt-get install -y zstd）。" >&2
      rm -rf "${tmp}"
      return 1
    fi
    curl -fL --retry 3 -o "${tmp}/ollama.tar.zst" "https://ollama.com/download/ollama-linux-${arch}.tar.zst" &&
      tar --use-compress-program=unzstd -xf "${tmp}/ollama.tar.zst" -C "${RUNTIME_DIR}" &&
      chmod +x "${RUNTIME_BIN}/ollama"
  fi

  rm -rf "${tmp}"
  ollama_runtime_complete
}

# --- sqlite-vec ---------------------------------------------------------------

sqlite_vec_filename() { if is_macos; then echo "vec0.dylib"; else echo "vec0.so"; fi; }

# install_sqlite_vec <dir>: the loadable extension for this OS/arch into <dir>
install_sqlite_vec() {
  local dest="$1" os arch tmp ver="${ASKDRIVE_SQLITE_VEC_VERSION}"
  is_macos && os="macos" || os="linux"
  [[ "${ASKDRIVE_ARCH}" == "arm64" ]] && arch="aarch64" || arch="x86_64"

  tmp="$(mktemp -d)"
  mkdir -p "${dest}"
  curl -fL --retry 3 -o "${tmp}/vec.tar.gz" \
    "https://github.com/asg017/sqlite-vec/releases/download/v${ver}/sqlite-vec-${ver}-loadable-${os}-${arch}.tar.gz" &&
    tar -xzf "${tmp}/vec.tar.gz" -C "${tmp}" &&
    cp "${tmp}/$(sqlite_vec_filename)" "${dest}/"
  rm -rf "${tmp}"
  [[ -f "${dest}/$(sqlite_vec_filename)" ]]
}

# --- Linux: system packages (sudo, once) ------------------------------------------

# pdftotext (poppler-utils), zstd (Ollama's archive), unzip/git/curl/openssl, and a C
# toolchain in case a native dependency has no precompiled build for this machine.
ensure_linux_packages() {
  is_linux || return 0
  local missing=()
  command -v pdftotext >/dev/null 2>&1 || missing+=(poppler-utils)
  command -v zstd >/dev/null 2>&1 || missing+=(zstd)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v make >/dev/null 2>&1 || missing+=(build-essential)
  [[ ${#missing[@]} -eq 0 ]] && return 0

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "次のパッケージをインストールしてください: ${missing[*]}（apt-get が見つかりません）" >&2
    return 1
  fi

  echo "システムパッケージをインストールします（sudo が必要です）: ${missing[*]} ca-certificates"
  sudo apt-get update -y && sudo apt-get install -y "${missing[@]}" ca-certificates
}

# --- Linux: Erlang/OTP and Elixir into .runtime -------------------------------------
#
# Ubuntu/Debian ship Erlang too old for this Elixir, and building it needs a toolchain and
# time. hex.pm publishes precompiled OTP for Ubuntu (used for Debian as well: same glibc
# lineage); Elixir is a platform-independent zip.

install_beam_linux() {
  is_linux || return 0
  if command -v erl >/dev/null 2>&1 && command -v elixir >/dev/null 2>&1 && command -v mix >/dev/null 2>&1; then
    return 0
  fi

  local distro="ubuntu-22.04" arch="amd64" id="" version_id="" base otp tmp
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && echo "${ID:-}")"
    version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  fi
  # Ubuntu 24.04 以降（26.04 等）は 24.04 向けビルド、Ubuntu 22.04 と Debian 12 以降は 22.04 向けビルド
  if [[ "${id}" == "ubuntu" && "${version_id%%.*}" =~ ^[0-9]+$ && "${version_id%%.*}" -ge 24 ]]; then
    distro="ubuntu-24.04"
  fi
  [[ "${ASKDRIVE_ARCH}" == "arm64" ]] && arch="arm64"
  base="https://builds.hex.pm/builds/otp/${arch}/${distro}"

  otp="$(curl -fsSL "${base}/builds.txt" | awk '{print $1}' | grep -E "^OTP-${ASKDRIVE_OTP_MAJOR}\.[0-9.]+$" | sort -V | tail -n 1)"
  if [[ -z "${otp}" ]]; then
    echo "OTP ${ASKDRIVE_OTP_MAJOR} のビルドが見つかりません (${base})" >&2
    return 1
  fi

  tmp="$(mktemp -d)"
  echo "Erlang/OTP (${otp}, ${distro}/${arch}) を取得中..."
  rm -rf "${RUNTIME_DIR}/otp"
  mkdir -p "${RUNTIME_DIR}/otp"
  curl -fL --retry 3 -o "${tmp}/otp.tar.gz" "${base}/${otp}.tar.gz" &&
    tar -xzf "${tmp}/otp.tar.gz" -C "${RUNTIME_DIR}/otp" --strip-components=1 &&
    (cd "${RUNTIME_DIR}/otp" && ./Install -minimal "${RUNTIME_DIR}/otp" >/dev/null) || { rm -rf "${tmp}"; return 1; }

  echo "Elixir ${ASKDRIVE_ELIXIR_VERSION} を取得中..."
  rm -rf "${RUNTIME_DIR}/elixir"
  mkdir -p "${RUNTIME_DIR}/elixir"
  curl -fL --retry 3 -o "${tmp}/elixir.zip" \
    "https://github.com/elixir-lang/elixir/releases/download/v${ASKDRIVE_ELIXIR_VERSION}/elixir-otp-${ASKDRIVE_OTP_MAJOR}.zip" &&
    unzip -q -o "${tmp}/elixir.zip" -d "${RUNTIME_DIR}/elixir" || { rm -rf "${tmp}"; return 1; }

  rm -rf "${tmp}"
  command -v erl >/dev/null 2>&1 && command -v mix >/dev/null 2>&1
}

# --- Linux: systemd unit and sudoers rule (pure: print to stdout, testable without sudo) ---

# systemd_unit_content <app_dir> <user> <group> <home>
systemd_unit_content() {
  local dir="$1" user="$2" group="$3" home="$4"
  cat << EOF
[Unit]
Description=AskDrive
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${group}
WorkingDirectory=${dir}
ExecStart=${dir}/app.sh start
Restart=on-failure
RestartSec=5
Environment=HOME=${home}
Environment=PATH=${dir}/.runtime/bin:${dir}/.runtime/elixir/bin:${dir}/.runtime/otp/bin:/usr/local/bin:/usr/bin:/bin
Environment=MIX_ENV=prod
Environment=PHX_SERVER=true
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_NUM_PARALLEL=1
Environment=OLLAMA_FLASH_ATTENTION=1
Environment=OLLAMA_KV_CACHE_TYPE=q8_0
StandardOutput=append:${dir}/log/ask_drive_stdout.log
StandardError=append:${dir}/log/ask_drive_stderr.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# systemd_sudoers_content <user> <systemctl_path> <unit>: lets <user> start/stop/restart
# only this unit without a password, so later deploys need no administrator
systemd_sudoers_content() {
  local user="$1" systemctl_bin="$2" unit="$3"
  cat << EOF
# AskDrive: ${user} may start/stop/restart ${unit} without a password
${user} ALL=(root) NOPASSWD: ${systemctl_bin} start ${unit}, ${systemctl_bin} stop ${unit}, ${systemctl_bin} restart ${unit}
EOF
}

# --- Listening ports (spec F-1013) ------------------------------------------------
# The admin screen stores the ports in <ssl_dir>/listen.json; otherwise the environment's
# defaults apply (HTTP 4000, HTTPS 4443).
askdrive_listen_file() {
  echo "${ASK_DRIVE_SSL_DIR:-${SCRIPT_DIR}/ssl}/listen.json"
}

askdrive_port() {
  local kind="$1" file value=""
  file="$(askdrive_listen_file)"
  if [[ -f "${file}" ]]; then
    value="$(sed -n "s/.*\"${kind}_port\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "${file}" | head -n 1)"
  fi
  if [[ -z "${value}" ]]; then
    case "${kind}" in
      https) value="${ASK_DRIVE_HTTPS_PORT:-4443}" ;;
      http) value="${ASK_DRIVE_HTTP_PORT:-${PORT:-4000}}" ;;
    esac
  fi
  echo "${value}"
}
