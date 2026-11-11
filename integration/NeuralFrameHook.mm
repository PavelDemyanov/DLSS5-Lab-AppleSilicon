#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <atomic>
#include <cmath>
#include <dlfcn.h>
#include <map>
#include <mutex>
#include <deque>
#include <unistd.h>
#include "NeuralFrameHook.h"
#include "neural/Sources/NRNeuralABI/include/NRNeuralBridge.h"

// No constructor in the hook core: explicit activation and successful warmup
// are required. NeuralGameEntry adds the version-gated experiment entry point.
@interface NRHookJob : NSObject
@property(nonatomic,strong) id<CAMetalDrawable> drawable;
@property(nonatomic,weak) id<MTLCommandBuffer> producerCommand;
@property(nonatomic) void *producerIdentity;
@property(atomic) BOOL producerSubmitted;
@property(atomic) BOOL retired;
@property(atomic) double submittedAt;
@property(nonatomic) uint64_t recoveryEpoch;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) double capturedAt;
@property(nonatomic) NSUInteger warmupFrame;
@property(nonatomic) NRFrameHookSettings settings;
@property(nonatomic) NRFrameHookTimings timings;
@property(nonatomic) double conversionStarted;
@property(nonatomic) double bridgeStarted;
@property(nonatomic) double finalStarted;
@property(nonatomic) BOOL processed;
@property(nonatomic,strong) dispatch_semaphore_t finalDone;
@property(nonatomic) NSUInteger variant;
@property(nonatomic) CFTimeInterval presentationParameter;
@property(nonatomic) BOOL linearColor;
@property(nonatomic) BOOL srgbTexture;
@property(nonatomic) BOOL gameReady;
@property(nonatomic) BOOL converting;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL expired;
@property(nonatomic) CVPixelBufferRef input;
@property(nonatomic) CVMetalTextureRef inputWrapper;
@property(nonatomic,strong) id<MTLBuffer> rangeFlags;
@end
@implementation NRHookJob
- (void)dealloc {
    if (_inputWrapper) CFRelease(_inputWrapper);
    if (_input) CVPixelBufferRelease(_input);
}
@end

