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

  # EXPERIMENTAL (2026-09-20). `kix.untrackedRef "name"` is the bare claim:
  # something else creates it, and nothing checks. The attrset form names
  # the creator and the kind: `kix.untrackedRef { kind = "Secret"; name =
  # "x"; by = self.job; }`. The creator's context rides on the string, so
  # the referring resource depends on it like on any resource it names,
  # and the marker carries the kind, so the referring resource is stamped
  # `kix.run/expects` and deploy waits for the object before applying it
  # (cli readiness.rs, wait_for_expectations). If that wait proves to be
  # the wrong place, or the kind cannot be known where the reference is
  # written, fall back to recording `by` without the check, or to the bare
  # claim plus the untrackedReferences audit.
  mkUntrackedRef =
    ref:
    let
      spec = if builtins.isString ref then { name = ref; } else ref;
      name =
        spec.name or (throw "kix.untrackedRef: expected a name, or { name; kind?; apiVersion?; by? }");
      kind = spec.kind or null;
      apiVersion = spec.apiVersion or "v1";
      by = spec.by or null;
      known = [
        "name"
        "kind"
        "apiVersion"
        "by"
      ];
      unknown = builtins.filter (k: !(builtins.elem k known)) (builtins.attrNames spec);
      _check =
        if !(builtins.isString name) then
          throw "kix.untrackedRef: name must be a string"
        else if unknown != [ ] then
          throw "kix.untrackedRef (${name}): unknown attribute(s) ${builtins.concatStringsSep ", " unknown}; takes name, kind, apiVersion, by"
        else if kind != null && !(builtins.isString kind) then
          throw "kix.untrackedRef (${name}): kind must be a string, e.g. \"Secret\""
        else if by != null && !(builtins.isAttrs by && by ? outPath) then
          throw "kix.untrackedRef (${name}): `by` must be a resource, the Job or workload that creates the object"
        else
          null;
      content =
        if kind == null then
          name
        else
          builtins.toJSON {
            inherit name kind apiVersion;
          };
      marker = builtins.toFile untrackedRefName content;
      byCtx = if by == null then { } else builtins.getContext "${by}";
    in
    builtins.seq _check (builtins.appendContext name (builtins.getContext "${marker}" // byCtx));

  isUntrackedRefPath = p: lib.hasPrefix untrackedRefName (pathName p);

  # What a marker expects to exist, when its reference named a kind:
  # { name; kind; apiVersion; }, else null.
  readExpectation =
    p:
    let
      content = builtins.readFile p;
    in
    if lib.hasPrefix "{" content then builtins.fromJSON content else null;
}
