+++
kind = "fixed"
+++
Kix checks that it can build a project's Kix library on every run. Before, a build that came from Kix's local cache skipped the check, so a newer Kix could build a project still pinned to an older library, for example Kix 0.10 with a 0.9 library, if an older Kix had built it first.
