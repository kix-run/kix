# 2026-10-18 · `kix deploy` · Switching a live Deployment from RollingUpdate to Recreate fails the apply.

The apiserver keeps the defaulted `spec.strategy.rollingUpdate` fields, so the server-side apply of `type: Recreate` is rejected with "may not be specified when strategy `type` is 'Recreate'". Hit on ludo when immich moved to Recreate; worked around with a `kubectl patch` removing `rollingUpdate` before the deploy. The preview only reports "invalid" with no reason, see `kix plan` output.
