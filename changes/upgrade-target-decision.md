+++
kind = "fixed"
cli = ["kix upgrade"]
+++
To resume a stopped upgrade started with Kix 0.10.0-rc.4 or earlier, run `kix upgrade --to <version>` or `kix upgrade --to latest`. Those versions did not save the requested target in `kix-upgrade.json`, so resuming without `--to` defaulted to the latest stable release and could downgrade the project. `kix upgrade` now stops without changing project files and asks for `--to`.
