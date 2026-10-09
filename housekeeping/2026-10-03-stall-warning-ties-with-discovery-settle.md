# 2026-10-03 · `cli/kix/src/cluster/watchdog.rs` · The watchdog's stall warning fires at the same 30 s as `DISCOVERY_SETTLE`.

`StallPolicy::default().warn_after` is 30 s and `discovery::DISCOVERY_SETTLE` is 30 s, so a rediscovery that waits out the whole settle window prints a stall warning before `FetchError::DiscoveryUnsettled` names the group version. With `KIX_STALL_TIMEOUT` at 30 or less the watchdog cancels the run first, and the unsettled group version is never shown.
