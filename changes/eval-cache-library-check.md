+++
kind = "fixed"
+++
Kix checks that it can build a project's Kix library on every run. Before, a build that came from Kix's local cache skipped the check, so Kix 0.10 could build a project still pinned to the Kix library 0.9 if Kix 0.9 had built it first.
