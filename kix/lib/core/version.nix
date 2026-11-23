# Parse and compare version strings for `meta.version`, `meta.k8s`,
# `meta.compatibleWith`, and `k8sVersion`.
#
# Versions consist of an optional leading `v`, dot-separated numbers, an
# optional `-suffix`, and an optional `+build`. A `-suffix` is treated as a
# prerelease only when its first identifier starts with a tag in
# `prereleaseTags` (such as `rc1`). Other suffixes (such as `-gke.1209000`,
# `-eks-7f9249a`, or `-0`) are vendor build tags and are ignored like `+build`.
{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
  prereleaseTags = [
    "alpha"
    "beta"
    "rc"
    "pre"
    "dev"
    "preview"
  ];

  # Capture groups: 0 = core numbers, 3 = suffix without "-", 5 = build.
  grammar = "[vV]?([0-9]+(\\.[0-9]+)*)(-([0-9A-Za-z.-]+))?(\\+([0-9A-Za-z.-]+))?";

  # Split "rc10" into [ "rc" "10" ] so rc2 sorts before rc10.
  prereleaseOf =
    suffix:
    let
      ids = lib.splitString "." suffix;
      head = builtins.match "(${lib.concatStringsSep "|" prereleaseTags})([0-9]*)" (builtins.head ids);
    in
    if head == null then
      [ ]
    else
      [ (builtins.elemAt head 0) ]
      ++ lib.optional (builtins.elemAt head 1 != "") (builtins.elemAt head 1)
      ++ builtins.tail ids;

  tryParse =
    v:
    let
      m = if builtins.isString v then builtins.match grammar v else null;
      suffix = builtins.elemAt m 3;
    in
    if m == null then
      null
    else
      {
        core = map lib.toIntBase10 (lib.splitString "." (builtins.elemAt m 0));
        pre = if suffix == null then [ ] else prereleaseOf suffix;
      };

  isVersion = v: tryParse v != null;

  describe = v: if builtins.isString v then "\"${v}\"" else builtins.toJSON v;

  parse =
    v:
    let
      parsed = tryParse v;
    in
    if parsed != null then
      parsed
    else
      fail {
        message = "${describe v} is not a version Kix can compare.";
        fix = "Use numbers separated by dots, optionally with a leading \"v\", a \"-suffix\", and a \"+build\" suffix (for example \"1.19.6\", \"v2.12.2\", \"1.31.2+rke2r1\", \"1.31.2-gke.1209000\").";
      };

  # Return the version an image tag names, or null when it names none, such
  # as `latest`. The result has no leading `v`, no digest, and no vendor
  # suffix, so `v1.37.1-alpine@sha256:...` gives `1.37.1`. A prerelease
  # suffix stays, so `2.0.0-rc1` gives `2.0.0-rc1`.
  ofTag =
    tag:
    let
      m =
        if builtins.isString tag then
          builtins.match grammar (builtins.head (lib.splitString "@" tag))
        else
          null;
      suffix = builtins.elemAt m 3;
    in
    if m == null then
      null
    else
      builtins.elemAt m 0
      + lib.optionalString (suffix != null && prereleaseOf suffix != [ ]) "-${suffix}";

  # Return `v` without its leading `v` or `V` when `v` is a version, and
  # return any other value unchanged. Kix reports `meta.version` this way,
  # so a package can set it to an upstream tag such as `v1.19.6`.
  bare =
    v:
    if isVersion v && builtins.match "[vV].*" v != null then
      builtins.substring 1 (builtins.stringLength v) v
    else
      v;

  # Return the major and minor numbers of a version, such as [ 1 19 ] for
  # `v1.19.6`, or null when `v` is not a version or names no minor.
  minorOf =
    v:
    let
      parsed = tryParse v;
    in
    if parsed == null || builtins.length parsed.core < 2 then null else lib.take 2 parsed.core;

  # Return `tag` with the version it names replaced by `version`, or null
  # when `tag` names none. The leading `v`, a vendor suffix, and a `+build`
  # stay as they are, so `retag "v1.30.6-alpine" "1.30.8"` gives
  # `v1.30.8-alpine`. A digest and a prerelease suffix belong to the old
  # version and are dropped. `retag tag (ofTag tag)` gives back the tag.
  retag =
    tag: version:
    let
      bare = if builtins.isString tag then builtins.head (lib.splitString "@" tag) else null;
      m = if bare == null then null else builtins.match grammar bare;
      suffix = builtins.elemAt m 3;
      build = builtins.elemAt m 5;
    in
    if m == null then
      null
    else
      lib.optionalString (builtins.match "[vV].*" bare != null) (builtins.substring 0 1 bare)
      + version
      + lib.optionalString (suffix != null && prereleaseOf suffix == [ ]) "-${suffix}"
      + lib.optionalString (build != null) "+${build}";

  cmp =
    a: b:
    if a < b then
      -1
    else if a > b then
      1
    else
      0;

  # Compare two numeric core lists, padding the shorter list with zeros.
  compareCore =
    a: b:
    let
      len = lib.max (builtins.length a) (builtins.length b);
      pad = l: l ++ lib.genList (_: 0) (len - builtins.length l);
      pa = pad a;
      pb = pad b;
      go =
        i:
        if i >= len then
          0
        else
          let
            c = cmp (builtins.elemAt pa i) (builtins.elemAt pb i);
          in
          if c != 0 then c else go (i + 1);
    in
    go 0;

  isNumeric = s: builtins.match "[0-9]+" s != null;

  # Compare two prerelease identifier lists using SemVer 2.0 precedence, where
  # an empty list (a release) sorts after any prerelease.
  comparePre =
    a: b:
    if a == [ ] && b == [ ] then
      0
    else if a == [ ] then
      1
    else if b == [ ] then
      -1
    else
      let
        go =
          i:
          if i >= builtins.length a && i >= builtins.length b then
            0
          else if i >= builtins.length a then
            -1
          else if i >= builtins.length b then
            1
          else
            let
              x = builtins.elemAt a i;
              y = builtins.elemAt b i;
              c =
                if isNumeric x && isNumeric y then
                  cmp (lib.toIntBase10 x) (lib.toIntBase10 y)
                else if isNumeric x then
                  -1
                else if isNumeric y then
                  1
                else
                  cmp x y;
            in
            if c != 0 then c else go (i + 1);
      in
      go 0;

  compareParsed =
    a: b:
    let
      c = compareCore a.core b.core;
    in
    if c != 0 then c else comparePre a.pre b.pre;

  # Compare two version strings and return -1, 0, or 1.
  compare = a: b: compareParsed (parse a) (parse b);

  # Compare `v` against `constraint` at the constraint's precision, returning
  # null when `v` is less precise than `constraint` and matches its prefix.
  compareAtPrecision =
    v: constraint:
    let
      pv = parse v;
      pc = parse constraint;
      n = builtins.length pc.core;
      m = builtins.length pv.core;
    in
    if m >= n then
      let
        c = compareCore (lib.take n pv.core) pc.core;
      in
      if c != 0 then
        c
      else if m > n then
        0
      else
        comparePre pv.pre pc.pre
    else
      let
        c = compareCore pv.core (lib.take m pc.core);
      in
      if c != 0 then c else null;

  # Return true or false, or null when `v` is less precise than `constraint`
  # and matches its prefix.
  atLeast =
    v: constraint:
    let
      c = compareAtPrecision v constraint;
    in
    if c == null then null else c >= 0;

  atMost =
    v: constraint:
    let
      c = compareAtPrecision v constraint;
    in
    if c == null then null else c <= 0;
in
{
  inherit
    prereleaseTags
    isVersion
    tryParse
    parse
    ofTag
    retag
    bare
    minorOf
    compare
    atLeast
    atMost
    ;
}
