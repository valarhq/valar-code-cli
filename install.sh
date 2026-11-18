#!/bin/sh
# install.sh — install the valar CLI from https://github.com/valarhq/valar-code-cli
#
# Usage:
#   curl -fsSL https://app.valarhq.ai/cli/install.sh | sh
#   (or: curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh | sh)
#
# Pin a version:
#   VALAR_VERSION=valar-cli-v1.2.3 sh -c "$(curl -fsSL https://app.valarhq.ai/cli/install.sh)"
#
# Where it downloads from: the latest release is served at https://app.valarhq.ai/cli/latest,
# which has no per-IP rate limit, so a whole office behind one public IP can install at once.
# Any failure there (unreachable, or a file that does not verify) falls back to the GitHub
# release. A pinned older version comes from GitHub. VALAR_DOWNLOAD_URL=github skips
# app.valarhq.ai; another URL serves the same files from there instead.
#
# Audit-first (recommended for production):
#   curl -fsSL -o install.sh https://raw.githubusercontent.com/valarhq/valar-code-cli/<commit-sha>/install.sh
#   less install.sh && sh install.sh
#
# Install system-wide:
#   sh install.sh --prefix /usr/local
#
# Set up: at a terminal it then runs `valar setup` (`valar setup --no-upgrade` when VALAR_VERSION
# pins a release). VALAR_NO_SETUP=1 installs only, for a script that runs `valar setup --force`
# itself, such as an MDM script.
#
# Private-repo validation (until valar-code-cli is public):
#   GITHUB_TOKEN=<pat-with-read> sh install.sh
#
# Integrity: the binary's SHA256 is verified against checksums.txt (mandatory). If
# cosign is installed, checksums.txt's Sigstore signature is also verified against
# the valar-monorepo release workflow identity (optional, fails closed if present but
# invalid). See SECURITY.md.

set -eu

REPO="valarhq/valar-code-cli"
VERSION="${VALAR_VERSION:-}"
PREFIX="${VALAR_PREFIX:-$HOME/.local/bin}"
TOKEN="${GITHUB_TOKEN:-}"
HOSTED="${VALAR_DOWNLOAD_URL:-https://app.valarhq.ai/cli/latest}"
HOSTED="${HOSTED%/}"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- arg parsing (only --prefix / --help / --version) ----
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; usage 1 ;;
  esac
done

# ---- detect OS + arch ----
os="$(uname -s)"
case "$os" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) echo "install.sh: unsupported OS: $os (expected Darwin or Linux)" >&2; exit 1 ;;
esac
arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="amd64" ;;
  *) echo "install.sh: unsupported arch: $arch (expected arm64 or x86_64)" >&2; exit 1 ;;
esac
TARGET="valar-$os-$arch"

# ---- temp workspace ----
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t valar)"
trap 'rm -rf "$tmp"' EXIT INT TERM

