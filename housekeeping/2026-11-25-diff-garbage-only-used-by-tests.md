# 2026-11-25 · `cli/kix/src/plan/diff.rs` · `diff_garbage` is used only by tests now that soft `kix gc` does not compare two builds.

Soft `kix gc` used to diff the Active build with the build from the current
files and printed the result through `diff_garbage` and `print_package_plan`.
It now lists the objects of the kept builds that the Active build lacks, as a
flat list. `diff_garbage` remains public and only the tests in
`cli/kix-cli/src/plan/mod.rs` call it. Either remove it, or group the soft gc
listing by package again with a function that takes kept closures.
