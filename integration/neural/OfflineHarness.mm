#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "NRNeuralBridge.h"
#include <dlfcn.h>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cmath>
#include <string>
#include <cstdlib>
#include <algorithm>
#include <vector>

struct Completion {
    std::mutex mutex;
    std::condition_variable condition;
    bool done = false, background = false;
    int status = -1, calls = 0;
    CVPixelBufferRef output = nullptr;
    double timestamp = 0, milliseconds = 0;
    std::string error;
    ~Completion() { if (output) CVPixelBufferRelease(output); }
    bool wait() {
        std::unique_lock<std::mutex> guard(mutex);
        return condition.wait_for(guard, std::chrono::seconds(120), [&] { return done; });
    }
};
static void Initialized(int32_t status, const char *error, void *context) {
    Completion &c = *(Completion *)context;
    std::lock_guard<std::mutex> guard(c.mutex);
    c.status = status; c.error = error ?: ""; c.background = !NSThread.isMainThread;
    c.done = true; c.calls++; c.condition.notify_one();
}
static void Processed(int32_t status, CVPixelBufferRef output, double timestamp,
                      double milliseconds, const char *error, void *context) {
    Completion &c = *(Completion *)context;
    std::lock_guard<std::mutex> guard(c.mutex);
    c.status = status; c.error = error ?: ""; c.background = !NSThread.isMainThread;
    c.timestamp = timestamp; c.milliseconds = milliseconds;
    if (output) c.output = CVPixelBufferRetain(output);
    c.done = true; c.calls++; c.condition.notify_one();
}

static CVPixelBufferRef ReadSRGB(NSString *path) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
    if (!source) return nullptr;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (!image) return nullptr;
    CVPixelBufferRef buffer = nullptr;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
        (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVReturn created = CVPixelBufferCreate(nullptr, CGImageGetWidth(image), CGImageGetHeight(image),
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer);
    if (created != kCVReturnSuccess) { CGImageRelease(image); return nullptr; }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), CGImageGetWidth(image),
        CGImageGetHeight(image), 8, CVPixelBufferGetBytesPerRow(buffer), space,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)), image);
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space); CGImageRelease(image);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (!context) { CVPixelBufferRelease(buffer); return nullptr; }
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

static bool WritePNG(CVPixelBufferRef buffer, NSString *path) {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    CFDataRef data = CFDataCreate(nullptr, (const UInt8 *)CVPixelBufferGetBaseAddress(buffer),
        CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer));
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 8, 32,
        CVPixelBufferGetBytesPerRow(buffer), space,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, nullptr, false, kCGRenderingIntentDefault);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
    bool result = false;
    if (image && destination) { CGImageDestinationAddImage(destination, image, nullptr); result = CGImageDestinationFinalize(destination); }
    if (destination) CFRelease(destination);
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider); CFRelease(data);
    return result;
}

static double Difference(CVPixelBufferRef input, CVPixelBufferRef output, bool left) {
    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
    size_t begin = left ? 0 : width / 2 + 3, end = left ? width / 2 - 3 : width;
    double sum = 0;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *a = (const uint8_t *)CVPixelBufferGetBaseAddress(input) + y * CVPixelBufferGetBytesPerRow(input);
        const uint8_t *b = (const uint8_t *)CVPixelBufferGetBaseAddress(output) + y * CVPixelBufferGetBytesPerRow(output);
        for (size_t x = begin; x < end; ++x) for (size_t channel = 0; channel < 3; ++channel)
            sum += std::abs((int)a[x*4+channel] - (int)b[x*4+channel]);
    }
    CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    return sum / ((end - begin) * height * 3 * 255.0);
}

