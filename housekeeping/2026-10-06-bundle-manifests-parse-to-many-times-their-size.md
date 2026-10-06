# 2026-10-06 · `cli/kix/src/eval/bundle.rs` · A bundle's manifests still parse into many times their size in memory.

`Bundle::read` caps each manifest at 3 MiB (`MAX_MANIFEST_BYTES`) and the uncompressed bundle at 64 MiB, but `check_build` and `Bundle::graph` parse manifests into `serde_json::Value`, which takes 10 to 30 times the JSON's size for text such as `[[],[],...]`. `graph()` keeps every manifest parsed at once, so a bundle of a few KB compressed can still cost a GiB or more. `kix-packages.json` has no size cap of its own and parses the same way.
