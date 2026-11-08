# 2026-11-08 · `.github/workflows/pages.yml` · A docs page that fails to build at the newest release tag blocks every site deploy.

The deploy rebuilds the docs at the newest release tag, and release tags never change. When `reference/kix-toml.mdx` failed to build at v0.7.0, every deploy failed until a new release went out, including changes to the landing page that had nothing to do with the docs. No check stops a release whose docs do not build. Deploys failed from 7 Nov 2026 until 0.7.1.
