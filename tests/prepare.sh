#!/usr/bin/env bash
# Builds the stand-ins tests/test-install.* run against, under $1: good/latest (the newest release,
# as app.valarhq.ai/cli/latest serves it), bad/latest (the same with every binary tampered with),
# nobin/latest (release.json and checksums only), stub/latest (a stand-in valar, below), plus the
# installers at the top.
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

# stub/latest: a stand-in valar for the set-up cases. `valar setup` writes how it ran to
# $HOME/setup.log and exits $STUB_SETUP_EXIT; STUB_NO_SETUP=1 makes it a release without `setup`.
mkdir -p "$out/stub/latest"
for t in valar-linux-amd64 valar-linux-arm64 valar-darwin-amd64 valar-darwin-arm64; do
  cat >"$out/stub/latest/$t" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "valar valar-cli-v0.0.0-stub" ;;
  setup)
    case " $* " in
      *" --help "*) if [ "${STUB_NO_SETUP:-}" = 1 ]; then echo 'Error: unknown command "setup" for "valar"' >&2; exit 1; fi ;;
      *) { echo "args: $*"; if [ -t 0 ]; then echo "stdin: terminal"; else echo "stdin: not a terminal"; fi; } >"$HOME/setup.log"
         exit "${STUB_SETUP_EXIT:-0}" ;;
    esac ;;
esac
EOF
done
if command -v sha256sum >/dev/null 2>&1; then sum="sha256sum"; else sum="shasum -a 256"; fi
(cd "$out/stub/latest" && $sum valar-* >checksums.txt)
printf '{"tag_name": "valar-cli-v0.0.0-stub", "assets": []}\n' >"$out/stub/latest/release.json"
