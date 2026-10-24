# 2026-10-24 · `cli/kix-cli/src/commands/pin.rs` · `kix pin` cannot remove a pin, so returning to a package default is a hand edit of JSON.

With instance pins, deleting an entry is how a cluster goes back to the package's default image. `kix pin set` adds and moves entries, but there is no `kix pin rm`, so a person or an agent edits `pins.json` by hand and must keep the canonical form, including writing `version: 1` again when the last instance pin goes. `PinFile::remove` already does both.
