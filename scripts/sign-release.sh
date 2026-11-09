#!/usr/bin/env bash
#
# Sign a release's SHA256SUMS with the release key, so Kix and the install
# script can check what they download from kix.run.
#
#   KIX_RELEASE_SIGNING_KEY=<PEM> scripts/sign-release.sh <dist-dir>
#
# Writes <dist-dir>/SHA256SUMS.sig. The key's public half must be committed
# as cli/kix/release-keys/<keyid>.pub, so run this from the repository root. The
# release job and the release rehearsal in .github/workflows/cli-tests.yml
# both run it. cli/kix/release-keys/README.md describes the key and the file
# format. Needs OpenSSL 3 and GNU coreutils.
set -euo pipefail

dist="${1:?usage: scripts/sign-release.sh <dist-dir>}"

# Before the first key is committed, no Kix could verify a signature, so the
# release goes out unsigned.
if ! ls cli/kix/release-keys/*.pub >/dev/null 2>&1; then
  echo "::warning::cli/kix/release-keys has no key, so this release is unsigned and Kix cannot install it automatically. cli/kix/release-keys/README.md says how to add a key."
  exit 0
fi
if [ -z "${KIX_RELEASE_SIGNING_KEY:-}" ]; then
  echo "::error::The repository secret KIX_RELEASE_SIGNING_KEY is not set, so the release cannot be signed. See cli/kix/release-keys/README.md."
  exit 1
fi

umask 077
work="${RUNNER_TEMP:-$(mktemp -d)}"
key="$work/kix-release.pem"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$KIX_RELEASE_SIGNING_KEY" > "$key"

openssl pkey -in "$key" -pubout -outform DER | tail -c 32 > "$work/release-key.raw"
keyid=$(sha256sum "$work/release-key.raw" | cut -c1-8)
public=$(od -An -v -tx1 "$work/release-key.raw" | tr -d ' \n')
committed="cli/kix/release-keys/$keyid.pub"
if [ ! -f "$committed" ] || [ "$(tr -d '[:space:]' < "$committed")" != "$public" ]; then
  echo "::error::$committed does not hold the public half of KIX_RELEASE_SIGNING_KEY. Commit it before releasing. See cli/kix/release-keys/README.md."
  exit 1
fi

openssl pkeyutl -sign -inkey "$key" -rawin -in "$dist/SHA256SUMS" > "$work/SHA256SUMS.sig.bin"
printf 'kix-release-signature v1\nkeyid=%s\nsignature=%s\n' \
  "$keyid" "$(base64 -w0 < "$work/SHA256SUMS.sig.bin")" > "$dist/SHA256SUMS.sig"

# Check the signature with the public key, which equals the committed one,
# as Kix will.
openssl pkey -in "$key" -pubout -out "$work/release-key.pub.pem"
openssl pkeyutl -verify -pubin -inkey "$work/release-key.pub.pem" -rawin \
  -in "$dist/SHA256SUMS" -sigfile "$work/SHA256SUMS.sig.bin"
cat "$dist/SHA256SUMS.sig"
