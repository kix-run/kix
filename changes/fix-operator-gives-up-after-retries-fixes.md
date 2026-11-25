+++
kind = "fixed"
+++
`kix deploy --operator` and `kix rollback --operator` now finish as soon as the Kix operator completes a deploy after a retry or a restart. Previously, both commands waited the full 600 seconds and timed out. When a deploy stalls, the operator now cancels only that deploy. Previously, a stalled deploy also cancelled every later deploy until the operator restarted.
