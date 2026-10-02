# 2026-10-02 · `kix/lib/eval/validate.nix` · An Ingress's `spec.ingressClassName` is not checked against the IngressClasses in the build.

An Ingress that names a class nothing creates or imports builds and deploys, and then no controller serves it. Cross-resource check 20 resolves StorageClass names on claims; nothing does the same for `ingressClassName`, or for a tailscale `ProxyClass` name. A check like 20 (an IngressClass in the build or an import marker of kind IngressClass) would close it.
