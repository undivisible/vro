#!/usr/bin/env bash
# vro installer — clone builds with V; otherwise GitHub Release tarball.
# Usage:
#   ./install.sh                              # clone → v -prod -o vro .
#   VRO_USE_RELEASE=1 ./install.sh            # clone → still use release tarball
#   curl -fsSL …/main/install.sh | bash       # latest release binary (needs V in PATH for local build fallback only)
#
set -euo pipefail

REPO="${VRO_GITHUB_REPO:-undivisible/vro}"
INSTALL_DIR="${VRO_INSTALL_DIR:-$HOME/.local/bin}"
DATA_DIR="${VRO_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vro}"
VERSION="${VRO_VERSION:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}%s${NC}\n" "$*"; }
ok()    { printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}! %s${NC}\n" "$*" >&2; }
die()   { printf "${RED}error: %s${NC}\n" "$*" >&2; exit 1; }

path_hint() {
  if command -v vro &>/dev/null 2>&1; then
    return
  fi
  printf "\n${BOLD}Add vro to your PATH:${NC}\n"
  case "${SHELL:-}" in
    */fish) printf '  fish_add_path %s\n' "$INSTALL_DIR" ;;
    *)      printf '  echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc  # or ~/.zshrc\n' "$INSTALL_DIR" ;;
  esac
}

install_from_repo() {
  local root="$1"
  if ! command -v v &>/dev/null; then
    die "v compiler not in PATH — install from https://vlang.io/ or use VRO_USE_RELEASE=1 for tarball."
  fi
  info "Building vro from local checkout (${root})…"
  ( cd "$root" && v -gc none -prod -o vro . )
  mkdir -p "$INSTALL_DIR"
  cp "${root}/vro" "${INSTALL_DIR}/vro"
  mkdir -p "$DATA_DIR"
  cp -R "${root}/syntax" "${DATA_DIR}/syntax"
  chmod +x "${INSTALL_DIR}/vro"
  ok "vro built and installed to ${INSTALL_DIR}/vro"
  ok "syntax rules installed to ${DATA_DIR}/syntax"
  path_hint
}

install_from_release() {
  local OS ARCH os arch ASSET BASE_URL TMP TMP_SHA HAVE_SHA EXPECTED ACTUAL

  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Linux)  os="linux" ;;
    Darwin) os="macos" ;;
    *)      die "Unsupported OS: $OS" ;;
  esac

  case "$ARCH" in
    x86_64|amd64)   arch="x86_64" ;;
    aarch64|arm64)  arch="aarch64" ;;
    *)              die "Unsupported architecture: $ARCH" ;;
  esac

  ASSET="vro-${os}-${arch}.tar.gz"

  if [ -z "$VERSION" ]; then
    info "Fetching latest release version…"
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')"
    [ -n "$VERSION" ] || die "Could not determine latest version from GitHub API"
  fi

  info "Installing vro ${VERSION} (${os}/${arch}) from GitHub Releases…"

  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP:-}"' EXIT

  if command -v curl &>/dev/null; then
    curl -fsSL --progress-bar "${BASE_URL}/${ASSET}" -o "${TMP}/vro.tgz"
    HAVE_SHA=0
    if curl -fsSL "${BASE_URL}/${ASSET}.sha256" -o "${TMP}/vro.tgz.sha256" 2>/dev/null; then
      HAVE_SHA=1
    fi
  elif command -v wget &>/dev/null; then
    wget -q --show-progress "${BASE_URL}/${ASSET}" -O "${TMP}/vro.tgz"
    HAVE_SHA=0
    if wget -q "${BASE_URL}/${ASSET}.sha256" -O "${TMP}/vro.tgz.sha256" 2>/dev/null; then
      HAVE_SHA=1
    fi
  else
    die "curl or wget is required"
  fi

  if [ "$HAVE_SHA" -eq 1 ] && [ -s "${TMP}/vro.tgz.sha256" ]; then
    EXPECTED="$(awk '{print $1}' < "${TMP}/vro.tgz.sha256" | head -1 | tr -d '[:space:]')"
    if command -v sha256sum &>/dev/null; then
      ACTUAL="$(sha256sum "${TMP}/vro.tgz" | awk '{print $1}')"
    elif command -v shasum &>/dev/null; then
      ACTUAL="$(shasum -a 256 "${TMP}/vro.tgz" | awk '{print $1}')"
    else
      die "sha256sum or shasum required to verify release integrity"
    fi
    [ "$ACTUAL" = "$EXPECTED" ] || die "SHA256 mismatch — download may be corrupted
  expected: $EXPECTED
  actual:   $ACTUAL"
    ok "checksum verified"
  elif [ "${VRO_NO_VERIFY:-}" = "1" ]; then
    warn "VRO_NO_VERIFY=1 set — skipping integrity verification"
  else
    die "No checksum file for ${VERSION}; set VRO_NO_VERIFY=1 to install without verification"
  fi

  tar -xzf "${TMP}/vro.tgz" -C "$TMP"
  chmod +x "${TMP}/vro"
  mkdir -p "$INSTALL_DIR"
  mv "${TMP}/vro" "${INSTALL_DIR}/vro"
  if [ -d "${TMP}/syntax" ]; then
    mkdir -p "$DATA_DIR"
    rm -rf "${DATA_DIR}/syntax"
    mv "${TMP}/syntax" "${DATA_DIR}/syntax"
    ok "syntax rules installed to ${DATA_DIR}/syntax"
  fi

  ok "vro ${VERSION} installed to ${INSTALL_DIR}/vro"
  path_hint
}

_src="${BASH_SOURCE[0]:-}"
if [[ -n "$_src" ]] && [[ "$(basename -- "$_src")" == "install.sh" ]] && [[ "${VRO_USE_RELEASE:-}" != "1" ]]; then
  _root="$(cd "$(dirname -- "$_src")" && pwd)"
  if [ -f "${_root}/v.mod" ] && [ -f "${_root}/main.v" ]; then
    install_from_repo "$_root"
    exit 0
  fi
fi

install_from_release
