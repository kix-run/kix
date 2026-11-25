+++
kind = "fixed"
state = true
+++
`kix deploy --operator` and `kix rollback --operator` now print a deploy that stopped at a failed object as `✗ Wave 1: Failed (0/1 applied, 1 failed)`. Previously, they printed `✓ Wave 1: Complete (0/1 applied, 1 failed)`. The last entry in `status.waves` on the Activation record now says `Failed` when any object failed, and older versions of Kix read that value too.
