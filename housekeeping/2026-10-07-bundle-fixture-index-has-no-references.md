# 2026-10-07 · `cli/kix/tests/fixtures/bundles/kix-enterprise-test.kixbundle` · The fixture's `kix-packages.json` lists paths but references none of them.

Current kix/lib gives the index the string context of every path it lists,
so a real build's index references them. The fixture was written before
that, so tests that edit it must follow the index's text as well as its
references (`set_file` in `eval/bundle.rs` tests does). Regenerating it
from a current stage1 build changes the fixture's paths and the tests that
name them.
