#!/bin/sh
# install.sh — install the valar CLI from https://github.com/valarhq/valar-code-cli
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh | sh
#
# Pin a version:
#   VALAR_VERSION=valar-cli-v1.2.3 sh -c "$(curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh)"
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
# the valar-monorepo release workflow identity (optional, fails closed if present but
# invalid). See SECURITY.md.
#
# Setup: on a terminal, the installer then runs `valar login`, reads the organization's
# installation defaults with `valar org-policy`, runs `valar proxy enable` and
# `valar configure --quota-first` when those defaults say so, and ends with `valar on`, where
# you pick your tools, unless the organization has turned Valar off. It stops at the first step
# that fails and prints the steps left. With no
# terminal it only installs, and prints the commands that finish the setup. A release without
# the guided setup installs exactly as before it.

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
# macOS <= 15 ships shasum, not sha256sum (Apple added /sbin/sha256sum in macOS 26).
if command -v sha256sum >/dev/null 2>&1; then
  sha_c="sha256sum -c -"
elif command -v shasum >/dev/null 2>&1; then
  sha_c="shasum -a 256 -c -"
else
  echo "install.sh: need sha256sum or shasum to verify the download" >&2
  exit 1
fi
# stderr stays visible: a swallowed "command not found" reads as a checksum mismatch.
echo "$line" | (cd "$tmp" && $sha_c) >/dev/null \
  || { echo "install.sh: SHA256 verification FAILED for $TARGET" >&2; exit 1; }
echo "    sha256: OK"

# ---- verify cosign signature (optional) ----
if command -v cosign >/dev/null 2>&1 \
   && [ -s "$tmp/checksums.txt.sig" ] && [ -s "$tmp/checksums.txt.bundle" ]; then
  identity="https://github.com/valarhq/valar-monorepo/.github/workflows/release-valar-code.yml@refs/tags/$VERSION"
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

# ---- guided setup ----
# On a terminal, run the setup from the binary just installed, one `valar` command per step:
# sign in, read the organization's installation defaults, then the on-device proxy and quota
# first when those defaults say so, then pick the tools. Each step reads /dev/tty, since
# `curl | sh` feeds this script on stdin. The steps call "$bin" by its full path; the commands
# printed for the engineer use the bare name, which works once PATH has reached the shell.
if [ "$found" = "$bin" ]; then
  run_hint="run:"
else
  run_hint="open a new terminal (or run: source $rc), then run:"
fi

# Prints the setup commands from step $1 on. Until the policy is read, the two optional steps
# carry the condition that decides them; after, only the steps the policy asks for are listed.
policy_read=""
proxy=""
quota_first=""
valar_switch=""
print_steps() {
  listing=""
  for s in login org-policy proxy quota-first on; do
    [ "$s" = "$1" ] && listing=1
    [ -n "$listing" ] || continue
    case "$s" in
      login)      echo "      valar login" ;;
      org-policy) echo "      valar org-policy" ;;
      proxy)
        if [ -z "$policy_read" ]; then
          echo "      valar proxy enable              (only if org-policy printed proxy=on)"
        elif [ "$proxy" = on ]; then
          echo "      valar proxy enable"
        fi ;;
      quota-first)
        if [ -z "$policy_read" ]; then
          echo "      valar configure --quota-first   (only if org-policy printed quota_first=on)"
        elif [ "$quota_first" = on ]; then
          echo "      valar configure --quota-first"
        fi ;;
      on)         echo "      valar on" ;;
    esac
  done
}

# A failed step ends the install with that step's exit code. Nothing after it runs: the
# remaining steps may depend on it, and a failed proxy step must not leave tools on the direct
# lane when the organization chose the proxy.
setup_failed() {
  echo
  echo "==> Setup stopped: '$2' did not finish (exit code $3)."
  if [ "$1" = proxy ]; then
    echo "    The on-device proxy needs administrator rights on this machine."
    echo "    If you cannot give them, ask your IT team to install it."
  fi
  echo "    To finish the setup, $run_hint"
  print_steps "$1"
  exit "$3"
}

run_step() {
  step=$1
  shift
  echo
  echo "==> valar $*"
  rc=0
  "$bin" "$@" </dev/tty || rc=$?
  [ "$rc" -eq 0 ] || setup_failed "$step" "valar $*" "$rc"
}

# A release without the guided setup (no `valar org-policy` or no global `valar on`; v1.1.46
# and v1.1.47 have the first but not the second) installs exactly as the installer did before
# the guided setup existed.
if ! "$bin" org-policy --help </dev/null >/dev/null 2>&1 \
   || ! "$bin" on --help </dev/null >/dev/null 2>&1; then
  echo "    next: valar help"
  exit 0
fi

echo
if ! ( : </dev/tty ) 2>/dev/null; then
  echo "==> No terminal, so the setup did not run. To finish it, $run_hint"
  print_steps login
  exit 0
fi

echo "==> Setting up valar"
run_step login login

echo
echo "==> valar org-policy"
rc=0
policy="$("$bin" org-policy </dev/tty)" || rc=$?
[ "$rc" -eq 0 ] || setup_failed org-policy "valar org-policy" "$rc"
# key=value lines; keys this script does not know are skipped.
while IFS='=' read -r key value; do
  case "$key" in
    valar)       valar_switch=$value ;;
    proxy)       proxy=$value ;;
    quota_first) quota_first=$value ;;
  esac
done <<EOF
$policy
EOF
case "$proxy:$quota_first" in
  on:on|on:off|off:on|off:off) ;;
  *)
    echo "install.sh: 'valar org-policy' did not print proxy=on|off and quota_first=on|off" >&2
    setup_failed org-policy "valar org-policy" 1 ;;
esac
policy_read=1
echo "    on-device proxy: $proxy, quota first: $quota_first"

if [ "$proxy" = on ]; then run_step proxy proxy enable; fi
if [ "$quota_first" = on ]; then run_step quota-first configure --quota-first; fi
# An organization that has turned Valar off gets no tools turned on: `valar on` would route them
# through Valar, and a new machine has not yet learned that the organization switched it off.
if [ "$valar_switch" = off ]; then
  echo
  echo "==> Your organization has turned Valar off, so no tools were turned on."
  echo "    Once it is back on, run:"
  echo "      valar on"
  exit 0
fi
run_step on on

echo
echo "==> valar is set up. For more, $run_hint"
echo "      valar help"
