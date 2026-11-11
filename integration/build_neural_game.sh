#!/bin/zsh
set -euo pipefail
task_dir=${0:A:h}
task_root=${task_dir:h}
for tool in python3 xcrun codesign xattr; do
  command -v "$tool" >/dev/null 2>&1 || { print -u2 "Missing build tool: $tool"; exit 1; }
done
[[ ! -L "$task_dir/build" ]] || { print -u2 'Refusing a symlinked integration/build directory.'; exit 1; }
mkdir -p "$task_dir/build"
python3 -B "$task_root/scripts/import-model.py" "$task_root/models/NeuralRendering-HT.dlssmodel" --check-only
for required in "$task_root/config/verified-game.json" "$task_root/LICENSE" "$task_root/NOTICE" \
  "$task_dir/neural/dist/libNRNeuralBridge.dylib" "$task_dir/neural/dist/mlx.metallib" \
  "$task_dir/neural/dist/NRNeuralBridge.h" \
  "$task_dir/neural/dist/NRNeuralBridgeResources.bundle/Contents/Resources/Shaders.metal"; do
  [[ -f "$required" ]] || { print -u2 "Required build input missing: $required"; exit 1; }
done
# Never use HTInGameLab's cache or the installed application. Build/sign a fresh
# bundle in this project's own local cache (Documents may add Finder metadata).
cache_root="$HOME/Library/Caches/DLSS5-Lab-AppleSilicon"
[[ ! -L "$cache_root" ]] || { print -u2 'Refusing a symlinked public staging cache.'; exit 1; }
mkdir -p "$cache_root"
final_app="$cache_root/HT In-Game Lab.app"
workspace_app="$task_dir/build/HT In-Game Lab.app"
[[ ! -L "$final_app" && ! -L "$workspace_app" ]] || { print -u2 'Refusing a symlinked staging application.'; exit 1; }
stage_parent=$(mktemp -d "$cache_root/.build.XXXXXX")
trap 'rm -rf -- "$stage_parent"' EXIT
ht_app="$stage_parent/HT In-Game Lab.app"
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -dynamiclib -arch arm64 -mmacosx-version-min=26.0 \
  -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics -framework CoreVideo \
  -framework AppKit -framework Carbon -framework CoreText \
  "$task_dir/NeuralFrameHook.mm" "$task_dir/NeuralGameEntry.mm" "$task_dir/InGameControls.mm" -o "$task_dir/build/NeuralGame.dylib"
codesign --force --sign - "$task_dir/build/NeuralGame.dylib"
xcrun clang -std=c11 -Wall -Wextra -arch arm64 -mmacosx-version-min=26.0 \
  "$task_dir/SteamAvailabilityProbe.c" -o "$task_dir/build/SteamAvailabilityProbe"
codesign --force --sign - "$task_dir/build/SteamAvailabilityProbe"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx26.0 \
  "$task_dir/NeuralLauncher.swift" -o "$task_dir/build/NeuralLauncher-staging"
python3 -B - "$task_root" "$ht_app" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, shutil, sys
root, app = map(Path, sys.argv[1:])
(app/'Contents/MacOS').mkdir(parents=True)
runtime = app/'Contents/Resources/runtime'
runtime.mkdir(parents=True)
shutil.copy2(root/'integration/build/NeuralLauncher-staging', app/'Contents/MacOS/NeuralLauncher')
for name in ('launch_neural.py', 'launch_probe.py'):
    shutil.copy2(root/'integration'/name, runtime/name)
for name in ('NeuralGame.dylib', 'SteamAvailabilityProbe'):
    shutil.copy2(root/'integration/build'/name, runtime/name)
(runtime/'neural').mkdir()
for name in ('libNRNeuralBridge.dylib', 'mlx.metallib', 'NRNeuralBridge.h'):
    shutil.copy2(root/'integration/neural/dist'/name, runtime/'neural'/name)
shutil.copytree(root/'integration/neural/dist/NRNeuralBridgeResources.bundle', runtime/'neural/NRNeuralBridgeResources.bundle')
model = root/'models/NeuralRendering-HT.dlssmodel'
if model.is_symlink() or any((model/name).is_symlink() for name in ('manifest.json', 'weights.safetensors')):
    raise SystemExit('Use the imported model package with regular files, not symlinks.')
