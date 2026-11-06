# 2026-11-06 · `cli/runtime/runtime.nix` · THIRD_PARTY_LICENSES gives some download addresses as nixpkgs `mirror://` URLs.

runtime.nix copies the first URL of each nixpkgs source, and for GNU,
Savannah, SourceForge, and GNOME packages that is a `mirror://` URL. A
reader outside Nix cannot open it. The hash beside it still identifies
the file.
