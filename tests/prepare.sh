#!/usr/bin/env bash
# Builds the stand-ins tests/test-install.* run against, under $1: good/latest (the newest release,
# as app.valarhq.ai/cli/latest serves it), bad/latest (the same with every binary tampered with),
# nobin/latest (release.json and checksums only), stub/latest (a stand-in valar, built with go),
# plus the installers at the top.
set -euo pipefail
out="$1"
tag="$(gh release view --repo valarhq/valar-code-cli --json tagName --jq .tagName)"
mkdir -p "$out/good/latest" "$out/bad/latest" "$out/nobin/latest"
gh release download "$tag" --repo valarhq/valar-code-cli --dir "$out/good/latest" --clobber
printf '{"tag_name": "%s", "assets": []}\n' "$tag" >"$out/good/latest/release.json"
cp "$out/good/latest/"* "$out/bad/latest/"
for f in "$out/bad/latest/"valar-*; do printf 'tampered' >"$f"; done
cp "$out/good/latest/release.json" "$out/good/latest/checksums.txt" "$out/nobin/latest/"
cp install.sh install.ps1 "$out/"
echo "$tag" >"$out/TAG"

# stub/latest: the stand-in valar of tests/stub.go, for the set-up cases.
mkdir -p "$out/stub/latest"
for t in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64; do
  ext=""; [ "${t%/*}" = windows ] && ext=".exe"
  GOOS="${t%/*}" GOARCH="${t#*/}" CGO_ENABLED=0 go build -o "$out/stub/latest/valar-${t%/*}-${t#*/}$ext" tests/stub.go
done
if command -v sha256sum >/dev/null 2>&1; then sum="sha256sum"; else sum="shasum -a 256"; fi
(cd "$out/stub/latest" && $sum valar-* >checksums.txt)
printf '{"tag_name": "valar-cli-v0.0.0-stub", "assets": []}\n' >"$out/stub/latest/release.json"
