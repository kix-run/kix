+++
kind = "silent"
cli = ["kix status --output json", "kix status --output yaml"]
+++
Update scripts that read `kix status -o json` or `-o yaml` to read `resources[].hash` instead of `resources[].identity_hash` (`deploy.identity_hash` and `failed_deploy.identity_hash` keep their names). Because Kix no longer writes `kix.run/identity-hash` onto deployed objects, `resources[].hash` holds the hash recorded for the object in the deployment record: a hash of the sent manifest for deploys made by this version of Kix, or the build identity hash for deploys made by earlier versions.
