#!/bin/sh
# install.sh — install the valar CLI from https://github.com/valarhq/valar-code-cli
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh | sh
#
# Pin a version:
#   VALAR_VERSION=v1.2.3 sh -c "$(curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh)"
#
# Audit-first (recommended for production):
#   curl -fsSL -o install.sh https://raw.githubusercontent.com/valarhq/valar-code-cli/<commit-sha>/install.sh
#   less install.sh && sh install.sh
#
# Install system-wide:
#   sh install.sh --prefix /usr/local
#
# Private-repo validation (until valar-code-cli is public):
#   GITHUB_TOKEN=<pat-with-read> sh install.sh
#
# Integrity: the binary's SHA256 is verified against checksums.txt (mandatory). If
# cosign is installed, checksums.txt's Sigstore signature is also verified against
# the valar-byoc release workflow identity (optional, fails closed if present but
# invalid). See SECURITY.md.

set -eu

REPO="valarhq/valar-code-cli"
VERSION="${VALAR_VERSION:-}"
PREFIX="${VALAR_PREFIX:-$HOME/.local/bin}"
TOKEN="${GITHUB_TOKEN:-}"

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

# ---- resolve version ----
if [ -z "$VERSION" ]; then
  api="https://api.github.com/repos/$REPO/releases/latest"
  if [ -n "$TOKEN" ]; then
    VERSION="$(curl -fsSL -H "Authorization: Bearer $TOKEN" "$api" \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  else
    VERSION="$(curl -fsSL "$api" \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
fi
if [ -z "$VERSION" ]; then
  echo "install.sh: could not resolve a release version (set VALAR_VERSION or GITHUB_TOKEN)" >&2
  exit 1
fi

# ---- temp workspace ----
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t valar)"
trap 'rm -rf "$tmp"' EXIT INT TERM

base="https://github.com/$REPO/releases/download/$VERSION"
curl_auth() {
  if [ -n "$TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" "$@"
  else
    curl -fsSL "$@"
  fi
}

echo "==> valar $VERSION for $TARGET"

# ---- download checksums + binary ----
curl_auth -o "$tmp/checksums.txt" "$base/checksums.txt"
curl_auth -o "$tmp/$TARGET"       "$base/$TARGET"
# Signature + bundle may not exist for older releases; download best-effort.
curl_auth -o "$tmp/checksums.txt.sig"    "$base/checksums.txt.sig"    2>/dev/null || :
curl_auth -o "$tmp/checksums.txt.bundle" "$base/checksums.txt.bundle" 2>/dev/null || :

# ---- verify SHA256 (mandatory, fails closed) ----
line="$(grep "  $TARGET\$" "$tmp/checksums.txt" || true)"
if [ -z "$line" ]; then
  echo "install.sh: no checksum entry for $TARGET in checksums.txt" >&2
  exit 1
fi
echo "$line" | (cd "$tmp" && sha256sum -c -) >/dev/null 2>&1 \
  || { echo "install.sh: SHA256 verification FAILED for $TARGET" >&2; exit 1; }
echo "    sha256: OK"

# ---- verify cosign signature (optional) ----
if command -v cosign >/dev/null 2>&1 \
   && [ -s "$tmp/checksums.txt.sig" ] && [ -s "$tmp/checksums.txt.bundle" ]; then
  identity="https://github.com/valarhq/valar-byoc/.github/workflows/release-valar-code.yml@refs/tags/$VERSION"
  if cosign verify-blob \
        --certificate-identity "$identity" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        --bundle "$tmp/checksums.txt.bundle" \
        "$tmp/checksums.txt" >/dev/null 2>&1; then
    echo "    cosign: OK (provenance verified)"
  else
    echo "install.sh: cosign signature verification FAILED" >&2
    exit 1
  fi
else
  echo "    cosign: skipped (install cosign to verify provenance; see SECURITY.md)"
fi

# ---- install ----
mkdir -p "$PREFIX"
bin="$PREFIX/valar"
if [ -w "$PREFIX" ]; then
  install -m 0755 "$tmp/$TARGET" "$bin"
else
  echo "==> $PREFIX is not writable; re-running install step with sudo"
  sudo install -m 0755 "$tmp/$TARGET" "$bin"
fi
echo "    installed: $bin"

# ---- PATH ----
case "$SHELL" in
  */zsh)  rc="$HOME/.zshrc" ;;
  */bash) if [ "$os" = "darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
  *)      rc="$HOME/.profile" ;;
esac
line="export PATH=\"$PREFIX:\$PATH\""
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
  echo "==> valar $($bin --version) installed"
else
  echo "==> valar installed (run 'valar --version' from a new shell)"
fi
echo "    next: valar help"
