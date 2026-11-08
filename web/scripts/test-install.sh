#!/bin/sh
# Test web/public/install against fake releases on disk.
#
#   sh web/scripts/test-install.sh
#
# The releases are signed with a throwaway Ed25519 key made here, with
# OpenSSL 3 when it can and with Node otherwise. The installer checks the
# signature only where its openssl can (OpenSSL 3, not LibreSSL), so on a
# machine without OpenSSL 3 the signature cases check that it says so.

# The expected output and the fake uname name shell variables literally.
# shellcheck disable=SC2016

set -eu

here=$(cd "$(dirname "$0")" && pwd)
script=$here/../public/install
generator=$here/release-index.mjs

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  if [ -f "$out" ]; then
    sed 's/^/     | /' "$out"
  fi
  failures=$((failures + 1))
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | cut -d' ' -f1
  else
    shasum -a 256 "$@" | cut -d' ' -f1
  fi
}

# Make the signing key, and decide whether the installer can verify here.
if openssl genpkey -algorithm ed25519 -out "$tmp/key.pem" 2>/dev/null &&
  openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  signer=openssl
  openssl pkey -in "$tmp/key.pem" -pubout -outform DER | tail -c 32 >"$tmp/key.raw"
elif command -v node >/dev/null 2>&1; then
  signer=node
  node -e '
    const crypto = require("crypto");
    const fs = require("fs");
    const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
    fs.writeFileSync(process.argv[1], privateKey.export({ type: "pkcs8", format: "pem" }));
    fs.writeFileSync(process.argv[2], publicKey.export({ type: "spki", format: "der" }).subarray(-32));
  ' "$tmp/key.pem" "$tmp/key.raw"
else
  echo "test-install: needs OpenSSL 3 or Node to sign the test releases" >&2
  exit 1
fi
pubkey=$(od -An -v -tx1 "$tmp/key.raw" | tr -d ' \n')
keyid=$(sha256 "$tmp/key.raw" | cut -c1-8)
if openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  can_verify=yes
else
  can_verify=no
fi
echo "signing with $signer, key $keyid; installer can verify signatures: $can_verify"

# Print the base64 Ed25519 signature of a file.
sign() {
  case $signer in
    openssl) openssl pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$1" | openssl base64 -A ;;
    node)
      node -e '
        const crypto = require("crypto");
        const fs = require("fs");
        const key = crypto.createPrivateKey(fs.readFileSync(process.argv[1]));
        process.stdout.write(crypto.sign(null, fs.readFileSync(process.argv[2]), key).toString("base64"));
      ' "$tmp/key.pem" "$1"
      ;;
  esac
}

# Build a release source tree under $1 holding the versions given after it,
# laid out as kix.run serves it.
make_source() {
  src=$1
  shift
  for v in "$@"; do
    sums=$tmp/sums-$(basename "$src")/v$v
    mkdir -p "$sums" "$src/download/$v"
    for sys in x86_64-linux aarch64-linux aarch64-darwin; do
      pkg=$tmp/pkg/$v/kix-$v-$sys
      mkdir -p "$pkg/bin"
      printf '#!/bin/sh\necho "kix %s"\n' "$v" >"$pkg/bin/kix"
      chmod 755 "$pkg/bin/kix"
      (cd "$tmp/pkg/$v" && COPYFILE_DISABLE=1 tar -czf "$src/download/$v/kix-$sys.tar.gz" "kix-$v-$sys")
      printf '%s  %s\n' "$(sha256 "$src/download/$v/kix-$sys.tar.gz")" "kix-$sys.tar.gz" >>"$sums/SHA256SUMS"
    done
    printf 'kix-release-signature v1\nkeyid=%s\nsignature=%s\n' "$keyid" "$(sign "$sums/SHA256SUMS")" >"$sums/SHA256SUMS.sig"
  done
  if command -v node >/dev/null 2>&1; then
    node "$generator" "$tmp/sums-$(basename "$src")" "$src" >/dev/null 2>&1
  else
    # The generator's shape, for a machine without Node.
    mkdir -p "$src/releases"
    cp -R "$tmp/sums-$(basename "$src")/." "$src/releases/"
    {
      printf '{\n  "schema": "kix.run/releases/v1",\n  "generated": "2026-11-08T12:00:00Z",\n  "latest": "%s",\n  "releases": [' "$1"
      sep=''
      for v in "$@"; do
        printf '%s\n    {\n      "version": "%s",\n      "systems": ["aarch64-darwin", "aarch64-linux", "x86_64-linux"],\n' "$sep" "$v"
        printf '      "sums": "/releases/v%s/SHA256SUMS",\n      "signature": "/releases/v%s/SHA256SUMS.sig",\n      "download": "/download/%s/"\n    }' "$v" "$v" "$v"
        sep=','
      done
      printf '\n  ]\n}\n'
    } >"$src/releases/index.json"
  fi
}

