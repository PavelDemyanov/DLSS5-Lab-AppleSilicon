# Validation scope

The initial public source snapshot derives from the English 0.3.4 app and the 0.3.3 recovery core. Public packaging is version 0.3.5. Its game-discovery and build-path changes are tested separately from the previously tested frame hook.

## Initial public 0.3.5 package

The documented dependency setup and full build completed from the isolated public source tree, using freshly resolved pinned source checkouts rather than the previous experiment's compiled libraries. SwiftPM reused its ordinary source-download cache where available; native outputs were rebuilt.

- 18 Python tests passed, including library discovery, rejection before helper/game execution, and model validation.
- Native queue/toggle/recovery tests passed; UI harness passed with 12 requests, four encoded frames and no rendering errors.
- The staged 0.3.5 / build 8 app passed strict code-signature verification and bundled preflight from a different working directory. No game was started.
- Real HT processing from the bundled runtime passed on a synthetic SDR image: five repeated frames, unchanged original half, changed processed half, retained-output stability, and rejection of duplicate timestamps, busy submissions, and PQ input. The supplied model stayed local and is not published.

The frame-hook and panel sources are unchanged from the tested English 0.3.4 snapshot. The public packaging update was not re-tested in a new live game session; the live evidence below applies to the earlier local builds.

## Previously observed on the development Mac

- Native Steam Cyberpunk 2077 2.5.0 / build 5814786, macOS 27.2, M4 Max, 128 GB, SDR at 2336×1460.
- User confirmed visible in-process HT, keyboard adjustment during gameplay, compact panel, both physical punctuation shortcuts, and continued effect/settings after a loading screen.
- The loading-screen confirmation did not trigger the forced-recovery path; its counter remained zero. Recovery was tested separately using an artificial producer delay.
- Real HT harness: a 650 ms producer-commit delay caused original-frame draining and recovery, followed by processed frames. Original half remained bit-exact; presentation order and all three present variants were checked.
- Queue/callback tests covered late inference, abandoned probes, old callbacks, preserved user Off/settings, and permanent failure on GPU/bridge errors.
- English panel harness: 12 requests, four rendered frames, zero render errors. The preview used synthetic content rather than a game capture.

## Standalone processing timings

One fixed 2336×1460 input, game closed, three warm-ups and 20 measured frames per size on M4 Max:

| Processing size | Median ms | p95 ms |
| --- | ---: | ---: |
| 1920×1200 | 104.88 | 109.20 |
| 1600×1000 | 78.55 | 78.86 |
| 1280×800 | 57.56 | 59.24 |
| 960×600 | 40.06 | 40.56 |
| 640×400 | 25.79 | 26.55 |

These are historical standalone HT measurements. They do not measure live game FPS, display latency, or speedups, and have not been reproduced on other Macs. No NVIDIA output-parity claim is made.

## Reproducible checks in this repository

Python tests exercise launcher discovery, strict rejection and model-input checks without starting the game. `scripts/test-native.sh` compiles and runs the keyboard/UI and CPU queue/recovery harnesses without a model. Native compilation requires the listed Mac development tools; UI rendering requires a Metal device.

Local app builds include a model, but public source releases do not. Full inference tests require the tester's own model. Long-session stability and compatibility with a different game hash remain unverified.