curl_auth() {
  if [ -n "$TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" "$@"
  else
    curl -fsSL "$@"
  fi
}
# app.valarhq.ai never gets the GitHub token.
curl_hosted() { curl -fsSL "$@"; }

# macOS <= 15 ships shasum, not sha256sum (Apple added /sbin/sha256sum in macOS 26).
if command -v sha256sum >/dev/null 2>&1; then
  sha_c="sha256sum -c -"
elif command -v shasum >/dev/null 2>&1; then
  sha_c="shasum -a 256 -c -"
else
  echo "install.sh: need sha256sum or shasum to verify the download" >&2
  exit 1
fi

# fetch <base> <version> <get>: downloads checksums + binary (+ signature) from <base> with <get>
# (curl_hosted or curl_auth) into $tmp and verifies them. Returns non-zero, having said why, on any failure,
# so the caller can try the next source; nothing is installed until one source verifies.
fetch() {
  _base="$1"; _ver="$2"; _get="$3"
  rm -f "$tmp/checksums.txt" "$tmp/$TARGET" "$tmp/checksums.txt.sig" "$tmp/checksums.txt.bundle"
  $_get -o "$tmp/checksums.txt" "$_base/checksums.txt" || { echo "    could not download checksums.txt" >&2; return 1; }
  $_get -o "$tmp/$TARGET" "$_base/$TARGET" || { echo "    could not download $TARGET" >&2; return 1; }
  # Signature + bundle may not exist for older releases; download best-effort.
  $_get -o "$tmp/checksums.txt.sig"    "$_base/checksums.txt.sig"    2>/dev/null || :
  $_get -o "$tmp/checksums.txt.bundle" "$_base/checksums.txt.bundle" 2>/dev/null || :

  # ---- verify SHA256 (mandatory, fails closed) ----
  _line="$(grep "  $TARGET\$" "$tmp/checksums.txt" || true)"
  if [ -z "$_line" ]; then
    echo "    no checksum entry for $TARGET in checksums.txt" >&2
    return 1
  fi
  # stderr stays visible: a swallowed "command not found" reads as a checksum mismatch.
  if ! echo "$_line" | (cd "$tmp" && $sha_c) >/dev/null; then
    echo "    SHA256 verification FAILED for $TARGET" >&2
    return 1
  fi
  echo "    sha256: OK"

  # ---- verify cosign signature (optional) ----
  if command -v cosign >/dev/null 2>&1 \
     && [ -s "$tmp/checksums.txt.sig" ] && [ -s "$tmp/checksums.txt.bundle" ]; then
    _identity="https://github.com/valarhq/valar-monorepo/.github/workflows/release-valar-code.yml@refs/tags/$_ver"
    if cosign verify-blob \
          --certificate-identity "$_identity" \
          --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
          --bundle "$tmp/checksums.txt.bundle" \
          "$tmp/checksums.txt" >/dev/null 2>&1; then
      echo "    cosign: OK (provenance verified)"
    else
      echo "    cosign signature verification FAILED" >&2
      return 1
    fi
  else
    echo "    cosign: skipped (install cosign to verify provenance; see SECURITY.md)"
  fi
}

# ---- resolve version + download ----
# app.valarhq.ai first: its release.json names the latest release. Used when no version is pinned,
# or when the pinned one is the latest. Anything else, or any failure, is the GitHub release.
fetched=""
if [ "$HOSTED" != "github" ]; then
  hosted_version="$(curl_hosted "$HOSTED/release.json" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
  if [ -n "$hosted_version" ] && { [ -z "$VERSION" ] || [ "$VERSION" = "$hosted_version" ]; }; then
    VERSION="$hosted_version"
    echo "==> valar $VERSION for $TARGET"
    if fetch "$HOSTED" "$VERSION" curl_hosted; then
      fetched=1
    else
      echo "==> falling back to the GitHub release"
    fi
  fi
fi
if [ -z "$fetched" ]; then
  if [ -z "$VERSION" ]; then
    api="https://api.github.com/repos/$REPO/releases/latest"
    VERSION="$(curl_auth "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
  fi
  if [ -z "$VERSION" ]; then
    echo "install.sh: could not resolve a release version (set VALAR_VERSION or GITHUB_TOKEN)" >&2
    exit 1
  fi
  echo "==> valar $VERSION for $TARGET (from GitHub)"
  fetch "https://github.com/$REPO/releases/download/$VERSION" "$VERSION" curl_auth \
    || { echo "install.sh: could not download and verify valar $VERSION" >&2; exit 1; }
fi

# ---- install (always overwrites $PREFIX/valar with the resolved version) ----
mkdir -p "$PREFIX"
bin="$PREFIX/valar"
prev=""
if [ -x "$bin" ]; then
  prev="$("$bin" --version 2>/dev/null | awk '{print $NF}')"
fi
if [ -w "$PREFIX" ]; then
  install -m 0755 "$tmp/$TARGET" "$bin"
else
  echo "==> $PREFIX is not writable; re-running install step with sudo"
  sudo install -m 0755 "$tmp/$TARGET" "$bin"
fi
if [ -n "$prev" ] && [ "$prev" != "$VERSION" ]; then
  echo "    installed: $bin (replaced $prev -> $VERSION)"
elif [ -n "$prev" ]; then
  echo "    installed: $bin (reinstalled $VERSION)"
else
  echo "    installed: $bin"
fi

# ---- PATH ----
# Pick the rc file AND the line syntax for the user's login shell. fish uses a
# different config location and its own PATH syntax (fish_add_path); the POSIX
# `export PATH=...` line is silently ignored by fish.
case "$SHELL" in
  */fish)
    rc="$HOME/.config/fish/config.fish"
    line="fish_add_path $PREFIX" ;;
  */zsh)
    rc="$HOME/.zshrc"
    line="export PATH=\"$PREFIX:\$PATH\"" ;;
  */bash)
    if [ "$os" = "darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi
    line="export PATH=\"$PREFIX:\$PATH\"" ;;
  *)
    rc="$HOME/.profile"
    line="export PATH=\"$PREFIX:\$PATH\"" ;;
esac
mkdir -p "$(dirname "$rc")"
if [ -f "$rc" ] && grep -qxF "$line" "$rc"; then
  echo "    path: $PREFIX already on PATH via $rc"
else
  printf '\n# Added by valar install.sh\n%s\n' "$line" >> "$rc"
  echo "    path: added $PREFIX to PATH via $rc"
  echo "    run:  source $rc  (or open a new shell)"
fi

# ---- finish ----
echo
if "$bin" --version >/dev/null 2>&1; then
  echo "==> $($bin --version) installed"
else
  echo "==> valar installed (run 'valar --version' from a new shell)"
fi

# Warn if a DIFFERENT valar earlier on PATH will shadow the one we just installed
# (the usual reason an install "doesn't take" — a stale copy in /usr/local/bin etc.).
found="$(command -v valar 2>/dev/null || true)"
if [ -n "$found" ] && [ "$found" != "$bin" ]; then
  echo "    warning: another 'valar' is earlier on your PATH and will shadow this install:"
  echo "               $found"
  echo "             remove it, or ensure $PREFIX comes first on PATH."
fi
# ---- set up ----
# A release without `valar setup` is set up by hand. The check sits in an `if`, where set -e lets
# it fail.
if ! "$bin" setup --help >/dev/null 2>&1; then
  echo "    next: valar login, then valar <tool> on (for example: valar claude on)"
  exit 0
fi
if [ "${VALAR_NO_SETUP:-}" = 1 ] || [ ! -t 1 ]; then
  echo "    next: valar setup"
  exit 0
fi
# A pinned release stays the one installed.
no_upgrade=""
if [ -n "${VALAR_VERSION:-}" ]; then no_upgrade="--no-upgrade"; fi
echo
# The terminal is setup's input: piped from curl, this script's own input is the script itself.
code=0
# shellcheck disable=SC2086 # $no_upgrade is one flag or none.
"$bin" setup $no_upgrade </dev/tty || code=$?
exit "$code"
