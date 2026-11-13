+++
kind = "fixed"
+++
Kix checks a project's Kix library against its own version on every run. Before, a build that came from Kix's local cache skipped the check, so Kix 0.10 could build a project still pinned to the Kix library 0.9 if Kix 0.9 had built it first.
