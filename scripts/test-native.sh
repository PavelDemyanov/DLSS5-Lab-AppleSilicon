#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$task_root/build/native-tests"
mkdir -p "$test_output"
common=(-std=c++17 -fobjc-arc -arch arm64 -mmacosx-version-min=26.0
  -framework Foundation -framework Metal -framework QuartzCore
  -framework CoreGraphics -framework CoreVideo -framework ImageIO)
xcrun clang++ "${common[@]}" -DNR_FRAME_HOOK_QUEUE_TEST=1 \
  "$task_root/integration/NeuralHookHarness.mm" -o "$test_output/QueueHarness"
"$test_output/QueueHarness" --toggle-queue
"$test_output/QueueHarness" --recovery-queue
"$test_output/QueueHarness" --recovery-callbacks
xcrun clang++ "${common[@]}" -framework AppKit -framework Carbon -framework CoreText \
  "$task_root/integration/InGameControls.mm" "$task_root/integration/InGameControlsHarness.mm" \
  -o "$test_output/ControlsHarness"
"$test_output/ControlsHarness" "$test_output"
printf 'Native queue, recovery and UI checks passed. Output: %s\n' "$test_output"
