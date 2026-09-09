# Inert context markers.
#
# `kix.untrackedRef "foo"` names a resource kix does not own (a Secret an
# operator mints at runtime, a ConfigMap another system owns). The validators
# reject bare string refs — a name with no Nix string context is an untracked
# reference — so the value has to carry SOME context to be accepted. The marker
# supplies it: a `builtins.toFile` whose only job is to exist.
#
# The marker is not a resource. It has no manifest, no identity hash, nothing
# to apply. So its store path must never be mistaken for a derivation edge:
# stamped into `kix.run/depends-on` it becomes a hash no manifest can ever
# resolve, and `kix health` reports the consuming workload as depending on a
# permanently MISSING resource. `isUntrackedRefPath` is how the depends-on
# stamper tells the inert channel from the real one.
{ lib }:

rec {
  # /nix/store/ = 11 chars, hash = 32, "-" = 1 → name starts at offset 44
  pathName = p: builtins.substring 44 (builtins.stringLength p) p;

  untrackedRefName = "kix-untracked-ref";

  mkUntrackedRef =
    name:
    let
      marker = builtins.toFile untrackedRefName name;
    in
    builtins.appendContext name (builtins.getContext "${marker}");

  isUntrackedRefPath = p: lib.hasPrefix untrackedRefName (pathName p);
}
