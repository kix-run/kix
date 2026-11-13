+++
kind = "fixed"
+++
`kix upgrade --to` with an older version than the project is on now stops with an error that says how to go back. It printed "Already on Kix 0.10.0-rc.3 (matches target 0.10.0-rc.2)" and exited `0`. When flake.nix asks for an older Kix than flake.lock pins, the error no longer tells you to run `kix upgrade`. It says how to stay on the version in flake.lock or go back to the older one. When `kix upgrade` sets a moved tag in flake.nix back, a Git url keeps the ref exactly as flake.lock records it, so the lock still matches flake.nix.
