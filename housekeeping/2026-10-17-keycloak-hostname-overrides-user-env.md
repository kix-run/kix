# 2026-10-17 · `kix/packages/keycloak/default.nix` · `KC_HOSTNAME` silently overrides a user's `env.KC_HOSTNAME` instead of refusing it.

Lines 340-347 merge `{ KC_HOSTNAME = hostname; }` with `//` after `kix.mergeEnv`, outside the owned groups. A user who sets `env.KC_HOSTNAME` gets no error, and the value is dropped. Every other variable the package sets is an owned group (package-review E8).
