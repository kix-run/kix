# A Kix runtime directory for the development shell, so `cargo test` and
# `cargo run` render Helm charts with the exact releases the library names.
#
# It holds every Helm release in kix/lib/helm-versions.json and this
# nixpkgs' nix, kubectl, and sops, in the `<program>-<version>/bin` layout
# that `runtime::tool` reads. A release ships the runtime that
# cli/runtime/ builds instead.
{ pkgs }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  platforms = {
    x86_64-linux = "linux-amd64";
    aarch64-linux = "linux-arm64";
    x86_64-darwin = "darwin-amd64";
    aarch64-darwin = "darwin-arm64";
  };

  helm =
    release:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "helm";
      inherit (release) version;
      src = pkgs.fetchurl {
        url = "https://get.helm.sh/helm-v${release.version}-${platforms.${system}}.tar.gz";
        sha256 = release.sha256.${system};
      };
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      installPhase = ''
        install -Dm755 helm $out/bin/helm
      '';
    };

  helmReleases = builtins.attrValues (lib.importJSON ../kix/lib/helm-versions.json);

  programs = [
    {
      name = "nix";
      package = pkgs.nix;
    }
    {
      name = "kubectl";
      package = pkgs.kubectl;
    }
    {
      name = "sops";
      package = pkgs.sops;
    }
  ]
  ++ map (release: {
    name = "helm";
    package = helm release;
  }) helmReleases;
in
pkgs.runCommand "kix-dev-runtime" { } (
  ''
    mkdir $out
  ''
  + lib.concatMapStrings (p: ''
    ln -s ${p.package} $out/${p.name}-${p.package.version}
  '') programs
)
