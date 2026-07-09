# Security: verifying a `valar` release

Every release of `valar` is built by a release workflow in the private
`valarhq/valar-monorepo` repo and published to this repo's GitHub Releases. Two layers
of verification protect the binary you run.

## 1. SHA256 checksum (mandatory)

Each release ships a `checksums.txt` listing the SHA256 of every platform binary:

```
<sha256>  valar-darwin-arm64
<sha256>  valar-darwin-amd64
<sha256>  valar-linux-arm64
<sha256>  valar-linux-amd64
```

`install.sh` downloads `checksums.txt`, extracts the line for your platform, and
runs `sha256sum -c`. If the downloaded binary does not match, installation aborts
and the temp file is discarded. This detects any in-transit or at-rest corruption
of the binary.

## 2. Sigstore / cosign signature on `checksums.txt` (optional but recommended)

`checksums.txt` itself is signed **keyless** with [cosign](https://github.com/sigstore/cosign)
using the GitHub Actions OIDC token of the build workflow. The signing identity is
recorded in the public Sigstore transparency log (Rekor) and is:

```
https://github.com/valarhq/valar-monorepo/.github/workflows/release-valar-code.yml@refs/tags/<tag>
```

The signature (`checksums.txt.sig`) and Rekor bundle (`checksums.txt.bundle`) are
published alongside the release. If `cosign` is on your `PATH`, `install.sh`
verifies the signature and aborts on failure. If `cosign` is not installed, the
step is skipped with a note — install `cosign` to get provenance verification.

To verify manually (no install.sh):

```sh
tag=valar-cli-v1.2.3
base=https://github.com/valarhq/valar-code-cli/releases/download/$tag
curl -fsSL -o checksums.txt        "$base/checksums.txt"
curl -fsSL -o checksums.txt.sig    "$base/checksums.txt.sig"
curl -fsSL -o checksums.txt.bundle "$base/checksums.txt.bundle"
cosign verify-blob \
  --certificate-identity "https://github.com/valarhq/valar-monorepo/.github/workflows/release-valar-code.yml@refs/tags/$tag" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --bundle checksums.txt.bundle checksums.txt
```

This proves `checksums.txt` — and therefore every binary listed in it — was produced
by that specific workflow run on that tag. Even if this distribution repo or its
releases were compromised, the signature would not validate against the
`valar-monorepo` workflow identity unless the attacker also controlled the private
repo's workflow.

## What this protects against

| Threat | Mitigation |
|--------|------------|
| Tampered/corrupted binary | Mandatory SHA256 vs `checksums.txt` |
| Tampered `checksums.txt` (release compromised) | cosign/Sigstore signature tied to the `valar-monorepo` workflow + tag identity, in a transparency log |
| Tampered `install.sh` (the `curl \| bash` surface) | Script is small and auditable; pin to an immutable commit SHA and read it first (`curl -o install.sh … && less install.sh && sh install.sh`) |

## Reproducible builds

Binaries are built with `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X …version=<tag>"`
for each `GOOS`/`GOARCH`. The flags are deterministic (trimpath drops local paths,
`-s -w` strips debug info), so a rebuild from the tagged source with the same Go
toolchain produces a byte-identical binary that matches the published checksum.
