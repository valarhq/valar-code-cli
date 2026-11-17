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

exit "$fail"
