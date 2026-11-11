#!/bin/bash
# Fetch source code only. No model weights are downloaded.
set -euo pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
dependency_dir="$task_root/vendor/MLX-DLSS"
dependency_url='https://github.com/iamwavecut/MLX-DLSS.git'
dependency_revision='7870371e8bf6c03967213f1a5d40db6c5a3bee38'
check_only=false
case "${1:-}" in
  '') ;;
  --check) check_only=true ;;
  -h|--help) printf '%s\n' 'Usage: bash scripts/setup-dependencies.sh [--check]' 'Fetch the pinned MLX-DLSS source, or verify an existing clean checkout.'; exit 0 ;;
  *) printf '%s\n' 'Unknown option. Use --help.' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf '%s\n' 'Too many arguments.' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf '%s\n' 'Git is required. Install Xcode command-line tools first.' >&2; exit 1; }
verify_dependency() {
  [[ -d "$dependency_dir" && ! -L "$dependency_dir" ]] || {
    printf '%s\n' 'Expected a real vendor/MLX-DLSS checkout, not a symlink or file.' >&2; return 1;
  }
  local actual_root actual_revision
  actual_root=$(git -C "$dependency_dir" rev-parse --show-toplevel 2>/dev/null) || {
    printf '%s\n' 'vendor/MLX-DLSS is not a Git checkout. Nothing was changed.' >&2; return 1;
  }
  [[ "$actual_root" == "$dependency_dir" ]] || {
    printf '%s\n' 'vendor/MLX-DLSS must be its own checkout. Nothing was changed.' >&2; return 1;
  }
  actual_revision=$(git -C "$dependency_dir" rev-parse HEAD)
  [[ "$actual_revision" == "$dependency_revision" ]] || {
    printf 'Expected MLX-DLSS commit %s; found %s. Move this checkout aside or select the pinned commit yourself.\n' "$dependency_revision" "$actual_revision" >&2; return 1;
  }
  [[ -z "$(git -C "$dependency_dir" status --porcelain --untracked-files=normal)" ]] || {
    printf '%s\n' 'vendor/MLX-DLSS has local changes. They were preserved; use a clean pinned checkout to build.' >&2; return 1;
  }
}
if [[ -e "$dependency_dir" || -L "$dependency_dir" ]]; then
  verify_dependency
else
  if "$check_only"; then
    printf '%s\n' 'Dependency missing. Run: bash scripts/setup-dependencies.sh' >&2; exit 1;
  fi
  mkdir -p "$task_root/vendor"
  dependency_stage=$(mktemp -d "$task_root/vendor/.MLX-DLSS-fetch.XXXXXX")
  trap 'if [[ -n "${dependency_stage:-}" && -d "$dependency_stage" ]]; then rm -rf -- "$dependency_stage"; fi' EXIT
  git -C "$dependency_stage" init --quiet
  git -C "$dependency_stage" remote add origin "$dependency_url"
  git -C "$dependency_stage" fetch --depth 1 origin "$dependency_revision"
  git -C "$dependency_stage" -c advice.detachedHead=false checkout --detach "$dependency_revision"
  [[ ! -e "$dependency_dir" && ! -L "$dependency_dir" ]] || {
    printf '%s\n' 'vendor/MLX-DLSS appeared during setup. It was not replaced.' >&2; exit 1;
  }
  mv -- "$dependency_stage" "$dependency_dir"
  dependency_stage=''
  verify_dependency
fi
printf 'MLX-DLSS source ready at %s. No model weights were downloaded.\n' "$dependency_revision"
