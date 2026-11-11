# 2026-11-11 · `cli/kix/src/plan/baseline.rs` · Soft `kix gc` warns that the cached build is not the Active build, even though it then uses the Active build.

`active_build_dir_with` logs a warning whenever this machine's cached build for
the cluster differs from the Active record, then loads the Active record's
build. After switching contexts this is the normal case, so the warning is
noise unless the Active build also cannot be found.