namespace {
using Present = void (*)(id, SEL, id<MTLDrawable>);
using TimedPresent = void (*)(id, SEL, id<MTLDrawable>, CFTimeInterval);
using Commit = void (*)(id, SEL);
using Initialize = decltype(&NRNeuralInitialize);
using Process = decltype(&NRNeuralProcess);
using Invalidate = decltype(&NRNeuralInvalidate);
using GetState = decltype(&NRNeuralGetState);
using SetSettings = decltype(&NRNeuralSetSettings);
using CopyTimings = decltype(&NRNeuralCopyLastTimings);

struct State {
    std::atomic<bool> started{false}, installed{false}, disabled{false}, armed{true};
    std::atomic<uint64_t> accepted{0}, processed{0}, bypassed{0}, expired{0}, late{0};
    std::atomic<uint64_t> errors{0}, pending{0}, peak{0}, completed{0}, unsupported{0};
    std::atomic<uint64_t> abandoned{0};
    dispatch_queue_t queue = nullptr;
    dispatch_source_t timer = nullptr;
    void *library = nullptr; // Intentionally never unloaded.
    Initialize initialize = nullptr;
    Process process = nullptr;
    Invalidate invalidate = nullptr;
    GetState getState = nullptr;
    SetSettings setSettings = nullptr;
    CopyTimings copyTimings = nullptr;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> gpu = nil;
    id<MTLComputePipelineState> conversion = nil;
    std::map<NSUInteger,id<MTLRenderPipelineState>> finalPipelines;
    CVMetalTextureCacheRef textureCache = nullptr;
    CVPixelBufferPoolRef inputPool = nullptr;
    NSMutableArray<NRHookJob *> *jobs = nil;
    CAMetalLayer *selectedLayer = nil;
    NSMutableSet<NSValue *> *activeDrawables = nil;
    BOOL bridgeBusy = NO;
    bool warming = true, settingsDirty = false, surfaceSupported = false;
    bool recovering=false,recoveryProbeInFlight=false;
    uint64_t recoveryCount=0,recoveryEpoch=0;
    uint64_t recoveryProbeID=0;
    NSString *lastRecoveryReason=nil,*lastRecoveryPhase=nil;
    double lastRecoveryAgeMilliseconds=0;
    uint64_t lastRecoverySequence=0;
    NRFrameHookSettings requested{1,1,1,.5f,1920,1}, applied{1,1,1,.5f,1920,1};
    uint64_t requestedRevision = 0, appliedRevision = 0;
    std::mutex publicLock;
    NRFrameHookSnapshot published{};
    NRFrameHookOverlayCallback overlay = nullptr;
    void *overlayContext = nullptr;
    std::atomic<uint64_t> presentations{0};
    struct RateSample { double at; uint64_t processed, presented; };
    std::deque<RateSample> rateSamples;
    std::deque<NRFrameHookTimings> timingSamples;
    uint32_t processingWidth=0, processingHeight=0;
    bool serialCommit = false;
    std::mutex commitLock;
    std::map<void *, NRHookJob *> committingJobs;
    uint64_t sequence = 0;
    double lastCaptureTimestamp = 0;
    uint32_t width = 0, height = 0;
    unsigned deadlineMS = 500;
    NSString *logPath = nil, *disablePath = nil, *enablePath = nil, *settingsPath = nil, *lastError = nil, *lastReason = nil;
    NSString *controlNotice = nil;
    NSDictionary *observedSurface = nil;
    NRFrameHookReadyCallback ready = nullptr;
    void *readyContext = nullptr;
    NRFrameHookObserver observer = nullptr;
    void *observerContext = nullptr;
    std::atomic<IMP> original[3]{};
    std::atomic<IMP> originalCommit{};
    std::atomic<uint64_t> commitWaits{0}, commitTimeouts{0};
    std::atomic<uint64_t> selectors[3]{};
};
State &S() { static State *s = new State; return *s; }
bool TestMode() { const char *v=getenv("NR_FRAME_HOOK_TEST"); return v && !strcmp(v,"1"); }
bool Absolute(const char *p) { return p && p[0]=='/' && p[1]; }
thread_local unsigned depth=0;
struct Scope { bool outer; Scope():outer(depth++==0){} ~Scope(){--depth;} };
void Pump();
void Finish(NRHookJob *job, CVPixelBufferRef output);
void BeginWarmup();
void ApplyPendingSettings();
void PauseForTiming(NRHookJob *job,NSString *reason);
void ObserveRecoveryProbe(id<MTLCommandBuffer> command);

bool ValidSettings(const NRFrameHookSettings &v) {
    return std::isfinite(v.intensity)&&std::isfinite(v.tone)&&std::isfinite(v.structure)&&std::isfinite(v.split)&&
        v.intensity>=0&&v.intensity<=2&&v.tone>=0&&v.tone<=2&&v.structure>=0&&v.structure<=2&&v.split>=0&&v.split<=1&&
        (v.enabled==0||v.enabled==1)&&(v.processingLongEdge==640||v.processingLongEdge==960||
        v.processingLongEdge==1280||v.processingLongEdge==1600||v.processingLongEdge==1920);
}
bool EqualSettings(const NRFrameHookSettings &a,const NRFrameHookSettings &b) {
    return a.intensity==b.intensity&&a.tone==b.tone&&a.structure==b.structure&&a.split==b.split&&
        a.processingLongEdge==b.processingLongEdge&&a.enabled==b.enabled;
}
double GPUTime(id<MTLCommandBuffer> command) {
    double begin=command.GPUStartTime,end=command.GPUEndTime;
    return std::isfinite(begin)&&std::isfinite(end)&&begin>0&&end>=begin ? (end-begin)*1000 : 0;
}
void EncodeOverlay(id<MTLCommandBuffer> command,id<CAMetalDrawable> drawable) {
    NRFrameHookOverlayCallback callback;void *context;
    { std::lock_guard<std::mutex> guard(S().publicLock); callback=S().overlay;context=S().overlayContext; }
    if(callback) callback((__bridge void*)command,(__bridge void*)drawable,context);
}
void PublishSnapshot() {
    State &s=S();double now=NSProcessInfo.processInfo.systemUptime;
    if(s.rateSamples.empty()||now-s.rateSamples.back().at>=.2)
        s.rateSamples.push_back({now,s.processed.load(),s.presentations.load()});
    while(s.rateSamples.size()>1&&now-s.rateSamples.front().at>2.5)s.rateSamples.pop_front();
    NRFrameHookSnapshot out{};out.abiVersion=2;out.requested=s.requested;out.applied=s.applied;
    out.counters={s.accepted.load(),s.processed.load(),s.bypassed.load(),s.expired.load(),s.late.load(),s.errors.load(),
        s.pending.load(),s.peak.load(),s.completed.load(),s.unsupported.load(),s.installed.load(),s.disabled.load()};
    out.requestedRevision=s.requestedRevision;out.appliedRevision=s.appliedRevision;
    out.armed=s.armed.load();out.faulted=s.disabled.load();out.warming=s.warming;out.settingsPending=s.settingsDirty;
    out.surfaceSupported=s.surfaceSupported;out.processingWidth=s.processingWidth;out.processingHeight=s.processingHeight;
    out.recovering=s.recovering;out.recoveryCount=s.recoveryCount;
    if(!s.rateSamples.empty()&&now>s.rateSamples.front().at) {
        auto first=s.rateSamples.front();out.processedFPS=(s.processed.load()-first.processed)/(now-first.at);
        out.presentFPS=(s.presentations.load()-first.presented)/(now-first.at);
    }
    if(!s.timingSamples.empty()) {
#define NR_MEAN(field) for(auto &sample:s.timingSamples)out.timings.field+=sample.field;out.timings.field/=s.timingSamples.size();
        NR_MEAN(totalMilliseconds) NR_MEAN(producerMilliseconds) NR_MEAN(conversionMilliseconds)
        NR_MEAN(bridgeMilliseconds) NR_MEAN(finalMilliseconds) NR_MEAN(producerGPUMilliseconds)
        NR_MEAN(conversionGPUMilliseconds) NR_MEAN(finalGPUMilliseconds) NR_MEAN(resizeMilliseconds)
        NR_MEAN(motionMilliseconds) NR_MEAN(inferenceMilliseconds) NR_MEAN(writeMilliseconds) NR_MEAN(compositeMilliseconds)
#undef NR_MEAN
    }
    NSString *status=s.disabled.load() ? (s.lastReason ?: @"Processing fault; restart required") :
        s.recovering ? @"Temporary timing pause; showing originals until a fresh SDR frame completes" :
        s.warming ? @"Preparing neural settings; showing original frames" :
        s.settingsDirty ? @"Applying controls after the current frame" :
        s.controlNotice ? s.controlNotice :
        !s.armed.load()||!s.applied.enabled ? @"HT is off" :
        !s.surfaceSupported ? (s.lastReason ?: @"Waiting for compatible SDR frames") : @"HT active";
    snprintf(out.status,sizeof(out.status),"%s",status.UTF8String ?: "");
    std::lock_guard<std::mutex> guard(s.publicLock);s.published=out;
}

void Error(NSString *text) { S().errors.fetch_add(1); S().lastError=[text copy] ?: @"Unknown error"; }
void Disable(NSString *reason) {
    State &s=S(); s.disabled.store(true); s.lastReason=[reason copy];
    if(s.bridgeBusy && s.invalidate) s.invalidate();
}
void Diagnostics() {
    State &s=S();
    PublishSnapshot();
    if(!s.logPath) return;
    NRFrameHookSnapshot snapshot;{std::lock_guard<std::mutex> guard(s.publicLock);snapshot=s.published;}
    auto t=snapshot.timings;
    NSDictionary *d=@{
        @"mode":@"experimental exact-frame HT hook; independent of NVIDIA DLSS",
        @"installed":@(s.installed.load()), @"disabled":@(s.disabled.load()), @"armed":@(s.armed.load()),
        @"accepted":@(s.accepted.load()), @"processed":@(s.processed.load()),
        @"bypassed":@(s.bypassed.load()), @"expired":@(s.expired.load()),
        @"late":@(s.late.load()), @"errors":@(s.errors.load()),
        @"pending":@(s.pending.load()), @"peakPending":@(s.peak.load()),
        @"finalCompleted":@(s.completed.load()), @"unsupported":@(s.unsupported.load()),
        @"abandonedProducerFrames":@(s.abandoned.load()),
        @"plainPresent":@(s.selectors[0].load()), @"timedPresent":@(s.selectors[1].load()),
        @"minimumDurationPresent":@(s.selectors[2].load()),
        @"bridgeBusy":@(s.bridgeBusy), @"width":@(s.width), @"height":@(s.height),
        @"warming":@(s.warming),@"settingsPending":@(s.settingsDirty),@"enabled":@(s.applied.enabled),
        @"requestedEnabled":@(s.requested.enabled),@"recovering":@(s.recovering),@"recoveryCount":@(s.recoveryCount),
        @"lastRecoveryReason":s.lastRecoveryReason ?: (id)[NSNull null],
        @"lastRecoveryPhase":s.lastRecoveryPhase ?: (id)[NSNull null],
        @"lastRecoveryAgeMilliseconds":@(s.lastRecoveryAgeMilliseconds),@"lastRecoverySequence":@(s.lastRecoverySequence),
        @"processingLongEdge":@(s.applied.processingLongEdge),@"settingsRevision":@(s.appliedRevision),
        @"intensity":@(s.applied.intensity),@"tone":@(s.applied.tone),@"structure":@(s.applied.structure),@"split":@(s.applied.split),
        @"processedFPS":@(snapshot.processedFPS),@"presentFPS":@(snapshot.presentFPS),
        @"processingWidth":@(snapshot.processingWidth),@"processingHeight":@(snapshot.processingHeight),
        @"rollingTimingsMilliseconds":@{@"total":@(t.totalMilliseconds),@"producer":@(t.producerMilliseconds),
            @"conversion":@(t.conversionMilliseconds),@"bridge":@(t.bridgeMilliseconds),@"final":@(t.finalMilliseconds),
            @"producerGPU":@(t.producerGPUMilliseconds),@"conversionGPU":@(t.conversionGPUMilliseconds),
            @"finalGPU":@(t.finalGPUMilliseconds),@"resize":@(t.resizeMilliseconds),@"motion":@(t.motionMilliseconds),
            @"inference":@(t.inferenceMilliseconds),@"write":@(t.writeMilliseconds),@"composite":@(t.compositeMilliseconds)},
        @"serialCommitEnabled":@(s.serialCommit), @"commitWaits":@(s.commitWaits.load()),
        @"commitTimeouts":@(s.commitTimeouts.load()),
        @"observedSurface":s.observedSurface ?: (id)[NSNull null],
        @"deadlineMilliseconds":@(s.deadlineMS),
        @"lastError":s.lastError ?: (id)[NSNull null],
        @"lastReason":s.lastReason ?: (id)[NSNull null],
        @"lastControlRejection":s.controlNotice ?: (id)[NSNull null],
        @"status":[NSString stringWithUTF8String:snapshot.status],
        @"completionMeaning":@"GPU completion only; physical display not verified"
    };
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:s.logPath options:NSDataWritingAtomic error:nil];
}

void PauseForTiming(NRHookJob *job,NSString *reason) {
    State &s=S();
    if(s.disabled.load() || job.retired || s.recovering || job.recoveryEpoch!=s.recoveryEpoch)return;
    s.recovering=true;++s.recoveryCount;++s.recoveryEpoch;s.recoveryProbeInFlight=false;
    s.lastRecoveryReason=[reason copy];s.lastRecoverySequence=job.sequence;
    s.lastRecoveryAgeMilliseconds=(NSProcessInfo.processInfo.systemUptime-job.capturedAt)*1000;
    s.lastRecoveryPhase=job.finished ? @"final_gpu" : !job.gameReady ?
        (job.producerSubmitted ? @"waiting_for_producer_gpu" : @"waiting_for_commit") :
        job.converting ? @"conversion" : job.bridgeStarted>0 ? @"bridge" : @"awaiting_conversion_or_final";
    s.lastReason=[reason copy];
    // Do not invalidate or declare the bridge idle while it owns GPU work.
    // Its late output is discarded; history resets once after the drain/probe.
}

