#!/usr/bin/env python3
"""Version-locked, process-local HT experiment; no game/config modifications."""
import argparse
import datetime
import fcntl
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

# Imports must not create __pycache__ inside the signed application bundle.
sys.dont_write_bytecode = True
import launch_probe as base

ROOT = base.ROOT
ARTIFACTS = Path.home() / 'Library/Application Support/HTInGameLab'
MODULE = ROOT / ('NeuralGame.dylib' if base.BUNDLED_RUNTIME else 'integration/build/NeuralGame.dylib')
MANIFEST = ROOT / ('neural-game-build.json' if base.BUNDLED_RUNTIME else 'integration/build/neural-game-build.json')
BRIDGE = ROOT / ('neural/libNRNeuralBridge.dylib' if base.BUNDLED_RUNTIME else 'integration/neural/dist/libNRNeuralBridge.dylib')
MODEL = ROOT / 'models/NeuralRendering-HT.dlssmodel'
SETTINGS = Path.home() / 'Library/Application Support/CD Projekt Red/Cyberpunk 2077/UserSettings.json'


def setting(data, name):
    if isinstance(data, dict):
        if data.get('name') == name:
            return data.get('value')
        for value in data.values():
            answer = setting(value, name)
            if answer is not None:
                return answer
    elif isinstance(data, list):
        for value in data:
            answer = setting(value, name)
            if answer is not None:
                return answer
    return None


def preflight():
    try:
        config = json.loads(SETTINGS.read_text())
    except FileNotFoundError:
        raise RuntimeError('Cyberpunk settings were not found. Start the native game normally from Steam once, choose a resolution with HDR off, then fully quit and retry.') from None
    except (OSError, ValueError):
        raise RuntimeError('Cyberpunk settings could not be read. Start the game normally from Steam, check its graphics settings, fully quit, and retry. No settings were changed.') from None
    expected, build = base.preflight(MODULE, MANIFEST)
    names = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    if 'DLSS_5_APPLE_SILICON' in names:
        raise RuntimeError('Close the old DLSS 5 Lab before launching.')
    try:
        width, height = map(int, setting(config, 'Resolution').split('x'))
    except Exception:
        raise RuntimeError('Could not determine the Cyberpunk resolution.') from None
    if not (2 <= width <= 8192 and 2 <= height <= 8192):
        raise RuntimeError('This game resolution is not supported.')
    if not MODEL.is_dir():
        raise RuntimeError('The HT model package was not found.')
    return expected, build, width, height, setting(config, 'HDRModes')


def say(message):
    # A closed launcher pipe must not abandon an already started game.
    try:
        print(message, flush=True)
    except (BrokenPipeError, OSError):
        pass


def write_json(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def write_phase(handle, phase, pid=None):
    # Keep the inode: Swift and Python lock this same control file.
    handle.seek(0)
    handle.truncate()
    handle.write(json.dumps({'phase': phase, 'pid': pid}) + '\n')
    handle.flush()


def run_directory(argument):
    parent = (ARTIFACTS / 'runs').resolve()
    if argument:
        run = Path(argument).resolve()
        if run.parent != parent or not run.is_dir():
            raise RuntimeError('Invalid session directory.')
    else:
        name = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-ht-' + uuid.uuid4().hex[:8]
        run = parent / name
        run.mkdir(parents=True, exist_ok=False)
    return run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--run-directory')
    options = parser.parse_args()
    if options.check_only:
        _, _, width, height, hdr = preflight()
        say(f'Checks passed. {width}×{height}, HDR={hdr}. Enable HT manually after launch. The game was not started.')
        return 0

    # The UI allocates the directory/token before starting Python, so Stop
    # during expensive preflight always refers to this particular launch.
    run = run_directory(options.run_directory)
    disabled = run / 'disable-ht'
    control_path = run / 'launch.lock'
    if disabled.exists():
        say('Launch cancelled. The game was not started.')
        return 0
    expected, build, width, height, hdr = preflight()
    if disabled.exists():
        say('Launch cancelled. The game was not started.')
        return 0
    environment = os.environ.copy()
    environment.update(
        DYLD_INSERT_LIBRARIES=str(MODULE), SteamAppId='1091500', SteamGameId='1091500',
        NR_FRAME_GAME_MODE='ht-sdr-serial-experiment', NR_FRAME_HOOK_TEST='1', NR_FRAME_HOOK_SERIAL_COMMIT='1',
        NR_FRAME_GAME_BRIDGE=str(BRIDGE), NR_FRAME_GAME_MODEL=str(MODEL),
        NR_FRAME_GAME_WIDTH=str(width), NR_FRAME_GAME_HEIGHT=str(height), NR_FRAME_HOOK_DEADLINE_MS='500',
        NR_FRAME_GAME_LOG=str(run / 'neural.json'), NR_FRAME_GAME_STARTUP_LOG=str(run / 'startup.json'),
        NR_FRAME_HOOK_DISABLE_FILE=str(disabled), NR_FRAME_HOOK_ENABLE_FILE=str(run / 'enable-ht'),
        NR_FRAME_HOOK_SETTINGS_FILE=str(ARTIFACTS / 'settings.json'), NR_FRAME_GAME_CONTROLS='1')
    for key in ('NR_METAL_PROBE_TEST', 'NR_METAL_PROBE_LOG', 'NR_METAL_PROBE_DISABLE_FILE'):
        environment.pop(key, None)
    metadata = {
        'run': str(run), 'diagnostics': str(run / 'neural.json'), 'startup': str(run / 'startup.json'),
        'disableFile': str(disabled), 'enableFile': str(run / 'enable-ht'),
        'settingsFile': str(ARTIFACTS / 'settings.json'), 'panelShortcut': 'Comma physical key (during gameplay)', 'effectShortcut': 'Period physical key (during gameplay)',
        'width': width, 'height': height, 'configuredHDR': hdr,
        'gameSHA256': expected['sha256'], 'librarySHA256': build['librarySHA256'],
        'mode': 'HT Standard with live controls and resolution presets, explicit enable, SDR only, sequential submission, not NVIDIA DLSS',
        'gameExecutableModified': False, 'settingsModified': False}
    game = None
    result = 1
    try:
        with (run / 'game-output.log').open('x') as log:
            try:
                with control_path.open('a+') as control:
                    fcntl.flock(control, fcntl.LOCK_EX)
                    if disabled.exists():
                        write_phase(control, 'cancelled')
                        say('Launch cancelled. The game was not started.')
                        return 0
                    # Stop uses this lock. If spawning has started, the UI must
                    # not kill Python merely because a PID file is not present.
                    write_phase(control, 'spawning')
                    game = subprocess.Popen([str(base.EXE)], cwd=base.APP.parent, env=environment,
                                            stdout=log, stderr=subprocess.STDOUT)
                    write_phase(control, 'running', game.pid)
                    metadata['pid'] = game.pid
                    write_json(run / 'launch.json', metadata)
                    write_json(ARTIFACTS / 'current-neural-run.json', metadata)
                say('The game is running. HT is off. With HDR disabled, press period (.) to enable it. Settings panel: comma (,).')
            except Exception:
                if game is not None:
                    disabled.touch(exist_ok=True)
                raise
            finally:
                # Reporting failures and a closed UI pipe cannot orphan the game.
                if game is not None:
                    result = game.wait()
    finally:
        if game is not None:
            write_json(run / 'exit.json', {'exitCode': result})
    say('The game has closed. A normal launch from Steam does not load the HT module.')
    return result


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        say(str(error))
        sys.exit(1)
