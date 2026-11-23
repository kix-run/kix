# Tests that the cluster the CLI's tests build (clusters/test-cli-fixture.nix)
# uses no package from kix/packages/. The CLI tests workflow skips a pull
# request that changes only kix/packages/, which is correct only while this
# holds.

{
  lib,
  publicKix,
  manifests,
  ofKind,
  namesOf,
  ...
}:

let
  file = ../../../../clusters/test-cli-fixture.nix;
  fixture = import file;
in
{
  # mkFlake passes a cluster function only the arguments it names, so a
  # function without `packages` cannot reach the package set. The text check
  # covers an import of a package file by path.
  cli-fixture-takes-no-package-set =
    let
      args = builtins.functionArgs fixture;
      text = builtins.readFile file;
    in
    (!(args ? packages) && !(lib.hasInfix "packages/" text))
    || throw "clusters/test-cli-fixture.nix must define its packages in the file: it takes `packages` or names a path under packages/. The CLI tests do not run for a change to kix/packages/.";

  # The library adds instances of its own in some configurations. Any
  # instance beyond the two the file defines would come from kix/packages/.
  cli-fixture-builds-only-its-own-instances =
    let
      names = lib.sort builtins.lessThan (
        namesOf (
          ofKind "PackageInstance" (
            manifests (fixture {
              kix = publicKix;
            })
          )
        )
      );
    in
    names == [
      "store"
      "web"
    ]
    || throw "clusters/test-cli-fixture.nix built the instances ${builtins.toJSON names}, expected store and web.";
}
