# 2026-10-02 · `kix/lib/scope/default.nix` `forNamespace` · The missing-namespace error does not name the instance that asked for the namespace.

`scope.forNamespace "nope"` throws `scope.forNamespace: namespace 'nope' does not exist in the cluster`. A package that derives the namespace from user input, such as reloader's `extraArgs = [ "--namespaces=nope" ]`, cannot add its own `who` prefix, because the scope exposes no way to ask whether a namespace exists before calling it. The user then has to find which instance and which option named the namespace.
