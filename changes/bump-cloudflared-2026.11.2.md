+++
kind = "note"
packages = ["experimental/cloudflared"]
+++
`cloudflared` now runs cloudflared 2026.11.2 instead of 2026.11.1. Nothing in your configuration changes. The first deploy after you upgrade replaces each connector pod once. To go back, set `image.tag` and `image.digest` to the 2026.11.1 image, or deploy the previous Kix version.
