#ifndef NR_NEURAL_FRAME_HOOK_H
#define NR_NEURAL_FRAME_HOOK_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Experimental hook core. Start requires NR_FRAME_HOOK_TEST=1; the separate
// game entry point additionally validates its host/version and explicit gate.
typedef void (*NRFrameHookReadyCallback)(int32_t status, const char *error, void *context);
typedef void (*NRFrameHookObserver)(void *commandBuffer, void *texture,
    uint64_t sequence, int32_t processed, void *context);

typedef struct NRFrameHookCounters {
    uint64_t accepted;
    uint64_t processed;
    uint64_t bypassed;
    uint64_t expired;
    uint64_t late;
    uint64_t errors;
    uint64_t pending;
    uint64_t peakPending;
    uint64_t finalCompleted;
    uint64_t unsupported;
    int32_t installed;
    int32_t disabled;
} NRFrameHookCounters;

typedef struct NRFrameHookSettings {
    float intensity, tone, structure, split;
    uint32_t processingLongEdge; // 640, 960, 1280, 1600 or 1920.
    int32_t enabled; // Reversible user choice, separate from permanent fault.
} NRFrameHookSettings;

typedef struct NRFrameHookTimings {
    double totalMilliseconds, producerMilliseconds, conversionMilliseconds;
    double bridgeMilliseconds, finalMilliseconds;
    double producerGPUMilliseconds, conversionGPUMilliseconds, finalGPUMilliseconds;
    double resizeMilliseconds, motionMilliseconds, inferenceMilliseconds;
    double writeMilliseconds, compositeMilliseconds;
} NRFrameHookTimings;

typedef struct NRFrameHookSnapshot {
    uint32_t abiVersion; // 2; append-only fields require a matching compiled client.
    NRFrameHookSettings requested, applied;
    NRFrameHookCounters counters;
    uint64_t requestedRevision, appliedRevision;
    int32_t armed, faulted, warming, settingsPending, surfaceSupported;
    double processedFPS, presentFPS; // Hook submissions, not physical display FPS.
    NRFrameHookTimings timings; // Rolling mean of completed processed frames.
    uint32_t processingWidth, processingHeight;
    char status[192]; // UTF-8, always NUL-terminated.
    int32_t recovering; // Temporary timing pause; requested enabled is preserved.
    uint64_t recoveryCount;
} NRFrameHookSnapshot;

// Queue/coalesce a complete settings snapshot. Values must be finite and in
// range. Applied only after outstanding frames drain; a resolution change
// warms privately while the game presents originals. Returns NR_NEURAL_*.
int32_t NRFrameHookSetSettings(const NRFrameHookSettings *settings);
// Update numeric controls/resolution only. The input enabled field is ignored;
// the latest queued requested.enabled is preserved atomically, so a slider
// edit cannot undo a queued toggle. Other validation matches SetSettings.
int32_t NRFrameHookSetParameters(const NRFrameHookSettings *settings);
// Atomically invert the latest requested enabled value on the hook queue,
// preserving all other requested controls. OK means queued, not already
// applied. A deferred SDR rejection keeps HT off and updates snapshot.status;
// permanent faults remain non-recoverable. Never waits on the GPU or queue.
int32_t NRFrameHookToggleEnabled(void);
// Fast mutex-protected snapshot; never synchronously dispatches or waits on GPU.
void NRFrameHookCopySnapshot(NRFrameHookSnapshot *snapshot);

typedef void (*NRFrameHookOverlayCallback)(void *commandBuffer, void *drawable, void *context);
// Encodes UI into the same drawable AFTER HT, or before original presentation
// while HT is off/warming. Callback must be thread-safe and must not commit,
// present, wait, throw, or recursively request a new frame.
void NRFrameHookSetOverlayRenderer(NRFrameHookOverlayCallback callback, void *context);

// All paths must be absolute. OK (0) means one asynchronous callback follows.
// The callback is delivered only after model loading, an actual warmup at the
// requested full-frame size, and hook installation. Error text is borrowed.
// Warmup geometry is the only accepted geometry in this first candidate.
// Optional NR_FRAME_HOOK_DEADLINE_MS: 50..1000, default 500.
// Optional NR_FRAME_HOOK_DISABLE_FILE: absolute path; existence disables.
// Optional NR_FRAME_HOOK_ENABLE_FILE: start unarmed/off; explicit file or UI
// enable activates only after observing a supported SDR game surface.
// Optional NR_FRAME_HOOK_SETTINGS_FILE: absolute path, validated parameters
// restored before warmup and saved atomically; activation is never persisted.
// Optional NR_FRAME_HOOK_SERIAL_COMMIT=1: experimental producer backpressure.
// A tracked producer's commit waits at most 500 ms AFTER original commit. This
// caps a single present/commit loop, not arbitrary concurrent producers.
int32_t NRFrameHookStartForTesting(const char *bridgePath, const char *modelPath,
    const char *diagnosticPath, uint32_t warmupWidth, uint32_t warmupHeight,
    NRFrameHookReadyCallback callback, void *context);

// Permanent disable: queued frames drain in order as originals. Rendering/
// inference failures and unsupported layer changes also disable permanently.
// Timing stalls instead drain, wait for a fresh completed SDR original frame,
// reset history while idle, and resume according to the current user settings.
void NRFrameHookDisableForTesting(void);
void NRFrameHookCopyCountersForTesting(NRFrameHookCounters *output);

// Test instrumentation, set before Start. Called on the serial state queue with
// an uncommitted final command buffer after the effect is encoded. It may append
// a readback/completion handler. It must not commit, present, wait, or throw.
void NRFrameHookSetObserverForTesting(NRFrameHookObserver observer, void *context);

#ifdef __cplusplus
}
#endif
#endif
