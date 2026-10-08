"""Keep immutable playground engines in the public package registry."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request

from site_versions import ordered


MANIFEST = "shared/playground-engines.json"
BEGIN = "# BEGIN HAPTIC playground engines"
END = "# END HAPTIC playground engines"
ENGINE = re.compile(r"playground/(dev|\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?)/(playground\.wasm(?:\.br|\.gz)?)")
CHECKSUM = re.compile(r"[0-9a-f]{64}")
FILENAMES = ("playground.wasm", "playground.wasm.br", "playground.wasm.gz")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def regular_path(public, relative):
    path = public / relative
    for parent in [path, *path.parents]:
        if parent == public:
            break
        if parent.is_symlink():
            raise ValueError(f"Playground storage path is a symlink: {parent}")
    if path.exists() and not path.is_file():
        raise ValueError(f"Playground storage path is not a file: {path}")
    return path


def read_manifest(public, project):
    path = regular_path(public, MANIFEST)
    if not path.exists():
        return {}
    manifest = json.loads(path.read_text())
    if not isinstance(manifest, dict) or set(manifest) != {"version", "project", "files"} or type(manifest["version"]) is not int or manifest["version"] != 1 or manifest["project"] != project:
        raise ValueError("Playground storage manifest has an unexpected version or project")
    records = manifest["files"]
    if not isinstance(records, dict):
        raise ValueError("Playground storage inventory is not a mapping")
    for name, record in records.items():
        if not ENGINE.fullmatch(name) or not isinstance(record, dict) or set(record) != {"sha256", "size"}:
            raise ValueError(f"Invalid playground storage entry: {name}")
        if not isinstance(record["sha256"], str) or not CHECKSUM.fullmatch(record["sha256"]):
            raise ValueError(f"Invalid playground checksum: {name}")
        if type(record["size"]) is not int or record["size"] <= 0:
            raise ValueError(f"Invalid playground size: {name}")
        regular_path(public, name)
    return records


def verify(path, record):
    if path.stat().st_size != record["size"] or digest(path) != record["sha256"]:
        raise ValueError(f"Playground engine checksum mismatch: {path.name}")


class RejectRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Registry:
    def __init__(self, project, token=""):
        if not re.fullmatch(r"[1-9][0-9]*", project):
            raise ValueError("CI_PROJECT_ID must identify the public Pages project")
        self.project = project
        self.token = token

    def url(self, checksum, filename="playground.wasm"):
        if not CHECKSUM.fullmatch(checksum) or filename not in FILENAMES:
            raise ValueError("Invalid playground package checksum")
        return f"https://gitlab.com/api/v4/projects/{self.project}/packages/generic/playground-engine/{checksum}/{filename}"

    def download(self, checksum, destination, filename="playground.wasm"):
        try:
            # Public reads avoid forwarding a job token through storage redirects.
            with urllib.request.urlopen(self.url(checksum, filename), timeout=120) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)
            return True
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return False
            raise

    def upload(self, source, record):
        if not self.token:
            raise ValueError("CI_JOB_TOKEN is required to publish a playground engine")
        with source.open("rb") as data:
            request = urllib.request.Request(self.url(record["sha256"], source.name), data=data, method="PUT", headers={
                "JOB-TOKEN": self.token,
                "Content-Type": "application/octet-stream",
                "Content-Length": str(record["size"]),
            })
            with urllib.request.build_opener(RejectRedirect).open(request, timeout=120) as response:
                if response.status != 201:
                    raise ValueError(f"Playground engine upload returned HTTP {response.status}")

    def ensure(self, source, record, temporary):
        checksum = record["sha256"]
        downloaded = temporary / (checksum + "-" + source.name)
        if not self.download(checksum, downloaded, source.name):
            self.upload(source, record)
            if not self.download(checksum, downloaded, source.name):
                raise ValueError("Uploaded playground engine is not publicly readable")
        verify(downloaded, record)


def restore(public, registry):
    public = public.resolve(strict=True)
    records = read_manifest(public, registry.project)
    with tempfile.TemporaryDirectory() as temporary:
        cached = {}
        plans = []
        for name, record in records.items():
            destination = regular_path(public, name)
            if not destination.parent.is_dir():
                raise ValueError(f"Stored playground directory is missing: {name}")
            if destination.exists():
                verify(destination, record)
                continue
            checksum = record["sha256"]
            key = (checksum, destination.name)
            if key not in cached:
                source = Path(temporary) / (checksum + "-" + destination.name)
                if not registry.download(checksum, source, destination.name):
                    raise ValueError(f"Stored playground engine is missing: {name}")
                verify(source, record)
                cached[key] = source
            else:
                verify(cached[key], record)
            plans.append((cached[key], destination))
        for source, destination in plans:
            shutil.copyfile(source, destination)
    print(f"Restored {len(records)} checksum-verified playground engines")


def redirect_block(records, registry):
    lines = [BEGIN]
    for name, record in sorted(records.items()):
        lines.append(f"/{name} {registry.url(record['sha256'], Path(name).name)} 302")
    return "\n".join([*lines, END]) + "\n"


def retained_versions(public):
    versions = {p.parent.name for p in public.glob("playground/*/playground.wasm")
                if ENGINE.fullmatch(p.relative_to(public).as_posix()) and p.parent.name != "dev"}
    stable = ordered(v for v in versions if "-" not in v)[:2]
    prerelease = ordered(v for v in versions if "-" in v)[:1]
    return {"dev", *stable, *prerelease}


def externalize(public, registry, retained=None):
    public = public.resolve(strict=True)
    previous = read_manifest(public, registry.project)
    for name in previous:
        path = regular_path(public, name)
        if path.parent.exists() and not path.exists():
            raise ValueError(f"Restore the playground engine before publication: {name}")
    records = {}
    sources = {}
    retained = retained_versions(public) if retained is None else retained
    for path in sorted(p for name in FILENAMES for p in public.glob(f"playground/*/{name}")):
        name = path.relative_to(public).as_posix()
        if not ENGINE.fullmatch(name):
            raise ValueError(f"Invalid playground engine path: {name}")
        regular_path(public, name)
        record = {"sha256": digest(path), "size": path.stat().st_size}
        if record["size"] == 0:
            raise ValueError(f"Playground engine is empty: {name}")
        if name in previous and path.parent.name != "dev" and previous[name] != record:
            raise ValueError(f"Released playground engine changed: {name}")
        if path.parent.name in retained:
            continue
        records[name] = record
        sources.setdefault((record["sha256"], path.name), (path, record))
    redirects = regular_path(public, "_redirects")
    original = redirects.read_text() if redirects.exists() else ""
    if BEGIN in original or END in original:
        old_block = redirect_block(previous, registry)
        if original.count(BEGIN) != 1 or original.count(END) != 1 or old_block not in original:
            raise ValueError("Published playground redirects do not match their manifest")
        original = original.replace(old_block, "")
    output = original.rstrip() + "\n" + redirect_block(records, registry)
    if len(output.encode()) > 65536 or len([line for line in output.splitlines() if line and not line.startswith("#")]) > 1000:
        raise ValueError("Playground redirects exceed the Pages redirect limit")
    manifest = regular_path(public, MANIFEST)
    with tempfile.TemporaryDirectory() as temporary:
        for source, record in sources.values():
            registry.ensure(source, record, Path(temporary))
    # Every remote engine is verified before any local engine is removed.
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"version": 1, "project": registry.project, "files": records}, indent=2, sort_keys=True) + "\n")
    redirects.write_text(output)
    for name in records:
        (public / name).unlink()
    print(f"Stored {len(records)} playground engines in {len(sources)} content-addressed packages")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["restore", "externalize"])
    parser.add_argument("public", type=Path)
    args = parser.parse_args()
    try:
        registry = Registry(os.environ.get("CI_PROJECT_ID", ""), os.environ.get("CI_JOB_TOKEN", ""))
        {"restore": restore, "externalize": externalize}[args.operation](args.public, registry)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"Playground storage refused publication: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
