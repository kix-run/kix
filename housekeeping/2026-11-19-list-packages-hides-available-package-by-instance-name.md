# 2026-11-19 · `kix list packages` · An available package is hidden when any instance has its name, whatever that instance runs.

`run_packages` in `cli/kix-cli/src/commands/list.rs` skips an `available` row when an instance shares the entry's name. An instance called `valkey` that runs a project's own package hides the `valkey` entry of `availablePackages`. Both rows now carry a package id, so the rows could be compared by what they run.
