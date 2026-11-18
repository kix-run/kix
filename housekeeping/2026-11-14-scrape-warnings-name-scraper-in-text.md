# 2026-11-14 · `kix/lib/plugins/netpol/scrape.nix` · Scrape policy warnings name the scraper at the start of their text, not in the `object` field.

The warnings `scrape.derive` returns start with `who`, such as `ServiceMonitor monitoring/prometheus: another ingress policy ...`, and reach `kix-warnings.json` as records with only a `message`. A tool cannot group them by object or instance. They can set `object` to the scraper and `instance` to the instance that built it.
