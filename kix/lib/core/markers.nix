# Mark references to resources created outside this cluster definition.
# The marker supplies string context so reference validators accept the name.
# core/resource.nix excludes marker paths from depends-on because they have
# no deployable manifest. A marker with a kind also supplies an expectation
# that deploy checks before applying the resource that refers to it.
{ lib }:

rec {
  # /nix/store/ = 11 chars, hash = 32, "-" = 1 → name starts at offset 44
  pathName = p: builtins.substring 44 (builtins.stringLength p) p;

  untrackedRefName = "kix-untracked-ref";

  # Accept a name or { name; kind?; apiVersion?; by?; } and return the name
  # with marker context. A string alone adds no deployment existence check.
  #
  # The experimental attrset form supports two additional constraints:
  # by adds the creator's resource context for dependency ordering; kind adds
  # a kix.run/expects entry checked before applying the referring resource.
  # apiVersion defaults to "v1".
  #   kix.untrackedRef { kind = "Secret"; name = "x"; by = self.job; }
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
          builtins.toJSON (
            {
              inherit name kind apiVersion;
            }
            // lib.optionalAttrs (by != null) { hasCreator = true; }
          );
      marker = builtins.toFile untrackedRefName content;
      byCtx = if by == null then { } else builtins.getContext "${by}";
    in
    builtins.seq _check (builtins.appendContext name (builtins.getContext "${marker}" // byCtx));

  isUntrackedRefPath = p: lib.hasPrefix untrackedRefName (pathName p);

  # What a marker expects to exist, when its reference named a kind:
  # { name; kind; apiVersion; hasCreator?; }, else null. hasCreator is true
  # when the reference also named `by`.
  readExpectation =
    p:
    let
      content = builtins.readFile p;
    in
    if lib.hasPrefix "{" content then builtins.fromJSON content else null;

  # Whether a marker's reference named both a kind and its creator (`by`),
  # so deploy orders the referrer after the creator and waits for the object.
  namesCreator =
    p:
    let
      e = readExpectation p;
    in
    e != null && (e.hasCreator or false);
}
