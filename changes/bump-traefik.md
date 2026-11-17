+++
kind = "silent"
packages = ["experimental/traefik"]
+++
`traefik` now runs Traefik v3.7.17, up from v3.7.13. Two Traefik changes can alter a result without an error. First, a request with more than 500 header values now gets `431 Request Header Fields Too Large`. To allow more, add `--entryPoints.<name>.http.maxHeaderValueCount=<n>` to `extraArgs`. Second, a backend Service that serves HTTPS on port 443, or on a port named `https`, now gets plain HTTP unless its port sets `appProtocol: https` or a `BackendTLSPolicy` targets the Service. Set one of them on each such backend. The release also fixes security issues in Traefik 3.7.14 through 3.7.17.
