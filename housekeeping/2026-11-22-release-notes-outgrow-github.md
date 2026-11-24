# 2026-11-22 · `.github/workflows/cli-tests.yml` · The release notes of a release candidate list every change since the last release.

The notes of a prerelease are written from every unreleased change record.
For 0.10.0-rc.6 that was 209 records and about 129,000 characters. GitHub
refuses release notes over 125,000, so the publish job failed. The job now
cuts the notes at whole lines and points at the attached change records.

A reader of a release candidate wants what changed since the candidate
before it. The notes could list only the records added since the previous
tag, and keep the full list for the release itself. The release of 0.10.0
will still be over the limit, so the cut stays either way.

Found while publishing Kix 0.10.0-rc.6 on 22 November 2026.
