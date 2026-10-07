import hashlib
from pathlib import Path
import shutil
import tempfile
import unittest

from compact_assets import STORE, compact, site_size


class CompactAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.public = Path(self.temp.name) / "public"
        self.public.mkdir()

    def asset(self, name, content=b"asset" * 1000):
        path = self.public / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def test_shared_bytes_survive_dev_replacement_and_repeat_publication(self):
        release = self.asset("docs/0.4.1/assets/bundle.js")
        dev = self.asset("docs/dev/assets/bundle.js")
        original = release.read_bytes()
        before = site_size(self.public)
        compact(self.public)
        self.assertTrue(release.is_symlink())
        self.assertEqual(release.resolve(), dev.resolve())
        self.assertLess(site_size(self.public), before)
        shutil.rmtree(dev.parents[1])
        self.assertEqual(release.read_bytes(), original)
        self.asset("docs/dev/assets/bundle.js")
        compact(self.public)
        size = site_size(self.public)
        compact(self.public)
        self.assertEqual(site_size(self.public), size)
        self.assertEqual(dev.read_bytes(), original)

    def test_preserves_playground_content_unique_assets_and_compressed_families(self):
        paths = [self.asset("playground/0.4.1/assets/bundle.js"),
                 self.asset("playground/dev/assets/bundle.js"),
                 self.asset("docs/0.4.1/assets/unique.js", b"unique" * 1000),
                 self.asset("docs/0.4.1/assets/encoded.js"),
                 self.asset("docs/0.4.1/assets/encoded.js.gz"),
                 self.asset("docs/dev/assets/encoded.js"),
                 self.asset("docs/dev/assets/encoded.js.br")]
        before = {p: p.read_bytes() for p in paths}
        compact(self.public)
        for path, content in before.items():
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.read_bytes(), content)

    def test_same_bytes_with_different_media_extensions_stay_separate(self):
        one = self.asset("docs/0.4.1/assets/file.js")
        two = self.asset("docs/0.4.1/assets/file.css")
        compact(self.public)
        self.assertFalse(one.is_symlink())
        self.assertFalse(two.is_symlink())

    def test_existing_shared_content_is_verified_before_replacing_any_file(self):
        one = self.asset("docs/0.4.1/assets/file.js")
        two = self.asset("docs/dev/assets/file.js")
        checksum = hashlib.sha256(one.read_bytes()).hexdigest()
        self.asset(f"{STORE}/{checksum}.js", b"corruption")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            compact(self.public)
        self.assertFalse(one.is_symlink())
        self.assertFalse(two.is_symlink())

    def test_rejects_corrupted_shared_targets_on_repeat(self):
        one = self.asset("docs/0.4.1/assets/file.js")
        self.asset("docs/dev/assets/file.js")
        compact(self.public)
        one.write_bytes(b"changed shared data")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            compact(self.public)

    def test_rejects_links_outside_shared_storage_and_symlinked_store(self):
        one = self.asset("docs/0.4.1/assets/file.js")
        one.unlink()
        one.symlink_to("../../../../outside.js")
        (self.public.parent / "outside.js").write_bytes(b"outside")
        with self.assertRaisesRegex(ValueError, "unexpected symlink"):
            compact(self.public)
        one.unlink()
        shared = self.public / "shared"
        shared.symlink_to(self.public.parent, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "directory is invalid"):
            compact(self.public)

    def test_size_limit_counts_unique_files_and_symlink_payloads(self):
        self.asset("index.html", b"hello")
        (self.public / "alias.html").symlink_to("index.html")
        self.assertEqual(site_size(self.public), 15)
        with self.assertRaisesRegex(ValueError, "limit is 14"):
            compact(self.public, limit=14)
        self.assertEqual(compact(self.public, limit=15), 15)

    def test_rejects_symlinked_asset_directories(self):
        outside = self.public.parent / "outside"
        outside.mkdir()
        docs = self.public / "docs/0.4.1"
        docs.mkdir(parents=True)
        (docs / "assets").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "asset directory is a symlink"):
            compact(self.public)

    def test_rejects_symlinked_canonical_files(self):
        one = self.asset("docs/0.4.1/assets/file.js")
        self.asset("docs/dev/assets/file.js")
        target = self.public / STORE / (hashlib.sha256(one.read_bytes()).hexdigest() + ".js")
        target.parent.mkdir(parents=True)
        target.symlink_to(one)
        with self.assertRaisesRegex(ValueError, "Shared asset is a symlink"):
            compact(self.public)
        self.assertFalse(one.is_symlink())


if __name__ == "__main__":
    unittest.main()