void CompleteRecoveryProbe(uint64_t epoch,uint64_t probeID,double milliseconds,NSString *gpuError) {
    State &s=S();
    if(gpuError) { Error(gpuError);Disable(@"Recovery probe producer GPU error"); }
    if(epoch!=s.recoveryEpoch || probeID!=s.recoveryProbeID || !s.recoveryProbeInFlight)return;
    s.recoveryProbeInFlight=false;
    if(s.disabled.load()||!s.recovering||s.pending.load()!=0||s.jobs.count!=0||s.bridgeBusy||s.warming||s.settingsDirty||
       !s.surfaceSupported||milliseconds>=s.deadlineMS) { Diagnostics();return; }
    // This is a newly completed, originally presented SDR producer frame.
    // Every older owned drawable and bridge callback has already retired.
    s.invalidate();s.recovering=false;s.lastReason=nil;s.controlNotice=nil;
    Diagnostics();
}

void ObserveRecoveryProbe(id<MTLCommandBuffer> command) {
    State &s=S();
    if(s.disabled.load()||!s.recovering||s.recoveryProbeInFlight||s.pending.load()!=0||s.jobs.count!=0||
       s.bridgeBusy||s.warming||s.settingsDirty||!s.surfaceSupported)return;
    s.recoveryProbeInFlight=true;uint64_t epoch=s.recoveryEpoch,probeID=++s.recoveryProbeID;
    double started=NSProcessInfo.processInfo.systemUptime;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){
        double milliseconds=(NSProcessInfo.processInfo.systemUptime-started)*1000;
        NSString *error=completed.status==MTLCommandBufferStatusError ?
            (completed.error.localizedDescription ?: @"Recovery probe command failed") : nil;
        dispatch_async(s.queue,^{CompleteRecoveryProbe(epoch,probeID,milliseconds,error);});
    }];
    // A game may abandon an uncommitted original command during loading. Its
    // completion never fires. Re-arm without retaining its command/drawable;
    // a distinct ID prevents a late old completion from affecting the retry.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)s.deadlineMS*NSEC_PER_MSEC),s.queue,^{
        if(epoch==s.recoveryEpoch && probeID==s.recoveryProbeID && s.recoveryProbeInFlight) {
            s.recoveryProbeInFlight=false;Diagnostics();
        }
    });
}

void Original(id command,id<MTLDrawable> drawable,NSUInteger variant,CFTimeInterval parameter) {
    Scope scope;
    S().presentations.fetch_add(1);
    if(variant==0) ((Present)S().original[0].load())(command,@selector(presentDrawable:),drawable);
    else if(variant==1) ((TimedPresent)S().original[1].load())(command,@selector(presentDrawable:atTime:),drawable,parameter);
    else ((TimedPresent)S().original[2].load())(command,@selector(presentDrawable:afterMinimumDuration:),drawable,parameter);
}

void DirectOriginal(NRHookJob *job) {
    // Last-resort fallback if a fresh final command buffer cannot be allocated.
    // Game and conversion GPU work are already complete at this point.
    if(job.variant==0) [job.drawable present];
    else if(job.variant==1) [job.drawable presentAtTime:job.presentationParameter];
    else [job.drawable presentAfterMinimumDuration:job.presentationParameter];
}

bool Supported(id<CAMetalDrawable> drawable,BOOL &linear,BOOL &srgbTexture,NSString **reason) {
    State &s=S(); id<MTLTexture> t=drawable.texture; CAMetalLayer *layer=drawable.layer;
    NSString *name=nil; BOOL edr=NO, transaction=YES;
    [CATransaction lock];
    @try {
        CGColorSpaceRef space=layer.colorspace;
        name=space ? [(__bridge NSString*)CGColorSpaceGetName(space) copy] : nil;
        edr=layer.wantsExtendedDynamicRangeContent; transaction=layer.presentsWithTransaction;
        s.observedSurface=@{
            @"colorSpaceName":name ?: (id)[NSNull null],
            @"wantsExtendedDynamicRangeContent":@(edr), @"presentsWithTransaction":@(transaction),
            @"width":@(t.width), @"height":@(t.height), @"pixelFormat":@(t.pixelFormat),
            @"framebufferOnly":@(t.framebufferOnly), @"maximumDrawableCount":@(layer.maximumDrawableCount)
        };
    } @finally { [CATransaction unlock]; }
    if(!layer || !t || t.device.registryID!=s.device.registryID ||
       t.textureType!=MTLTextureType2D || t.sampleCount!=1 || t.framebufferOnly) {
        *reason=@"Unsupported drawable/device/framebuffer-only texture"; return false;
    }
    if(t.width!=s.width || t.height!=s.height) { *reason=@"Geometry changed; warmup required"; return false; }
    if(t.pixelFormat!=MTLPixelFormatBGRA8Unorm && t.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB &&
       t.pixelFormat!=MTLPixelFormatRGBA16Float) { *reason=@"Unsupported pixel format"; return false; }
    if(edr || transaction) { *reason=@"HDR/EDR or transactional presentation is unsupported"; return false; }
    linear=[name isEqualToString:(__bridge NSString*)kCGColorSpaceLinearSRGB] ||
           [name isEqualToString:(__bridge NSString*)kCGColorSpaceExtendedLinearSRGB];
    // Extended color spaces use the same transfer functions in [0,1]. The
    // conversion GPU guard still rejects every negative/over-one/nonfinite pixel.
    if(!linear && ![name isEqualToString:(__bridge NSString*)kCGColorSpaceSRGB] &&
                  ![name isEqualToString:(__bridge NSString*)kCGColorSpaceExtendedSRGB]) {
        *reason=@"Only explicit SDR sRGB or linear-sRGB is supported"; return false;
    }
    srgbTexture=t.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB;
    if(linear && srgbTexture) { *reason=@"Linear color space on sRGB format is unsupported"; return false; }
    return true;
}

