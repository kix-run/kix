# 2026-11-12 · `cli/kix-cli/src/plan/render.rs` · `kix plan`'s drift line shows the same opening text for the live and the built value.

It printed `data.default.conf: "server {"… (214 bytes) live, "server {"… (218 bytes) in deployed build`. Both start the same way, so the line shows only that the lengths differ, not what changed.
