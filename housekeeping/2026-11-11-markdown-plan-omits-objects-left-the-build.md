# 2026-11-11 · `cli/kix-cli/src/plan/mod.rs` · The Markdown plan posted in pull requests does not list objects that left the build and stay running.

The terminal plan prints "N object(s) left the build, still running on the
cluster" with the command that deletes them. `render_package_diff_markdown`
and `render::render_markdown` have no such section, so a reviewer reading the
pull-request comment cannot see that a removed resource keeps running. The
deploy's prune lines (`commands/deploy/observer.rs`, `deploy_log.rs`) also
name `kix gc` without the cluster, because the cluster name does not reach
them.
