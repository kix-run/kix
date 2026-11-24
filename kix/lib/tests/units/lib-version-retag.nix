# Tests for `versions.retag` (core/version.nix) and for
# kix/packages/release-images.nix, which the bump workflow uses to ask a
# registry for the images of a release before it starts a bump.

{ lib, ... }:

let
  versions = import ../../core/version.nix { inherit lib; };
  defaultImages = import ../../../packages/default-images.nix { inherit lib; };
  releaseImages = import ../../../packages/release-images.nix { inherit lib; };

  # Every default image as `{ package; path; repository; tag; }`, with the
  # package named as `kix list packages` shows it.
  images = lib.concatLists (
    lib.mapAttrsToList (
      level: packages:
      lib.concatLists (
        lib.mapAttrsToList (
          name: found:
          map (
            i:
            i
            // {
              package = if level == "stable" then name else "${level}.${name}";
            }
          ) (builtins.filter (i: i.repository != null && i.tag != null) found)
        ) packages
      )
    ) defaultImages
  );
  named = builtins.filter (i: versions.ofTag i.tag != null) images;
in
{
  lib-version-retag-keeps-the-tag-shape =
    let
      got = {
        prefix = versions.retag "v1.30.6" "1.30.8";
        vendorSuffix = versions.retag "1.30.6-alpine" "1.30.8";
        digest = versions.retag "v1.30.6-alpine@sha256:abc" "1.30.8";
        fourParts = versions.retag "26.8.40.7" "26.8.44.3";
        twoParts = versions.retag "18.7-standard-trixie" "18.8";
        build = versions.retag "1.31.2+rke2r1" "1.31.3";
        prerelease = versions.retag "2.0.0-rc1" "2.0.0";
        noVersion = versions.retag "latest" "1.0.0";
      };
      want = {
        prefix = "v1.30.8";
        vendorSuffix = "1.30.8-alpine";
        digest = "v1.30.8-alpine";
        fourParts = "26.8.44.3";
        twoParts = "18.8-standard-trixie";
        build = "1.31.3+rke2r1";
        prerelease = "2.0.0";
        noVersion = null;
      };
    in
    got == want || throw "versions.retag gave ${builtins.toJSON got}, expected ${builtins.toJSON want}";

  # The bump workflow relies on this for every image a package pins: the
  # tag read as a version and written back is the same tag.
  lib-version-retag-inverts-oftag-for-every-default-image =
    let
      wrong = builtins.filter (i: versions.retag i.tag (versions.ofTag i.tag) != i.tag) named;
    in
    wrong == [ ]
    || throw "versions.retag does not give back these default tags: ${
      builtins.toJSON (map (i: "${i.package} ${i.path} ${i.tag}") wrong)
    }";

  # Asked for the version a package pins now, release-images.nix returns
  # references the package already pins, and at least the image asked about.
  lib-version-release-images-at-the-pinned-version =
    let
      wrong = builtins.filter (
        i:
        let
          from = versions.ofTag i.tag;
          refs =
            map (r: r.ref)
              (releaseImages {
                ${i.package} = {
                  inherit from;
                  to = [ from ];
                };
              }).${i.package}.${from};
          pinned = map (p: "${p.repository}:${p.tag}") (builtins.filter (p: p.package == i.package) images);
        in
        !(builtins.elem "${i.repository}:${i.tag}" refs) || !(lib.all (r: builtins.elem r pinned) refs)
      ) named;
    in
    wrong == [ ]
    || throw "release-images.nix is wrong at the pinned version for: ${
      builtins.toJSON (map (i: "${i.package} ${i.path}") wrong)
    }";

  # A helper image on a version line of its own is not part of a release.
  lib-version-release-images-leave-out-other-version-lines =
    let
      got =
        map (r: r.ref)
          (releaseImages {
            "experimental.mayastor" = {
              from = "2.12.2";
              to = [ "2.12.3" ];
            };
          })."experimental.mayastor"."2.12.3";
      helpers = builtins.filter (r: lib.hasInfix "csi-attacher" r || lib.hasInfix "etcd" r) got;
    in
    (got != [ ] && helpers == [ ])
    || throw "release-images.nix listed helper images for mayastor: ${builtins.toJSON helpers}";
}
