import json
from pathlib import Path
import tempfile
import unittest

from site_versions import reconcile


class SiteVersionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.public = Path(self.temp.name)

    def add(self, prefix, version):
        path = self.public / prefix / version
        path.mkdir(parents=True, exist_ok=True)
        (path / "index.html").write_text(f"Original {prefix} {version}")
        (path / "asset.txt").write_text(f"Original asset {prefix} {version}")
        return path

    def versions(self, prefix):
        data = json.loads((self.public / prefix / "versions.json").read_text())
        return data["versions"] if prefix == "playground" else data

    def snapshot(self):
        return {p.relative_to(self.public).as_posix(): (p.readlink().as_posix() if p.is_symlink() else p.read_bytes())
                for p in self.public.rglob("*") if p.is_symlink() or p.is_file()}

    def test_stable_release_retires_matching_prereleases_in_both_doc_layouts(self):
        originals = []
        for prefix in ("docs", "playground"):
            originals.extend([self.add(prefix, "0.2.0"), self.add(prefix, "dev"), self.add(prefix, "0.3.0-alpha.1")])
        for prefix in ("controller", "helm-chart"):
            originals.extend([self.add(prefix, "0.1.0"), self.add(prefix, "v0.1.0"), self.add(prefix, "dev")])
        retired = []
        for prefix in ("docs", "controller", "helm-chart", "playground"):
            for version in ("0.2.0-alpha.3", "0.2.0-beta.1", "0.2.0-rc.1", "v0.2.0-alpha.1"):
                retired.append(self.add(prefix, version))
        before = {p: {f.name: f.read_bytes() for f in p.iterdir()} for p in originals}
        reconcile(self.public)
        for path in retired:
            self.assertFalse(path.exists(), path)
        for path, files in before.items():
            self.assertEqual({f.name: f.read_bytes() for f in path.iterdir()}, files)
        self.assertEqual([v["version"] for v in self.versions("docs")], ["0.3.0-alpha.1", "0.2.0", "0.1.0", "dev"])
        self.assertEqual((self.public / "docs/latest").readlink(), Path("0.2.0"))
        for prefix in ("controller", "helm-chart"):
            self.assertEqual([v["version"] for v in self.versions(prefix)], ["0.1.0", "dev"])
            self.assertTrue(all(v["aliases"] == [] for v in self.versions(prefix)))
        landing = (self.public / "docs/0.1.0/index.html").read_text()
        self.assertIn('href="/controller/0.1.0/"', landing)
        self.assertIn('href="/helm-chart/0.1.0/"', landing)
        self.assertNotIn("0.1.0", [v["version"] for v in self.versions("playground")])
        self.assertEqual(json.loads((self.public / "playground/versions.json").read_text())["current"], "0.2.0")

    def test_old_prerelease_retry_cannot_restore_retired_versions(self):
        for prefix in ("docs", "playground"):
            self.add(prefix, "0.2.0")
            self.add(prefix, "0.3.0")
        reconcile(self.public)
        before = self.snapshot()
        for prefix in ("docs", "playground"):
            self.add(prefix, "0.2.0-alpha.3")
            (self.public / prefix / "versions.json").write_text('[{"version":"0.2.0-alpha.3"}]')
        reconcile(self.public)
        self.assertEqual(before, self.snapshot())

    def test_newer_prerelease_survives_and_prerelease_only_site_has_no_latest(self):
        for prefix in ("docs", "playground"):
            for version in ("1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0-rc.1", "dev"):
                self.add(prefix, version)
        reconcile(self.public)
        self.assertFalse((self.public / "docs/latest").exists())
        self.assertEqual([v["version"] for v in self.versions("docs")], ["1.0.0-rc.1", "1.0.0-alpha.10", "1.0.0-alpha.2", "dev"])
        self.assertTrue(all(v["aliases"] == [] for v in self.versions("docs")))

    def test_v_prefixed_legacy_release_links_to_its_original_paths(self):
        self.add("controller", "v0.1.0")
        self.add("helm-chart", "v0.1.0")
        reconcile(self.public)
        landing = (self.public / "docs/0.1.0/index.html").read_text()
        self.assertIn('/controller/v0.1.0/', landing)
        self.assertIn('/helm-chart/v0.1.0/', landing)
        self.assertEqual(self.versions("docs"), [{"version": "0.1.0", "title": "0.1.0", "aliases": ["latest"]}])
        self.assertFalse((self.public / "playground").exists())

    def test_existing_combined_stable_docs_are_preserved(self):
        combined = self.add("docs", "0.1.0")
        self.add("controller", "0.1.0")
        before = (combined / "index.html").read_bytes()
        reconcile(self.public)
        self.assertEqual((combined / "index.html").read_bytes(), before)
        self.assertFalse((combined / "legacy-documentation.json").exists())

    def test_old_stable_release_and_idempotent_refresh_do_not_move_latest_back(self):
        self.add("docs", "0.2.0")
        reconcile(self.public)
        self.add("controller", "0.1.0")
        reconcile(self.public)
        before = self.snapshot()
        reconcile(self.public)
        self.assertEqual(before, self.snapshot())
        self.assertEqual((self.public / "docs/latest").readlink(), Path("0.2.0"))

    def test_modified_legacy_index_is_rejected_before_retirement(self):
        self.add("controller", "0.1.0")
        self.add("docs", "0.2.0")
        reconcile(self.public)
        self.add("docs", "0.2.0-alpha.1")
        (self.public / "docs/0.1.0/index.html").write_text("modified")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "index was modified"):
            reconcile(self.public)
        self.assertEqual(before, self.snapshot())

    def test_incomplete_stable_release_cannot_remove_its_prerelease(self):
        self.add("docs", "0.2.0-alpha.1")
        (self.add("docs", "0.2.0") / "index.html").unlink()
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            reconcile(self.public)
        self.assertEqual(before, self.snapshot())

    def test_unsafe_alias_and_output_paths_fail_before_retirement(self):
        self.add("docs", "0.2.0")
        self.add("docs", "0.2.0-alpha.1")
        (self.public / "docs/latest").mkdir()
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "not a symlink"):
            reconcile(self.public)
        self.assertEqual(before, self.snapshot())
        (self.public / "docs/latest").rmdir()
        (self.public / "docs/versions.json").symlink_to(self.public / "outside.json")
        with self.assertRaisesRegex(ValueError, "output is a symlink"):
            reconcile(self.public)
        self.assertTrue((self.public / "docs/0.2.0-alpha.1").exists())

    def test_empty_legacy_catalog_loses_retired_entries(self):
        self.add("docs", "0.2.0")
        self.add("controller", "0.2.0-alpha.1")
        (self.public / "controller/versions.json").write_text('[{"version":"0.2.0-alpha.1"}]')
        reconcile(self.public)
        self.assertEqual(self.versions("controller"), [])


if __name__ == "__main__":
    unittest.main()
