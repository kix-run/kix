+++
kind = "fixed"
+++
`kix deploy --operator` and `kix rollback --operator` now finish as soon as the Kix operator completes a deploy that succeeded on a retry. Before, they waited the full 600 seconds and then timed out. A deploy that stalls in the operator now stops only that deploy. Before, it also cancelled every later deploy until the operator restarted.
