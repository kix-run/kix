# 2026-11-13 · `cli/kix-core/src/pin_library.rs` · Two evaluations read the Kix library's version, each in its own way.

`pin_library::eval_version` (line 502) and `eval::nix::library_facts` (line 509) each build the attribute path to `kixLibrary.version` and each turn a missing version into `LibraryVersion::Older`. A change to where the library keeps its version must be made twice, and the two can drift apart. One function, such as `eval::nix::library_version`, could serve both, with `pin_library::Plan::check` calling it.
