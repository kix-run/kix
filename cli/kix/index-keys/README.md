# Index signing keys

The public keys that Kix and the install script trust to sign the release
index, `kix.run/releases/index.json`. The site build in
`.github/workflows/pages.yml` runs `scripts/sign-index.sh`, which signs the
index with the private key in the repository secret `KIX_INDEX_SIGNING_KEY`
and writes `kix.run/releases/index.json.sig`. The release rehearsal in
`.github/workflows/cli-tests.yml` signs its copy of the site the same way. The
design is `discussions/163_cli_install_versions_and_upgrades.md` § 3.

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
site is not deployed. That step runs only on the tip of `main`: a preview
from another branch deploys an unsigned index, and a re-run of an old run
fails there, because Kix accepts any newer index. The index on kix.run then expires a week after it was
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

`index.json.sig` can hold one `keyid` and `signature` pair per key, and Kix
and the install script accept it when one pair verifies with a key they know.
`scripts/sign-index.sh` signs with every PEM key in the secret.

1. Make a new key and add it in all three places, beside the old one.
2. Put both private keys, one after the other, in `KIX_INDEX_SIGNING_KEY`.
   From the next site build, the index carries both signatures, so every
   Kix verifies it.
3. Release a Kix that knows the new key. Keep both keys in the secret for as
   long as people may run a Kix that knows only the old one.
4. Remove the old key from the secret and from all three places.
