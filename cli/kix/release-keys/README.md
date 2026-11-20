# Release signing keys

The public keys that Kix and the install script trust to sign a release's
`SHA256SUMS`. The `publish` job in `.github/workflows/cli-tests.yml` runs
`scripts/sign-release.sh`, which signs with the private key in the repository
secret `KIX_RELEASE_SIGNING_KEY` and writes the signature as `SHA256SUMS.sig`.
A manual run with the `rehearse` input runs the same script and installs the
result without publishing it (`cli/README.md` § Releases). kix.run lists a release only when
it has one (`web/scripts/release-index.mjs`). The design is
`v2_discussions/163_cli_install_versions_and_upgrades.md` § 3. The release
index has a key of its own, in `cli/kix/index-keys/`.

## Format

Each key is one file, `<keyid>.pub`, holding the raw 32-byte Ed25519 public
key as 64 lowercase hex digits. `<keyid>` is the first 8 hex digits of the
SHA-256 of those 32 bytes. `SHA256SUMS.sig` names the key that signed it:

```
kix-release-signature v1
keyid=<keyid>
signature=<base64 of the 64-byte Ed25519 signature over the bytes of SHA256SUMS>
```

A key is trusted in three places, which must agree:

- this directory
- `KEYS` in `cli/kix/src/release/verify.rs`, compiled into Kix
- `RELEASE_KEYS` in `web/public/install`, one hex key per line
  (`web/scripts/install.test.mjs` checks it against this directory)

The current key is `07c2b3e1`, created on 8 November 2026. Its private key is
the secret `KIX_RELEASE_SIGNING_KEY`, with a backup in 1Password.

Without any key in this directory, Kix refuses to install another version, the
install script checks the SHA-256 only, and `publish` skips "Sign checksums"
with a warning and publishes the release unsigned. kix.run does not list an
unsigned release, so neither Kix nor the install script installs it
automatically. Once a key file is in this directory, "Sign checksums" fails
when the secret `KIX_RELEASE_SIGNING_KEY` is empty.

## Add the first key

```sh
openssl genpkey -algorithm ed25519 -out kix-release.pem
pub=$(openssl pkey -in kix-release.pem -pubout -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n')
keyid=$(printf '%s' "$pub" | xxd -r -p | shasum -a 256 | cut -c1-8)
printf '%s\n' "$pub" > "cli/kix/release-keys/$keyid.pub"
```

`openssl` here must be OpenSSL 3 (macOS ships LibreSSL, which has no
Ed25519): use `nix shell nixpkgs#openssl`. Then:

1. Store the contents of `kix-release.pem` as the repository secret
   `KIX_RELEASE_SIGNING_KEY`, and keep an offline copy. Do not commit it.
2. Add `<keyid>.pub` to this directory, the key to `KEYS` in
   `cli/kix/src/release/verify.rs`, and the hex key to `RELEASE_KEYS` in
   `web/public/install`.
3. Run `node --test 'web/scripts/*.test.mjs'` and the CLI tests.

## Rotate a key

1. Make a new key as above and add it in all three places, beside the old
   one. Release a Kix signed by the old key, so that Kix knows both.
2. Replace the secret with the new private key. Releases from then on are
   signed by the new key.
3. One minor release later, remove the old key from all three places.

`keyid` in `SHA256SUMS.sig` selects the key, so a Kix that knows both
verifies either signature.
