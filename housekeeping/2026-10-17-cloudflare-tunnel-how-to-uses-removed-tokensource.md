# 2026-10-17 · `docs/src/content/docs/how-to/platform-capabilities/expose-a-service-through-cloudflare-tunnel.mdx`, kix-examples `how-to/platform/cloudflare-tunnel-cluster.nix` · The Cloudflare tunnel how-to and its example cluster set `tokenSource`, an option cloudflared no longer has.

cloudflared takes the token as a `tunnelToken` secret dependency since
2026-10-17 (`kix/packages/cloudflared/default.nix` header). The how-to's
prose says "`tokenSource` must point to a SOPS file", and its code snippet is
generated from the kix-examples repository
(`docs/src/snippets/how-to/platform/cloudflare-tunnel-cluster/cloudflaredInstance.json`),
so the example cluster there fails to evaluate against this kixpkgs and the
page shows an option that does not exist. Fix in kix-examples first (a
`packages.secret` instance aliased `tunnelToken` with `source`), then
regenerate the snippets and reword the prose.
