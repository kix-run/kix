# 2026-10-02 · `kix/packages/cloudflared` · cloudflared fails five items of the package checklist.

- `replicas` is `types.int` (`default.nix:66`) and accepts 0 or a negative number; the convention is `ints.positive`.
- The `replicas` description cites `discussions/145`, which a public reader cannot see.
- The image `repository = "cloudflare/cloudflared"` has no registry host (`docker.io/`).
- `meta.lifecycle = "stateless"` restates the default.
- The package declares no world-egress intent for the tunnel connection, so the connector cannot reach Cloudflare under a default-deny network policy.

The token taken as a string option is its own entry, `2026-10-01-cloudflared-takes-tunnel-token-as-option.md`.
