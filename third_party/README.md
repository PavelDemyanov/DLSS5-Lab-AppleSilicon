# Third-party source provenance

| Component | Pinned source | License |
| --- | --- | --- |
| Overlay rendering lineage | [gtrg55/dlss5-macos-overlay](https://github.com/gtrg55/dlss5-macos-overlay/tree/0d4caa1fd36d2581785efa80e6ade09983a18f05) | MIT, including NeuralScreen attribution |
| Inference runtime | [iamwavecut/MLX-DLSS](https://github.com/iamwavecut/MLX-DLSS/tree/7870371e8bf6c03967213f1a5d40db6c5a3bee38) | Apache-2.0; fetched by setup |
| MLX Swift | 0.31.6 / `0bb916c67f4b9e5c682cbe02a42c701c93ab5021` | MIT |
| Swift Numerics | 1.1.1 / `0c0290ff6b24942dadb83a929ffaaa1481df04a2` | Apache-2.0 with Swift Runtime Library Exception |
| Swift Argument Parser | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Apache-2.0 with Swift Runtime Library Exception |

License texts are in [licenses](licenses). Swift dependencies are pinned by `integration/neural/Package.resolved`.

The checked-in `RenderEngine.swift` adaptation preserves GPU resources on parameter/history changes and adds stage timings. `MetalFrames.swift`, `Shaders.metal`, and `RenderSettings.swift` retain the recorded upstream content. `FrameFreshness.swift` was local integration work, not a file in the pinned overlay commit. Exact file hashes and changes are recorded in `integration/neural/source-manifest.json`.

The upstream NeuralScreen license file includes a note about a DLL in that upstream distribution. **That DLL is not included in this repository.** The MIT source license does not apply to it.

No weights, NVIDIA DLLs, game files, disassembly, private captures, or extraction tools are copied into this repository. MLX-DLSS is fetched as a separate pinned upstream dependency. Its source license and publication notes do not grant rights to separately supplied model weights. See its [NOTICE](https://github.com/iamwavecut/MLX-DLSS/blob/7870371e8bf6c03967213f1a5d40db6c5a3bee38/NOTICE) and [publication notes](https://github.com/iamwavecut/MLX-DLSS/blob/7870371e8bf6c03967213f1a5d40db6c5a3bee38/PUBLICATION.md).

A future binary distributor must account for the licenses/notices of the exact MLX/MLX-C, metal-cpp, JSON, fmt, pocketfft and other resolved native dependencies as well. This repository does not offer a redistributable binary release.
