# 2026-11-12 · `kix/lib/eval/resolve.nix` · Setting `package = ./my-package` (a path, not `import ./my-package`) fails with "attempt to call something which is not a function but a path".

The error points at `resolve.nix:549` inside Kix. Kix could import the path or say to.
