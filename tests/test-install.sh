#!/usr/bin/env bash
# install.sh against a local stand-in for https://app.valarhq.ai/cli/latest (tests/serve.py on
# $PORT, fixtures from tests/prepare.sh in $FIX): served from there when it verifies, and the GitHub
# release on every failure. Each case installs into a throwaway HOME.
set -uo pipefail
FIX="$1"; PORT="$2"
TAG="$(cat "$FIX/TAG")"
URL="http://127.0.0.1:$PORT"
fail=0

run() { # run <name> <expect version> <expect source: hosted|github> <env...>
  local name="$1" want="$2" src="$3"; shift 3
  local h out got
  h="$(mktemp -d)"
  out="$(env HOME="$h" SHELL=/bin/sh VALAR_PREFIX="$h/bin" "$@" sh "$FIX/install.sh" 2>&1)"
  got="$("$h/bin/valar" --version 2>/dev/null | awk '{print $NF}')"
  local ok=1
  [ "$got" = "$want" ] || ok=0
  case "$src" in
    hosted) case "$out" in *"(from GitHub)"*) ok=0 ;; esac ;;
    github) case "$out" in *"(from GitHub)"*) ;; *) ok=0 ;; esac ;;
  esac
  if [ "$ok" = 1 ]; then echo "ok    $name ($got from $src)"; else echo "FAIL  $name: got '$got', want '$want' from $src"; echo "$out" | sed 's/^/      /'; fail=1; fi
  rm -rf "$h"
}

run "latest from the hosted copy"              "$TAG" hosted VALAR_DOWNLOAD_URL="$URL/good/latest"
run "pinned to the latest: hosted copy"        "$TAG" hosted VALAR_DOWNLOAD_URL="$URL/good/latest" VALAR_VERSION="$TAG"
run "a binary that does not verify: GitHub"     "$TAG" github VALAR_DOWNLOAD_URL="$URL/bad/latest"
run "a missing binary: GitHub"                  "$TAG" github VALAR_DOWNLOAD_URL="$URL/nobin/latest"
run "host unreachable: GitHub"                  "$TAG" github VALAR_DOWNLOAD_URL="http://127.0.0.1:1/latest"
run "VALAR_DOWNLOAD_URL=github"                 "$TAG" github VALAR_DOWNLOAD_URL=github
older="$(gh release list --repo valarhq/valar-code-cli --limit 2 --json tagName --jq '.[1].tagName')"
run "pinned to an older release: GitHub"        "$older" github VALAR_DOWNLOAD_URL="$URL/good/latest" VALAR_VERSION="$older"

# The hand-over to `valar setup`, against the stub. "tty" runs the installer as `curl … | sh` runs
# it at a terminal: its output a terminal, its input the piped script.
STUB="$URL/stub/latest"
TERMINAL='import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))'
setup_case() { # setup_case <name> <tty|log> <want exit> <want setup args, or - for none> <want in output> <env...>
  local name="$1" mode="$2" want_code="$3" want_args="$4" want_out="$5"; shift 5
  local h out code got ok=1
  h="$(mktemp -d)"; mkdir "$h/tmp"
  if [ "$mode" = tty ]; then
    out="$(env HOME="$h" SHELL=/bin/sh TMPDIR="$h/tmp" VALAR_PREFIX="$h/bin" VALAR_DOWNLOAD_URL="$STUB" STUB_LOG="$h/setup.log" "$@" \
      python3 -c "$TERMINAL" sh -c 'cat "$1" | sh' sh "$FIX/install.sh" 2>&1)"
  else
    out="$(env HOME="$h" SHELL=/bin/sh TMPDIR="$h/tmp" VALAR_PREFIX="$h/bin" VALAR_DOWNLOAD_URL="$STUB" STUB_LOG="$h/setup.log" "$@" \
      sh "$FIX/install.sh" 2>&1 </dev/null)"
  fi
  code=$?
  got="$(sed -n 's/^args: //p' "$h/setup.log" 2>/dev/null)"
  [ -n "$got" ] || got="-"
  [ "$code" = "$want_code" ] || ok=0
  [ "$got" = "$want_args" ] || ok=0
  case "$out" in *"$want_out"*) ;; *) ok=0 ;; esac
  if [ "$got" != "-" ] && ! grep -qx 'stdin: terminal' "$h/setup.log"; then ok=0; fi
  [ -z "$(ls -A "$h/tmp")" ] || ok=0 # no download folder left behind
  if [ "$ok" = 1 ]; then echo "ok    $name"; else echo "FAIL  $name: exit $code (want $want_code), setup '$got' (want '$want_args') $(grep stdin "$h/setup.log" 2>/dev/null), want '$want_out' in:"; echo "$out" | sed 's/^/      /'; fail=1; fi
  rm -rf "$h"
}

setup_case "at a terminal: valar setup, on the terminal"  tty 0 "setup"              "installed"
setup_case "pinned at a terminal: --no-upgrade"           tty 0 "setup --no-upgrade" "installed"  VALAR_VERSION=valar-cli-v0.0.0-stub
setup_case "valar setup fails: the installer exits 1"     tty 1 "setup"              "installed"  STUB_SETUP_EXIT=1
setup_case "VALAR_NO_SETUP=1: installs only"              tty 0 "-"                  "next: valar setup" VALAR_NO_SETUP=1
setup_case "output to a log: installs only"               log 0 "-"                  "next: valar setup"
setup_case "a release without setup: the manual commands" tty 0 "-"                  "valar claude on" STUB_NO_SETUP=1

# The default directory: ~/.local/bin for an account; /usr/local/bin for root, run with no HOME or
# SHELL as an MDM script runs it. The root case writes /usr/local/bin, so it runs on CI only.
if [ "$(id -u)" != 0 ]; then
  h="$(mktemp -d)"
  env HOME="$h" SHELL=/bin/sh VALAR_DOWNLOAD_URL="$STUB" VALAR_NO_SETUP=1 sh "$FIX/install.sh" >/dev/null 2>&1
  if [ -x "$h/.local/bin/valar" ]; then echo "ok    an account: ~/.local/bin"; else echo "FAIL  an account: no ~/.local/bin/valar"; fail=1; fi
  rm -rf "$h"
fi
if [ -n "${CI:-}" ]; then
  as_root=""
  [ "$(id -u)" = 0 ] || as_root="sudo -n"
  out="$($as_root env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin VALAR_DOWNLOAD_URL="$STUB" VALAR_NO_SETUP=1 sh "$FIX/install.sh" 2>&1)"
  code=$?
  got="$(/usr/local/bin/valar --version 2>/dev/null | awk '{print $NF}')"
  case "$code $got $out" in
    "0 valar-cli-v0.0.0-stub "*"path: unchanged (run as root)"*) echo "ok    root: /usr/local/bin, no rc file" ;;
    *) echo "FAIL  root: exit $code, /usr/local/bin/valar '$got'"; echo "$out" | sed 's/^/      /'; fail=1 ;;
  esac
  $as_root rm -f /usr/local/bin/valar
fi

exit "$fail"
