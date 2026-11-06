# List the programs the Kix runtime ships for the platform of `pkgs`: the
# exact version and source of each, and the licence facts the release build
# checks.
#
# `kix` compiles in the names and versions from programs.json and refuses a
# runtime whose manifest lists others. Evaluating this file fails when the two
# disagree, so a version change edits both files.
#
# Each program here also needs a `Tool` variant in cli/kix/src/runtime.rs
# before Kix can run it.
{ pkgs }:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system isDarwin;

  compiledIn = lib.importJSON ./programs.json;
  helmVersions = lib.importJSON ../../kix/lib/helm-versions.json;

  kubectlVersion = "1.37.2";
  sopsVersion = "3.12.1";

  # Upstream names for each target platform.
  upstream =
    {
      x86_64-linux = {
        helm = "linux-amd64";
        kubectl = "linux/amd64";
        sops = "linux.amd64";
      };
      aarch64-linux = {
        helm = "linux-arm64";
        kubectl = "linux/arm64";
        sops = "linux.arm64";
      };
      aarch64-darwin = {
        helm = "darwin-arm64";
        kubectl = "darwin/arm64";
        sops = "darwin.arm64";
      };
    }
    .${system} or (throw "The Kix runtime has no build for ${system}.");

  # The SHA-256 of each upstream release file, from the checksum file each
  # project publishes beside it. Helm's live in kix/lib/helm-versions.json,
  # which the Kix library reads too.
  hashes = {
    "kubectl-1.37.2" = {
      x86_64-linux = "sha256-wESHUj56p9FJP3gIF0yJnbk9epz1dTFCDNdrm9QV+PQ=";
      aarch64-linux = "sha256-/MFvYxhmWdlyIBS34C1f3S1OZpy4wKtmNl19O4ugNQk=";
      aarch64-darwin = "sha256-VXAa8NUYFe4zXyQOSKzwlZw8IwF+0/qBbogMSpK65YE=";
    };
    "kubectl-1.37.2-LICENSE" = "sha256-z8d0m5b2O9McPEK1xHG/dWgUBT6EfBDz6wA0F7xSPTA=";
    "sops-3.12.1" = {
      x86_64-linux = "sha256-zzE20gpgBEBcmGpI4XnDx6cx93f78QWje9XaxckEcQA=";
      aarch64-linux = "sha256-x5BNB78fs//cMpsBA85w/2qISqeveTFCdAK+oMCcxSI=";
      aarch64-darwin = "sha256-OiPDiOLXub7/MG9IF9GXaYsdnd8BwQAgRwyUIlQ16QE=";
    };
    "sops-3.12.1-LICENSE" = "sha256-HyVuytGSiAUQ6ErWBHTqt1iSGHhLmlC8fO7jTCuR8dU=";
  };

  hashOf =
    key:
    let
      entry = hashes.${key} or (throw "cli/runtime/runtime.nix has no hash for ${key}.");
    in
    if builtins.isString entry then
      entry
    else
      entry.${system} or (throw "cli/runtime/runtime.nix has no hash for ${key} on ${system}.");

  helm =
    release:
    let
      inherit (release) version;
      tarball = pkgs.fetchurl {
        url = "https://get.helm.sh/helm-v${version}-${upstream.helm}.tar.gz";
        sha256 =
          release.sha256.${system}
            or (throw "kix/lib/helm-versions.json has no hash for Helm ${version} on ${system}.");
      };
      unpacked = pkgs.runCommand "helm-${version}-${upstream.helm}" { } ''
        mkdir $out
        tar -xzf ${tarball} -C $out --strip-components=1
      '';
    in
    {
      program = {
        name = "helm";
        inherit version;
        files."bin/helm" = "${unpacked}/helm";
        bin = [ "helm" ];
      };
      components = [
        {
          name = "helm";
          inherit version;
          licences = [ "Apache-2.0" ];
          homepage = "https://helm.sh";
          source = "https://github.com/helm/helm/tree/v${version}";
          download = tarball.url;
          downloadHash = tarball.outputHash;
          licenceFiles = [ "${unpacked}/LICENSE" ];
        }
      ];
    };

  kubectl =
    let
      version = kubectlVersion;
      binary = pkgs.fetchurl {
        url = "https://dl.k8s.io/release/v${version}/bin/${upstream.kubectl}/kubectl";
        hash = hashOf "kubectl-${version}";
      };
    in
    {
      program = {
        name = "kubectl";
        inherit version;
        files."bin/kubectl" = "${binary}";
        bin = [ "kubectl" ];
      };
      components = [
        {
          name = "kubectl";
          inherit version;
          licences = [ "Apache-2.0" ];
          homepage = "https://kubernetes.io";
          source = "https://github.com/kubernetes/kubernetes/tree/v${version}";
          download = binary.url;
          downloadHash = binary.outputHash;
          licenceFiles = [
            (pkgs.fetchurl {
              name = "kubernetes-${version}-LICENSE";
              url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v${version}/LICENSE";
              hash = hashOf "kubectl-${version}-LICENSE";
            })
          ];
        }
      ];
    };

  sops =
    let
      version = sopsVersion;
      binary = pkgs.fetchurl {
        url = "https://github.com/getsops/sops/releases/download/v${version}/sops-v${version}.${upstream.sops}";
        hash = hashOf "sops-${version}";
      };
    in
    {
      program = {
        name = "sops";
        inherit version;
        files."bin/sops" = "${binary}";
        bin = [ "sops" ];
      };
      components = [
        {
          name = "sops";
          inherit version;
          licences = [ "MPL-2.0" ];
          homepage = "https://getsops.io";
          source = "https://github.com/getsops/sops/tree/v${version}";
          download = binary.url;
          downloadHash = binary.outputHash;
          licenceFiles = [
            (pkgs.fetchurl {
              name = "sops-${version}-LICENSE";
              url = "https://raw.githubusercontent.com/getsops/sops/v${version}/LICENSE";
              hash = hashOf "sops-${version}-LICENSE";
            })
          ];
        }
      ];
    };

  # Linux gets a static build with no library to bundle. macOS has no static
  # build in the binary cache, so the assembly step copies the dynamic build's
  # libraries beside it (`relocate`).
  nixPackage = if isDarwin then pkgs.nix else pkgs.pkgsStatic.nix;

  # Licence decisions for the libraries in the `nix` build. Each entry names
  # the licence nixpkgs lists, so a nixpkgs update that changes it fails
  # evaluation here and someone reviews the entry again.
  licenceOverrides = {
    libgit2 = {
      nixpkgs = [ "GPL-2.0-only" ];
      ships = [ "GPL-2.0-only WITH GCC-exception-2.0" ];
      why = "libgit2's COPYING adds a linking exception, which nixpkgs does not record.";
    };
    xz = {
      nixpkgs = [
        "GPL-2.0-or-later"
        "LGPL-2.1-or-later"
      ];
      ships = [ "0BSD" ];
      why = "Nix links only liblzma, which is 0BSD. The GPL and LGPL cover xz's other tools.";
    };
    acl = {
      nixpkgs = [ "GPL-2.0-or-later" ];
      ships = [ "LGPL-2.1-or-later" ];
      why = "Nix links only libacl, which is LGPL. The GPL covers the acl tools.";
    };
    attr = {
      nixpkgs = [ "GPL-2.0-or-later" ];
      ships = [ "LGPL-2.1-or-later" ];
      why = "Nix links only libattr, which is LGPL. The GPL covers the attr tools.";
    };
    libidn2 = {
      nixpkgs = [
        "LGPL-3.0-or-later"
        "GPL-2.0-or-later"
        "GPL-3.0-or-later"
      ];
      ships = [ "LGPL-3.0-or-later" ];
      why = "libidn2 is offered under the LGPL or the GPL. Kix ships it under the LGPL.";
    };
    gettext = {
      nixpkgs = [ "GPL-2.0-or-later" ];
      ships = [ "LGPL-2.1-or-later" ];
      why = "Nix links only libintl, which is LGPL. The GPL covers the gettext tools.";
    };
    icu4c = {
      nixpkgs = [ ];
      ships = [ "Unicode-3.0" ];
      why = "nixpkgs records no licence for ICU. ICU 74 and later use the Unicode License v3.";
    };
    gcc = {
      nixpkgs = [ "GPL-3.0-or-later" ];
      ships = [ "GPL-3.0-or-later WITH GCC-exception-3.1" ];
      why = "The static build links libstdc++ and libgcc, which carry the GCC Runtime Library Exception.";
    };
  };

  # Packages in the build graph of `nix` whose code does not end up in the
  # shipped files.
  notShipped = {
    bash = "Runs build scripts. Nix does not link it.";
    getopt = "A command-line tool used by build scripts.";
    doctest = "A test framework.";
    atf = "A test framework.";
    lzo = "libarchive in this build runs the external lzop program instead of linking lzo.";
    find-xml-catalogs-hook = "A build hook.";
    musl-iconv = "The iconv headers of musl, which the musl entry covers.";
  };

  # Libraries every Mac provides, which the macOS bundle loads from /usr/lib
  # instead of shipping (see `system_substitute` in assemble.py).
  systemLibraries = lib.optionals isDarwin [
    pkgs.darwin.libiconv
    pkgs.darwin.libresolv
  ];

  # The C and C++ runtime the static Linux build links in. Nothing in the
  # build-input graph names them.
  toolchainRuntime = lib.optionals (!isDarwin) [
    pkgs.pkgsStatic.stdenv.cc.libc
    pkgs.pkgsStatic.stdenv.cc.cc
  ];

  # Cross compilers carry the target in their name, such as
  # `x86_64-unknown-linux-musl-gcc`.
  nameOf =
    d:
    lib.removePrefix "${pkgs.pkgsStatic.stdenv.hostPlatform.config}-" (
      d.pname or (builtins.parseDrvName d.name).name
    );

  licenceIds =
    l:
    if builtins.isList l then
      lib.concatMap licenceIds l
    else if builtins.isAttrs l then
      [ (l.spdxId or l.shortName or (throw "a licence in nixpkgs has neither spdxId nor shortName")) ]
    else
      [ l ];

  shippedLicences =
    d:
    let
      name = nameOf d;
      listed = licenceIds (d.meta.license or [ ]);
      override = licenceOverrides.${name} or null;
    in
    if override == null then
      listed
    else if override.nixpkgs == listed then
      override.ships
    else
      throw ''
        nixpkgs now lists ${builtins.toJSON listed} as the licence of ${name}, where
        cli/runtime/runtime.nix expects ${builtins.toJSON override.nixpkgs}. Review the
        entry in licenceOverrides: ${override.why}
      '';

  # Every package `nix` is built against, following buildInputs and
  # propagatedBuildInputs. This over-approximates what is linked, which is
  # safe for licence texts. On macOS, assemble.py checks that every library
  # it bundles belongs to one of these packages.
  linkedPackages =
    let
      deps =
        d:
        builtins.filter (x: lib.isDerivation x && !(notShipped ? ${nameOf x})) (
          (d.buildInputs or [ ]) ++ (d.propagatedBuildInputs or [ ])
        );
      walked = builtins.genericClosure {
        startSet = [
          {
            key = nixPackage.nix-cli.outPath;
            drv = nixPackage.nix-cli;
          }
        ];
        operator =
          x:
          map (d: {
            key = d.outPath;
            drv = d;
          }) (deps x.drv);
      };
      # By name and version, because the build graph can hold several
      # instances of one package that differ only in how they were built.
      isSystemLibrary = d: lib.any (s: nameOf s == nameOf d && s.version == d.version) systemLibraries;
    in
    builtins.filter (d: !(isSystemLibrary d)) (map (x: x.drv) walked) ++ toolchainRuntime;

  component =
    d:
    let
      src = d.src or null;
    in
    {
      name = nameOf d;
      version = d.version or "";
      licences = shippedLicences d;
      homepage = d.meta.homepage or null;
      source = null;
      download = if src == null then null else builtins.head (src.urls or [ (src.url or null) ]);
      downloadHash = if src == null then null else src.outputHash or null;
      src = if src == null then null else "${src}";
      patches = map (p: "${p}") (d.patches or [ ]);
      storePaths = map (o: d.${o}.outPath) (d.outputs or [ "out" ]);
    };

  nix = {
    program = {
      name = "nix";
      inherit (nixPackage) version;
      files."bin/nix" = "${nixPackage}/bin/nix";
      links."bin/nix-store" = "nix";
      bin = [
        "nix"
        "nix-store"
      ];
      relocate = isDarwin;
    };
    components = map component linkedPackages;
  };

  entries = [
    nix
  ]
  ++ map helm (lib.attrValues helmVersions)
  ++ [
    kubectl
    sops
  ];

  programs = map (e: e.program) entries;

  shippedVersions = lib.foldl' (
    acc: p: acc // { ${p.name} = lib.sort lib.versionOlder ((acc.${p.name} or [ ]) ++ [ p.version ]); }
  ) { } programs;

  # Licences the runtime may ship. Adding one is a legal decision, not a
  # build fix.
  allowedLicences = [
    "0BSD"
    "Apache-2.0"
    "BSD-2-Clause"
    "BSD-3-Clause"
    "BSD-4-Clause"
    "BSL-1.0"
    "Boehm-GC"
    "CC0-1.0"
    "ISC"
    "MIT"
    "MPL-2.0"
    "Unicode-3.0"
    "Zlib"
    "curl"
    "publicDomain"
    "LGPL-2.0-or-later"
    "LGPL-2.1-only"
    "LGPL-2.1-or-later"
    "LGPL-3.0-or-later"
    "GPL-2.0-only WITH GCC-exception-2.0"
    "GPL-3.0-or-later WITH GCC-exception-3.1"
  ];

  components = lib.concatMap (e: map (c: c // { program = e.program.name; }) e.components) entries;

  refused = builtins.filter (
    c: c.licences == [ ] || lib.subtractLists allowedLicences c.licences != [ ]
  ) components;
in
assert lib.assertMsg (shippedVersions == compiledIn) ''
  cli/runtime/programs.json lists ${builtins.toJSON compiledIn},
  but cli/runtime/runtime.nix ships ${builtins.toJSON shippedVersions}.
  kix compiles programs.json in, so update it to match.
'';
assert lib.assertMsg (refused == [ ]) ''
  The Kix runtime would ship code under a licence that is not on the approved
  list in cli/runtime/runtime.nix:
  ${lib.concatMapStringsSep "\n" (
    c:
    "  ${c.name} ${c.version}: ${
        if c.licences == [ ] then "no licence recorded" else builtins.toJSON c.licences
      }"
  ) refused}
'';
{
  inherit system programs components;
}
