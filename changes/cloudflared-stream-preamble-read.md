+++
kind = "fixed"
packages = ["experimental/cloudflared"]
+++
A tunnel stream whose first bytes arrive in separate frames could fail to parse, because the connector read the two-byte protocol version with one read that could return fewer bytes. The connector now reads the whole version, and `cloudflared` 2026.11.2 carries that fix.
