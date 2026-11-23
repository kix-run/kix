# Return the images a package would pin at other versions of its upstream.
#
# `requests` maps a package name, as `kix list packages` shows it, to
# `{ from; to; }`: the version pinned now and a list of versions to move
# to. The result maps each package to
# `{ <version> = [ { path; ref; replaces; } ]; }`. `ref` is `repository:tag`
# with the tag rewritten for that version, and `replaces` is the reference
# the package pins now.
#
# An image follows the release when its default tag names the version in
# `from`. An image on a version line of its own, such as a `kubectl` or
# `busybox` helper, is left out, because a new upstream release says
# nothing about it.
{ lib }:
let
  versions = import ../lib/core/version.nix { inherit lib; };
  defaultImages = import ./default-images.nix { inherit lib; };

  imagesOf =
    package:
    let
      parts = lib.splitString "." package;
      level = if builtins.length parts == 2 then builtins.head parts else "stable";
    in
    defaultImages.${level}.${lib.last parts} or [ ];
in
lib.mapAttrs (
  package:
  { from, to }:
  let
    following = builtins.filter (
      i: i.repository != null && i.tag != null && versions.ofTag i.tag == from
    ) (imagesOf package);
  in
  lib.genAttrs to (
    version:
    map (i: {
      inherit (i) path;
      ref = "${i.repository}:${versions.retag i.tag version}";
      replaces = if i.digest != null then "${i.repository}@${i.digest}" else "${i.repository}:${i.tag}";
    }) following
  )
)
