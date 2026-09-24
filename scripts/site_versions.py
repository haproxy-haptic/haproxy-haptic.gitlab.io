"""Maintain published version catalogs and retire superseded prereleases."""

import argparse
import functools
import html
import json
from pathlib import Path
import re
import shutil
import sys


PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:alpha|beta|rc)\.[0-9]+))?$")
PREFIXES = ("docs", "controller", "helm-chart", "playground")
LEGACY_MARKER = "legacy-documentation.json"


def parse(version):
    match = PATTERN.fullmatch(version)
    if not match:
        raise ValueError(f"Invalid semantic version: {version}")
    prerelease = match.group(4)
    pre = None
    if prerelease is not None:
        label, number = prerelease.split(".")
        pre = ({"alpha": 0, "beta": 1, "rc": 2}[label], int(number))
    return tuple(map(int, match.group(1, 2, 3))), pre


def compare(left, right):
    left_core, left_pre = parse(left)
    right_core, right_pre = parse(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        return (left_pre is None) - (right_pre is None)
    return (left_pre > right_pre) - (left_pre < right_pre)


def ordered(versions):
    return sorted(versions, key=functools.cmp_to_key(compare), reverse=True)


def inventory(public):
    result = {}
    for prefix in PREFIXES:
        directory = public / prefix
        if directory.is_symlink():
            raise ValueError(f"Version directory is a symlink: {directory}")
        versions = {}
        for path in sorted(directory.iterdir()) if directory.exists() else []:
            version = path.name.removeprefix("v")
            if not PATTERN.fullmatch(version) and version != "dev":
                continue
            if path.is_symlink() or not path.is_dir() or (path / "index.html").is_symlink() or not (path / "index.html").is_file():
                raise ValueError(f"Published version is incomplete: {path}")
            versions.setdefault(version, []).append(path)
        result[prefix] = versions
    return result


def legacy_page(version, sources):
    if parse(version)[1] is not None or not sources:
        raise ValueError("Legacy documentation requires a stable version and its sources")
    links = []
    for prefix, directory in sorted(sources.items()):
        if prefix not in ("controller", "helm-chart") or directory not in (version, "v" + version):
            raise ValueError("Invalid legacy documentation source")
        label = "Controller documentation" if prefix == "controller" else "Helm chart documentation"
        links.append(f'<li><a href="/{prefix}/{html.escape(directory)}/">{label}</a></li>')
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HAPTIC {version} documentation</title>
<style>
:root {{ color-scheme: light dark; }}
body {{ font: 1.1rem/1.6 system-ui, sans-serif; max-width: 44rem; margin: 4rem auto; padding: 0 1.5rem; }}
li {{ margin: 1rem 0; }}
</style></head><body><main>
<h1>HAPTIC {version} documentation</h1>
<p>Choose the documentation you need for this release.</p>
<ul>{''.join(links)}</ul>
<p><a href="/">All HAPTIC versions</a></p>
</main></body></html>
'''


def json_bytes(value):
    return (json.dumps(value, indent=2) + "\n").encode()


def reconcile(public):
    catalogs = inventory(public)
    stable = {version for versions in catalogs.values() for version in versions
              if version != "dev" and parse(version)[1] is None}
    retired = []
    for versions in catalogs.values():
        for version in list(versions):
            if version != "dev" and parse(version)[1] is not None and version.split("-")[0] in stable:
                retired.extend(versions.pop(version))
    outputs = {}
    for version in ordered(stable):
        sources = {prefix: paths[0].name for prefix in ("controller", "helm-chart")
                   if (paths := catalogs[prefix].get(version))}
        target = public / "docs" / version
        existing = catalogs["docs"].get(version)
        if not sources or existing and not (target / LEGACY_MARKER).exists():
            continue
        if existing:
            if (target / LEGACY_MARKER).is_symlink():
                raise ValueError(f"Legacy documentation marker is a symlink: {target}")
            marker = json.loads((target / LEGACY_MARKER).read_text())
            if marker["version"] != version or (target / "index.html").read_text() != legacy_page(version, marker["sources"]):
                raise ValueError(f"Legacy documentation index was modified: {target}")
            if set(p.name for p in target.iterdir()) != {"index.html", LEGACY_MARKER}:
                raise ValueError(f"Unexpected files in legacy documentation index: {target}")
        outputs[target / "index.html"] = legacy_page(version, sources).encode()
        outputs[target / LEGACY_MARKER] = json_bytes({"version": version, "sources": sources})
        catalogs["docs"][version] = [target]

    docs_stable = ordered(set(catalogs["docs"]) & stable)
    latest = docs_stable[0] if docs_stable else next(iter(ordered(stable)), None)
    for prefix, versions in catalogs.items():
        if not versions:
            if (public / prefix).exists():
                if prefix == "playground":
                    raise ValueError("No published playground remains; publish a stable or dev bundle first")
                outputs[public / prefix / "versions.json"] = json_bytes([])
            continue
        releases = ordered(set(versions) - {"dev"})
        names = releases + (["dev"] if "dev" in versions else [])
        if prefix == "playground":
            current = next((v for v in releases if v in stable), releases[0] if releases else None)
            value = {"versions": [{"version": versions[v][0].name, "stable": v in stable} for v in names]}
            if current:
                value["current"] = versions[current][0].name
            landing = versions[current or "dev"][0].name
            outputs[public / prefix / "index.html"] = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>HAPTIC Playground</title>
<script>location.replace('./{landing}/' + location.search + location.hash)</script>
<meta http-equiv="refresh" content="0; url=./{landing}/">
<link rel="canonical" href="./{landing}/"></head>
<body><p><a href="./{landing}/">HAPTIC Playground &rarr;</a></p></body></html>
'''.encode()
        else:
            value = [{"version": versions[v][0].name, "title": v,
                      "aliases": ["latest"] if v == latest else []} for v in names]
        outputs[public / prefix / "versions.json"] = json_bytes(value)

    latest_link = public / "docs/latest"
    if latest_link.exists() and not latest_link.is_symlink():
        raise ValueError(f"Latest documentation alias is not a symlink: {latest_link}")
    for path in outputs:
        if path.is_symlink():
            raise ValueError(f"Version catalog output is a symlink: {path}")

    # GitLab publishes this complete artifact only after reconciliation succeeds.
    for path in retired:
        shutil.rmtree(path)
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    if docs_stable:
        latest_link.unlink(missing_ok=True)
        latest_link.symlink_to(catalogs["docs"][docs_stable[0]][0].name)
    elif latest_link.is_symlink():
        latest_link.unlink()
    print(f"Updated version catalogs; retired {len(retired)} prerelease directories")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("public", type=Path)
    args = parser.parse_args()
    try:
        reconcile(args.public)
    except (ValueError, KeyError, OSError) as error:
        print(f"Version catalog publication refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