# Run the installer with HOME=$1, from the source $2, with the remaining
# arguments as environment assignments. Its output goes to $out.
install_into() {
  home=$1
  from=$2
  shift 2
  mkdir -p "$home"
  out=$home.out
  set +e
  (
    unset XDG_DATA_HOME KIX_VERSION KIX_INSTALL_DIR KIX_INSTALL_TEST_PUBKEY
    HOME=$home
    KIX_INSTALL_SOURCE=file://$from
    export HOME KIX_INSTALL_SOURCE
    for assignment in "$@"; do
      export "${assignment?}"
    done
    sh "$script"
  ) >"$out" 2>&1
  status=$?
  set -e
}

has() { grep -qF -- "$1" "$out"; }

# The newest release is listed first so the hand-written index gets latest right.
make_source "$tmp/good" 1.10.0 1.2.3

# Install an older version by name, then the latest, which moves the link.
h=$tmp/h-upgrade
install_into "$h" "$tmp/good" KIX_VERSION=1.2.3 "KIX_INSTALL_TEST_PUBKEY=$pubkey"
data=$h/.local/share/kix
if [ "$status" -eq 0 ] && [ -L "$h/.local/bin/kix" ] &&
  [ "$(readlink "$h/.local/bin/kix")" = "$data/1.2.3/bin/kix" ] &&
  [ "$("$h/.local/bin/kix")" = "kix 1.2.3" ] &&
  has 'Installed Kix 1.2.3 to ~/.local/share/kix/1.2.3' &&
  has 'Add ~/.local/bin to your PATH: export PATH="$HOME/.local/bin:$PATH"'; then
  pass 'installs a named version and links it'
else
  bad 'installs a named version and links it'
fi

if grep -qF '"installer": "script"' "$data/receipt.json" &&
  grep -qF '"version": "1.2.3"' "$data/receipt.json" &&
  grep -qF "\"link\": \"$h/.local/bin/kix\"" "$data/receipt.json"; then
  pass 'writes the receipt'
else
  bad 'writes the receipt'
  cat "$data/receipt.json" 2>/dev/null || true
fi

if [ "$can_verify" = yes ]; then
  if has "Verified SHA256SUMS for Kix 1.2.3 with release key $keyid"; then
    pass 'verifies the signature'
  else
    bad 'verifies the signature'
  fi
elif has "this machine's openssl cannot check Ed25519 signatures; checked the SHA-256 only"; then
  pass 'says the signature was not checked'
else
  bad 'says the signature was not checked'
fi

if ls -d "$data"/tmp-* >/dev/null 2>&1; then
  bad 'leaves no temporary directory'
else
  pass 'leaves no temporary directory'
fi

install_into "$h" "$tmp/good" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
if [ "$status" -eq 0 ] && [ "$(readlink "$h/.local/bin/kix")" = "$data/1.10.0/bin/kix" ] &&
  [ -x "$data/1.2.3/bin/kix" ] && grep -qF '"version": "1.10.0"' "$data/receipt.json"; then
  pass 'installs the latest version and moves the link'
else
  bad 'installs the latest version and moves the link'
fi

install_into "$h" "$tmp/good" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
if [ "$status" -eq 0 ] && has 'Kix 1.10.0 is already installed in ~/.local/share/kix/1.10.0'; then
  pass 'reuses an installed version'
else
  bad 'reuses an installed version'
fi

