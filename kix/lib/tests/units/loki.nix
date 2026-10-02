# Tests for the kix/lib behaviour the loki rework relies on: kix.mergeGuarded
# refuses an override that replaces an ancestor of a locked path.

{
  kixlib,
  ...
}:

let
  merge = kixlib.mergeGuarded {
    who = "test ns/inst";
    what = "settings";
    locked = [
      [
        "a"
        "b"
      ]
    ];
  } { a.b = "locked"; };

  fails = overrides: !(builtins.tryEval (builtins.deepSeq (merge overrides) true)).success;
in
{
  # `{ a = null; }`, `{ a = 1; }` and `{ a.b = …; }` each replace the locked
  # `a.b` and throw; `{ a.c = 1; }` leaves it in place and merges.
  loki-mergeGuarded-null-ancestor =
    let
      sibling = merge { a.c = 1; };
    in
    (
      fails { a = null; }
      && fails { a = 1; }
      && fails { a.b = "other"; }
      &&
        sibling == {
          a = {
            b = "locked";
            c = 1;
          };
        }
    )
    || throw "mergeGuarded ancestors: a = null ${
      if fails { a = null; } then "throws" else "passes"
    }, a = 1 ${
      if fails { a = 1; } then "throws" else "passes"
    }, a.c = 1 gives ${builtins.toJSON sibling}";
}
