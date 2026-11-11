#!/usr/bin/env python3
"""Shared HT launcher discovery, integrity and Steam connection checks.

This module never launches the game or changes game files/settings. Its legacy
filename is retained for the bundled launch_neural.py import.
"""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import subprocess

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
BUNDLED_RUNTIME = (SCRIPT_DIRECTORY / "runtime-manifest.json").is_file()
ROOT = SCRIPT_DIRECTORY if BUNDLED_RUNTIME else SCRIPT_DIRECTORY.parent
# Immutable compatibility and runtime inputs; no session files are written here.
VERIFIED_GAME = ROOT / ("audit/installed-game.json" if BUNDLED_RUNTIME else "config/verified-game.json")
APP = EXE = STEAM_API = None  # Resolved and verified by preflight, never on import.
STEAM_PROBE = ROOT / "SteamAvailabilityProbe" if BUNDLED_RUNTIME else ROOT / "integration/build/SteamAvailabilityProbe"
STEAM_PROBE_TIMEOUT = 8


def parse_library_folders(text):
    """Read Valve's quoted KeyValues, including legacy numbered path entries."""
    if len(text) > 1024 * 1024:
        raise ValueError("Steam library list is too large")
    tokens = []
    end = 0
    for match in re.finditer(r'\s+|//[^\n]*|"((?:\\.|[^"\\])*)"|([{}])|([^\s{}"]+)', text):
        if match.start() != end:
            raise ValueError("Invalid Steam library list token")
        end = match.end()
        raw, brace, bare = match.groups()
        if raw is not None:
            tokens.append(("text", re.sub(r'\\(["\\])', r'\1', raw)))
        elif brace:
            tokens.append((brace, brace))
        elif bare:
            tokens.append(("text", bare))
    if end != len(text):
        raise ValueError("Invalid Steam library list token")
    index = 0

    def object_value(nested=False, depth=0):
        nonlocal index
        if depth > 16:
            raise ValueError("Steam library list nesting is too deep")
        result = {}
        while index < len(tokens):
            kind, key = tokens[index]
            index += 1
            if kind == "}" and nested:
                return result
            if kind != "text" or index >= len(tokens):
                raise ValueError("Invalid Steam library list")
            kind, value = tokens[index]
            index += 1
            if kind == "{":
                result[key] = object_value(True, depth + 1)
            elif kind == "text":
                result[key] = value
            else:
                raise ValueError("Invalid Steam library path")
        if nested:
            raise ValueError("Unclosed Steam library list")
        return result

    document = object_value()
    folders = next((value for key, value in document.items() if key.lower() == "libraryfolders"), None)
    if not isinstance(folders, dict):
        raise ValueError("Missing libraryfolders object")
    paths = []
    for key, value in folders.items():
        if not key.isdecimal():
            continue
        path = value.get("path") if isinstance(value, dict) else value
        if not isinstance(path, str) or not Path(path).is_absolute():
            raise ValueError("Steam library paths must be absolute")
        paths.append(Path(path))
    return paths


