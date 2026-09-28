# 2026-09-27 · kix-examples `how-to/platform/cloudflare-tunnel-cluster.nix` · The example sets the cloudflared image as a string, which fails once kix-examples moves to a kixpkgs where the option takes an image record.

`kix/packages/cloudflared` now declares `image = kix.options.image { ... }`,
so the example's `image = "cloudflare/cloudflared:2026.9.0"` (line 30) no
longer type-checks against current kixpkgs. The docs site still builds,
because it shows that file as a snippet and does not evaluate it here.
The example needs
`image = { repository = "cloudflare/cloudflared"; tag = "2026.9.0"; };`
in the same change that bumps its kixpkgs pin.