bool AllocateInput(NRHookJob *job) {
    State &s=S();
    NSDictionary *attributes=@{
        (__bridge NSString*)kCVPixelBufferWidthKey:@(s.width),
        (__bridge NSString*)kCVPixelBufferHeightKey:@(s.height),
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
        (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey:@YES,
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}
    };
    if(!s.inputPool && CVPixelBufferPoolCreate(nullptr,nullptr,(__bridge CFDictionaryRef)attributes,&s.inputPool)!=kCVReturnSuccess)
        return false;
    CVPixelBufferRef input=nullptr;
    // Pool returns a different surface while any GPU job or late bridge
    // callback retains the previous input. No manual slot reuse is allowed.
    if(CVPixelBufferPoolCreatePixelBuffer(nullptr,s.inputPool,&input)!=kCVReturnSuccess) return false;
    job.input=input;
    CVBufferSetAttachment(input,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(input,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVMetalTextureRef wrapper=nullptr;
    if(CVMetalTextureCacheCreateTextureFromImage(nullptr,s.textureCache,input,nullptr,MTLPixelFormatBGRA8Unorm,
        s.width,s.height,0,&wrapper)!=kCVReturnSuccess) return false;
    job.inputWrapper=wrapper;
    job.rangeFlags=[s.device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if(!job.rangeFlags) return false;
    *(uint32_t*)job.rangeFlags.contents=0;
    return true;
}

void BridgeFrame(int32_t status,CVPixelBufferRef output,double timestamp,double milliseconds,const char *error,void *context) {
    (void)timestamp; (void)milliseconds;
    NRHookJob *job=(__bridge_transfer NRHookJob*)context;
    CVPixelBufferRef retained=output ? CVPixelBufferRetain(output) : nullptr;
    NSString *message=error ? [NSString stringWithUTF8String:error] : nil;
    double completedAt=NSProcessInfo.processInfo.systemUptime;
    NRNeuralTimings bridgeTimings{}; if(S().copyTimings) S().copyTimings(&bridgeTimings);
    dispatch_async(S().queue,^{ @autoreleasepool {
        State &s=S(); s.bridgeBusy=NO;
        NRFrameHookTimings timings=job.timings;
        timings.bridgeMilliseconds=(completedAt-job.bridgeStarted)*1000;
        timings.resizeMilliseconds=bridgeTimings.resizeMilliseconds;timings.motionMilliseconds=bridgeTimings.motionMilliseconds;
        timings.inferenceMilliseconds=bridgeTimings.inferenceMilliseconds;timings.writeMilliseconds=bridgeTimings.writeMilliseconds;
        timings.compositeMilliseconds=bridgeTimings.compositeMilliseconds;job.timings=timings;
        s.processingWidth=bridgeTimings.processingWidth;s.processingHeight=bridgeTimings.processingHeight;
        if(job.finished) {
            s.late.fetch_add(1);
            if(status!=NR_NEURAL_OK && status!=NR_NEURAL_CANCELLED) {
                Error(message ?: @"Late neural processing failed");Disable(@"Late neural processing failure");
            }
        }
        else if(s.recovering && (status==NR_NEURAL_OK || status==NR_NEURAL_CANCELLED)) Finish(job,nullptr);
        else if(status==NR_NEURAL_OK && retained && !s.disabled.load()) Finish(job,retained);
        else {
            // A successful callback racing with a manual disable is expected,
            // as is CANCELLED after generation invalidation; neither is an error.
            if(status!=NR_NEURAL_OK && status!=NR_NEURAL_CANCELLED)
                Error(message ?: @"Neural processing failed");
            else if(status==NR_NEURAL_OK && !retained && !s.disabled.load())
                Error(@"Neural processing returned no output");
            if(!s.disabled.load()) Disable(message ?: @"Neural processing stopped");
            Finish(job,nullptr);
        }
        if(retained) CVPixelBufferRelease(retained);
        Pump(); Diagnostics();
    }});
}

void SubmitNeural(NRHookJob *job) {
    State &s=S();
    if(job.finished) return;
    if(s.disabled.load() || s.recovering || job.expired || s.bridgeBusy || s.settingsDirty || !s.requested.enabled) { Finish(job,nullptr); return; }
    s.bridgeBusy=YES;job.bridgeStarted=NSProcessInfo.processInfo.systemUptime;
    void *context=(__bridge_retained void*)job;
    int32_t result=s.process(job.input,job.capturedAt,BridgeFrame,context);
    if(result!=NR_NEURAL_OK) {
        CFBridgingRelease(context); s.bridgeBusy=NO;
        Error([NSString stringWithFormat:@"Bridge rejected frame: %d",result]);
        Disable(@"Bridge rejected processing request"); Finish(job,nullptr);
    }
}

void Convert(NRHookJob *job) {
    State &s=S();
    job.conversionStarted=NSProcessInfo.processInfo.systemUptime;
    if(!AllocateInput(job)) { Error(@"Could not allocate owned neural input"); Disable(@"Input allocation failed"); Finish(job,nullptr); return; }
    id<MTLCommandBuffer> command=[s.gpu commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    if(!command || !encoder) { Error(@"Could not encode input conversion"); Disable(@"Input conversion failed"); Finish(job,nullptr); return; }
    uint32_t encodeSRGB=job.linearColor || job.srgbTexture;
    [encoder setComputePipelineState:s.conversion];
    [encoder setTexture:job.drawable.texture atIndex:0];
    [encoder setTexture:CVMetalTextureGetTexture(job.inputWrapper) atIndex:1];
    [encoder setBuffer:job.rangeFlags offset:0 atIndex:0];
    [encoder setBytes:&encodeSRGB length:sizeof(encodeSRGB) atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(s.width,s.height,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
    [encoder endEncoding]; job.converting=YES;
    [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        double completedAt=NSProcessInfo.processInfo.systemUptime,gpuMS=GPUTime(finished);
        dispatch_async(s.queue,^{ @autoreleasepool {
            job.converting=NO;
            NRFrameHookTimings timings=job.timings;timings.conversionMilliseconds=(completedAt-job.conversionStarted)*1000;
            timings.conversionGPUMilliseconds=gpuMS;job.timings=timings;
            if(finished.status==MTLCommandBufferStatusError) {
                Error(finished.error.localizedDescription ?: @"Input GPU conversion failed"); Disable(@"Input GPU conversion failed");
            } else if(*(uint32_t*)job.rangeFlags.contents) {
                s.unsupported.fetch_add(1); Disable(@"Input exceeds SDR range, is nonfinite, or has nonopaque alpha");
            }
            SubmitNeural(job);
        }});
    }];
    [command commit];
}

void ReleaseJobResources(NRHookJob *job) {
    State &s=S();
    [s.activeDrawables removeObject:[NSValue valueWithPointer:(__bridge const void*)job.drawable]];
    job.drawable=nil;
    // Deadline blocks and an overdue bridge callback may still retain the job.
    // Neither needs these input owners after presentation; the bridge has its
    // own retain until callback and the conversion GPU work is already done.
    if(job.inputWrapper) { CFRelease(job.inputWrapper); job.inputWrapper=nullptr; }
    if(job.input) { CVPixelBufferRelease(job.input); job.input=nullptr; }
    job.rangeFlags=nil;
}

void Retire(NRHookJob *job) {
    State &s=S();
    if(job.processed) { s.timingSamples.push_back(job.timings);if(s.timingSamples.size()>30)s.timingSamples.pop_front(); }
    ReleaseJobResources(job);
    job.retired=YES;s.pending.fetch_sub(1); s.completed.fetch_add(1);
    if(job.finalDone) dispatch_semaphore_signal(job.finalDone);
    Pump(); Diagnostics();
}

void Finish(NRHookJob *job,CVPixelBufferRef output) {
    State &s=S();
    if(job.finished) { s.late.fetch_add(1); return; }
    if(job.converting || !job.gameReady || s.jobs.firstObject!=job) return;
    if(s.recovering || job.recoveryEpoch!=s.recoveryEpoch)output=nullptr;
    // Timers and bridge callbacks share this queue. If the timer has not run
    // yet, an already overdue result must still lose to original-frame fallback.
    if(output && NSProcessInfo.processInfo.systemUptime-job.capturedAt >= (double)s.deadlineMS/1000.0) {
        if(!job.expired) { job.expired=YES; s.expired.fetch_add(1); }
        PauseForTiming(job,@"Frame deadline exceeded before final write; draining to originals");
        output=nullptr;
    }
    BOOL processed=output!=nullptr;
    CVMetalTextureRef wrapper=nullptr;
    if(processed && (CVPixelBufferGetWidth(output)!=s.width || CVPixelBufferGetHeight(output)!=s.height ||
       CVPixelBufferGetPixelFormatType(output)!=kCVPixelFormatType_32BGRA ||
       CVMetalTextureCacheCreateTextureFromImage(nullptr,s.textureCache,output,nullptr,MTLPixelFormatBGRA8Unorm,
           s.width,s.height,0,&wrapper)!=kCVReturnSuccess)) {
        Error(@"Invalid neural output buffer"); Disable(@"Invalid neural output"); processed=NO;
    }
    job.finalStarted=NSProcessInfo.processInfo.systemUptime;
    id<MTLCommandBuffer> command=[s.gpu commandBuffer];
    if(processed) {
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=job.drawable.texture;
        pass.colorAttachments[0].loadAction=MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
        if(encoder) {
            [encoder setRenderPipelineState:s.finalPipelines[(NSUInteger)job.drawable.texture.pixelFormat]];
            // The comparison left half stays in the original drawable, avoiding
            // an SDR8 round-trip for linear/half-float native pixels.
            NSUInteger left=MIN((NSUInteger)s.width,(NSUInteger)std::ceil(s.width*job.settings.split));
            if(left<s.width) [encoder setScissorRect:MTLScissorRect{left,0,(NSUInteger)s.width-left,(NSUInteger)s.height}];
            [encoder setFragmentTexture:CVMetalTextureGetTexture(wrapper) atIndex:0];
            uint32_t decodeSRGB=job.linearColor || job.srgbTexture;
            [encoder setFragmentBytes:&decodeSRGB length:sizeof(decodeSRGB) atIndex:0];
            if(left<s.width) [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding];
        } else { Error(@"Could not encode final neural write"); Disable(@"Final render encoder unavailable"); processed=NO; }
    }
    job.finished=YES;job.processed=processed;
    if(processed) s.processed.fetch_add(1); else s.bypassed.fetch_add(1);
    [s.jobs removeObjectAtIndex:0];
    if(command) {
        EncodeOverlay(command,job.drawable);
        if(s.observer) s.observer((__bridge void*)command,(__bridge void*)job.drawable.texture,job.sequence,processed,s.observerContext);
        Original(command,job.drawable,job.variant,job.presentationParameter);
        CVPixelBufferRef retained=processed ? CVPixelBufferRetain(output) : nullptr;
        [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            double completedAt=NSProcessInfo.processInfo.systemUptime,gpuMS=GPUTime(finished);
            dispatch_async(s.queue,^{ @autoreleasepool {
                NRFrameHookTimings timings=job.timings;timings.finalMilliseconds=(completedAt-job.finalStarted)*1000;
                timings.finalGPUMilliseconds=gpuMS;timings.totalMilliseconds=(completedAt-job.capturedAt)*1000;job.timings=timings;
                if(finished.status==MTLCommandBufferStatusError) {
                    Error(finished.error.localizedDescription ?: @"Final GPU write failed"); Disable(@"Final GPU error");
                }
                if(wrapper) CFRelease(wrapper);
                if(retained) CVPixelBufferRelease(retained);
                Retire(job);
            }});
        }];
        [command commit];
    } else {
        if(wrapper) CFRelease(wrapper);
        Error(@"Could not allocate final command buffer"); Disable(@"Final command buffer unavailable");
        DirectOriginal(job); Retire(job);
    }
    dispatch_async(s.queue,^{ Pump(); });
}

void Pump() {
    State &s=S(); NRHookJob *job=s.jobs.firstObject;
    // An unsubmitted producer can be discarded during an aborted frame. Its
    // ARC weak identity then clears; never display that unrendered drawable.
    // Drop only the queue head, preserving every later frame's ordering.
    // Submitted producers are excluded: their GPU completion is authoritative.
    while(job && !job.finished && !job.gameReady && !job.producerSubmitted && !job.producerCommand) {
        job.finished=YES;
        Disable(@"Producer command was abandoned before submission; processing disabled");
        {
            std::lock_guard<std::mutex> guard(s.commitLock);
            auto found=s.committingJobs.find(job.producerIdentity);
            if(found!=s.committingJobs.end() && found->second==job) s.committingJobs.erase(found);
        }
        [s.jobs removeObjectAtIndex:0];
        ReleaseJobResources(job);
        job.retired=YES;s.pending.fetch_sub(1); s.abandoned.fetch_add(1);
        if(job.finalDone) dispatch_semaphore_signal(job.finalDone);
        job=s.jobs.firstObject;
        Diagnostics();
    }
    if(!job) { if(s.pending.load()==0 && !s.bridgeBusy && !s.warming) ApplyPendingSettings(); return; }
    if(!job.gameReady || job.finished || job.converting) return;
    if(s.disabled.load() || s.recovering || job.expired || s.settingsDirty || !s.requested.enabled || s.warming) { Finish(job,nullptr); return; }
    if(s.bridgeBusy) return;
    Convert(job);
}

bool Accept(id<MTLCommandBuffer> command,id<MTLDrawable> drawable,NSUInteger variant,CFTimeInterval parameter) {
    State &s=S();
    if(!s.installed.load() || ![drawable respondsToSelector:@selector(layer)] ||
       ![drawable respondsToSelector:@selector(texture)] || command.status>=MTLCommandBufferStatusCommitted) return false;
    __block BOOL accepted=NO;
    dispatch_sync(s.queue,^{ @autoreleasepool {
        id<CAMetalDrawable> metal=(id<CAMetalDrawable>)drawable;
        if(s.selectedLayer && metal.layer!=s.selectedLayer) return;
        if(s.disabled.load() && s.pending.load()==0) return;
        BOOL linear=NO,srgb=NO; NSString *reason=nil;
        BOOL supported=Supported(metal,linear,srgb,&reason);
        s.surfaceSupported=supported;
        if(!supported) s.lastReason=reason;
        if(s.recovering && s.pending.load()==0) {
            if(supported)ObserveRecoveryProbe(command);
            else if(s.armed.load() && s.applied.enabled && s.requested.enabled && !s.settingsDirty && !s.warming) {
                s.unsupported.fetch_add(1);Disable(reason);
            }
            return;
        }
        if(s.pending.load()==0 && (!s.armed.load() || !s.applied.enabled || !s.requested.enabled || s.settingsDirty || s.warming)) return;
        if(!supported) {
            s.unsupported.fetch_add(1); s.lastReason=reason;
            if(!s.selectedLayer || s.pending.load()==0) { if(s.selectedLayer) Disable(reason); return; }
            Disable(reason); // Already queued frames must not be overtaken.
        }
        NSValue *identity=[NSValue valueWithPointer:(__bridge const void*)drawable];
        if([s.activeDrawables containsObject:identity]) {
            Error(@"Duplicate presentation of a retained drawable"); Disable(@"Duplicate presentation");
            accepted=YES; return; // Original drawable is already queued exactly once.
        }
        if(!s.selectedLayer) s.selectedLayer=metal.layer;
        NRHookJob *job=[NRHookJob new]; job.drawable=metal; job.sequence=++s.sequence;
        job.settings=s.applied;job.recoveryEpoch=s.recoveryEpoch;
        job.producerCommand=command; job.producerIdentity=(__bridge void*)command;
        job.finalDone=dispatch_semaphore_create(0);
        // Sequence numbers are identities, not seconds: passing sequence as
        // time reset temporal history on every frame (> 0.5 s discontinuity).
        // Use source capture time and guarantee strict increase even if the
        // system clock returns identical values for adjacent submissions.
        job.capturedAt=fmax(NSProcessInfo.processInfo.systemUptime,
                            std::nextafter(s.lastCaptureTimestamp,INFINITY));
        s.lastCaptureTimestamp=job.capturedAt;
        job.variant=variant; job.presentationParameter=parameter;
        job.linearColor=linear; job.srgbTexture=srgb;
        [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            double completedAt=NSProcessInfo.processInfo.systemUptime,gpuMS=GPUTime(finished);
            dispatch_async(s.queue,^{ @autoreleasepool {
                job.gameReady=YES;
                NRFrameHookTimings timings=job.timings;timings.producerMilliseconds=(completedAt-job.capturedAt)*1000;
                timings.producerGPUMilliseconds=gpuMS;job.timings=timings;
                if(finished.status==MTLCommandBufferStatusError) {
                    Error(finished.error.localizedDescription ?: @"Game command buffer failed"); Disable(@"Producer GPU error");
                }
                Pump();
            }});
        }];
        [s.jobs addObject:job]; [s.activeDrawables addObject:identity];
        if(s.serialCommit) {
            std::lock_guard<std::mutex> guard(s.commitLock);
            void *key=(__bridge void*)command;
            auto previous=s.committingJobs.find(key);
            if(previous!=s.committingJobs.end() && previous->second.producerCommand==command) {
                Error(@"Multiple deferred drawables in one command buffer are unsupported");
                Disable(@"Multiple drawables in tracked producer command buffer");
            }
            s.committingJobs[key]=job;
        }
        uint64_t pending=s.pending.fetch_add(1)+1;
        if(pending>s.peak.load()) s.peak.store(pending);
        // maximumDrawableCount is NOT backpressure: an isolated CAMetalLayer
        // already exceeded it in our harness. SERIAL_COMMIT bounds a single
        // producer loop; this check only disables on unexpected concurrency.
        if(pending>metal.layer.maximumDrawableCount) {
            Error(@"Drawable pool bound changed; candidate requires further validation"); Disable(@"Unexpected drawable pool expansion");
        }
        s.accepted.fetch_add(1); s.selectors[variant].fetch_add(1); accepted=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)s.deadlineMS*NSEC_PER_MSEC),s.queue,^{
            if(job.finished || job.retired || job.recoveryEpoch!=s.recoveryEpoch) return;
            job.expired=YES; s.expired.fetch_add(1); PauseForTiming(job,@"Frame deadline exceeded; draining to originals");
            Pump(); Diagnostics();
        });
    }});
    return accepted;
}

