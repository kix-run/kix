+++
kind = "silent"
cli = ["kix status --output json", "kix status --output yaml"]
+++
In `kix status -o json` and `-o yaml`, the field `resources[].identity_hash` is now `resources[].hash`. Kix no longer writes `kix.run/identity-hash` on objects, so the field holds the hash that the deploy record gives the object: for a deploy by this version of Kix, a hash of the manifest Kix sends for it, and for a deploy by an earlier version, its identity hash as before. Update scripts that read `identity_hash` from `resources[]`. The deploy record's own `identity_hash` keeps its name.
