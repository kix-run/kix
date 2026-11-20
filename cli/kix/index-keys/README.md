# Index signing keys

The public keys that Kix and the install script trust to sign the release
index, `kix.run/releases/index.json`. The site build in
`.github/workflows/pages.yml` runs `scripts/sign-index.sh`, which signs the
index with the private key in the repository secret `KIX_INDEX_SIGNING_KEY`
and writes `kix.run/releases/index.json.sig`. The release rehearsal in
`.github/workflows/cli-tests.yml` signs its copy of the site the same way. The
design is `v2_discussions/163_cli_install_versions_and_upgrades.md` § 3.

## Why the index has its own key

The index says which releases exist, which one is the newest, and which were
withdrawn. Kix refuses an index after it expires, a week after the site made
it, so the site build signs a new one every day and must hold the key all
the time. A release key signs what Kix installs and is used only by the
`publish` job. Keeping the two apart means that whoever steals the index key
can hide or withdraw a release, but cannot make one that Kix installs.
`scripts/sign-index.sh` refuses a key that is also a release key.

## Format

The same as a release key (`cli/kix/release-keys/README.md`): one file per
key, `<keyid>.pub`, holding the raw 32-byte Ed25519 public key as 64
lowercase hex digits. The signature file starts with a different line, so a
signature over `SHA256SUMS` never passes for one over the index:

```
kix-index-signature v1
keyid=<keyid>
signature=<base64 of the 64-byte Ed25519 signature over the bytes of index.json>
```

A key is trusted in three places, which must agree:

- this directory
- `INDEX_KEYS` in `cli/kix/src/release/verify.rs`, compiled into Kix
- `INDEX_KEYS` in `web/public/install`, one hex key per line
  (`web/scripts/install.test.mjs` checks it against this directory)

The current key is `297d90c8`, created on 20 November 2026. Its private key is
the secret `KIX_INDEX_SIGNING_KEY`.

If the secret is empty, "Sign the release index" in `pages.yml` fails and the
site is not deployed. The index on kix.run then expires a week after it was
made, and from then on Kix installs nothing until a build signs a new one.

## Make a key

```sh
openssl genpkey -algorithm ed25519 -out kix-index.pem
pub=$(openssl pkey -in kix-index.pem -pubout -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n')
keyid=$(printf '%s' "$pub" | xxd -r -p | shasum -a 256 | cut -c1-8)
printf '%s\n' "$pub" > "cli/kix/index-keys/$keyid.pub"
```

`openssl` here must be OpenSSL 3: use `nix shell nixpkgs#openssl`. Then store
the contents of `kix-index.pem` as the repository secret
`KIX_INDEX_SIGNING_KEY`, keep an offline copy, and add the key to the other
two places above.

## Rotate a key

1. Add the new key in all three places, beside the old one, and release a
   Kix that knows both.
2. Replace the secret with the new private key. The next site build signs
   with it.
3. One minor release later, remove the old key from all three places.

A Kix that knows only the old key stops trusting the index after step 2, so
wait until few people run a Kix older than the release in step 1.
