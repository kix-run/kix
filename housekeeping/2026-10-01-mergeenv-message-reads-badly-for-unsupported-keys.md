# 2026-10-01 · `kix/lib/vocab/compose.nix` · `kix.mergeEnv` words every refusal as "which comes from …", which fits a variable the package sets but not one it refuses outright.

An `owned` group with only `names` is how a package refuses a variable it does not support (tailscale's `CLIENT_ID`, `APISERVER_PROXY`). The message is fixed as "env sets X, which comes from <from>. <fix>", so the package has to phrase "not supported" as a source ("which comes from the oauthCredentials dependency in this package; CLIENT_ID selects …"). A separate wording for unsupported names would read plainly.
