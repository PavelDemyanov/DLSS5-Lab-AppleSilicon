#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "NRNeuralBridge.h"
#include <dlfcn.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

// Never unwind a callback context after an asynchronous timeout: the isolated
// process exits while the bridge still owns it instead.
#define CHECK(value, message) do { if (!(value)) { fprintf(stderr,"FAIL: %s\n",message); fflush(nullptr); std::_Exit(1); } } while (0)

struct Completion {
    std::mutex mutex;
    std::condition_variable changed;
    bool done = false, background = false;
    int32_t status = -1;
    unsigned calls = 0;
    CVPixelBufferRef output = nullptr;
    double timestamp = 0, milliseconds = 0;
    std::string error;
    ~Completion() { if (output) CVPixelBufferRelease(output); }
    bool wait() {
        std::unique_lock<std::mutex> guard(mutex);
        return changed.wait_for(guard, std::chrono::seconds(120), [&] { return done; });
    }
};
static void Initialized(int32_t status, const char *error, void *context) {
    auto &c = *static_cast<Completion *>(context);
    std::lock_guard<std::mutex> guard(c.mutex);
    c.status = status; c.error = error ?: ""; c.background = !NSThread.isMainThread;
    c.calls++; c.done = true; c.changed.notify_one();
}
static void Processed(int32_t status, CVPixelBufferRef output, double timestamp,
                      double milliseconds, const char *error, void *context) {
    auto &c = *static_cast<Completion *>(context);
    std::lock_guard<std::mutex> guard(c.mutex);
    c.status = status; c.error = error ?: ""; c.timestamp = timestamp;
    c.milliseconds = milliseconds; c.background = !NSThread.isMainThread;
    if (output) c.output = CVPixelBufferRetain(output);
    c.calls++; c.done = true; c.changed.notify_one();
}

// Decoding, colour conversion and the one-time game-sized resize are outside
// every timed interval. The RGB values and tags are explicitly SDR sRGB.
static CVPixelBufferRef LoadInput(NSString *path, size_t width, size_t height) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
    CHECK(source, "could not open input PNG");
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source); CHECK(image, "could not decode input PNG");
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
        (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef buffer = nullptr;
    CHECK(CVPixelBufferCreate(nullptr, width, height, kCVPixelFormatType_32BGRA,
          (__bridge CFDictionaryRef)attributes, &buffer) == kCVReturnSuccess, "could not allocate input IOSurface");
    CHECK(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess, "input lock failed");
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
        CVPixelBufferGetBytesPerRow(buffer), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CHECK(context, "could not create input colour conversion context");
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context); CGColorSpaceRelease(space); CGImageRelease(image);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_sRGB, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

static bool WritePNG(CVPixelBufferRef buffer, NSString *path) {
    CHECK(CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess, "PNG input lock failed");
    CFDataRef data = CFDataCreate(nullptr, static_cast<const UInt8 *>(CVPixelBufferGetBaseAddress(buffer)),
        CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer));
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    CHECK(data, "PNG pixel copy failed");
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 8, 32,
        CVPixelBufferGetBytesPerRow(buffer), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
    bool ok = false;
    if (image && destination) { CGImageDestinationAddImage(destination, image, nullptr); ok = CGImageDestinationFinalize(destination); }
    if (destination) CFRelease(destination);
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider); CFRelease(data);
    return ok;
}

// Counts exact component differences, never rounded floating-point tolerance.
// The explicit split separator is excluded; the original-side alpha is checked.
static uint64_t Differences(CVPixelBufferRef input, CVPixelBufferRef output, float split, bool all) {
    CHECK(CVPixelBufferGetWidth(input) == CVPixelBufferGetWidth(output) &&
          CVPixelBufferGetHeight(input) == CVPixelBufferGetHeight(output) &&
          CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA, "output layout mismatch");
    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    const size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
    const size_t limit = all ? width : static_cast<size_t>(std::max(0.0, std::floor(static_cast<double>(width) * split) - 3));
    uint64_t differences = 0;
    for (size_t y = 0; y < height; ++y) {
        const auto *a = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(input)) + y * CVPixelBufferGetBytesPerRow(input);
        const auto *b = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(output)) + y * CVPixelBufferGetBytesPerRow(output);
        for (size_t x = 0; x < limit * 4; ++x) differences += a[x] != b[x];
    }
    CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    return differences;
}

