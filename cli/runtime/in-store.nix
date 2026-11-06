# Assemble a Kix runtime directory whose programs keep loading their
# libraries from /nix/store, for a Kix installed with Nix and for the
# development shell. The release archive relocates the macOS nix instead
# (assemble.py), which needs the command line tools that a Nix build on macOS
# does not have.
{ pkgs, nixRelease }:
pkgs.runCommand "kix-runtime-${pkgs.stdenv.hostPlatform.system}"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./assemble.py} --in-store ${import ./. { inherit pkgs nixRelease; }} $out
  ''
