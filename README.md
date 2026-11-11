# DLSS5-Lab-AppleSilicon — experimental

An independent HT neural-rendering experiment inside the **native macOS Steam version of Cyberpunk 2077**, using MLX and Metal on Apple Silicon.

**This is not an NVIDIA product or an official DLSS 5 SDK integration.** It uses a separately supplied HT model through an independent runtime. It does not implement the full DLSS feature set, super resolution or frame generation. The current experiment is expensive and can substantially **reduce** frame rate.

The repository contains source code only. **No model weights, NVIDIA libraries, game files, or ready-to-run app containing weights are provided.** You need your own compatible, prepared HT package under the terms that apply to it. A clone alone cannot enable the effect.

## Video demo

**[Watch the ON/OFF demo on YouTube (3:58)](https://youtu.be/_ECFX1ww3s0)**

Cyberpunk 2077 running natively on an Apple MacBook Pro with M4 Max, with experimental HT processing toggled on and off during gameplay. This is a visual comparison, not an FPS benchmark.

## What works

- Processing is composited into the game's Metal frame, with an optional original/processed split.
- A compact English settings panel sits in the lower-right corner and works during gameplay.
- Three controls: intensity, local tone, and structure.
- Processing sizes: 640, 960, 1280, 1600, or 1920 pixels on the long edge.
- Temporary deadline recovery preserves the selected settings; severe errors disable processing.
- The launcher injects the module into that game process only. It does not patch the game executable, change game settings, re-sign the game, or change system security settings. A normal Steam launch has no HT module.

## Compatibility

| Item | Requirement / tested scope |
| --- | --- |
| Mac | Apple Silicon; live testing on an M4 Max with 128 GB unified memory |
| macOS | Build target 26+; live testing on macOS 27.2. Other versions are not confirmed |
| Game | Native Steam release, version 2.5.0, bundle build 5814786, exact executable hash in [config/verified-game.json](config/verified-game.json) |
| Display mode | HDR **off**; tested at 2336×1460. Keep the game resolution fixed for the session |
| Model | Prepared HT 71-block `NeuralRendering.dlssmodel` package; Small is not connected to this integration |
| Build tools | Full Xcode with Swift 6.2+ and Metal tools, CMake 3.25+, Ninja, Git, Python 3.10+, and zsh |
| Runtime | Steam open and signed in; Apple's `/usr/bin/python3` available through developer tools |

The launcher rejects an unverified executable instead of trying a new game build. Different stores, Intel Macs, Windows versions under Wine/CrossOver, HDR, changing game resolution mid-session, and other injected mods are not supported by this release.

## Build and try it

Install the build tools first. For CMake and Ninja, Homebrew users can run `brew install cmake ninja`. Xcode must be selected as the active developer directory and its Metal compiler must be available (`xcrun --find metal`).

```sh
git clone https://github.com/PavelDemyanov/DLSS5-Lab-AppleSilicon.git
cd DLSS5-Lab-AppleSilicon
bash scripts/setup-dependencies.sh
```

Provide a prepared **HT** model package. The upstream [MLX-DLSS model documentation](https://github.com/iamwavecut/MLX-DLSS/tree/7870371e8bf6c03967213f1a5d40db6c5a3bee38#weights) describes supported user-supplied inputs. This project does not download libraries or weights. Source licenses do not grant rights to model weights; check the terms applicable to your inputs.

```sh
python3 scripts/import-model.py /path/to/NeuralRendering.dlssmodel
bash scripts/build.sh
```

The importer verifies the package checksum and HT architecture, then copies the package into the ignored `models/` directory. Build output is a locally signed app at:

```text
~/Library/Caches/DLSS5-Lab-AppleSilicon/HT In-Game Lab.app
```

This is a local build, not a Developer ID signed/notarized downloadable release. Do not redistribute an app containing the model. Copy the finished app to your Applications folder if desired, and open **HT In-Game Lab**. Quit the game and launcher before rebuilding or replacing the app. The old **DLSS In-Game Probe** and screen-capture **DLSS 5 Lab** are different prototypes and are not included here.

1. Launch Cyberpunk normally once, select the desired game resolution, turn HDR off, then save and quit the game. Leave Steam open.
2. Open **HT In-Game Lab** and click **Launch Cyberpunk**.
3. Load a save. HT starts **off**. Press `.` to enable it.
4. Press `,` to open the settings panel. Start with 640 or 960 for lower processing cost. Increase the resolution if the speed is acceptable.

The launcher discovers the normal Steam library and additional libraries listed by Steam. For an unusual installation, start the app executable with `NR_CYBERPUNK_APP` pointing to `Cyberpunk2077.app`. The exact version/hash checks still apply. See [troubleshooting](docs/TROUBLESHOOTING.md).

## Controls

| Key | Action |
| --- | --- |
| `,` | Show/hide settings |
| `.` | Toggle HT, including when the panel is closed |
| Tab / Shift+Tab or ↑ / ↓ | Select a row |
| ← / → | Adjust the selected setting |
| Shift + ← / → | Adjust in finer steps |
| Enter | Toggle the selected switch or cycle resolution |
| 1–5 | Select a preset when the resolution row is selected |
| Esc | Close the settings panel |
| Option + Command + 0 | Emergency stop; restart the game to re-enable HT |

Comma and period use physical keys, without Shift/Option/Command/Control. On a Russian layout these are the Б and Ю keys. The panel is keyboard-only; movement and mouse look remain available. Panel navigation keys are consumed while it is open.

## Performance and limits

This runs on the **Apple GPU through MLX/Metal**, not the Apple Neural Engine. Processing and the game share GPU resources. The current integration waits for processing of the same drawable, so model time can limit the game's frame rate and add latency.

Earlier standalone measurements on the M4 Max, with the game closed and a fixed 2336×1460 input, measured median HT processing times of about 105 ms at 1920, 79 ms at 1600, 58 ms at 1280, 40 ms at 960, and 26 ms at 640. These are **not game FPS**, a guarantee, or a comparison with NVIDIA hardware. See [validation](docs/VALIDATION.md).

The effect and controls were confirmed in a live game, including after a loading screen. Long-session stability and other machines are not established. A temporary 500 ms deadline can show original frames while recovery waits for a fresh compatible frame. GPU errors and emergency stops require a game restart. Synthetic tests do not replace live compatibility testing.

## Development

```sh
python3 -m unittest discover -s tests -v
# On a Mac with the build tools (no model or game required):
bash scripts/test-native.sh
# After staging the intended files:
python3 scripts/audit-public-tree.py
```

Sources are in `integration/`. `NeuralFrameHook.mm` owns frame submission/recovery, `InGameControls.mm` draws the panel, `NeuralLauncher.swift` supplies the app UI, and `integration/neural/` provides the Swift/MLX bridge. Dependencies are pinned; generated upstream adaptations are checked in and described in `source-manifest.json`.

Logs and settings are local to `~/Library/Application Support/HTInGameLab`. They may contain local paths and game output; review and redact them before attaching them to an issue. Do not upload game files, model packages, or saves.

## License and acknowledgments

Original integration code: [MIT](LICENSE). Adapted rendering code comes from [dlss5-macos-overlay](https://github.com/gtrg55/dlss5-macos-overlay) and its NeuralScreen lineage (MIT). Inference uses [MLX-DLSS](https://github.com/iamwavecut/MLX-DLSS) (Apache-2.0) and [MLX Swift](https://github.com/ml-explore/mlx-swift) (MIT). See [NOTICE](NOTICE) and [third-party details](third_party/README.md). Model weights and game assets are not covered by these source-code licenses.
