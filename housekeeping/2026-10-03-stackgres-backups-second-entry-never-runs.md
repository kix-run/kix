# 2026-10-03 · `kix/packages/stackgres-cluster` · The `backups` option accepts a list, but StackGres only schedules the first entry.

StackGres creates one backup CronJob, from the first entry of `spec.configurations.backups`, and ignores the rest. This was seen with StackGres 1.19 in PR #175. The option's description does not say so, so a cluster that lists a daily and a weekly schedule only ever gets the daily one, and nothing warns.
