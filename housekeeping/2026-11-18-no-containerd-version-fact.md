# 2026-11-18 · `kix/lib/modules.nix` · `cluster.containerd` has no version, so Kix cannot refuse nodes whose containerd a package does not support.

Spegel 0.8 needs containerd 2.2 or later, and its registry container exits at start on an older one. The spegel package can only say so in its header and change record, because `cluster.containerd` records paths and `discardUnpackedLayers` but not the version. The flavours know the version their node images ship, as they know the paths.
