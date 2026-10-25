# 2026-10-22 · `kix/lib/eval/instance.nix` · A `deps.<arg>` value bound as it is and holding a list of instance handles adds no dependency links, while a single handle does.

`directDepLinks` reads `_meta` only from attrset values of `instCfg.deps`.
A list of handles (not refs) is skipped, so the annotation-domain check
does not see the operators those instances declare. A list of refs is
not affected: it resolves through `resolvedDepMeta`.
