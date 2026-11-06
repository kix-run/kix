#!/usr/bin/env python3
"""Assemble a Kix runtime directory from the spec that runtime.nix builds.

Usage: assemble.py <kix-runtime-spec.json> <out-dir>

<out-dir> becomes libexec/kix/ in a release archive. It holds one directory
per program, named <name>-<version>, the THIRD_PARTY_LICENSES file, and
manifest.json, the index Kix reads:

  {
    "manifestVersion": 1,
    "system": "aarch64-darwin",
    "programs": [
      {
        "name": "nix", "version": "2.31.3",
        "bin": { "nix": "nix-2.31.3/bin/nix", "nix-store": "nix-2.31.3/bin/nix-store" },
        "files": {
          "nix-2.31.3/bin/nix": { "sha256": "<hex>" },
          "nix-2.31.3/bin/nix-store": { "symlink": "nix" },
          "nix-2.31.3/lib/libnixutil.dylib": { "sha256": "<hex>" }
        }
      }
    ]
  }

Every path is relative to <out-dir>. `kix doctor` checks each file against
its hash.

A program the spec marks `relocate` is a dynamically linked macOS build. Its
executables are copied with every library they load from /nix/store, into
the program's own lib/ directory, and each load command is rewritten to
@loader_path. The libraries come only from packages runtime.nix lists for
that program, so THIRD_PARTY_LICENSES covers each of them. Relocation runs
only on macOS and needs the command line tools (otool, install_name_tool,
codesign).
"""

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys

MANIFEST_VERSION = 1


def copy_program(program, out):
    """Copy a program's files into out/<name>-<version>.

    Return the directory name and a map from each copied file to the store
    file it came from.
    """
    dirname = f"{program['name']}-{program['version']}"
    root = os.path.join(out, dirname)
    origins = {}
    for rel, src in sorted(program["files"].items()):
        real = os.path.realpath(src)
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(real, dst)
        # Upstream binaries arrive as plain downloads without the executable
        # bit, so everything in bin/ gets it.
        executable = rel.startswith("bin/") or os.stat(real).st_mode & stat.S_IXUSR
        os.chmod(dst, 0o755 if executable else 0o644)
        origins[dst] = real
    for rel, target in sorted(program.get("links", {}).items()):
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.symlink(target, dst)
    return dirname, origins


# --- macOS relocation ----------------------------------------------------


def otool(*args):
    return subprocess.run(
        ["otool", *args], check=True, capture_output=True, text=True
    ).stdout


def install_name(path):
    lines = otool("-D", path).strip().splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def load_commands(path):
    """Return the libraries `path` loads, without its own install name."""
    own = install_name(path)
    deps = []
    for line in otool("-L", path).splitlines()[1:]:
        dep = line.strip().split(" (compatibility")[0]
        if dep and dep != own:
            deps.append(dep)
    return deps


def rpaths(path):
    lines = otool("-l", path).splitlines()
    return [
        lines[i + 2].split()[1]
        for i, line in enumerate(lines)
        if "cmd LC_RPATH" in line
    ]


# Libraries every Mac ships in /usr/lib, which the bundle loads from there
# instead of shipping the copy from nixpkgs. runtime.nix lists the same
# packages under systemLibraries.
SYSTEM_LIBRARIES = {
    "libresolv.9.dylib": "/usr/lib/libresolv.9.dylib",
}


def system_substitute(real):
    """Return the macOS system library to load instead of store file `real`, or None.

    Nixpkgs' darwin libiconv is Apple's libiconv. It loads its converter
    modules from a lib/i18n path compiled into the library, which would point
    into /nix/store after relocation. Every Mac ships the same library as
    /usr/lib/libiconv.2.dylib, so the bundle loads that instead. GNU
    libiconv, which has no lib/i18n, ships in the bundle.
    """
    name = os.path.basename(real)
    package = store_package(real)
    if name == "libiconv.2.dylib" and os.path.isdir(
        os.path.join(package, "lib", "i18n")
    ):
        return "/usr/lib/libiconv.2.dylib"
    return SYSTEM_LIBRARIES.get(name)


def store_package(real):
    """Return the /nix/store/<hash>-<name> directory that holds `real`."""
    return "/".join(real.split("/")[:4])


def resolve(dep, image):
    """Return the store file a load command in `image` names, or None for a system library."""
    here = os.path.dirname(image)
    if dep.startswith("@rpath/"):
        for rp in rpaths(image):
            rp = rp.replace("@loader_path", here).replace("@executable_path", here)
            candidate = os.path.join(rp, dep[len("@rpath/") :])
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        # An @rpath dependency of a store library normally sits beside it.
        candidate = os.path.join(here, dep[len("@rpath/") :])
        if os.path.exists(candidate):
            return os.path.realpath(candidate)
        sys.exit(f"cannot resolve {dep} from {image}")
    if dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(here, dep[len("@loader_path/") :]))
    if dep.startswith("@"):
        sys.exit(f"unhandled load command {dep} in {image}")
    if dep.startswith("/nix/"):
        return os.path.realpath(dep)
    return None