static NSDictionary *Timing(const NRNeuralTimings &t, double callWall) {
    return @{@"inputResizeAndImportMilliseconds":@(t.resizeMilliseconds),
        @"motionMilliseconds":@(t.motionMilliseconds), @"inferenceMilliseconds":@(t.inferenceMilliseconds),
        @"writeMilliseconds":@(t.writeMilliseconds), @"compositeMilliseconds":@(t.compositeMilliseconds),
        @"totalMilliseconds":@(t.totalMilliseconds), @"callWallMilliseconds":@(callWall),
        @"processingWidth":@(t.processingWidth), @"processingHeight":@(t.processingHeight)};
}
static NSDictionary *Statistics(NSArray<NSDictionary *> *samples) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"inputResizeAndImportMilliseconds", @"motionMilliseconds", @"inferenceMilliseconds",
            @"writeMilliseconds", @"compositeMilliseconds", @"totalMilliseconds", @"callWallMilliseconds"]) {
        std::vector<double> values; double sum = 0;
        for (NSDictionary *sample in samples) { double value = [sample[key] doubleValue]; values.push_back(value); sum += value; }
        std::sort(values.begin(), values.end());
        const size_t count = values.size(); CHECK(count > 0, "empty timing sample set");
        double median = count % 2 ? values[count / 2] : (values[count / 2 - 1] + values[count / 2]) / 2;
        size_t p95 = static_cast<size_t>(std::ceil(.95 * count)) - 1;
        result[key] = @{@"median":@(median), @"p95":@(values[p95]), @"mean":@(sum/count),
            @"minimum":@(values.front()), @"maximum":@(values.back())};
    }
    return result;
}

