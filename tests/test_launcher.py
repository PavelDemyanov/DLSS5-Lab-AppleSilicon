"""Portable launcher checks using temporary fixtures; never launch Steam/game."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from contextlib import ExitStack
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import launch_probe as base
import launch_neural as neural


def sha(data):
    return hashlib.sha256(data).hexdigest()


def make_app(library, binary=b"verified native game", version="2.5.0"):
    app = library / "steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/Cyberpunk2077").write_bytes(binary)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.cdprojektred.cyberpunk.steam",
        "CFBundleShortVersionString": version,
    }))
    return app


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.steam = self.home / "Library/Application Support/Steam"

    def libraries(self, paths, legacy=False):
        config = self.steam / "steamapps/libraryfolders.vdf"
        config.parent.mkdir(parents=True, exist_ok=True)
        entries = []
        for index, path in enumerate(paths):
            value = json.dumps(str(path), ensure_ascii=False)
            entries.append(f'"{index}" {value}' if legacy else f'"{index}" {{ "path" {value} "apps" {{ "1091500" "1" }} }}')
        config.write_text('"libraryfolders"\n{\n// Steam libraries\n' + "\n".join(entries) + "\n}")
        return config

    def discover(self, environment=None):
        return base.discover_game_app(self.home, environment or {})

    def test_standard_library_without_configuration(self):
        app = make_app(self.steam)
        self.assertEqual(self.discover(), app.resolve())

    def test_external_library_spaces_unicode_and_quotes(self):
        library = self.root / 'External SSD Игры "Library"'
        app = make_app(library)
        self.libraries([self.steam, library])
        self.assertEqual(self.discover(), app.resolve())

    def test_legacy_numbered_paths(self):
        library = self.root / "Old Steam Library"
        app = make_app(library)
        self.libraries([library], legacy=True)
        self.assertEqual(self.discover(), app.resolve())

    def test_duplicate_symlink_library_is_not_ambiguous(self):
        app = make_app(self.steam)
        alias = self.root / "Same library"
        alias.symlink_to(self.steam, target_is_directory=True)
        self.libraries([self.steam, alias])
        self.assertEqual(self.discover(), app.resolve())

    def test_multiple_installations_require_explicit_choice(self):
        make_app(self.steam)
        external = self.root / "Other"
        app = make_app(external)
        self.libraries([external])
        with self.assertRaisesRegex(RuntimeError, "Several.*NR_CYBERPUNK_APP"):
            self.discover()
        self.assertEqual(self.discover({"NR_CYBERPUNK_APP": str(app)}), app.resolve())

    def test_explicit_override_does_not_require_valid_library_list(self):
        app = make_app(self.root / "Explicit")
        config = self.libraries([])
        config.write_text('"libraryfolders" { "0" "unfinished')
        self.assertEqual(self.discover({"NR_CYBERPUNK_APP": str(app)}), app.resolve())
        with self.assertRaisesRegex(RuntimeError, "libraryfolders.vdf"):
            self.discover()

    def test_missing_game_and_incomplete_or_relative_overrides(self):
        with self.assertRaisesRegex(RuntimeError, "was not found"):
            self.discover()
        with self.assertRaisesRegex(RuntimeError, "absolute path"):
            self.discover({"NR_CYBERPUNK_APP": "relative/Cyberpunk2077.app"})
        with self.assertRaisesRegex(RuntimeError, "complete native"):
            self.discover({"NR_CYBERPUNK_APP": str(self.root)})

    def test_malformed_tokens_are_rejected(self):
        for text in ('"libraryfolders" {}"', '"libraryfolders" {', '"libraryfolders" { "0" "relative" }'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                base.parse_library_folders(text)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = self.root = Path(self.temporary.name)
        self.app = make_app(root / "External library")
        self.runtime = root / "runtime"
        self.runtime.mkdir()
        self.module = self.runtime / "NeuralGame.dylib"
        self.module.write_bytes(b"fixture module")
        self.helper = self.runtime / "SteamAvailabilityProbe"
        self.helper.write_bytes(b"fixture helper - never executed")
        self.resource = self.runtime / "neural-resource"
        self.resource.write_bytes(b"fixture resource")
        self.manifest = self.runtime / "neural-game-build.json"
        self.manifest.write_text(json.dumps({"librarySHA256": sha(self.module.read_bytes()), "dependencies": {
            self.helper.name: sha(self.helper.read_bytes()), self.resource.name: sha(self.resource.read_bytes()),
        }}))
        verified = root / "verified-game.json"
        verified.write_text(json.dumps({"version": "2.5.0", "sha256": sha(b"verified native game")}))
        self.settings = root / "UserSettings.json"
        self.settings.write_text(json.dumps({"options": [{"name": "Resolution", "value": "2336x1460"}, {"name": "HDRModes", "value": "None"}]}))
        self.model = self.runtime / "models/NeuralRendering-HT.dlssmodel"
        self.model.mkdir(parents=True)
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.dict(os.environ, {}, clear=True))
        for module, name, value in (
            (base, "ROOT", self.runtime), (base, "VERIFIED_GAME", verified), (base, "STEAM_PROBE", self.helper),
            (neural, "ROOT", self.runtime), (neural, "MODULE", self.module), (neural, "MANIFEST", self.manifest),
            (neural, "ARTIFACTS", root / "artifacts"), (neural, "SETTINGS", self.settings), (neural, "MODEL", self.model),
        ):
            self.stack.enter_context(patch.object(module, name, value))
        self.discovery = self.stack.enter_context(patch.object(base, "discover_game_app", return_value=self.app))
        self.codesign = self.stack.enter_context(patch.object(base.subprocess, "run", return_value=SimpleNamespace(returncode=0)))
        self.stack.enter_context(patch.object(base.subprocess, "check_output", return_value="123 /Applications/Steam.app/steam_osx\n"))
        self.steam_check = self.stack.enter_context(patch.object(base, "check_steam_reachability"))
        self.spawn = self.stack.enter_context(patch.object(neural.subprocess, "Popen"))

    def run_preflight(self):
        return base.preflight(self.module, self.manifest)

    def test_custom_app_passes_all_existing_identity_checks(self):
        self.run_preflight()
        self.assertEqual(base.APP, self.app)
        self.assertEqual(base.EXE, self.app / "Contents/MacOS/Cyberpunk2077")
        self.assertEqual(base.STEAM_API, self.app / "Contents/Frameworks/libsteam_api.dylib")
        self.steam_check.assert_called_once()
        self.assertEqual(self.codesign.call_count, 2)
        self.spawn.assert_not_called()

    def test_unknown_game_hash_blocks_actual_launch_path(self):
        (self.app / "Contents/MacOS/Cyberpunk2077").write_bytes(b"unknown build")
        with patch.object(sys, "argv", ["launch_neural.py"]), self.assertRaisesRegex(RuntimeError, "executable has changed"):
            neural.main()
        self.codesign.assert_not_called()
        self.steam_check.assert_not_called()
        self.spawn.assert_not_called()

    def test_wrong_game_version_is_rejected(self):
        info = self.app / "Contents/Info.plist"
        content = plistlib.loads(info.read_bytes())
        content["CFBundleShortVersionString"] = "2.6.0"
        info.write_bytes(plistlib.dumps(content))
        with self.assertRaisesRegex(RuntimeError, "version differs"):
            self.run_preflight()
        self.steam_check.assert_not_called()
        self.spawn.assert_not_called()

    def test_bad_signature_is_rejected(self):
        self.codesign.return_value.returncode = 1
        with self.assertRaisesRegex(RuntimeError, "Signature verification failed"):
            self.run_preflight()
        self.steam_check.assert_not_called()
        self.spawn.assert_not_called()

    def test_changed_helper_is_rejected_before_any_helper_execution(self):
        self.helper.write_bytes(b"changed helper")
        with self.assertRaisesRegex(RuntimeError, "Runtime resource changed"):
            self.run_preflight()
        self.codesign.assert_not_called()
        self.steam_check.assert_not_called()
        self.spawn.assert_not_called()

    def test_helper_must_have_a_manifest_hash(self):
        content = json.loads(self.manifest.read_text())
        del content["dependencies"][self.helper.name]
        self.manifest.write_text(json.dumps(content))
        with self.assertRaisesRegex(RuntimeError, "not covered by the build manifest"):
            self.run_preflight()
        self.steam_check.assert_not_called()

    def test_resource_path_cannot_escape_runtime(self):
        content = json.loads(self.manifest.read_text())
        content["dependencies"]["../outside"] = "0" * 64
        self.manifest.write_text(json.dumps(content))
        with self.assertRaisesRegex(RuntimeError, "outside the runtime"):
            self.run_preflight()
        self.steam_check.assert_not_called()

    def test_missing_settings_explains_first_normal_launch(self):
        self.settings.unlink()
        with self.assertRaisesRegex(RuntimeError, "normally from Steam once"):
            neural.preflight()
        self.discovery.assert_not_called()
        self.spawn.assert_not_called()

    def test_invalid_settings_do_not_get_overwritten(self):
        self.settings.write_text("not JSON")
        with self.assertRaisesRegex(RuntimeError, "No settings were changed"):
            neural.preflight()
        self.assertEqual(self.settings.read_text(), "not JSON")
        self.spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
