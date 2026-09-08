# Annotation keys and values that Kix itself stamps and that more than one
# module reads. A key spelled in one helper and one checker drifts; a key
# spelled here does not.
{
  # A Job carrying this is never patched by the deploy engine: a changed
  # one is deleted and created again, and under `kix deploy` and
  # `kix rollback` so is an unchanged one whose last run failed. Stamped by
  # `kix.healthCheck`; check 16 refuses it on any other kind and any other
  # value. The engine's side is `RERUN_ANNOTATION` in `cli/kix/src/cluster/apply.rs`.
  rerun = {
    key = "kix.dev/rerun";
    onChange = "on-change";
  };
}