void Hook0(id command,SEL selector,id<MTLDrawable> drawable) {
    Scope scope; if(scope.outer && Accept(command,drawable,0,0)) return;
    if(scope.outer) { S().presentations.fetch_add(1);if([drawable respondsToSelector:@selector(texture)])EncodeOverlay(command,(id<CAMetalDrawable>)drawable); }
    ((Present)S().original[0].load())(command,selector,drawable);
}
void Hook1(id command,SEL selector,id<MTLDrawable> drawable,CFTimeInterval value) {
    Scope scope; if(scope.outer && Accept(command,drawable,1,value)) return;
    if(scope.outer) { S().presentations.fetch_add(1);if([drawable respondsToSelector:@selector(texture)])EncodeOverlay(command,(id<CAMetalDrawable>)drawable); }
    ((TimedPresent)S().original[1].load())(command,selector,drawable,value);
}
void Hook2(id command,SEL selector,id<MTLDrawable> drawable,CFTimeInterval value) {
    Scope scope; if(scope.outer && Accept(command,drawable,2,value)) return;
    if(scope.outer) { S().presentations.fetch_add(1);if([drawable respondsToSelector:@selector(texture)])EncodeOverlay(command,(id<CAMetalDrawable>)drawable); }
    ((TimedPresent)S().original[2].load())(command,selector,drawable,value);
}

