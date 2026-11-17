#!/usr/bin/env bash
# Builds the stand-ins tests/test-install.* run against, under $1: good/latest (the newest release,
# as app.valarhq.ai/cli/latest serves it), bad/latest (the same with every binary tampered with),
# nobin/latest (release.json and checksums only), plus the installers at the top.
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
