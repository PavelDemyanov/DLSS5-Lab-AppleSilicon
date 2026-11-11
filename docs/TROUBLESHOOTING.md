# Troubleshooting

## Wrong launcher

Use **HT In-Game Lab**. A Russian-language window headed “Проверка игрового кадра Metal” or showing only a turquoise test-line button is the old probe, not the neural-processing launcher. The external screen-capture overlay is also not used here.

## Game not found

Keep Steam's `libraryfolders.vdf` up to date. The launcher searches the default library and the additional library paths recorded there. If there is more than one compatible installation, or the game is elsewhere, specify the intended app for this launch:

```sh
NR_CYBERPUNK_APP="/Volumes/Games/SteamLibrary/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app" \
  "$HOME/Library/Caches/DLSS5-Lab-AppleSilicon/HT In-Game Lab.app/Contents/MacOS/NeuralLauncher"
```

This does not bypass version, hash, signature, or Steam checks. Do not edit the compatibility hash to force an untested game build to run.

## No game settings / unknown resolution

Run the game normally through Steam once. Set resolution and turn HDR off, then quit normally so it writes settings. Start it again through the HT launcher. Changing the game's resolution while HT is attached is not supported; restart the game after such a change.

## Steam connection check fails

Save and quit Cyberpunk. Quit Steam completely, reopen it, sign in and wait for the library to become available, then try the launcher again. The launcher checks the game's Steam API in a separate helper before starting the game.

## No effect

HT starts off every time. Load a scene and press `.` without modifiers; press `,` to inspect the status. Check that HDR is off, intensity is nonzero, and processing is enabled. With comparison enabled, the original is on the left. The processing resolution controls model cost, not the game's render resolution.

After an emergency stop, restart the game. A normal `.` toggle is reversible. If an arrow cursor remains after switching apps, opening and closing the game's pause menu may restore normal pointer behavior.

## Low frame rate

Try 640 or 960 processing size. HT performs extra GPU work and the current frame path waits for the result. This experiment is not a frame-rate booster. Lowering a model control does not necessarily remove the inference cost; turn HT off to compare with the game's baseline.

## Build fails

Confirm full Xcode is selected, Swift is at least 6.2, and `xcrun --find metal`, `cmake --version`, `ninja --version`, and `/usr/bin/python3 --version` work. Dependency setup requires network access. Setup refuses to overwrite an existing checkout at a different revision; move it aside or review it yourself first.

The build creates its own cache and signs only the generated app and module. It never changes the game's signature, Gatekeeper, SIP, or other system protections. Do not disable system protections to make this experiment work.

## Remove the experiment

Quit the game, remove your local HT app, and launch the game normally through Steam. The module is not installed into the game. Optional local settings/logs remain under `~/Library/Application Support/HTInGameLab`; build files remain in the repository's ignored directories and `~/Library/Caches/DLSS5-Lab-AppleSilicon`.
