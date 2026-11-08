# 2026-11-08 · `.github/workflows/cli-tests.yml` · The `test` job loses its self-hosted runner partway through.

On 8 Nov 2026 the `test` job failed this way twice in a row, on PR #334 and then on the merge of that PR to main. Each time the job has no failed step and no log. The only message is "The self-hosted runner lost communication with the server". A rerun gets past it, but a release waits for the `test` job, so each drop delays the release by a full run. The job may be starving the runner of memory or CPU.

Later the same day, on the merge of the 0.8.0-rc.1 release, the Tests step of the same job hung for over 15 minutes, against under 5 minutes for a normal run. The run did not stop on a plain cancel and needed a force-cancel through the API. The job has no timeout, so a hang holds the release until someone notices.
