# 2026-11-04 · `cli/kix-cli/tests/deploy_test.rs` · `deploy_reads_the_cache_under_the_cluster_name_not_the_attribute` fails on macOS.

The test points `XDG_CACHE_HOME` at a temporary directory and writes the cached build there. On macOS, `eval::store::default_cache_dir` uses `directories::ProjectDirs`, which reads `~/Library/Caches` and ignores `XDG_CACHE_HOME`. So `kix deploy minimal --dry-run` finds no cached build, prints "No previous activation. First deploy.", and exits 2. Seen on main at 9f35d2a4.
