#!/usr/bin/env python3
"""Apply reviewed UI corrections without changing released rendering assets."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


MARKER = "ui-revision.json"
MUTABLE_FILES = {"index.html"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hashes(directory):
    hashes = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Playground contains a symlink: {path}")
        if path.is_file():
            hashes[path.relative_to(directory).as_posix()] = digest(path.read_bytes())
    return hashes


def prepare(directory, manifest_path):
    raw_manifest = manifest_path.read_bytes()
    manifest = json.loads(raw_manifest)
    release = manifest["release"]
    if directory.is_symlink() or directory.parent.is_symlink():
        raise ValueError(f"Playground directory is a symlink: {directory}")
    if json.loads((directory / "release-identity.json").read_text()) != release:
        raise ValueError(f"Release identity mismatch: {directory}")
    changes = manifest["files"]
    if not changes or not changes.keys() <= MUTABLE_FILES:
        raise ValueError("UI patches may only change index.html")
    baseline = manifest["release_files"]
    if MARKER in baseline or not changes.keys() <= baseline.keys():
        raise ValueError("Invalid release file inventory")
    revised = dict(baseline)
    revised.update({name: change["sha256"] for name, change in changes.items()})
    marker = {
        "release": release,
        "revision": manifest["revision"],
        "source": manifest["source"],
        "manifest_sha256": digest(raw_manifest),
        "files": {name: change["sha256"] for name, change in changes.items()},
    }
    actual = file_hashes(directory)
    if MARKER in actual:
        if json.loads((directory / MARKER).read_text()) != marker:
            raise ValueError(f"Unknown UI revision: {directory}")
        del actual[MARKER]
        if actual != revised:
            raise ValueError(f"Patched playground checksum mismatch: {directory}")
        return {}
    if actual != baseline:
        raise ValueError(f"Released playground checksum mismatch: {directory}")
    outputs = {}
    for name, change in changes.items():
        content = (directory / name).read_text()
        for replacement in change["replacements"]:
            old, new = replacement["old"], replacement["new"]
            if not old or content.count(old) != 1:
                raise ValueError(f"UI patch context is not unique: {name}")
            content = content.replace(old, new, 1)
        data = content.encode()
        if digest(data) != change["sha256"]:
            raise ValueError(f"UI patch output checksum mismatch: {name}")
        outputs[name] = data
    outputs[MARKER] = (json.dumps(marker, indent=2, sort_keys=True) + "\n").encode()
    return outputs


def apply(public, patch_root, required_version=None):
    plans = []
    found = False
    for manifest_path in sorted(patch_root.glob("*.json")):
        version = manifest_path.stem
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?", version):
            raise ValueError(f"Invalid UI patch version: {version}")
        directory = public / "playground" / version
        if not directory.exists():
            continue
        manifest = json.loads(manifest_path.read_bytes())
        if manifest["release"]["version"] != version:
            raise ValueError(f"UI patch release version mismatch: {version}")
        plans.append((directory, prepare(directory, manifest_path)))
        found = found or version == required_version
    if required_version is not None and not found:
        raise ValueError(f"No published playground and reviewed UI patch for {required_version}")
    # Validate every affected release before changing the publication artifact.
    for directory, outputs in plans:
        for name, data in outputs.items():
            (directory / name).write_bytes(data)
        print(f"Verified playground UI revision: {directory.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("public", type=Path)
    parser.add_argument("--require-version")
    args = parser.parse_args()
    try:
        apply(args.public, Path(__file__).resolve().parents[1] / "playground-ui-patches", args.require_version)
    except (ValueError, KeyError, OSError) as error:
        print(f"Playground UI publication refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
