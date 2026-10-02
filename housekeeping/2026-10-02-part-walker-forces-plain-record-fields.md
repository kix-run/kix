# 2026-10-02 · `kix/lib/eval/helpers.nix` · `collectTypedAttrs` forces every field of a plain record part up to depth 3.

A part that is a plain attrset (not a resource) has each value evaluated by
the walker, which tests `v == null` and `builtins.isAttrs v`. A field that
throws on purpose, such as `exposure.url` without a route, fails every
build of the instance even when nothing reads it. `kix.expose` works around
it by giving the record `_type = "kix-exposure"`, which stops the walker;
any other record part with a lazy error needs the same trick.
