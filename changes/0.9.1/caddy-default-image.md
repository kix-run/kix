+++
kind = "fixed"
packages = ["caddy"]
+++
`caddy` defaults to the official Caddy image, `caddy:2.10.0`. Before, it pointed at a private registry nobody else could pull. A Caddyfile that uses plugins needs `image` set to a build that has them.
