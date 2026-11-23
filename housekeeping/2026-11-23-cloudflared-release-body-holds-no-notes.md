# 2026-11-23 · `bump` agents · A GitHub release body can hold only checksums, so the notes must come from the repo.

The cloudflared 2026.11.2 release body is a list of SHA256 checksums and no notes. Its changes are in `RELEASE_NOTES` at the tag (raw file via `raw.githubusercontent.com`), and in the compare API between the two tags. The bump skill's "read the notes" step names neither, so an agent can conclude that there are none. Say where the notes live when the release body is empty.
