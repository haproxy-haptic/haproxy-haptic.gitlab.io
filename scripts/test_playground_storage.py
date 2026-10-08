import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from compact_assets import compact, site_size
from playground_storage import BEGIN, END, MANIFEST, Registry, RejectRedirect, digest, externalize as store, restore


def externalize(public, registry):
    store(public, registry, retained=set())


class MemoryRegistry(Registry):
    def __init__(self):
        super().__init__("123")
        self.objects = {}
        self.uploads = []
        self.corrupt_upload = False

    def download(self, checksum, destination, filename="playground.wasm"):
        key = (checksum, filename)
        if key not in self.objects:
            return False
        destination.write_bytes(self.objects[key])
        return True

    def upload(self, source, record):
        key = (record["sha256"], source.name)
        self.uploads.append(key)
        self.objects[key] = b"corrupt" if self.corrupt_upload else source.read_bytes()


class PlaygroundStorageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.public = Path(self.temp.name) / "public"
        self.public.mkdir()
        self.registry = MemoryRegistry()

    def engine(self, version="0.5.0", content=b"engine" * 2048):
        path = self.public / "playground" / version / "playground.wasm"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def snapshot(self):
        return {p.relative_to(self.public).as_posix(): p.read_bytes()
                for p in self.public.rglob("*") if p.is_file()}

    def manifest(self):
        return json.loads((self.public / MANIFEST).read_text())

    def test_publish_restore_and_retry_preserve_released_bytes(self):
        release = self.engine()
        dev = self.engine("dev")
        compressed = Path(str(release) + ".br")
        compressed.write_bytes(b"compressed engine")
        (release.parent / "release-identity.json").write_text('{"version":"0.5.0"}')
        before = self.snapshot()
        before_size = site_size(self.public)
        externalize(self.public, self.registry)
        self.assertFalse(release.exists())
        self.assertFalse(dev.exists())
        self.assertEqual(len(self.registry.uploads), 2)
        self.assertLess(site_size(self.public), before_size)
        compact(self.public)
        stored = self.snapshot()
        restore(self.public, self.registry)
        for name, content in before.items():
            self.assertEqual((self.public / name).read_bytes(), content)
        externalize(self.public, self.registry)
        self.assertEqual(self.snapshot(), stored)
        self.assertEqual(len(self.registry.uploads), 2)

    def test_dev_updates_preserve_stable_packages_and_redirects(self):
        release = self.engine()
        dev = self.engine("dev")
        compressed = Path(str(dev) + ".br")
        compressed.write_bytes(b"old compressed")
        checksum = digest(release)
        original = release.read_bytes()
        externalize(self.public, self.registry)
        restore(self.public, self.registry)
        dev.write_bytes(b"new dev engine")
        compressed.write_bytes(b"new compressed")
        externalize(self.public, self.registry)
        records = self.manifest()["files"]
        self.assertEqual(records["playground/0.5.0/playground.wasm"]["sha256"], checksum)
        self.assertNotEqual(records["playground/dev/playground.wasm"]["sha256"], checksum)
        self.assertEqual(self.registry.objects[(checksum, "playground.wasm")], original)
        redirects = (self.public / "_redirects").read_text()
        self.assertEqual(redirects.count(BEGIN), 1)
        self.assertEqual(redirects.count(END), 1)
        self.assertIn(f"/playground/0.5.0/playground.wasm {self.registry.url(checksum)} 302", redirects)

    def test_existing_corrupted_package_never_gets_overwritten(self):
        engine = self.engine()
        checksum = digest(engine)
        self.registry.objects[(checksum, "playground.wasm")] = b"tampered"
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            externalize(self.public, self.registry)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.registry.uploads, [])
        self.assertEqual(self.registry.objects[(checksum, "playground.wasm")], b"tampered")

    def test_bad_upload_keeps_every_local_engine(self):
        self.engine()
        self.engine("0.4.1", b"older")
        before = self.snapshot()
        self.registry.corrupt_upload = True
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            externalize(self.public, self.registry)
        self.assertEqual(self.snapshot(), before)

    def test_corrupted_or_missing_remote_blocks_restore_before_any_write(self):
        one = self.engine("0.4.1", b"first")
        self.engine("0.5.0", b"second")
        externalize(self.public, self.registry)
        before = self.snapshot()
        second = self.manifest()["files"]["playground/0.5.0/playground.wasm"]["sha256"]
        self.registry.objects[(second, "playground.wasm")] = b"bad"
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            restore(self.public, self.registry)
        self.assertFalse(one.exists())
        self.assertEqual(self.snapshot(), before)
        del self.registry.objects[(second, "playground.wasm")]
        with self.assertRaisesRegex(ValueError, "engine is missing"):
            restore(self.public, self.registry)
        self.assertEqual(self.snapshot(), before)

    def test_stable_engine_mutation_is_rejected_before_upload(self):
        engine = self.engine()
        externalize(self.public, self.registry)
        restore(self.public, self.registry)
        engine.write_bytes(b"changed release")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Released playground engine changed"):
            externalize(self.public, self.registry)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(len(self.registry.uploads), 1)

    def test_manifest_rejects_foreign_projects_paths_sizes_and_checksums(self):
        self.engine()
        externalize(self.public, self.registry)
        original = self.manifest()
        invalid = [
            {**original, "project": "456"},
            {**original, "files": {"../outside": {"sha256": "a" * 64, "size": 1}}},
            {**original, "files": {"playground/dev/playground.wasm": {"sha256": "bad", "size": 1}}},
            {**original, "files": {"playground/dev/playground.wasm": {"sha256": "a" * 64, "size": True}}},
        ]
        for manifest in invalid:
            with self.subTest(manifest=manifest):
                (self.public / MANIFEST).write_text(json.dumps(manifest))
                before = self.snapshot()
                with self.assertRaises(ValueError):
                    restore(self.public, self.registry)
                self.assertEqual(self.snapshot(), before)

    def test_missing_restore_cannot_silently_discard_inventory(self):
        self.engine()
        externalize(self.public, self.registry)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Restore the playground"):
            externalize(self.public, self.registry)
        self.assertEqual(self.snapshot(), before)

    def test_removed_prerelease_drops_redirect_but_retains_package(self):
        engine = self.engine("0.5.0-rc.1")
        self.engine()
        externalize(self.public, self.registry)
        restore(self.public, self.registry)
        shutil.rmtree(engine.parent)
        externalize(self.public, self.registry)
        self.assertNotIn("0.5.0-rc.1", (self.public / "_redirects").read_text())
        self.assertEqual(len(self.registry.objects), 1)

    def test_redirect_tampering_and_symlinks_are_rejected(self):
        engine = self.engine()
        externalize(self.public, self.registry)
        restore(self.public, self.registry)
        redirects = self.public / "_redirects"
        valid = redirects.read_text()
        redirects.write_text(valid.replace("gitlab.com", "example.com"))
        with self.assertRaisesRegex(ValueError, "redirects do not match"):
            externalize(self.public, self.registry)
        redirects.write_text(valid)
        engine.unlink()
        engine.symlink_to(self.public / "_redirects")
        with self.assertRaisesRegex(ValueError, "symlink"):
            externalize(self.public, self.registry)

    def test_current_versions_keep_compression_while_old_families_are_archived(self):
        paths = {}
        for version in ["0.9.0", "0.10.0", "0.11.0", "0.12.0-rc.1", "dev"]:
            engine = self.engine(version)
            for suffix in [".br", ".gz"]:
                Path(str(engine) + suffix).write_bytes((version + suffix).encode())
            paths[version] = engine
        before = self.snapshot()
        store(self.public, self.registry)
        for version, engine in paths.items():
            for suffix in ["", ".br", ".gz"]:
                self.assertEqual(Path(str(engine) + suffix).exists(), version != "0.9.0")
        self.assertEqual(len(self.manifest()["files"]), 3)
        restore(self.public, self.registry)
        for name, content in before.items():
            self.assertEqual((self.public / name).read_bytes(), content)
        self.engine("0.12.0")
        store(self.public, self.registry)
        self.assertFalse(paths["0.10.0"].exists())
        self.assertTrue(paths["0.11.0"].exists())
        self.assertTrue(paths["dev"].exists())