# An archive that does not match SHA256SUMS.
cp -R "$tmp/good" "$tmp/tampered"
for archive in "$tmp"/tampered/download/1.10.0/*.tar.gz; do
  printf 'x' >>"$archive"
done
h=$tmp/h-tampered
install_into "$h" "$tmp/tampered" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
if [ "$status" -ne 0 ] && has 'does not match SHA256SUMS (expected' &&
  [ ! -e "$h/.local/share/kix/1.10.0" ] && [ ! -e "$h/.local/bin/kix" ]; then
  pass 'refuses an archive with the wrong SHA-256'
else
  bad 'refuses an archive with the wrong SHA-256'
fi

if [ "$can_verify" = yes ]; then
  # A signature over other bytes.
  cp -R "$tmp/good" "$tmp/badsig"
  printf 'other\n' >"$tmp/other"
  printf 'kix-release-signature v1\nkeyid=%s\nsignature=%s\n' "$keyid" "$(sign "$tmp/other")" \
    >"$tmp/badsig/releases/v1.10.0/SHA256SUMS.sig"
  h=$tmp/h-badsig
  install_into "$h" "$tmp/badsig" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
  if [ "$status" -ne 0 ] && has 'the release signature for Kix 1.10.0 does not verify' &&
    [ ! -e "$h/.local/share/kix/1.10.0" ]; then
    pass 'refuses a signature that does not verify'
  else
    bad 'refuses a signature that does not verify'
  fi

  h=$tmp/h-otherkey
  install_into "$h" "$tmp/good" "KIX_INSTALL_TEST_PUBKEY=$(printf '%064d' 7)"
  if [ "$status" -ne 0 ] && has "names key $keyid, which this install script does not know"; then
    pass 'refuses a signature by an unknown key'
  else
    bad 'refuses a signature by an unknown key'
  fi
fi

# Without the test key, only the keys built into the script count.
h=$tmp/h-nokey
install_into "$h" "$tmp/good"
if grep -q "^RELEASE_KEYS=''$" "$script"; then
  if [ "$status" -eq 0 ] && has 'this install script has no release signing key yet, so it checked the SHA-256 only'; then
    pass 'installs with the SHA-256 only while the script has no key'
  else
    bad 'installs with the SHA-256 only while the script has no key'
  fi
elif [ "$can_verify" = yes ]; then
  if [ "$status" -ne 0 ] && has 'which this install script does not know'; then
    pass 'refuses a release signed by the test key'
  else
    bad 'refuses a release signed by the test key'
  fi
fi

# A kix the script did not install.
h=$tmp/h-occupied
mkdir -p "$h/.local/bin"
printf '#!/bin/sh\n' >"$h/.local/bin/kix"
install_into "$h" "$tmp/good" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
if [ "$status" -ne 0 ] &&
  has 'install: ~/.local/bin/kix exists and was not installed by this script. Remove it, or install elsewhere with KIX_INSTALL_DIR'; then
  pass 'leaves a kix it did not install alone'
else
  bad 'leaves a kix it did not install alone'
fi
install_into "$h" "$tmp/good" "KIX_INSTALL_TEST_PUBKEY=$pubkey" "KIX_INSTALL_DIR=$h/bin"
if [ "$status" -eq 0 ] && [ "$(readlink "$h/bin/kix")" = "$h/.local/share/kix/1.10.0/bin/kix" ] &&
  has 'Add ~/bin to your PATH: export PATH="$HOME/bin:$PATH"'; then
  pass 'links into KIX_INSTALL_DIR'
else
  bad 'links into KIX_INSTALL_DIR'
fi

h=$tmp/h-missing
install_into "$h" "$tmp/good" KIX_VERSION=9.9.9 "KIX_INSTALL_TEST_PUBKEY=$pubkey"
if [ "$status" -ne 0 ] && has 'no Kix 9.9.9 release exists. The newest is 1.10.0'; then
  pass 'refuses a version that has no release'
else
  bad 'refuses a version that has no release'
fi

h=$tmp/h-bad-version
install_into "$h" "$tmp/good" KIX_VERSION=1.2.3- "KIX_INSTALL_TEST_PUBKEY=$pubkey"
if [ "$status" -ne 0 ] && has 'KIX_VERSION=1.2.3- is not a Kix version'; then
  pass 'refuses a version that is not one'
else
  bad 'refuses a version that is not one'
fi

# Prereleases need the generator, which marks them in the index.
if command -v node >/dev/null 2>&1; then
  make_source "$tmp/mixed" 1.3.0-rc.1 1.2.3
  h=$tmp/h-mixed
  install_into "$h" "$tmp/mixed" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
  if [ "$status" -eq 0 ] && [ "$("$h/.local/bin/kix")" = "kix 1.2.3" ]; then
    pass 'installs the newest release, not a newer prerelease'
  else
    bad 'installs the newest release, not a newer prerelease'
  fi
  install_into "$h" "$tmp/mixed" KIX_VERSION=1.3.0-rc.1 "KIX_INSTALL_TEST_PUBKEY=$pubkey"
  if [ "$status" -eq 0 ] && [ "$("$h/.local/bin/kix")" = "kix 1.3.0-rc.1" ] &&
    has 'Installed Kix 1.3.0-rc.1 to ~/.local/share/kix/1.3.0-rc.1'; then
    pass 'installs a prerelease by name'
  else
    bad 'installs a prerelease by name'
  fi

  make_source "$tmp/pre" 2.0.0-rc.1
  h=$tmp/h-pre
  install_into "$h" "$tmp/pre" "KIX_INSTALL_TEST_PUBKEY=$pubkey"
  if [ "$status" -ne 0 ] && has 'lists no Kix release yet, only the prerelease 2.0.0-rc.1' &&
    has 'KIX_VERSION=2.0.0-rc.1 sh'; then
    pass 'names the prerelease when there is no release'
  else
    bad 'names the prerelease when there is no release'
  fi
else
  echo 'skip prerelease checks, which need node'
fi

mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\ncase $1 in -s) echo FreeBSD ;; -m) echo amd64 ;; esac\n' >"$tmp/fakebin/uname"
chmod 755 "$tmp/fakebin/uname"
h=$tmp/h-freebsd
install_into "$h" "$tmp/good" "PATH=$tmp/fakebin:$PATH"
if [ "$status" -ne 0 ] &&
  has 'Kix has no release for FreeBSD amd64. Supported: x86_64-linux, aarch64-linux, aarch64-darwin'; then
  pass 'refuses an unsupported platform'
else
  bad 'refuses an unsupported platform'
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
