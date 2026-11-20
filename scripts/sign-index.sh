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

# The secret holds one PEM private key, or two during a key rotation. Each
# key adds a keyid and signature pair, so a Kix that knows either key
# verifies the index.
printf '%s\n' "$KIX_INDEX_SIGNING_KEY" | awk -v dir="$work" '
  /-----BEGIN / { n++ }
  n { print > (dir "/key-" n ".pem") }
'
ls "$work"/key-*.pem >/dev/null 2>&1 || { echo "::error::KIX_INDEX_SIGNING_KEY holds no PEM key. See cli/kix/index-keys/README.md."; exit 1; }

printf 'kix-index-signature v1\n' > "$work/index.json.sig"
for key in "$work"/key-*.pem; do
  openssl pkey -in "$key" -pubout -outform DER | tail -c 32 > "$work/index-key.raw"
  keyid=$(sha256sum "$work/index-key.raw" | cut -c1-8)
  public=$(od -An -v -tx1 "$work/index-key.raw" | tr -d ' \n')
  committed="cli/kix/index-keys/$keyid.pub"
  if [ ! -f "$committed" ] || [ "$(tr -d '[:space:]' < "$committed")" != "$public" ]; then
    echo "::error::$committed does not hold the public half of a key in KIX_INDEX_SIGNING_KEY. Commit it before signing. See cli/kix/index-keys/README.md."
    exit 1
  fi
  if [ -f "cli/kix/release-keys/$keyid.pub" ]; then
    echo "::error::KIX_INDEX_SIGNING_KEY holds release key $keyid. The index needs a key of its own. See cli/kix/index-keys/README.md."
    exit 1
  fi
  openssl pkeyutl -sign -inkey "$key" -rawin -in "$index" > "$work/index.sig.bin"
  openssl pkey -in "$key" -pubout -out "$work/index-key.pub.pem"
  openssl pkeyutl -verify -pubin -inkey "$work/index-key.pub.pem" -rawin \
    -in "$index" -sigfile "$work/index.sig.bin"
  printf 'keyid=%s\nsignature=%s\n' "$keyid" "$(base64 -w0 < "$work/index.sig.bin")" >> "$work/index.json.sig"
done

cp "$work/index.json.sig" "$index.sig"
cat "$index.sig"
