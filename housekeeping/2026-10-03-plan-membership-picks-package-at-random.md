# 2026-10-03 · `cli/kix/src/plan/server.rs` · `membership` files an object listed by several packages under whichever package comes last.

The build's packages are a HashMap, so for an import marker that several
packages list, the overlay's entry is chosen in no fixed order. It can clear
the build comparison's entry in one package and add the server's answer to
another, so the object shows twice or in a different package from run to run.
