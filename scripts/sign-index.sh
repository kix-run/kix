#!/usr/bin/env bash
#
# Sign the release index, so Kix and the install script can tell which
# releases kix.run really lists.
#
#   KIX_INDEX_SIGNING_KEY=<PEM> scripts/sign-index.sh <site-dir>
#
# Writes <site-dir>/releases/index.json.sig. The key's public half must be
# committed as cli/kix/index-keys/<keyid>.pub, so run this from the
# repository root. pages.yml runs it on every site build, and the release
# rehearsal in .github/workflows/cli-tests.yml runs it on its copy of the
# site. cli/kix/index-keys/README.md describes the key. Needs OpenSSL 3 and
# GNU coreutils.
#
# The index key is not the release key. It signs only which releases exist,
# so the site build never holds the key that signs a release.
set -euo pipefail

site="${1:?usage: scripts/sign-index.sh <site-dir>}"
index="$site/releases/index.json"
[ -f "$index" ] || { echo "::error::$index does not exist. Run web/scripts/release-index.mjs first."; exit 1; }

if [ -z "${KIX_INDEX_SIGNING_KEY:-}" ]; then
  echo "::error::The secret KIX_INDEX_SIGNING_KEY is not set, so the release index cannot be signed, and Kix would refuse it. See cli/kix/index-keys/README.md."
  exit 1
fi

umask 077
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/sign-index.XXXXXX")
trap 'rm -rf "$work"' EXIT
key="$work/kix-index.pem"
printf '%s\n' "$KIX_INDEX_SIGNING_KEY" > "$key"

openssl pkey -in "$key" -pubout -outform DER | tail -c 32 > "$work/index-key.raw"
keyid=$(sha256sum "$work/index-key.raw" | cut -c1-8)
public=$(od -An -v -tx1 "$work/index-key.raw" | tr -d ' \n')
committed="cli/kix/index-keys/$keyid.pub"
if [ ! -f "$committed" ] || [ "$(tr -d '[:space:]' < "$committed")" != "$public" ]; then
  echo "::error::$committed does not hold the public half of KIX_INDEX_SIGNING_KEY. Commit it before signing. See cli/kix/index-keys/README.md."
  exit 1
fi
if [ -f "cli/kix/release-keys/$keyid.pub" ]; then
  echo "::error::KIX_INDEX_SIGNING_KEY is release key $keyid. The index needs a key of its own. See cli/kix/index-keys/README.md."
  exit 1
fi

openssl pkeyutl -sign -inkey "$key" -rawin -in "$index" > "$work/index.sig.bin"
printf 'kix-index-signature v1\nkeyid=%s\nsignature=%s\n' \
  "$keyid" "$(base64 -w0 < "$work/index.sig.bin")" > "$index.sig"

openssl pkey -in "$key" -pubout -out "$work/index-key.pub.pem"
openssl pkeyutl -verify -pubin -inkey "$work/index-key.pub.pem" -rawin \
  -in "$index" -sigfile "$work/index.sig.bin"
cat "$index.sig"
