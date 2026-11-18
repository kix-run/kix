+++
kind = "changed"
packages = ["experimental/cloudflared"]
+++
`cloudflared` now runs cloudflared 2026.11.1 instead of 2026.9.3. The new version takes the same flags and token, so you do not need to change anything. The first deploy after you upgrade replaces each connector pod once. The metrics port now serves only an allowlist of debug endpoints: `/debug/vars` no longer lists the command line, and `/debug/requests` and `/debug/events` are gone. The release also adds `--disable-path-normalization`, which is on by default. When you turn it off, cloudflared normalizes request paths before it matches ingress rules that require Cloudflare Access. To go back, set `image.tag` and `image.digest` to the 2026.9.3 image, or deploy the previous Kix version.
