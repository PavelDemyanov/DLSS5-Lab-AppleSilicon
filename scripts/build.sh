#!/bin/bash
# Build a local staging app; never install it or launch the game.
set -euo pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case "${1:-}" in
  '') ;;
  -h|--help) printf '%s\n' 'Usage: bash scripts/build.sh' 'Requires Apple Silicon, macOS 26+, Xcode/Metal tools, Swift 6.2+, Python 3, CMake 3.25+, Ninja, and an imported HT package.' 'Optional: NR_BUILD_JOBS (positive integer; default 6).'; exit 0 ;;
  *) printf '%s\n' 'Unknown option. Use --help.' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf '%s\n' 'Too many arguments.' >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf '%s\n' 'Build on an Apple Silicon Mac in a native arm64 shell (not Rosetta).' >&2; exit 1;
}
for tool in git python3 cmake ninja xcrun swift codesign xattr zsh sw_vers; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing build tool: %s. Install it, then run this script again.\n' "$tool" >&2; exit 1;
  }
done
for tool in clang clang++ swiftc metal metallib; do
  xcrun --find "$tool" >/dev/null 2>&1 || {
    printf 'Xcode tool %s is unavailable. Select a complete Xcode installation and install its Metal toolchain.\n' "$tool" >&2; exit 1;
  }
done
python3 - <<'PY'
import re, subprocess
def version(command):
    pattern = r'(?:Apple )?Swift version\s+(\d+)\.(\d+)' if command[0] == 'swift' else r'(\d+)\.(\d+)'
    match = re.search(pattern, subprocess.check_output(command, text=True), re.IGNORECASE)
    if not match:
        raise SystemExit('Could not determine version: ' + ' '.join(command))
    return tuple(map(int, match.groups()))
for command, minimum, name in [(['sw_vers', '-productVersion'], (26, 0), 'macOS 26'),
                              (['swift', '--version'], (6, 2), 'Swift 6.2'),
                              (['cmake', '--version'], (3, 25), 'CMake 3.25')]:
    if version(command) < minimum:
        raise SystemExit(name + ' or newer is required.')
PY
[[ "${NR_BUILD_JOBS:-6}" =~ ^[1-9][0-9]*$ ]] || {
  printf '%s\n' 'NR_BUILD_JOBS must be a positive integer.' >&2; exit 2;
}
bash "$task_root/scripts/setup-dependencies.sh" --check
model_dir="$task_root/models/NeuralRendering-HT.dlssmodel"
[[ -d "$model_dir" && ! -L "$model_dir" ]] || {
  printf '%s\n' 'Import your own HT package first: python3 scripts/import-model.py /path/to/NeuralRendering.dlssmodel' >&2; exit 1;
}
python3 -B "$task_root/scripts/import-model.py" "$model_dir" --check-only
zsh "$task_root/integration/build_neural.sh"
zsh "$task_root/integration/build_neural_game.sh"
printf '%s\n' 'Build complete. The staging app was not installed and the game was not launched.'
