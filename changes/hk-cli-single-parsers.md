+++
kind = "fixed"
+++
A field listed in `kix.run/cede-fields` is now handed over when the conflict is under a list item that two keys pick, such as a Service port picked by `port` and `protocol`. Before, `kix deploy` stopped on that conflict. Kix also now says that it found no project when it runs in a folder with no `flake.nix`, in that folder or any folder above it, and asks you to change into the project's folder or pass `--flake <path>`. Before, it printed the error from Nix.