void HookCommit(id command,SEL selector) {
    State &s=S(); NRHookJob *job=nil;
    {
        std::lock_guard<std::mutex> guard(s.commitLock);
        auto found=s.committingJobs.find((__bridge void*)command);
        if(found!=s.committingJobs.end()) {
            // The address alone is not identity: an abandoned producer may be
            // deallocated and its address reused by an unrelated MLX command.
            NRHookJob *candidate=found->second;
            if(candidate.producerCommand==command) {
                job=candidate; job.producerSubmitted=YES;job.submittedAt=NSProcessInfo.processInfo.systemUptime;
            }
            s.committingJobs.erase(found);
        }
    }
    // Producer GPU work must be submitted before any wait. All conversion,
    // final-output and MLX command buffers have no entry and never wait here.
    ((Commit)s.originalCommit.load())(command,selector);
    if(!job || !s.serialCommit) return;
    s.commitWaits.fetch_add(1);
    if(dispatch_semaphore_wait(job.finalDone,dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC))) {
        // The game might need to submit a future command to satisfy a GPU
        // dependency. Return its thread after a fixed bound, never waitUntilCompleted.
        s.commitTimeouts.fetch_add(1);
        dispatch_async(s.queue,^{
            // finished only means final submission, not GPU retirement. The
            // epoch/retired check prevents an old notification re-pausing a
            // newer recovered frame, but still catches final-GPU stalls.
            if(job.retired || job.recoveryEpoch!=s.recoveryEpoch)return;
            PauseForTiming(job,@"Producer backpressure reached 500 ms; draining to originals");Pump();Diagnostics();
        });
    }
}

bool Install() {
    Class cls=object_getClass([S().gpu commandBuffer]);
    SEL selectors[]={@selector(presentDrawable:),@selector(presentDrawable:atTime:),@selector(presentDrawable:afterMinimumDuration:)};
    IMP hooks[]={(IMP)Hook0,(IMP)Hook1,(IMP)Hook2};
    for(int i=0;i<3;i++) if(!class_getInstanceMethod(cls,selectors[i])) return false;
    Method commitMethod=class_getInstanceMethod(cls,@selector(commit));
    if(S().serialCommit && !commitMethod) return false;
    for(int i=0;i<3;i++) {
        Method method=class_getInstanceMethod(cls,selectors[i]); S().original[i].store(method_getImplementation(method));
        const char *type=method_getTypeEncoding(method);
        if(!class_addMethod(cls,selectors[i],hooks[i],type)) class_replaceMethod(cls,selectors[i],hooks[i],type);
    }
    if(S().serialCommit) {
        S().originalCommit.store(method_getImplementation(commitMethod));
        const char *type=method_getTypeEncoding(commitMethod);
        if(!class_addMethod(cls,@selector(commit),(IMP)HookCommit,type))
            class_replaceMethod(cls,@selector(commit),(IMP)HookCommit,type);
    }
    S().installed.store(true); return true;
}

void Ready(int32_t status,NSString *error) {
    State &s=S();
    if(status!=NR_NEURAL_OK) { s.warming=false;s.bridgeBusy=NO;Error(error ?: @"Initialization failed"); Disable(error ?: @"Initialization failed"); }
    Diagnostics();
    NRFrameHookReadyCallback callback=s.ready; void *context=s.readyContext; s.ready=nullptr; s.readyContext=nullptr;
    if(callback) callback(status,error.UTF8String,context);
}

void WarmupComplete(int32_t status,CVPixelBufferRef output,double timestamp,double milliseconds,const char *error,void *context) {
    (void)output; (void)timestamp; (void)milliseconds;
    NRHookJob *warmup=(__bridge_transfer NRHookJob*)context;
    NSString *message=error ? [NSString stringWithUTF8String:error] : nil;
    dispatch_async(S().queue,^{
        (void)warmup; State &s=S();
        if(status!=NR_NEURAL_OK) { Ready(status,message ?: @"Warmup failed"); return; }
        if(warmup.warmupFrame<2) {
            ++warmup.warmupFrame;
            void *owner=(__bridge_retained void*)warmup;
            int32_t result=s.process(warmup.input,(double)warmup.warmupFrame/30.0,WarmupComplete,owner);
            if(result!=NR_NEURAL_OK) { CFBridgingRelease(owner); Ready(result,@"Temporal warmup was rejected"); }
            return;
        }
        // Zero intensity bypasses the model. Warm it at positive intensity,
        // then restore the requested controls without discarding resources.
        auto actual=s.applied;
        int32_t restored=s.setSettings(actual.intensity,actual.tone,actual.structure,actual.split,actual.processingLongEdge);
        if(restored!=NR_NEURAL_OK){Ready(restored,@"Could not restore controls after warmup");return;}
        s.invalidate();
        s.bridgeBusy=NO;s.warming=false;
        NRNeuralTimings timings{};s.copyTimings(&timings);s.processingWidth=timings.processingWidth;s.processingHeight=timings.processingHeight;
        if(!s.installed.load()) {
            if(!Install()) { Ready(NR_NEURAL_FAILED,@"Could not install all presentation variants"); return; }
            Ready(NR_NEURAL_OK,nil);
        }
        ApplyPendingSettings();Diagnostics();
    });
}

void PersistSettings() {
    State &s=S(); if(!s.settingsPath)return;
    uint64_t revision=s.appliedRevision;
    // Slider motion is coalesced. Writes run on their own serial queue and
    // never touch activation/emergency-stop files or persist enabled=true.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),s.queue,^{
        if(s.appliedRevision!=revision)return;
        NRFrameHookSettings values=s.applied;NSString *path=s.settingsPath;
        NSDictionary *object=@{@"schemaVersion":@1,@"intensity":@(values.intensity),@"tone":@(values.tone),
            @"structure":@(values.structure),@"split":@(values.split),@"processingLongEdge":@(values.processingLongEdge)};
        static dispatch_queue_t writer=dispatch_queue_create("local.nr.frame-hook.settings-writer",DISPATCH_QUEUE_SERIAL);
        dispatch_async(writer,^{ @autoreleasepool {
            NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
            if(data)[data writeToFile:path options:NSDataWritingAtomic error:nil];
        }});
    });
}