class RegistryTest(unittest.TestCase):
    def test_public_reads_do_not_send_credentials(self):
        registry = Registry("123", "secret")
        with tempfile.TemporaryDirectory() as directory, patch("urllib.request.urlopen", return_value=io.BytesIO(b"engine")) as opened:
            target = Path(directory) / "engine"
            registry.download("a" * 64, target)
            self.assertEqual(target.read_bytes(), b"engine")
            self.assertEqual(opened.call_args.args, (registry.url("a" * 64),))

    def test_authenticated_uploads_do_not_follow_redirects(self):
        self.assertIsNone(RejectRedirect().redirect_request(None, None, 303, "", {}, "https://example.com"))
        registry = Registry("123", "secret")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "playground.wasm"
            source.write_bytes(b"engine")
            record = {"sha256": digest(source), "size": 6}
            with patch("urllib.request.build_opener") as builder:
                builder.return_value.open.return_value.__enter__.return_value.status = 201
                registry.upload(source, record)
                self.assertIs(builder.call_args.args[0], RejectRedirect)
                request = builder.return_value.open.call_args.args[0]
                self.assertEqual(request.method, "PUT")
                self.assertEqual(request.get_header("Job-token"), "secret")
                self.assertEqual(request.get_header("Content-length"), "6")

    def test_only_not_found_permits_upload(self):
        registry = Registry("123")
        with tempfile.TemporaryDirectory() as directory:
            for status in [403, 429, 500]:
                with self.subTest(status=status), patch("urllib.request.urlopen", side_effect=urllib.error.HTTPError("url", status, "error", {}, None)):
                    with self.assertRaises(urllib.error.HTTPError):
                        registry.download("a" * 64, Path(directory) / "engine")


if __name__ == "__main__":
    unittest.main()
