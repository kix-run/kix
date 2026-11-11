# 2026-11-11 · `kix/lib` · Nothing stops `throw "a" + "b"`, which prints only "a".

Nix parses `throw "first part " + "rest"` as `(throw "first part ") + "rest"`, so the error ends after the first string. Seventeen library errors had this shape, among them the untracked-reference error, which printed `[gateway] Untracked configMap reference in volumes[].configMap.name: ` with the name and the fix cut off. They now wrap the whole message in parentheses, but no lint or test catches a new one.
