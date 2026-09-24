import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("patches", Path(__file__).with_name("apply-playground-ui-patches.py"))
patches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patches)


class PlaygroundUIPatchesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.public = self.root / "public"
        self.patch_root = self.root / "patches"
        self.patch_root.mkdir()
        self.bundle = self.public / "playground/0.2.0"
        self.bundle.mkdir(parents=True)
        identity = {"version": "0.2.0", "commit": "a" * 40, "pipeline": "1", "job": "2"}
        for name, data in {
            "release-identity.json": json.dumps(identity).encode(),
            "index.html": b"<html>broken</html>\n",
            "playground.wasm": b"released engine",
            "playground.wasm.br": b"compressed engine",
            "schemas.json": b"released schemas",
            "starter.config.yaml": b"released preset",
        }.items():
            (self.bundle / name).write_bytes(data)
        self.manifest = {
            "release": identity,
            "revision": "fix-1",
            "source": {"commit": "b" * 40},
            "release_files": patches.file_hashes(self.bundle),
            "files": {"index.html": {
                "sha256": patches.digest(b"<html>fixed</html>\n"),
                "replacements": [{"old": "broken", "new": "fixed"}],
            }},
        }
        self.save_manifest()

    def save_manifest(self):
        (self.patch_root / "0.2.0.json").write_text(json.dumps(self.manifest))

    def apply(self):
        patches.apply(self.public, self.patch_root, "0.2.0")

    def assert_refused_without_mutation(self):
        before = patches.file_hashes(self.public)
        with self.assertRaises((ValueError, KeyError)):
            self.apply()
        self.assertEqual(before, patches.file_hashes(self.public))

    def test_patch_preserves_every_rendering_asset_and_release_identity(self):
        before = patches.file_hashes(self.bundle)
        self.apply()
        after = patches.file_hashes(self.bundle)
        for name, value in before.items():
            if name != "index.html":
                self.assertEqual(value, after[name], name)
        self.assertEqual((self.bundle / "index.html").read_text(), "<html>fixed</html>\n")
        marker = json.loads((self.bundle / patches.MARKER).read_text())
        self.assertEqual(marker["release"], self.manifest["release"])
        self.assertEqual(marker["source"], self.manifest["source"])
        self.assertEqual(marker["manifest_sha256"], patches.digest((self.patch_root / "0.2.0.json").read_bytes()))
        self.apply()
        self.assertEqual(after, patches.file_hashes(self.bundle))

    def test_asset_drift_and_extra_files_are_rejected_before_mutation(self):
        for name in ("playground.wasm", "playground.wasm.br", "schemas.json", "starter.config.yaml", "index.html", "unexpected.js"):
            with self.subTest(name=name):
                path = self.bundle / name
                original = path.read_bytes() if path.exists() else None
                path.write_bytes(b"unexpected content")
                self.assert_refused_without_mutation()
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_symlinks_are_rejected(self):
        path = self.bundle / "playground.wasm"
        path.unlink()
        path.symlink_to(self.bundle / "schemas.json")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.apply()
        self.assertIn("broken", (self.bundle / "index.html").read_text())

    def test_wrong_release_identity_is_rejected(self):
        identity = self.manifest["release"] | {"commit": "c" * 40}
        (self.bundle / "release-identity.json").write_text(json.dumps(identity))
        self.assert_refused_without_mutation()

    def test_engine_patch_is_rejected_even_with_matching_checksums(self):
        self.manifest["files"] = {"playground.wasm": {
            "sha256": patches.digest(b"new engine"),
            "replacements": [{"old": "released engine", "new": "new engine"}],
        }}
        self.save_manifest()
        self.assert_refused_without_mutation()

    def test_patch_context_and_output_digest_must_match(self):
        for mutation in ("context", "digest"):
            with self.subTest(mutation=mutation):
                original = copy.deepcopy(self.manifest)
                if mutation == "context":
                    self.manifest["files"]["index.html"]["replacements"][0]["old"] = "absent"
                else:
                    self.manifest["files"]["index.html"]["sha256"] = "0" * 64
                self.save_manifest()
                self.assert_refused_without_mutation()
                self.manifest = original

    def test_modified_patch_marker_and_post_patch_asset_drift_are_rejected(self):
        self.apply()
        marker = self.bundle / patches.MARKER
        original = marker.read_bytes()
        marker.write_text("{}")
        self.assert_refused_without_mutation()
        marker.write_bytes(original)
        (self.bundle / "schemas.json").write_bytes(b"changed")
        self.assert_refused_without_mutation()

    def test_missing_target_and_unknown_version_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "No published playground"):
            patches.apply(self.public, self.patch_root, "0.3.0")
        self.assertIn("broken", (self.bundle / "index.html").read_text())

    def test_all_releases_are_validated_before_any_mutation(self):
        other = self.public / "playground/0.3.0"
        other.mkdir()
        manifest = copy.deepcopy(self.manifest)
        manifest["release"]["version"] = "0.3.0"
        (other / "release-identity.json").write_text(json.dumps(manifest["release"]))
        (self.patch_root / "0.3.0.json").write_text(json.dumps(manifest))
        self.assert_refused_without_mutation()


if __name__ == "__main__":
    unittest.main()
