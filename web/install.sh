#!/bin/sh
# Installs the Kix CLI into the user's Nix profile.
#
#   curl -fsSL https://kix.run/install | sh
#
# Not published yet. To publish it, copy this file to web/public/install
# (Astro serves public/ as-is, so it appears at kix.run/install) and
# uncomment the CommandBar in web/src/components/sections/Hero.astro and
# FinalCta.astro. See web/HANDOVER.md.
#
# The CLI is built from the kixpkgs flake, so Nix with flakes is required.
# The script does not install Nix itself: it prints where to get it and
# stops.
#
# Environment:
#   KIX_INSTALL_FLAKE  flake reference to install (default github:kix-run/kixpkgs#kix)

set -eu

KIX_INSTALL_FLAKE="${KIX_INSTALL_FLAKE:-github:kix-run/kixpkgs#kix}"
NIX_FLAGS="--extra-experimental-features nix-command --extra-experimental-features flakes"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'kix install: %s\n' "$*" >&2
  exit 1
}

if ! command -v nix >/dev/null 2>&1; then
  fail "Nix is not installed, or not on PATH. Kix is built with Nix.
Install Nix from https://nixos.org/download (or the Determinate Nix
installer at https://determinate.systems/nix), open a new shell, and run
this installer again."
fi

say "Installing the Kix CLI from ${KIX_INSTALL_FLAKE}"
say "Nix builds it or downloads it from a binary cache; the first run can take a few minutes."

# shellcheck disable=SC2086 # NIX_FLAGS is a list of flags.
if ! nix $NIX_FLAGS profile install "$KIX_INSTALL_FLAKE"; then
  fail "nix profile install failed (output above).
If your profile was created with nix-env, nix profile cannot manage it.
Run the command yourself after migrating the profile:
  nix profile install ${KIX_INSTALL_FLAKE}"
fi

if command -v kix >/dev/null 2>&1; then
  say ""
  say "Installed: $(kix --version 2>/dev/null || echo kix)"
  say "Next: https://kix.run/docs/tutorials/02-local-setup-and-first-run/"
else
  say ""
  say "Installed, but kix is not on PATH in this shell."
  say "Open a new shell, or add ~/.nix-profile/bin to PATH."
fi
