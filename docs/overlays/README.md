# overlays/

Per-tutorial overlays that the docs captures pipeline lays on top of a
writable copy of `kix-examples/` before running commands. An overlay
is just a directory whose layout mirrors `kix-examples/` — files in
it land at the same relative path in the workspace.

Use an overlay for:

- **Adding new files** that don't exist in `kix-examples/` (e.g.
  `tutorial-04/cluster.nix`, the finished version of a "build it
  yourself" tutorial cluster).

If the captures pipeline also needs to **modify** an existing file
(e.g. add an entry to `kix-examples/flake.nix`), express that as a
`mutate` step in `docs/nix/captures.nix` rather than checking in a
patched copy. That way the overlay stays minimal and the patch is
anchored on a string literal that fails loudly if the upstream file
drifts.

## Convention

```
overlays/
  04-from-scratch/                  # one overlay per group that needs one
    tutorial-04/
      cluster.nix
```

A manifest group selects an overlay via `overlay = ../overlays/04-from-scratch;`.
The pipeline `cp -r overlay/. $workspace/`, then runs the group's
`setup` mutations, then the captures.

## Spoiler protection

These overlays are NOT exposed in the public `kix-examples` flake. A
reader cloning kix-examples and running `kix list clusters` doesn't
see them. The docs pipeline opts in by overlaying at capture time.