// An accepted async request may still own a stack context on failure/timeout.
// Exit this isolated harness without destroying that context under its callback.
#define REQUIRE(value, message) do { if (!(value)) { fprintf(stderr,"FAIL: %s\n",message); fflush(nullptr); std::_Exit(1); } } while (0)
int main(int argc, const char **argv) {
    @autoreleasepool {
        REQUIRE(argc == 5, "usage: NeuralOfflineHarness LIBRARY MODEL INPUT_PNG OUTPUT_DIRECTORY");
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        REQUIRE(library, dlerror());
        auto initialize = (decltype(&NRNeuralInitialize))dlsym(library, "NRNeuralInitialize");
        auto process = (decltype(&NRNeuralProcess))dlsym(library, "NRNeuralProcess");
        auto controls = (decltype(&NRNeuralSetControls))dlsym(library, "NRNeuralSetControls");
        auto invalidate = (decltype(&NRNeuralInvalidate))dlsym(library, "NRNeuralInvalidate");
        auto state = (decltype(&NRNeuralGetState))dlsym(library, "NRNeuralGetState");
        REQUIRE(initialize && process && controls && invalidate && state, "missing C ABI export");
        CVPixelBufferRef input = ReadSRGB(@(argv[3]));
        REQUIRE(input, "cannot decode input as sRGB BGRA8 IOSurface");
        Completion rejected;
        REQUIRE(process(input, 1, Processed, &rejected) == NR_NEURAL_NOT_READY, "processing before initialization accepted");
        REQUIRE(controls(1, 1, 1, .5) == NR_NEURAL_OK, "controls rejected");
        Completion initialized;
        REQUIRE(initialize(argv[2], Initialized, &initialized) == NR_NEURAL_OK, "initialization not accepted");
        REQUIRE(initialized.wait(), "initialization timed out");
        REQUIRE(initialized.status == NR_NEURAL_OK, initialized.error.c_str());
        REQUIRE(initialized.background && initialized.calls == 1 && state() == NR_NEURAL_READY, "initialization callback contract failed");
        Completion cancelled;
        REQUIRE(process(input, 2, Processed, &cancelled) == NR_NEURAL_OK, "first processing not accepted");
        int32_t concurrentStatus = process(input, 3, Processed, &rejected);
        REQUIRE(concurrentStatus == NR_NEURAL_BUSY || concurrentStatus == NR_NEURAL_OK, "unexpected concurrent admission status");
        invalidate();
        REQUIRE(cancelled.wait(), "cancelled request did not complete");
        // A fast completion before invalidate is legal. Report a cancellation
        // check as observed only when an actually pending request was cancelled.
        REQUIRE(cancelled.status == NR_NEURAL_CANCELLED || cancelled.status == NR_NEURAL_OK, "unexpected cancellation status");
        REQUIRE(cancelled.status != NR_NEURAL_CANCELLED || !cancelled.output, "cancelled callback delivered pixels");
        bool cancellationObserved = cancelled.status == NR_NEURAL_CANCELLED;
        if (concurrentStatus == NR_NEURAL_OK) {
            REQUIRE(rejected.wait(), "second accepted request did not complete");
            REQUIRE(rejected.status == NR_NEURAL_CANCELLED || rejected.status == NR_NEURAL_OK, "unexpected second callback status");
            REQUIRE(rejected.status != NR_NEURAL_CANCELLED || !rejected.output, "cancelled second callback delivered pixels");
            cancellationObserved |= rejected.status == NR_NEURAL_CANCELLED;
        }
        Completion rendered;
        REQUIRE(process(input, 2, Processed, &rendered) == NR_NEURAL_OK, "fresh processing not accepted after invalidate");
        REQUIRE(rendered.wait(), "processing timed out");
        REQUIRE(rendered.status == NR_NEURAL_OK && rendered.output, rendered.error.c_str());
        REQUIRE(rendered.background && rendered.calls == 1 && rendered.timestamp == 2, "frame callback contract failed");
        REQUIRE(CVPixelBufferGetWidth(rendered.output) == CVPixelBufferGetWidth(input) &&
                CVPixelBufferGetHeight(rendered.output) == CVPixelBufferGetHeight(input), "output dimensions changed");
        REQUIRE(process(input, 2, Processed, &rejected) == NR_NEURAL_STALE, "duplicate timestamp accepted");
        CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVAttachmentMode_ShouldPropagate);
        REQUIRE(process(input, 3, Processed, &rejected) == NR_NEURAL_INVALID_ARGUMENT, "PQ input accepted by SDR bridge");
        CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, kCVAttachmentMode_ShouldPropagate);
        double left = Difference(input, rendered.output, true), right = Difference(input, rendered.output, false);
        REQUIRE(left <= 1.0/255 && right > 0.00001, "split did not preserve original / produce measurable neural change");
        NSMutableArray *repeatedEngine = [NSMutableArray array], *repeatedWall = [NSMutableArray array];
        std::vector<double> wallTimings;
        double engineSum = 0, wallSum = 0;
        for (int index = 0; index < 5; ++index) {
            Completion repeated;
            // Increasing timestamps exercise actual inference/temporal work,
            // not RenderEngine's retained-result cache for an identical PTS.
            double timestamp = 2 + (index + 1) / 30.0;
            auto started = std::chrono::steady_clock::now();
            REQUIRE(process(input, timestamp, Processed, &repeated) == NR_NEURAL_OK, "repeated frame rejected");
            REQUIRE(repeated.wait(), "repeated frame timed out");
            double wall = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
            REQUIRE(repeated.status == NR_NEURAL_OK && repeated.output && repeated.timestamp == timestamp, "repeated frame failed");
            REQUIRE(repeated.background && repeated.calls == 1, "repeated callback contract failed");
            [repeatedEngine addObject:@(repeated.milliseconds)]; [repeatedWall addObject:@(wall)];
            wallTimings.push_back(wall); engineSum += repeated.milliseconds; wallSum += wall;
        }
        // The caller-retained first output must survive later buffer-pool reuse.
        REQUIRE(Difference(input, rendered.output, true) == left &&
                Difference(input, rendered.output, false) == right, "retained output changed after subsequent processing");
        std::sort(wallTimings.begin(), wallTimings.end());
        NSString *directory = @(argv[4]);
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        REQUIRE(WritePNG(input, [directory stringByAppendingPathComponent:@"input-srgb.png"]), "input PNG write failed");
        REQUIRE(WritePNG(rendered.output, [directory stringByAppendingPathComponent:@"comparison.png"]), "output PNG write failed");
        NSDictionary *report = @{@"passed":@YES, @"width":@(CVPixelBufferGetWidth(input)), @"height":@(CVPixelBufferGetHeight(input)),
            @"model":@(argv[2]), @"input":@(argv[3]), @"profile":@"standard", @"processingLongEdge":@1920,
            @"intensity":@1, @"tone":@1, @"structure":@1, @"split":@0.5,
            @"firstOutputMilliseconds":@(rendered.milliseconds), @"leftOriginalMAE":@(left), @"rightNeuralMAE":@(right),
            @"repeatedFrameMilliseconds":repeatedEngine, @"repeatedCallWallMilliseconds":repeatedWall,
            @"repeatedMeanEngineMilliseconds":@(engineSum/5), @"repeatedMeanWallMilliseconds":@(wallSum/5),
            @"repeatedMedianWallMilliseconds":@(wallTimings[2]), @"repeatedMaximumWallMilliseconds":@(wallTimings.back()),
            @"meanBridgeAndCallbackOverheadMilliseconds":@((wallSum-engineSum)/5),
            @"callbacksOffMain":@YES, @"busyRejected":@(concurrentStatus == NR_NEURAL_BUSY), @"invalidationSuppressedOutput":@(cancellationObserved),
            @"duplicateTimestampRejected":@YES, @"pqInputRejected":@YES, @"retainedOutputStable":@YES,
            @"notes":@"Offline repeated-static-image SDR C-ABI proof with unique timestamps. First output and first temporal use may compile shaders. Wall timings include submit-to-callback overhead. Not live-game FPS, motion quality, or HDR support."};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[directory stringByAppendingPathComponent:@"result.json"] atomically:YES];
        fwrite(json.bytes, 1, json.length, stdout); fputs("\n", stdout);
        CVPixelBufferRelease(input);
        // Deliberately no dlclose: the bridge owns a process-lifetime async worker.
        return 0;
    }
}