void BeginWarmup() {
    State &s=S();s.warming=true;s.bridgeBusy=YES;
    if(s.applied.intensity==0) {
        auto actual=s.applied;
        int32_t forced=s.setSettings(1,actual.tone,actual.structure,actual.split,actual.processingLongEdge);
        if(forced!=NR_NEURAL_OK){Ready(forced,@"Could not prepare zero-intensity settings");return;}
    }
    // SetSettings deliberately preserves accepted timestamp monotonicity.
    // A fresh generation is required before synthetic warmup times 0,1/30,2/30.
    s.invalidate();
    NRHookJob *job=[NRHookJob new];
    if(!AllocateInput(job)) { Ready(NR_NEURAL_FAILED,@"Could not allocate warmup input"); return; }
    CVPixelBufferLockBaseAddress(job.input,0);
    uint8_t *base=(uint8_t*)CVPixelBufferGetBaseAddress(job.input);
    size_t stride=CVPixelBufferGetBytesPerRow(job.input);
    for(uint32_t y=0;y<s.height;y++) for(uint32_t x=0;x<s.width;x++) {
        uint8_t *p=base+y*stride+x*4;p[0]=77;p[1]=51;p[2]=26;p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(job.input,0);
    void *owner=(__bridge_retained void*)job;
    int32_t result=s.process(job.input,0,WarmupComplete,owner);
    if(result!=NR_NEURAL_OK) { CFBridgingRelease(owner);Ready(result,@"Warmup was rejected"); }
    Diagnostics();
}

void ApplyPendingSettings() {
    State &s=S();
    if(!s.settingsDirty||s.disabled.load()||s.warming||s.bridgeBusy||s.pending.load()!=0||!s.installed.load())return;
    NRFrameHookSettings next=s.requested;
    // Activation checks are repeated at the idle boundary; a surface can
    // change after the UI took its snapshot (for example enabling HDR).
    if(next.enabled&&!s.applied.enabled&&!s.surfaceSupported) {
        s.requested=s.applied;s.settingsDirty=false;s.lastReason=@"Choose a supported SDR game surface before enabling HT";
        s.controlNotice=s.lastReason;
        Diagnostics();return;
    }
    int32_t result=s.setSettings(next.intensity,next.tone,next.structure,next.split,next.processingLongEdge);
    if(result==NR_NEURAL_BUSY)return;
    if(result!=NR_NEURAL_OK) {
        Error(@"Bridge rejected validated controls");s.requested=s.applied;s.settingsDirty=false;Diagnostics();return;
    }
    bool resolutionChanged=next.processingLongEdge!=s.applied.processingLongEdge;
    s.applied=next;s.appliedRevision=s.requestedRevision;s.settingsDirty=false;
    s.controlNotice=nil;
    if(next.enabled)s.armed.store(true);
    PersistSettings();
    if(resolutionChanged)BeginWarmup();
    else { s.lastReason=nil;Diagnostics(); }
}

void Initialized(int32_t status,const char *error,void *context) {
    (void)context; NSString *message=error ? [NSString stringWithUTF8String:error] : nil;
    dispatch_async(S().queue,^{ @autoreleasepool {
        if(status!=NR_NEURAL_OK) { Ready(status,message ?: @"Model load failed"); return; }
        State &s=S();auto next=s.requested;
        int32_t result=s.setSettings(next.intensity,next.tone,next.structure,next.split,next.processingLongEdge);
        if(result!=NR_NEURAL_OK) { Ready(result,@"Initial settings were rejected");return; }
        s.applied=next;s.appliedRevision=s.requestedRevision;s.settingsDirty=false;
        BeginWarmup();
    }});
}

bool Pipelines() {
    State &s=S(); NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
    "float3 encode(float3 v){return select(1.055f*pow(max(v,float3(0)),float3(1.0f/2.4f))-0.055f,12.92f*v,v<=0.0031308f);}\n"
    "float3 decode(float3 v){return select(pow((v+0.055f)/1.055f,float3(2.4f)),v/12.92f,v<=0.04045f);}\n"
    "kernel void toInput(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],"
    "device atomic_uint*bad[[buffer(0)]],constant uint&enc[[buffer(1)]],uint2 p[[thread_position_in_grid]]){"
    "if(p.x>=dst.get_width()||p.y>=dst.get_height())return;float4 v=src.read(p);"
    "if(any(!isfinite(v))||any(v.rgb<0)||any(v.rgb>1)||abs(v.a-1)>0.0001f)atomic_store_explicit(bad,1u,memory_order_relaxed);"
    "dst.write(float4(enc?encode(v.rgb):v.rgb,1),p);}\n"
    "struct V{float4 p[[position]];float2 uv;};vertex V vertexMain(uint i[[vertex_id]]){"
    "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};float2 u[3]={float2(0,1),float2(2,1),float2(0,-1)};return{float4(p[i],0,1),u[i]};}\n"
    "fragment float4 fragmentMain(V in[[stage_in]],texture2d<float>src[[texture(0)]],constant uint&dec[[buffer(0)]]){"
    "constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest);float3 c=src.sample(s,in.uv).rgb;return float4(dec?decode(c):c,1);}\n";
    id<MTLLibrary> library=[s.device newLibraryWithSource:source options:nil error:&error];
    if(!library) { Error(error.localizedDescription ?: @"Shader compilation failed"); return false; }
    s.conversion=[s.device newComputePipelineStateWithFunction:[library newFunctionWithName:@"toInput"] error:&error];
    if(!s.conversion) return false;
    MTLPixelFormat formats[]={MTLPixelFormatBGRA8Unorm,MTLPixelFormatBGRA8Unorm_sRGB,MTLPixelFormatRGBA16Float};
    for(auto format:formats) {
        MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
        d.vertexFunction=[library newFunctionWithName:@"vertexMain"]; d.fragmentFunction=[library newFunctionWithName:@"fragmentMain"];
        d.colorAttachments[0].pixelFormat=format;
        id<MTLRenderPipelineState> pipeline=[s.device newRenderPipelineStateWithDescriptor:d error:&error];
        if(!pipeline) { Error(error.localizedDescription ?: @"Final pipeline creation failed"); return false; }
        s.finalPipelines[(NSUInteger)format]=pipeline;
    }
    return true;
}
}

