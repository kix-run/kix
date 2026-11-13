# 2026-11-13 · `kix/packages/*` · Every Job that reruns sets `kix.run/rerun = on-change` itself.

Ten packages and `kix/lib/vocab/health-check.nix` write `annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange`, and check 16 in `kix/lib/eval/validate.nix` (line 742) allows no other value. The library already adds the rerun hash (`kix/lib/core/resource.nix:470`). `scope.mkJob` could set the annotation as well, through a builder argument or by default, so a package cannot forget it.
