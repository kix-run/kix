# Tests that every default image a package Kix ships is pinned by digest.
# A tag can move to other content on the registry, so a default without a
# digest deploys whatever the tag points at on the day of the pull. The
# check reads the default images that `kix/packages/default-images.nix`
# finds in each package's option declarations. An image option with a
# default repository and tag must also carry a default digest, and its
# repository must name the registry host.
# `kix/packages/unpinned-images.nix` lists the images that cannot take a
# digest. A container image written as a string literal in a package file
# escapes the option walk, so a second check refuses those.

{
  lib,
  ...
}:

let
  defaultImages = import ../../../packages/default-images.nix { inherit lib; };
  unpinnedAllowed = import ../../../packages/unpinned-images.nix;

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

  images = lib.concatMap (
    level:
    lib.concatLists (
      lib.mapAttrsToList (
        pkgName: pkgImages:
        map (i: i // { name = "${pkgName}.${i.path}"; }) (builtins.filter hasDefaultImage pkgImages)
      ) defaultImages.${level}
    )
  ) (builtins.attrNames defaultImages);

  unpinned = map (i: "${i.name} (${i.repository}:${i.tag})") (
    builtins.filter (i: !(unpinnedAllowed ? ${i.name}) && !(isDigest i.digest)) images
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
  noHost = map (i: "${i.name} (${i.repository})") (
    builtins.filter (i: !(hasRegistryHost i.repository)) images
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
