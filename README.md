# valar-code-cli

Public installer and release distribution for the **`valar`** CLI — the client-side
tool that routes Claude Code and Cursor through the Valar gateway
(`api.valarhq.ai`), changing only the base URL and key.

This repo holds the installer (`install.sh`) and the published release binaries.
The product source lives in a private repo; binaries are built there and published
here by a release workflow, signed with Sigstore/cosign.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh | sh
```

Pin a version:

```sh
VALAR_VERSION=v1.2.3 sh -c "$(curl -fsSL https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.sh)"
```

Install system-wide (to `/usr/local/bin`, prompts for `sudo`):

```sh
sh install.sh --prefix /usr/local
```

Audit-first (recommended for production — pin the script to an immutable commit
and read it before running):

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/valarhq/valar-code-cli/<commit-sha>/install.sh
less install.sh
sh install.sh
```

## What it does

1. Detects OS (`darwin`/`linux`) and arch (`arm64`/`amd64`).
2. Resolves the version (latest, or `VALAR_VERSION`).
3. Downloads the matching binary + `checksums.txt` (+ cosign signature/bundle) from
   this repo's Releases.
4. **Verifies the binary's SHA256 against `checksums.txt`** — mandatory, fails closed.
5. If [`cosign`](https://github.com/sigstore/cosign) is installed, verifies the
   Sigstore signature on `checksums.txt` against the build workflow identity
   (provenance; see [SECURITY.md](SECURITY.md)). Skipped if `cosign` is absent.
6. Installs to `~/.local/bin/valar` (override with `--prefix`).
7. Adds the install dir to `PATH` via your shell rc (`~/.zshrc` / `~/.bashrc` /
   `~/.bash_profile`), idempotently.

Dependencies: `curl`, `sha256sum`, `uname`. `cosign` is optional.

## Supported platforms

| OS | Arch |
|----|------|
| macOS (darwin) | arm64, amd64 |
| Linux | arm64, amd64 |

## Verify a release manually

```sh
tag=v1.2.3
curl -fsSL -o checksums.txt     https://github.com/valarhq/valar-code-cli/releases/download/$tag/checksums.txt
curl -fsSL -o checksums.txt.sig https://github.com/valarhq/valar-code-cli/releases/download/$tag/checksums.txt.sig
curl -fsSL -o checksums.txt.bundle https://github.com/valarhq/valar-code-cli/releases/download/$tag/checksums.txt.bundle
cosign verify-blob \
  --certificate-identity "https://github.com/valarhq/valar-byoc/.github/workflows/release-valar-code.yml@refs/tags/$tag" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --bundle checksums.txt.bundle --signature checksums.txt.sig checksums.txt
sha256sum -c checksums.txt   # check the binary you downloaded
```

See [SECURITY.md](SECURITY.md) for the full integrity + provenance story.
