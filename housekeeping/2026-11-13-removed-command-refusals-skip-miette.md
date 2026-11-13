# 2026-11-13 · `cli/kix-cli/src/removed.rs` · Refusals of removed commands and flags print in a different style from other refusals.

A removed command or flag prints a plain `error: [K6116] ...` line. A refused output format prints a miette block with a `help:` line. Both tell the user to change what they typed, so they should look the same. Pick one renderer for both.
