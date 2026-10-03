# 2026-10-03 · `cli/kix-cli/src/plan/saved.rs` · `kix deploy --plan` does not compare which rerun Jobs the deploy would run again.

A rerun Job (`kix.run/rerun: on-change`) whose last run failed is deleted and
created again by the deploy, even when the build is unchanged. Whether that
happens depends on live state, and no comparison rule covers it, so a
deploy from a reviewed plan can rerun a probe Job the review did not show.