extern "C" int32_t NRFrameHookStartForTesting(const char *bridge,const char *model,const char *diagnostic,
    uint32_t width,uint32_t height,NRFrameHookReadyCallback callback,void *context) {
    if(!TestMode() || !Absolute(bridge) || !Absolute(model) || !Absolute(diagnostic) ||
       !callback || width<2 || height<2 || width>8192 || height>8192) return NR_NEURAL_INVALID_ARGUMENT;
    State &s=S(); if(s.started.exchange(true)) return NR_NEURAL_BUSY;
    s.width=width;s.height=height;s.ready=callback;s.readyContext=context;
    const char *serial=getenv("NR_FRAME_HOOK_SERIAL_COMMIT"); s.serialCommit=serial && !strcmp(serial,"1");
    s.logPath=[NSString stringWithUTF8String:diagnostic];
    NSString *bridgePath=[NSString stringWithUTF8String:bridge], *modelPath=[NSString stringWithUTF8String:model];
    const char *disable=getenv("NR_FRAME_HOOK_DISABLE_FILE");
    if(Absolute(disable)) s.disablePath=[NSString stringWithUTF8String:disable];
    const char *enable=getenv("NR_FRAME_HOOK_ENABLE_FILE");
    if(Absolute(enable)) { s.enablePath=[NSString stringWithUTF8String:enable]; s.armed.store(false);s.requested.enabled=0;s.applied.enabled=0; }
    const char *settings=getenv("NR_FRAME_HOOK_SETTINGS_FILE");
    if(Absolute(settings)) s.settingsPath=[NSString stringWithUTF8String:settings];
    const char *deadline=getenv("NR_FRAME_HOOK_DEADLINE_MS");
    if(deadline) { char *end=nullptr; long value=strtol(deadline,&end,10); if(end && !*end && value>=50 && value<=1000) s.deadlineMS=(unsigned)value; }
    s.queue=dispatch_queue_create("local.nr.frame-hook.test",DISPATCH_QUEUE_SERIAL);
    dispatch_async(s.queue,^{ @autoreleasepool {
        s.jobs=[NSMutableArray new];s.activeDrawables=[NSMutableSet new];
        if(s.settingsPath) {
            NSData *data=[NSData dataWithContentsOfFile:s.settingsPath];
            id parsed=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if([parsed isKindOfClass:NSDictionary.class]) {
                NSDictionary *object=parsed;auto values=s.requested;
                NSArray *keys=@[@"intensity",@"tone",@"structure",@"split",@"processingLongEdge"];
                bool numbers=true;for(NSString *key in keys)numbers&=[object[key] isKindOfClass:NSNumber.class];
                if(numbers) {
                    values.intensity=[object[@"intensity"] floatValue];values.tone=[object[@"tone"] floatValue];
                    values.structure=[object[@"structure"] floatValue];values.split=[object[@"split"] floatValue];
                    double edge=[object[@"processingLongEdge"] doubleValue];
                    if(std::isfinite(edge)&&edge>=640&&edge<=1920&&std::floor(edge)==edge) {
                        values.processingLongEdge=(uint32_t)edge;
                        if(ValidSettings(values))s.requested=values;
                    }
                }
            }
        }
        s.library=dlopen(bridgePath.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
        if(!s.library) { Ready(NR_NEURAL_FAILED,[NSString stringWithUTF8String:dlerror()]); return; }
        s.initialize=(Initialize)dlsym(s.library,"NRNeuralInitialize");
        s.process=(Process)dlsym(s.library,"NRNeuralProcess");
        s.invalidate=(Invalidate)dlsym(s.library,"NRNeuralInvalidate");
        s.getState=(GetState)dlsym(s.library,"NRNeuralGetState");
        s.setSettings=(SetSettings)dlsym(s.library,"NRNeuralSetSettings");
        s.copyTimings=(CopyTimings)dlsym(s.library,"NRNeuralCopyLastTimings");
        if(!s.initialize||!s.process||!s.invalidate||!s.getState||!s.setSettings||!s.copyTimings) { Ready(NR_NEURAL_FAILED,@"Bridge symbols missing"); return; }
        s.device=MTLCreateSystemDefaultDevice();s.gpu=[s.device newCommandQueue];
        if(!s.gpu || CVMetalTextureCacheCreate(nullptr,nullptr,s.device,nullptr,&s.textureCache)!=kCVReturnSuccess || !Pipelines()) {
            Ready(NR_NEURAL_FAILED,@"Metal setup failed");return;
        }
        s.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,s.queue);
        dispatch_source_set_timer(s.timer,DISPATCH_TIME_NOW,NSEC_PER_MSEC*100,NSEC_PER_MSEC*10);
        dispatch_source_set_event_handler(s.timer,^{
            if(s.disablePath && access(s.disablePath.fileSystemRepresentation,F_OK)==0) Disable(@"Disable file requested");
            if(s.enablePath && !s.armed.load() && s.surfaceSupported && !s.disabled.load() &&
                access(s.enablePath.fileSystemRepresentation,F_OK)==0) {
                s.requested.enabled=1;++s.requestedRevision;s.settingsDirty=true;
            }
            Pump(); Diagnostics();
        });dispatch_resume(s.timer);
        int32_t result=s.initialize(modelPath.fileSystemRepresentation,Initialized,nullptr);
        if(result!=NR_NEURAL_OK) Ready(result,@"Bridge initialization rejected");
    }});
    return NR_NEURAL_OK;
}

extern "C" void NRFrameHookDisableForTesting() {
    if(!TestMode() || !S().queue) return;
    S().disabled.store(true);
    dispatch_async(S().queue,^{ Disable(@"Test requested disable"); Pump(); Diagnostics(); });
}
extern "C" void NRFrameHookCopyCountersForTesting(NRFrameHookCounters *out) {
    if(!out) return; State &s=S();
    *out={s.accepted.load(),s.processed.load(),s.bypassed.load(),s.expired.load(),s.late.load(),s.errors.load(),
        s.pending.load(),s.peak.load(),s.completed.load(),s.unsupported.load(),s.installed.load(),s.disabled.load()};
}
extern "C" void NRFrameHookSetObserverForTesting(NRFrameHookObserver observer,void *context) {
    if(!TestMode() || S().started.load()) return;
    S().observer=observer;S().observerContext=context;
}
extern "C" int32_t NRFrameHookSetSettings(const NRFrameHookSettings *settings) {
    if(!settings||!ValidSettings(*settings))return NR_NEURAL_INVALID_ARGUMENT;
    State &s=S();if(!s.queue||!s.installed.load())return NR_NEURAL_NOT_READY;
    if(s.disabled.load())return NR_NEURAL_FAILED;
    NRFrameHookSettings values=*settings;
    { std::lock_guard<std::mutex> guard(s.publicLock);
      if(values.enabled&&!s.published.applied.enabled&&!s.published.surfaceSupported)return NR_NEURAL_NOT_READY; }
    dispatch_async(s.queue,^{
        if(s.disabled.load()||EqualSettings(values,s.requested))return;
        s.requested=values;++s.requestedRevision;s.settingsDirty=true;s.controlNotice=nil;
        Pump();Diagnostics();
    });
    return NR_NEURAL_OK;
}
extern "C" int32_t NRFrameHookToggleEnabled(void) {
    State &s=S();if(!s.queue||!s.installed.load())return NR_NEURAL_NOT_READY;
    if(s.disabled.load())return NR_NEURAL_FAILED;
    dispatch_async(s.queue,^{
        if(s.disabled.load())return;
        // Read/modify on the owning queue, never from a possibly stale public
        // snapshot. Two queued presses therefore cancel even before publication.
        int32_t enabled=!s.requested.enabled;
        if(enabled&&!s.surfaceSupported) {
            s.controlNotice=@"Choose a supported SDR game surface before enabling HT";
            Diagnostics();return;
        }
        s.requested.enabled=enabled;++s.requestedRevision;s.settingsDirty=true;s.controlNotice=nil;
        Pump();Diagnostics();
    });
    return NR_NEURAL_OK;
}
extern "C" int32_t NRFrameHookSetParameters(const NRFrameHookSettings *settings) {
    if(!settings)return NR_NEURAL_INVALID_ARGUMENT;
    NRFrameHookSettings values=*settings;values.enabled=0; // Ignored, including non-boolean caller values.
    if(!ValidSettings(values))return NR_NEURAL_INVALID_ARGUMENT;
    State &s=S();if(!s.queue||!s.installed.load())return NR_NEURAL_NOT_READY;
    if(s.disabled.load())return NR_NEURAL_FAILED;
    dispatch_async(s.queue,^{
        if(s.disabled.load())return;
        NRFrameHookSettings latest=values;latest.enabled=s.requested.enabled;
        if(EqualSettings(latest,s.requested))return;
        s.requested=latest;++s.requestedRevision;s.settingsDirty=true;s.controlNotice=nil;
        Pump();Diagnostics();
    });
    return NR_NEURAL_OK;
}
extern "C" void NRFrameHookCopySnapshot(NRFrameHookSnapshot *out) {
    if(!out)return;std::lock_guard<std::mutex> guard(S().publicLock);*out=S().published;
}
extern "C" void NRFrameHookSetOverlayRenderer(NRFrameHookOverlayCallback callback,void *context) {
    std::lock_guard<std::mutex> guard(S().publicLock);S().overlay=callback;S().overlayContext=context;
}