def relocate(root, origins, allowed_packages):
    """Bundle every store library the executables in `origins` load into root/lib.

    `origins` maps each copied executable to the store file it came from.
    """
    if sys.platform != "darwin":
        sys.exit(
            "relocating a program needs macOS (otool, install_name_tool, codesign)"
        )
    allowed = set(allowed_packages)

    # Walk the load graph instead of copying the store closure, so packages
    # the program never loads stay out.
    names = {}  # store file -> file name in lib/
    taken = set()
    queue = sorted(origins.values())
    seen = set()
    while queue:
        image = queue.pop()
        if image in seen:
            continue
        seen.add(image)
        for dep in load_commands(image):
            real = resolve(dep, image)
            if real is None or real in names or system_substitute(real):
                continue
            if store_package(real) not in allowed:
                sys.exit(
                    f"{image} loads {real}, from a package runtime.nix does not list for this "
                    "program. Add the package to the build-input walk in runtime.nix, so "
                    "THIRD_PARTY_LICENSES covers it, or list it under systemLibraries."
                )
            name = os.path.basename(dep)
            # GNU and Apple libiconv both install libiconv.2.dylib, so a
            # colliding name gets its package name as a prefix.
            if name in taken:
                name = real.split("/")[3].split("-", 1)[1] + "-" + name
            if name in taken:
                sys.exit(f"two libraries would share the name {name} in {root}/lib")
            taken.add(name)
            names[real] = name
            queue.append(real)

    lib_dir = os.path.join(root, "lib")
    copies = dict(origins)
    if names:
        os.makedirs(lib_dir, exist_ok=True)
    for real, name in names.items():
        dst = os.path.join(lib_dir, name)
        shutil.copyfile(real, dst)
        os.chmod(dst, 0o755)
        copies[dst] = real

    for dst, src in sorted(copies.items()):
        is_lib = os.path.dirname(dst) == lib_dir
        prefix = (
            "@loader_path/"
            if is_lib
            else "@loader_path/" + os.path.relpath(lib_dir, os.path.dirname(dst)) + "/"
        )
        args = []
        for dep in load_commands(src):
            real = resolve(dep, src)
            if real is None:
                continue
            target = system_substitute(real) or prefix + names[real]
            args += ["-change", dep, target]
        if is_lib:
            args += ["-id", "@loader_path/" + os.path.basename(dst)]
        for rp in rpaths(src):
            if rp.startswith("/nix/") or rp.startswith("@"):
                args += ["-delete_rpath", rp]
        if args:
            subprocess.run(
                ["install_name_tool", *args, dst], check=True, capture_output=True
            )
        subprocess.run(
            ["codesign", "--force", "--sign", "-", dst], check=True, capture_output=True
        )

    bad = []
    for dst in copies:
        for ref in [install_name(dst) or ""] + load_commands(dst) + rpaths(dst):
            if "/nix/" in ref or ref.startswith("@rpath"):
                bad.append(f"{dst}: {ref}")
    if bad:
        sys.exit("the bundle still refers to /nix or @rpath:\n" + "\n".join(bad))
    print(
        f"relocated {len(origins)} executables and {len(names)} libraries into {root}"
    )


# --- manifest ------------------------------------------------------------


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entries(out, dirname):
    entries = {}
    root = os.path.join(out, dirname)
    for parent, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(
            files + [d for d in dirs if os.path.islink(os.path.join(parent, d))]
        ):
            path = os.path.join(parent, name)
            rel = os.path.relpath(path, out)
            if os.path.islink(path):
                target = os.readlink(path)
                resolved = os.path.normpath(os.path.join(parent, target))
                if os.path.isabs(target) or not resolved.startswith(root + os.sep):
                    sys.exit(f"{rel} links to {target}, outside {dirname}")
                entries[rel] = {"symlink": target}
            else:
                entries[rel] = {"sha256": sha256(path)}
    return entries


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        spec = json.load(f)
    out = sys.argv[2]
    if os.path.exists(out) and os.listdir(out):
        sys.exit(f"{out} is not empty")
    os.makedirs(out, exist_ok=True)

    manifest = {
        "manifestVersion": MANIFEST_VERSION,
        "system": spec["system"],
        "programs": [],
    }
    for program in sorted(spec["programs"], key=lambda p: (p["name"], p["version"])):
        dirname, origins = copy_program(program, out)
        if program.get("relocate"):
            relocate(
                os.path.join(out, dirname),
                origins,
                spec["packages"].get(program["name"], []),
            )
        bin_paths = {}
        for b in program["bin"]:
            rel = f"{dirname}/bin/{b}"
            if not os.path.exists(os.path.join(out, rel)):
                sys.exit(
                    f"{program['name']} {program['version']} lists bin/{b}, which the spec does not ship"
                )
            bin_paths[b] = rel
        manifest["programs"].append(
            {
                "name": program["name"],
                "version": program["version"],
                "bin": bin_paths,
                "files": file_entries(out, dirname),
            }
        )

    licences = os.path.join(out, "THIRD_PARTY_LICENSES")
    shutil.copyfile(spec["licenses"], licences)
    os.chmod(licences, 0o644)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    shipped = ", ".join(f"{p['name']} {p['version']}" for p in manifest["programs"])
    print(f"assembled {out}: {shipped}")


if __name__ == "__main__":
    main()