model_target = runtime/'models/NeuralRendering-HT.dlssmodel'
model_target.mkdir(parents=True)
for name in ('manifest.json', 'weights.safetensors'):
    shutil.copy2(model/name, model_target/name)
(runtime/'audit').mkdir()
# The public source is portable config; the bundled loader retains its audit name.
shutil.copy2(root/'config/verified-game.json', runtime/'audit/installed-game.json')
licenses = runtime/'licenses'
licenses.mkdir()
for name in ('LICENSE', 'NOTICE'):
    shutil.copy2(root/name, licenses/name)
shutil.copytree(root/'third_party/licenses', licenses/'third_party')
if (root/'third_party/README.md').is_file():
    shutil.copy2(root/'third_party/README.md', licenses/'third_party/README.md')
def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024*1024), b''):
            result.update(chunk)
    return result.hexdigest()
paths = sorted(p for p in runtime.rglob('*') if p.is_file())
if any(p.is_symlink() for p in runtime.rglob('*')):
    raise SystemExit('Runtime must contain real copies, not workspace links.')
manifest = {'librarySHA256':sha(runtime/'NeuralGame.dylib'),
            'dependencies':{str(p.relative_to(runtime)):sha(p) for p in paths if p.name != 'NeuralGame.dylib'}}
assert 'SteamAvailabilityProbe' in manifest['dependencies']
(runtime/'neural-game-build.json').write_text(json.dumps(manifest, indent=2)+'\n')
(runtime/'runtime-manifest.json').write_text(json.dumps({
    'layoutVersion':1, 'selfContained':True, 'artifacts':'~/Library/Application Support/HTInGameLab',
    'gameFilesModified':False, 'enableRequired':True,
    'distribution':'Local build with user-supplied model; not a redistributable model release.'}, indent=2)+'\n')
source_inputs = [root/'integration/build/SteamAvailabilityProbe', root/'config/verified-game.json',
                 root/'integration/launch_neural.py', root/'integration/launch_probe.py']
source_inputs += [p for p in (root/'integration/neural/dist').rglob('*')
                  if p.is_file() and (p.name in ('libNRNeuralBridge.dylib', 'mlx.metallib', 'NRNeuralBridge.h')
                                     or 'NRNeuralBridgeResources.bundle' in p.parts)]
source_inputs += [model/'manifest.json', model/'weights.safetensors']
source_manifest = {'librarySHA256':sha(root/'integration/build/NeuralGame.dylib'),
                   'dependencies':{str(p.relative_to(root)):sha(p) for p in sorted(source_inputs)}}
assert 'integration/build/SteamAvailabilityProbe' in source_manifest['dependencies']
(root/'integration/build/neural-game-build.json').write_text(json.dumps(source_manifest, indent=2)+'\n')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'local.nr.ht-ingame', 'CFBundleName':'HT In-Game Lab',
    'CFBundleExecutable':'NeuralLauncher', 'CFBundlePackageType':'APPL',
    'CFBundleDevelopmentRegion':'en', 'CFBundleLocalizations':['en'],
    'CFBundleShortVersionString':'0.3.5', 'CFBundleVersion':'8', 'LSMinimumSystemVersion':'26.0'}))
print('Bundled runtime bytes:', sum(p.stat().st_size for p in runtime.rglob('*') if p.is_file()))
PY
xattr -cr "$ht_app"
codesign --force --sign - "$ht_app"
codesign --verify --strict "$ht_app"
# Replace only this project's generated staging copy, after signing succeeded.
python3 -B - "$ht_app" "$final_app" "$workspace_app" <<'PY'
from pathlib import Path
import shutil, sys, uuid
source, target, workspace = map(Path, sys.argv[1:])
if target.is_symlink() or workspace.is_symlink():
    raise SystemExit('Staging targets must not be symlinks.')
backup = target.parent/('.previous-'+uuid.uuid4().hex+'.app')
had_previous = target.exists()
if had_previous:
    target.rename(backup)
try:
    source.rename(target)
except BaseException:
    if had_previous:
        backup.rename(target)
    raise
if had_previous:
    shutil.rmtree(backup)
if workspace.exists():
    shutil.rmtree(workspace)
shutil.copytree(target, workspace, copy_function=shutil.copy)
PY
print "Signed staging application (not installed): $final_app"
print "Workspace staging copy: $workspace_app"
