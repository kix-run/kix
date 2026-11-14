+++
kind = "fixed"
cli = ["kix upgrade"]
+++
`kix upgrade` without `--to` now resumes a stopped upgrade toward the version the first run asked for. Before, it went to the latest release instead, so an upgrade to a release candidate that stopped for a fix moved the project back to the latest stable release and reported it as upgraded. A resumed upgrade also refuses a target older than the version the project is pinned to now. `kix-upgrade.json` gains the field `requested`.
