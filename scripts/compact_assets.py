"""Share identical documentation files without changing published URLs or bytes."""

import argparse
import collections
import hashlib
import os
from pathlib import Path
import sys


MAX_PAGES_BYTES = 1000 * 1024 ** 2
STORE = "shared/documentation-assets"
DOC_ROOTS = {"docs", "controller", "helm-chart"}
IDENTITY_FILES = {"release-identity.json", "legacy-documentation.json"}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def candidates(public):
    for directory, children, files in os.walk(public, followlinks=False):
        base = Path(directory)
        relative = base.relative_to(public)
        in_docs = len(relative.parts) >= 2 and relative.parts[0] in DOC_ROOTS
        for name in children:
            if (base / name).is_symlink() and (in_docs or "assets" in relative.parts or name == "assets"):
                raise ValueError(f"Documentation asset directory is a symlink: {base / name}")
        children[:] = [name for name in children if not (base / name).is_symlink()
                       and name != "playground"]
        if not in_docs and "assets" not in relative.parts:
            continue
        for name in sorted(files):
            if name in IDENTITY_FILES or in_docs and len(relative.parts) == 2 and name == "index.html":
                continue
            path = base / name
            if path.suffix in (".br", ".gz") or any(Path(str(path) + ext).exists() for ext in (".br", ".gz")):
                continue
            yield path


def site_size(public):
    return sum(path.lstat().st_size for path in public.rglob("*")
               if path.is_symlink() or path.is_file())


def compact(public, limit=MAX_PAGES_BYTES):
    public = public.resolve(strict=True)
    store = public / STORE
    for directory in (public / "shared", store):
        if directory.is_symlink() or directory.exists() and not directory.is_dir():
            raise ValueError(f"Shared asset directory is invalid: {directory}")
    groups = collections.defaultdict(list)
    retained = set()
    for path in candidates(public):
        if path.is_symlink():
            target = Path(os.path.abspath(path.parent / path.readlink()))
            if path.readlink().is_absolute() or target.parent != store or target.is_symlink():
                raise ValueError(f"Documentation asset has an unexpected symlink: {path}")
            if target.name != digest(target) + path.suffix:
                raise ValueError(f"Shared asset checksum mismatch: {path}")
            retained.add(target)
            continue
        if not path.is_file():
            raise ValueError(f"Documentation asset is not a regular file: {path}")
        if path.stat().st_size >= 1024:
            groups[(digest(path), path.suffix)].append(path)
    plans = []
    for (checksum, suffix), paths in groups.items():
        target = store / (checksum + suffix)
        if target.is_symlink():
            raise ValueError(f"Shared asset is a symlink: {target}")
        if target.exists() and (not target.is_file() or digest(target) != checksum):
            raise ValueError(f"Shared asset checksum mismatch: {target}")
        if len(paths) > 1 or target.exists():
            plans.append((target, paths))
            retained.add(target)
    orphaned = []
    for path in public.rglob("*"):
        if path.is_symlink():
            target = Path(os.path.abspath(path.parent / path.readlink()))
            if target.parent == store:
                retained.add(target)
    for target in store.iterdir() if store.exists() else []:
        if target.is_symlink() or not target.is_file() or target.name != digest(target) + target.suffix:
            raise ValueError(f"Shared asset checksum mismatch: {target}")
        if target not in retained:
            orphaned.append(target)
    before = site_size(public)
    replaced = 0
    for target, paths in plans:
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_bytes(paths[0].read_bytes())
        for path in paths:
            path.unlink()
            path.symlink_to(os.path.relpath(target, path.parent))
            replaced += 1
    for target in orphaned:
        target.unlink()
    after = site_size(public)
    if after > limit:
        raise ValueError(f"Pages site is {after} bytes; limit is {limit}. Move retained assets to additional storage before publishing.")
    print(f"Shared {replaced} documentation assets; Pages size {before} -> {after} bytes (limit {limit})")
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("public", type=Path)
    args = parser.parse_args()
    try:
        compact(args.public)
    except (ValueError, OSError) as error:
        print(f"Pages publication refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
