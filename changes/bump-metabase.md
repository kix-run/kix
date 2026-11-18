+++
kind = "silent"
packages = ["experimental/metabase"]
touches-data = true
+++
`metabase` runs Metabase 0.65.5 instead of 0.63.19. The first deploy stops the running pods, and the new version migrates the application database when it starts. Metabase is unavailable until the migration finishes. Upstream changed some behavior in 0.64 and 0.65 without an error. Metabot now sends query results to the AI provider by default; turn this off in Admin > AI > Metabot settings. Only admins can create actions, and users with row or column security can no longer run them. Metabase now ignores `MB_LLM_MAX_TOKENS` and the `MB_METABOT_*` prompt and limit variables if you set them through `env`, so move those settings to the admin settings. Custom visualizations built with version 1 of the custom visualization SDK may stop working. Read upstream's changelogs for 64 and 65 before you upgrade. Back up the application database first. Going back with `kix rollback` alone leaves the pods failing with "Downgrade detected". To go back, run the 0.65.5 image once with the argument `migrate down` against the same database, then deploy the previous Kix release, or restore the backup.