def discover_game_app(home=None, environment=None):
    """Discover native Steam installs; an explicit override never bypasses validation."""
    home = Path.home() if home is None else Path(home)
    environment = os.environ if environment is None else environment
    override = environment.get("NR_CYBERPUNK_APP")
    if override:
        app = Path(override).expanduser()
        if not app.is_absolute():
            raise RuntimeError("NR_CYBERPUNK_APP must be an absolute path to Cyberpunk2077.app.")
        app = app.resolve()
        if not app.is_dir() or not (app / "Contents/Info.plist").is_file() or not (app / "Contents/MacOS/Cyberpunk2077").is_file():
            raise RuntimeError("NR_CYBERPUNK_APP does not point to a complete native Cyberpunk2077.app. Check the path or verify the game in Steam.")
        return app
    steam = home / "Library/Application Support/Steam"
    libraries = [steam]
    folders = steam / "steamapps/libraryfolders.vdf"
    if folders.exists():
        try:
            libraries.extend(parse_library_folders(folders.read_text(encoding="utf-8-sig")))
        except (OSError, UnicodeError, ValueError) as error:
            raise RuntimeError("Could not read Steam's libraryfolders.vdf. Reopen Steam to refresh its libraries, or set NR_CYBERPUNK_APP to the full native .app path.") from error
    candidates = set()
    for library in libraries:
        app = library / "steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"
        if app.is_dir() and (app / "Contents/Info.plist").is_file() and (app / "Contents/MacOS/Cyberpunk2077").is_file():
            candidates.add(app.resolve())
    if not candidates:
        raise RuntimeError("Native Cyberpunk 2077 was not found in the Steam libraries. Install its macOS version, or set NR_CYBERPUNK_APP to the full Cyberpunk2077.app path.")
    if len(candidates) != 1:
        choices = "\n".join(str(path) for path in sorted(candidates))
        raise RuntimeError("Several native Cyberpunk installations were found. Set NR_CYBERPUNK_APP to the one to use:\n" + choices)
    return candidates.pop()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def check_steam_reachability():
    # A running process is not sufficient: query the game's own Steam API using
    # a separate helper, without initializing Steam or loading the game/probe.
    try:
        result = subprocess.run(
            [str(STEAM_PROBE), str(STEAM_API)],
            capture_output=True, text=True, timeout=STEAM_PROBE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(
            "Steam did not respond within 8 seconds. Quit Steam completely, reopen it, "
            "and try again. The game was not started."
        ) from None
    except OSError:
        raise RuntimeError(
            "Could not start the Steam connection check. "
            "Rebuild the launcher. The game was not started."
        ) from None
    if result.returncode == 1:
        raise RuntimeError(
            "Steam is open, but the game cannot connect to it. Quit Steam completely, "
            "reopen it, and try again. The game was not started."
        )
    try:
        reachable = json.loads(result.stdout).get("steamAPIReachable") is True
    except (ValueError, AttributeError):
        reachable = False
    if result.returncode != 0 or not reachable:
        raise RuntimeError(
            "The Steam connection check failed. "
            "Game launch was cancelled. Check the launcher installation."
        )


def preflight(library, build_manifest):
    global APP, EXE, STEAM_API
    library, build_manifest = Path(library), Path(build_manifest)
    expected = json.loads(VERIFIED_GAME.read_text())
    build = json.loads(build_manifest.read_text())
    APP = discover_game_app()
    EXE = APP / "Contents/MacOS/Cyberpunk2077"
    STEAM_API = APP / "Contents/Frameworks/libsteam_api.dylib"
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.cdprojektred.cyberpunk.steam" or info.get("CFBundleShortVersionString") != "2.5.0":
        raise RuntimeError("The game version differs from the verified version 2.5.0. A new compatibility check is required.")
    if digest(EXE) != expected["sha256"]:
        raise RuntimeError("The game executable has changed. Launch was cancelled until the new build is verified.")
    if digest(library) != build["librarySHA256"]:
        raise RuntimeError("The module changed after the build. Rebuild it before launching.")
    # Verify runtime inputs before executing a bundled helper or loading its
    # Steam library. Hashes detect build drift; they are not a trust authority.
    verified_resources = set()
    for relative, sha in build.get("dependencies", {}).items():
        path = (ROOT / relative).resolve()
        if not path.is_relative_to(ROOT.resolve()):
            raise RuntimeError("Invalid build manifest: a resource lies outside the runtime directory.")
        if not path.is_file() or digest(path) != sha:
            raise RuntimeError("Runtime resource changed or is missing: " + relative + ". Rebuild the app.")
        verified_resources.add(path)
    if STEAM_PROBE.resolve() not in verified_resources:
        raise RuntimeError("The Steam helper is not covered by the build manifest. Rebuild the launcher before running it.")
    for target in (APP, library):
        checked = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(target)], capture_output=True, text=True)
        if checked.returncode:
            raise RuntimeError("Signature verification failed: " + target.name)
    if os.environ.get("DYLD_INSERT_LIBRARIES"):
        raise RuntimeError("Another injected module is already configured. Running them together has not been verified.")
    processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True)
    names = [row.strip().split(None, 1)[1] for row in processes.splitlines() if len(row.strip().split(None, 1)) == 2]
    if str(EXE) in names:
        raise RuntimeError("Save your progress and fully exit Cyberpunk before launching.")
    if not any(Path(name).name == "steam_osx" for name in names):
        raise RuntimeError("Open Steam and sign in to your account first.")
    check_steam_reachability()
    return expected, build


if __name__ == "__main__":
    print("Use HT In-Game Lab or launch_neural.py; this file only supplies shared checks.")
    raise SystemExit(2)
