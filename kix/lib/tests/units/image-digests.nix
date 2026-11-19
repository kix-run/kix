# Tests that every default image a package Kix ships is pinned by digest.
# A tag can move to other content on the registry, so a default without a
# digest deploys whatever the tag points at on the day of the pull. The
# check reads each package's option declarations and finds the image
# options that `kix.options.image` builds, at any depth. An image option
# with a default repository and tag must also carry a default digest, and
# its repository must name the registry host.
# `kix/packages/unpinned-images.nix` lists the images that cannot take a
# digest. A container image written as a string literal in a package file
# escapes the option walk, so a second check refuses those.

{
  lib,
  eval,
  ...
}:

let
  packagesByLevel = import ../../../packages/by-level.nix { inherit lib; };
  unpinnedAllowed = import ../../../packages/unpinned-images.nix;

  # A scope with the values option declarations read for their defaults.
  stubScope = {
    instanceName = "inst";
    namespaceName = "ns";
  };

  optionsOf =
    package:
    (eval.callPackagePhase1 {
      inherit package;
      scope = stubScope;
    }).options or { };

  # The options a submodule declares, under any `nullOr`, `listOf`, or
  # `attrsOf`, or `{ }` for any other type.
  subOptionsOf =
    t:
    if t == null then
      { }
    else if
      builtins.elem t.name [
        "nullOr"
        "listOf"
        "attrsOf"
        "lazyAttrsOf"
      ]
    then
      subOptionsOf (t.nestedTypes.elemType or null)
    else if t.name == "submodule" then
      removeAttrs (t.getSubOptions [ ]) [ "_module" ]
    else
      { };

  isImageOption =
    v:
    let
      subs = subOptionsOf (v.type or null);
    in
    subs ? repository && subs ? tag && subs ? digest && subs ? pullPolicy;

  # Return `[ { path; default; } ]` for every image option under `opts`.
  imagesIn =
    prefix: opts:
    lib.concatLists (
      lib.mapAttrsToList (
        name: v:
        let
          path = if prefix == "" then name else "${prefix}.${name}";
        in
        if (v._type or null) == "option" then
          if isImageOption v then
            [
              {
                inherit path;
                default = v.default or { };
              }
            ]
          else
            imagesIn path (subOptionsOf (v.type or null))
        else if builtins.isAttrs v && !(v ? _type) then
          imagesIn path v
        else
          [ ]
      ) opts
    );

  hasDefaultImage = d: (d.repository or null) != null && (d.tag or null) != null;
  isDigest = d: d != null && builtins.match "sha256:[0-9a-f]{64}" d != null;
  # The first path segment names a registry host when it holds a dot or a
  # port, or is `localhost`.
  hasRegistryHost =
    repo:
    let
      first = builtins.head (lib.splitString "/" repo);
    in
    lib.hasInfix "/" repo && (lib.hasInfix "." first || lib.hasInfix ":" first || first == "localhost");

  allPackages = packagesByLevel.stable // packagesByLevel.experimental;
  images = lib.concatLists (
    lib.mapAttrsToList (
      pkgName: package:
      map (i: i // { name = "${pkgName}.${i.path}"; }) (
        builtins.filter (i: hasDefaultImage i.default) (imagesIn "" (optionsOf package))
      )
    ) allPackages
  );

  unpinned = map (i: "${i.name} (${i.default.repository}:${i.default.tag})") (
    builtins.filter (i: !(unpinnedAllowed ? ${i.name}) && !(isDigest (i.default.digest or null))) images
  );
  stale = builtins.filter (k: !(builtins.any (i: i.name == k) images)) (
    builtins.attrNames unpinnedAllowed
  );

  # Every .nix file under kix/packages, as a path.
  nixFiles =
    dir:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        if type == "directory" then
          nixFiles (dir + "/${name}")
        else
          lib.optional (lib.hasSuffix ".nix" name) (dir + "/${name}")
      ) (builtins.readDir dir)
    );
  packagesDir = ../../../packages;
  # Lines that set a container image to a string literal, such as
  # `image = "docker.io/library/busybox:1.38.0";`.
  literalImages = lib.concatMap (
    file:
    map (line: "${lib.removePrefix "${toString packagesDir}/" (toString file)}: ${lib.trim line}") (
      builtins.filter (line: builtins.match "[[:space:]]*image = \"[^\"$]*\";.*" line != null) (
        lib.splitString "\n" (builtins.readFile file)
      )
    )
  ) (nixFiles packagesDir);
  noHost = map (i: "${i.name} (${i.default.repository})") (
    builtins.filter (i: !(hasRegistryHost i.default.repository)) images
  );
in
{
  # Guard the walk itself: it must find the images of a package known to
  # have several, or the two tests below pass by finding nothing.
  image-digests-walk-finds-images =
    builtins.length (builtins.filter (i: lib.hasPrefix "cert-manager." i.name) images) >= 3
    || throw "image-digests: expected at least 3 default image options in cert-manager, found options across all packages: ${
      builtins.toJSON (map (i: i.name) images)
    }. Update imagesIn or isImageOption in kix/lib/tests/units/image-digests.nix if kix.options.image changed.";

  image-digests-defaults-are-pinned =
    unpinned == [ ]
    || throw "Package image options with a default tag are missing a valid sha256 digest: ${lib.concatStringsSep ", " unpinned}. Look up the tag's multi-arch digest with `nix run nixpkgs#crane -- digest <repository>:<tag>` and pass it as `digest` to `kix.options.image`. If an image cannot run with a digest, add the option to `kix/packages/unpinned-images.nix` with the reason.";

  image-digests-allowlist-is-current =
    stale == [ ]
    || throw "kix/packages/unpinned-images.nix lists options that no package declares with a default image: ${lib.concatStringsSep ", " stale}. Remove them from kix/packages/unpinned-images.nix.";

  image-digests-no-literal-images =
    literalImages == [ ]
    || throw "Package files under kix/packages set `image` to a hardcoded string: ${lib.concatStringsSep "; " literalImages}. Declare an option with `kix.options.image` (including the registry host and `digest`) and render it with `kix.image.ref`.";

  image-digests-defaults-name-registry =
    noHost == [ ]
    || throw "Package image options omit the registry host in their default `repository`: ${lib.concatStringsSep ", " noHost}. Include the registry host in `repository`, such as `docker.io/<org>/<name>` or `docker.io/library/<name>`.";
}
