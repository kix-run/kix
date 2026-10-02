# 2026-10-02 · `kix/packages/harbor` · Kix cannot check the length of a value inside a dependency's Secret.

Harbor needs `secretKey` to be exactly 16 characters and `csrfKey` exactly 32. A `harborSecrets` dependency publishes only its key names, and a SOPS value is not readable at evaluation, so a wrong length passes the build and shows up only when Harbor uses the key. The package header gives the `openssl` commands instead.
