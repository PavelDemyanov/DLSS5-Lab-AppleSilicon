#ifndef NR_NEURAL_BRIDGE_H
#define NR_NEURAL_BRIDGE_H
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    NR_NEURAL_OK = 0,
    NR_NEURAL_BUSY = 1,
    NR_NEURAL_INVALID_ARGUMENT = 2,
    NR_NEURAL_NOT_READY = 3,
    NR_NEURAL_CANCELLED = 4,
    NR_NEURAL_FAILED = 5,
    NR_NEURAL_STALE = 6
};
enum {
    NR_NEURAL_UNINITIALIZED = 0,
    NR_NEURAL_LOADING = 1,
    NR_NEURAL_READY = 2,
    NR_NEURAL_PROCESSING = 3,
    NR_NEURAL_INITIALIZATION_FAILED = 4
};

typedef void (*NRNeuralInitializationCallback)(int32_t status, const char *error, void *context);
typedef void (*NRNeuralFrameCallback)(int32_t status, CVPixelBufferRef output,
    double timestamp, double milliseconds, const char *error, void *context);

// Immediate return: OK means accepted and exactly one asynchronous callback will
// follow; any other status rejects the request and does NOT invoke its callback.
// Callbacks run off the main thread. Error text and output are borrowed only for
// the callback's duration; copy text / CVPixelBufferRetain(output) to keep them.
// Callbacks must return promptly. They may submit another request but must not
// synchronously wait for it: the same worker processes that request afterward.
// The caller owns context and must keep it alive until its callback returns.
// Do not unload this library: its serial async worker lives until process exit.
int32_t NRNeuralInitialize(const char *modelPath, NRNeuralInitializationCallback callback, void *context);

// One processing request at a time. The bridge retains input until completion;
// the caller must not mutate its pixels during that interval. Input must be
// IOSurface-backed BGRA8, tagged with sRGB transfer and Rec.709 primaries.
// This proof does not accept HDR or perform implicit tone mapping.
// Timestamps must be finite, >=0 and strictly increase until invalidate/init.
int32_t NRNeuralProcess(CVPixelBufferRef input, double timestamp, NRNeuralFrameCallback callback, void *context);

// Standard profile, temporal enabled. Defaults 1/1/1/.5 and long edge 1920.
// Finite intensity/tone/structure 0..2 and split 0..1; only accepted while idle.
// This legacy function keeps the currently selected processing resolution.
int32_t NRNeuralSetControls(float intensity, float tone, float structure, float split);
// Supported long-edge presets: 640, 960, 1280, 1600, 1920. Changes affect the
// next request. Resolution changes need caller-managed warmup before live use.
// Split-only and identical updates preserve temporal history.
int32_t NRNeuralSetSettings(float intensity, float tone, float structure, float split,
    uint32_t processingLongEdge);

typedef struct NRNeuralTimings {
    double resizeMilliseconds;
    double motionMilliseconds;
    double inferenceMilliseconds;
    double writeMilliseconds;
    double compositeMilliseconds;
    double totalMilliseconds;
    uint32_t processingWidth;
    uint32_t processingHeight;
} NRNeuralTimings;
// Last successfully completed frame's stage wall times; NOT pure GPU times.
// Lazy MLX work may finish in the write stage. Thread-safe snapshot, available
// during subsequent processing; NOT_READY until the first successful result.
int32_t NRNeuralCopyLastTimings(NRNeuralTimings *output);

// Invalidates pending output immediately by generation; the in-flight callback
// receives CANCELLED with null output. History resets before the next frame.
// Does not wait for or cancel GPU work. Does not unload the selected model.
void NRNeuralInvalidate(void);
int32_t NRNeuralGetState(void);

// Internal resource anchor: resolves this library, never the host executable.
const char *NRNeuralImagePath(void);

#ifdef __cplusplus
}
#endif
#endif
