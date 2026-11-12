+++
kind = "error"
packages = ["harbor", "experimental/immich", "experimental/n8n", "valkey"]
library = ["kix.contracts.redis"]
id = "K9191"
+++
`harbor`, `immich`, and `n8n` take their Redis server as the dependency `redis`.
It was `valkey`. A `valkey` package instance still answers it under any name.
A `kix.mkImport` that these packages found because the instance was named
`valkey` is no longer found: rename the instance to `redis`, or give it
`aliases = [ "redis" ]`. Change `deps.valkey` on a `harbor`, `immich`, or `n8n`
instance to `deps.redis`. A package of your own that reads the Redis contract
names its build argument `redis`.
