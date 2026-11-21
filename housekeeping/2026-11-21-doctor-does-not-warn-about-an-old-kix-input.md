# 2026-11-21 · `cli/kix-cli` · `kix doctor` does not warn when an input falls far behind `kix`.

A project with a `[versions]` table can leave an input such as `kix-stable`
on an old release for a long time. Kix reads the cluster state of releases
from the last six months or the previous minor release, and
`kix upgrade <cluster>` refuses a move that skips a required stop.
`kix doctor` lists each input and its version
(`check_versions` in `cli/kix-cli/src/commands/doctor.rs`) but says nothing
when an input is more than one minor release behind `kix`.

A fix would add a warning to that check, naming the input, how far behind
it is, and `kix upgrade <input>`.

Found by a review of kix#288 on 21 November 2026.
