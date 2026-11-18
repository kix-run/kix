# 2026-11-18 · `clusters/test-arc.nix` · The arc and arc runner set test cannot pass without real GitHub credentials.

The controller must register the scale set with GitHub before the AutoscalingRunnerSet reaches phase `Running`, so `kix deploy arc-runner-set` on kind always stops at that object with "hard ceiling 300s exceeded" and a 401 from api.github.com in the controller log. No listener or runner pod ever starts, so a runner bump is never tested running a job. The repository has no test organization or GitHub App whose credentials a test could use.
