# 2026-11-12 · `kix self install` · `kix self install <version>` does not say that `kix` on PATH still runs the old version.

After `kix self install 0.10.0-rc.2`, it prints "Installed Kix 0.10.0-rc.2" and `kix --version` still says 0.8.0. A project with `kix = "0.10.0-rc.2"` in kix.toml runs the new one, so this works as designed, but the output does not say so or name `kix self update`.
