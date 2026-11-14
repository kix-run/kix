# 2026-11-14 · `.github/workflows/cli-tests.yml` · The jobs that test the release archive run only on a release pull request, so a change that breaks them is found when the release is cut.

The `nix-builder` job runs `cli/runtime/nix-builder.sh` against the built
archive only when `build` is true, which a pull request gets only when it
changes the workspace version. The change that made Kix refuse a project
with no `flake.lock` passed every check on its own pull request, and the
script's test project, which had no `flake.lock`, failed first on the
0.10.0-rc.4 release pull request. The release then waited on a fix.

Options:

1. Run `nix-builder.sh` on any pull request that changes `cli/` or `kix/`,
   with a debug archive built the way `runtime` builds one. It costs one
   archive build per such pull request.
2. Run the release jobs nightly on main with `workflow_dispatch`, and open an
   issue when they fail. It is cheap, but a break still lands on main first.
3. Keep it as it is, and run the release jobs by hand
   (`gh workflow run cli-tests.yml -f rehearse=...`) before a release.

Option 2 looks like the best trade, since breaks here are rare.