struct API {
    decltype(&NRNeuralInitialize) initialize;
    decltype(&NRNeuralProcess) process;
    decltype(&NRNeuralSetSettings) settings;
    decltype(&NRNeuralCopyLastTimings) timings;
    decltype(&NRNeuralGetState) state;
};
static NSDictionary *Render(API &api, CVPixelBufferRef input, uint64_t &sequence,
                            uint32_t edge, Completion &completion, bool bypass = false) {
    const double timestamp = (++sequence) / 30.0;
    auto begin = std::chrono::steady_clock::now();
    CHECK(api.process(input, timestamp, Processed, &completion) == NR_NEURAL_OK, "frame rejected");
    CHECK(completion.wait(), "frame timed out");
    const double wall = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
    CHECK(completion.status == NR_NEURAL_OK, completion.error.c_str());
    CHECK(completion.output && completion.calls == 1 && completion.background && completion.timestamp == timestamp,
          "callback contract failed");
    CHECK(api.state() == NR_NEURAL_READY, "bridge did not return to ready");
    NRNeuralTimings timing{};
    CHECK(api.timings(&timing) == NR_NEURAL_OK, "stage timings unavailable after successful frame");
    for (double value : {timing.resizeMilliseconds, timing.motionMilliseconds, timing.inferenceMilliseconds,
            timing.writeMilliseconds, timing.compositeMilliseconds, timing.totalMilliseconds})
        CHECK(std::isfinite(value) && value >= 0, "invalid stage time");
    const double scale = std::min(1.0, static_cast<double>(edge) /
        std::max(CVPixelBufferGetWidth(input), CVPixelBufferGetHeight(input)));
    const auto width = std::max(2u, static_cast<unsigned>(CVPixelBufferGetWidth(input) * scale) / 2 * 2);
    const auto height = std::max(2u, static_cast<unsigned>(CVPixelBufferGetHeight(input) * scale) / 2 * 2);
    CHECK(timing.processingWidth == width && timing.processingHeight == height,
          "stage timings retained an old processing geometry");
    CHECK(std::abs(timing.totalMilliseconds - completion.milliseconds) < 0.001, "callback and snapshot timing disagree");
    if (bypass) {
        CHECK(timing.totalMilliseconds == 0 && timing.resizeMilliseconds == 0 && timing.motionMilliseconds == 0 &&
              timing.inferenceMilliseconds == 0 && timing.writeMilliseconds == 0 && timing.compositeMilliseconds == 0,
              "bypass retained old stage timings");
    } else {
        CHECK(timing.totalMilliseconds > 0 && timing.inferenceMilliseconds > 0, "processed frame has no measured work");
        const double stages = timing.resizeMilliseconds + timing.motionMilliseconds + timing.inferenceMilliseconds +
            timing.writeMilliseconds + timing.compositeMilliseconds;
        CHECK(stages <= timing.totalMilliseconds + 0.01, "overlapping stages exceed total time");
    }
    return Timing(timing, wall);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        CHECK(argc == 5 || argc == 7, "usage: SettingsBenchmark LIBRARY MODEL INPUT_PNG OUTPUT_DIRECTORY [WIDTH HEIGHT]");
        size_t width = 2336, height = 1460;
        if (argc == 7) {
            char *endW = nullptr, *endH = nullptr;
            width = strtoul(argv[5], &endW, 10); height = strtoul(argv[6], &endH, 10);
            CHECK(endW && !*endW && endH && !*endH && width >= 16 && height >= 16 && width <= 8192 && height <= 8192,
                  "invalid input dimensions");
        }
        NSString *directory = @(argv[4]);
        CHECK(![[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"result.json"]],
              "result.json already exists; choose a fresh output directory");
        NSError *createError = nil;
        CHECK([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                  attributes:nil error:&createError], createError.localizedDescription.UTF8String);
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); CHECK(library, dlerror());
        API api{(decltype(&NRNeuralInitialize))dlsym(library,"NRNeuralInitialize"),
            (decltype(&NRNeuralProcess))dlsym(library,"NRNeuralProcess"),
            (decltype(&NRNeuralSetSettings))dlsym(library,"NRNeuralSetSettings"),
            (decltype(&NRNeuralCopyLastTimings))dlsym(library,"NRNeuralCopyLastTimings"),
            (decltype(&NRNeuralGetState))dlsym(library,"NRNeuralGetState")};
        CHECK(api.initialize && api.process && api.settings && api.timings && api.state, "new C ABI exports missing");
        NRNeuralTimings absent{};
        CHECK(api.timings(&absent) == NR_NEURAL_NOT_READY, "stage snapshot unexpectedly ready before initialization");
        CHECK(api.timings(nullptr) == NR_NEURAL_INVALID_ARGUMENT, "null timing destination accepted");
        unsigned invalidCases = 0;
        struct Settings { float intensity, tone, structure, split; uint32_t edge; };
        const float nan = std::numeric_limits<float>::quiet_NaN();
        const float infinity = std::numeric_limits<float>::infinity();
        for (auto s : std::vector<Settings>{{nan,1,1,.5f,1920},{1,infinity,1,.5f,1920},
                {1,1,nan,.5f,1920},{1,1,1,infinity,1920},{-.01f,1,1,.5f,1920},
                {1,2.01f,1,.5f,1920},{1,1,2.01f,.5f,1920},{1,1,1,-.01f,1920},
                {1,1,1,1.01f,1920},{1,1,1,.5f,0},{1,1,1,.5f,512},{1,1,1,.5f,1921}}) {
            CHECK(api.settings(s.intensity,s.tone,s.structure,s.split,s.edge) == NR_NEURAL_INVALID_ARGUMENT,
                  "invalid settings accepted"); invalidCases++;
        }
        CHECK(api.settings(1,1,1,.5f,1920) == NR_NEURAL_OK, "initial settings rejected");
        CVPixelBufferRef input = LoadInput(@(argv[3]), width, height);
        CHECK(WritePNG(input, [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"input-srgb-%zux%zu.png",width,height]]), "input PNG save failed");
        Completion initialized;
        CHECK(api.initialize(argv[2],Initialized,&initialized) == NR_NEURAL_OK && initialized.wait(), "initialization failed/timed out");
        CHECK(initialized.status == NR_NEURAL_OK, initialized.error.c_str());
        CHECK(initialized.calls == 1 && initialized.background && api.state() == NR_NEURAL_READY, "initialization contract failed");
        uint64_t sequence = 0;
        NSMutableArray *presets = [NSMutableArray array];
        const uint32_t edges[] = {1920,1600,1280,960,640,1920};
        for (size_t presetIndex = 0; presetIndex < sizeof(edges)/sizeof(edges[0]); ++presetIndex) {
            uint32_t edge = edges[presetIndex];
            CHECK(api.settings(1,1,1,.5f,edge) == NR_NEURAL_OK, "resolution switch rejected");
            NSString *label = presetIndex == 5 ? @"1920-repeat" : [NSString stringWithFormat:@"%u",edge];
            NSMutableArray *warmup = [NSMutableArray array], *samples = [NSMutableArray array];
            for (unsigned frame = 0; frame < 3; ++frame) {
                @autoreleasepool { Completion c; [warmup addObject:Render(api,input,sequence,edge,c)]; }
            }
            uint64_t changedLeftComponents = 0;
            for (unsigned frame = 0; frame < 20; ++frame) {
                @autoreleasepool {
                    Completion c; [samples addObject:Render(api,input,sequence,edge,c)];
                    changedLeftComponents += Differences(input,c.output,.5f,false);
                    CHECK(changedLeftComponents == 0, "original left side changed");
                    if (frame == 19) CHECK(WritePNG(c.output,[directory stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"comparison-%@.png",label]]), "comparison PNG save failed");
                }
            }
            NSDictionary *stats = Statistics(samples);
            [presets addObject:@{@"label":label,@"processingLongEdge":@(edge),@"warmupFrames":@3,@"measuredFrames":@20,
                @"warmup":warmup,@"samples":samples,@"statistics":stats,@"leftChangedComponents":@(changedLeftComponents),
                @"leftMAE":@0,@"comparisonPNG":[NSString stringWithFormat:@"comparison-%@.png",label]}];
            fprintf(stderr,"Preset %s: median %.3f ms, p95 %.3f ms\n",label.UTF8String,
                [stats[@"totalMilliseconds"][@"median"] doubleValue],[stats[@"totalMilliseconds"][@"p95"] doubleValue]);
            fflush(stderr);
        }

        Completion rejected;
        CHECK(api.settings(1,1,1,.5f,1920) == NR_NEURAL_OK, "no-op settings rejected");
        CHECK(api.process(input,sequence/30.0,Processed,&rejected) == NR_NEURAL_STALE, "no-op reset timestamp validation");
        CHECK(api.settings(1,1,1,.25f,1920) == NR_NEURAL_OK, "split-only settings rejected");
        CHECK(api.process(input,sequence/30.0,Processed,&rejected) == NR_NEURAL_STALE, "split-only change reset timestamp validation");
        { Completion c; Render(api,input,sequence,1920,c); CHECK(Differences(input,c.output,.25f,false) == 0, "quarter split changed original pixels"); }
        CHECK(api.settings(0,1,1,.5f,1920) == NR_NEURAL_OK, "zero intensity rejected");
        { Completion c; Render(api,input,sequence,1920,c,true); CHECK(Differences(input,c.output,1,true) == 0, "zero intensity did not preserve exact original"); }
        CHECK(api.settings(1,1,1,.5f,1920) == NR_NEURAL_OK, "restoring intensity failed");
        NSMutableArray *restore = [NSMutableArray array];
        for (unsigned frame = 0; frame < 3; ++frame) {
            Completion c; [restore addObject:Render(api,input,sequence,1920,c)];
            CHECK(Differences(input,c.output,.5f,false) == 0, "restored effect changed original half");
        }
        CHECK(rejected.calls == 0, "rejected request invoked a callback");
        NSDictionary *report = @{@"passed":@YES,@"input":@(argv[3]),@"model":@(argv[2]),@"library":@(argv[1]),
            @"inputWidth":@(width),@"inputHeight":@(height),@"presets":presets,@"profile":@"standard",
            @"intensity":@1,@"tone":@1,@"structure":@1,@"split":@0.5,@"temporal":@YES,
            @"invalidSettingsRejected":@(invalidCases),@"noOpPreservesTimestampValidation":@YES,
            @"splitOnlyPreservesTimestampValidation":@YES,@"zeroIntensityExactOriginal":@YES,
            @"restoredIntensityFrames":restore,@"freshStageGeometryVerified":@YES,@"callbackContractVerified":@YES,
            @"totalAcceptedFrames":@(sequence),@"timestampStepSeconds":@(1.0/30),
            @"notes":@"Repeated static SDR input resized once before timing. Three warmup frames and twenty measured temporal frames per preset; unique timestamps prevent retained-result reuse. Stage times are wall times, not pure GPU times. Input stage includes RGB import/evaluation. PNG/readback checks are outside timing. No live-game FPS, moving-scene quality, or speed target claim."};
        NSError *jsonError = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&jsonError];
        CHECK(json, jsonError.localizedDescription.UTF8String);
        CHECK([json writeToFile:[directory stringByAppendingPathComponent:@"result.json"] atomically:YES], "report save failed");
        fprintf(stdout,"PASS: %lu presets, %llu accepted frames; %s\n",(unsigned long)presets.count,
            static_cast<unsigned long long>(sequence),[directory stringByAppendingPathComponent:@"result.json"].UTF8String);
        CVPixelBufferRelease(input);
        // The bridge owns a process-lifetime worker; deliberately no dlclose.
        return 0;
    }
}
