#!/bin/zsh
set -euo pipefail
task_dir=${0:A:h}
task_root=${task_dir:h}
package="$task_dir/neural"
scratch="$package/.build"
build_jobs="${NR_BUILD_JOBS:-6}"
[[ "$build_jobs" == <1-> ]] || { print -u2 'NR_BUILD_JOBS must be a positive integer.'; exit 2; }
for tool in git python3 swift cmake ninja xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { print -u2 "Missing build tool: $tool"; exit 1; }
done
bash "$task_root/scripts/setup-dependencies.sh" --check
[[ ! -L "$scratch" ]] || { print -u2 'Refusing a symlinked neural/.build directory; use a separate public checkout build.'; exit 1; }
# Sources and shaders here are canonical: no original workspace or overlay build.
python3 - "$package/Package.resolved" <<'PY'
import json, sys
pins = {p['identity']: p['state'] for p in json.load(open(sys.argv[1]))['pins']}
expected = {'version': '0.31.6', 'revision': '0bb916c67f4b9e5c682cbe02a42c701c93ab5021'}
if pins.get('mlx-swift') != expected:
    raise SystemExit('Package.resolved must retain the audited mlx-swift 0.31.6 pin.')
PY
swift package --package-path "$package" --scratch-path "$scratch" --force-resolved-versions resolve
mlx_checkout="$scratch/checkouts/mlx-swift"
python3 - "$package" "$mlx_checkout" <<'PY'
from pathlib import Path
import subprocess, sys
package, checkout = map(Path, sys.argv[1:])
try:
    checkout.resolve(strict=True).relative_to(package.resolve())
except (ValueError, FileNotFoundError):
    raise SystemExit('The MLX checkout must be inside this public neural package.')
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
dirty = subprocess.check_output(['git', '-C', str(checkout), 'status', '--porcelain'], text=True)
if revision != '0bb916c67f4b9e5c682cbe02a42c701c93ab5021' or dirty:
    raise SystemExit('The mlx-swift checkout must be clean and pinned to 0.31.6. Nothing was reset.')
PY
metal_build="$scratch/mlx-metallib"
metallib="$metal_build/kernels/mlx.metallib"
mkdir -p "$metal_build/kernels"
cmake -S "$mlx_checkout/Source/Cmlx/mlx" -B "$metal_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF -DMLX_BUILD_BENCHMARKS=OFF \
  -DMLX_BUILD_PYTHON_BINDINGS=OFF -DMLX_BUILD_PYTHON_STUBS=OFF \
  -DMLX_BUILD_CPU=OFF -DMLX_BUILD_CUDA=OFF -DMLX_BUILD_METAL=ON \
  -DMLX_BUILD_GGUF=OFF -DMLX_BUILD_SAFETENSORS=OFF -DMLX_METAL_JIT=OFF \
  -DMLX_METAL_PATH="$metal_build/kernels"
cmake --build "$metal_build" --target mlx-metallib --parallel "$build_jobs"
[[ -s "$metallib" ]] || { print -u2 'The MLX Metal library was not produced.'; exit 1; }
swift build --package-path "$package" --scratch-path "$scratch" --force-resolved-versions \
  -c release --product NRNeuralBridge --jobs "$build_jobs"
bin_dir=$(swift build --package-path "$package" --scratch-path "$scratch" -c release --show-bin-path)
dist="$package/dist"
mkdir -p "$dist/NRNeuralBridgeResources.bundle/Contents/Resources"
cp "$bin_dir/libNRNeuralBridge.dylib" "$dist/libNRNeuralBridge.dylib"
cp "$metallib" "$dist/mlx.metallib"
cp "$package/Resources/Shaders.metal" "$dist/NRNeuralBridgeResources.bundle/Contents/Resources/Shaders.metal"
cp "$package/Sources/NRNeuralABI/include/NRNeuralBridge.h" "$dist/NRNeuralBridge.h"
python3 - "$package" "$dist" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, sys
package, dist = map(Path, sys.argv[1:])
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
(dist/'NRNeuralBridgeResources.bundle/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'local.nr.neural-bridge.resources', 'CFBundleName':'NRNeuralBridgeResources',
    'CFBundlePackageType':'BNDL', 'CFBundleVersion':'1'}))
sources = [p for directory in ('Sources', 'Resources') for p in (package/directory).rglob('*') if p.is_file()]
sources += [package/'Package.swift', package/'Package.resolved']
(dist/'build.json').write_text(json.dumps({
    'sha256':{name:sha(dist/name) for name in ('libNRNeuralBridge.dylib', 'mlx.metallib')},
    'mlxSwiftVersion':'0.31.6', 'metallibSource':'.build/checkouts/mlx-swift/Source/Cmlx/mlx',
    'canonicalSources':{str(p.relative_to(package)):sha(p) for p in sorted(sources)},
    'scope':'SDR bridge built from this repository; no original workspace or overlay build required.'}, indent=2)+'\n')
PY
xcrun clang++ -std=c++17 -fobjc-arc -arch arm64 -mmacosx-version-min=26.0 \
  -framework Foundation -framework CoreVideo -framework CoreGraphics -framework CoreImage -framework ImageIO \
  -I "$package/Sources/NRNeuralABI/include" "$package/OfflineHarness.mm" -o "$dist/NeuralOfflineHarness"
print "Neural bridge and offline harness: $dist"
