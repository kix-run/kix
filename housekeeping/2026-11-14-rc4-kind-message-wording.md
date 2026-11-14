# 2026-11-14 · CLI messages · Small wording problems found testing 0.10.0-rc.4 on kind.

- The plan shows a version change `cert-manager v1.21.2 -> 1.21.2`, which is
  only the dropped "v". The line is accurate: the PackageInstance record held
  `v1.21.2`, and 0.10 records `1.21.2`. It shows once per instance, on the
  first deploy after the upgrade. Hiding it would need a Rust copy of the
  rule `kix.image.version` applies in Nix, so two places would own what a
  version is. Options: (a) leave it, and name it in the 0.10 upgrade note
  on versions; (b) compare versions in Rust with a `v` stripped, a second
  copy of the rule; (c) have the library write the version it read from the
  image and the one it shows, so the plan compares one field. Recommended:
  (a), since the change ends after one deploy.
