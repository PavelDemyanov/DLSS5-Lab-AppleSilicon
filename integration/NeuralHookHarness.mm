#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "NeuralFrameHook.h"
#include <dlfcn.h>
#include <atomic>
#include <cmath>
#include <mutex>
#include <vector>
#include <unistd.h>
#if defined(NR_FRAME_HOOK_QUEUE_TEST)
// CPU-only fixture: compile the production core into this translation unit to
// initialize its queue without loading MLX, installing hooks or creating GPU
// resources. All assertions below exercise the exported production APIs.
#include <cassert>
#include "NeuralFrameHook.mm"
@interface NRRecoveryProbeCommand : NSObject
@property(nonatomic,copy) MTLCommandBufferHandler completion;
@property(nonatomic) MTLCommandBufferStatus status;
@property(nonatomic,strong) NSError *error;
@property(nonatomic) NSUInteger registrations;
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler;
- (void)complete;
@end
@implementation NRRecoveryProbeCommand
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { self.completion=handler;++self.registrations; }
- (void)complete { self.status=MTLCommandBufferStatusCompleted;self.completion((id<MTLCommandBuffer>)self);self.completion=nil; }
@end
static NRFrameHookSettings queueBridgeSettings{};
static unsigned queueBridgeCalls=0;
static unsigned recoveryInvalidations=0;
static void RecoveryInvalidate(){++recoveryInvalidations;}
static int32_t QueueBridgeSettings(float intensity,float tone,float structure,float split,uint32_t edge) {
    queueBridgeSettings={intensity,tone,structure,split,edge,0};++queueBridgeCalls;return NR_NEURAL_OK;
}
static int QueueToggleRegression() { @autoreleasepool {
    assert(NRFrameHookToggleEnabled()==NR_NEURAL_NOT_READY);
    State &state=S();state.queue=dispatch_queue_create("local.nr.harness.control-queue",DISPATCH_QUEUE_SERIAL);
    state.jobs=[NSMutableArray new];state.warming=false;state.surfaceSupported=true;
    state.setSettings=QueueBridgeSettings;state.installed.store(true);state.armed.store(false);
    state.requested={.7f,1.3f,.4f,.2f,960,0};state.applied=state.requested;
    dispatch_sync(state.queue,^{PublishSnapshot();});
    auto drain=[&]{dispatch_sync(state.queue,^{});};
    auto hold=[&] {
        dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
        dispatch_async(state.queue,^{dispatch_semaphore_signal(entered);
            assert(dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);});
        assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);return release;
    };
    NRFrameHookSnapshot before{},after{};NRFrameHookCopySnapshot(&before);
    auto gate=hold();
    for(int i=0;i<128;i++)assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);
    NRFrameHookCopySnapshot(&after);assert(after.requestedRevision==before.requestedRevision&&after.requested.enabled==0);
    dispatch_semaphore_signal(gate);drain();NRFrameHookCopySnapshot(&after);
    assert(after.requested.enabled==0&&after.applied.enabled==0&&after.requestedRevision==128&&!after.faulted);
    assert(after.requested.intensity==before.requested.intensity&&after.requested.processingLongEdge==960);
    // A queued numeric edit carries a stale/off enabled value but must preserve
    // the preceding atomic toggle, even though neither has been published yet.
    NRFrameHookSettings edit=after.requested;edit.intensity=1.25f;edit.tone=.8f;edit.split=.4f;edit.enabled=0;
    gate=hold();assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);assert(NRFrameHookSetParameters(&edit)==NR_NEURAL_OK);
    dispatch_semaphore_signal(gate);drain();NRFrameHookCopySnapshot(&after);
    assert(after.requested.enabled==1&&after.applied.enabled==1&&after.requested.intensity==1.25f&&after.requested.tone==.8f&&after.requested.split==.4f);
    // Parameter snapshots intentionally ignore enabled, even a non-boolean value.
    edit.structure=.9f;edit.enabled=42;assert(NRFrameHookSetParameters(&edit)==NR_NEURAL_OK);drain();NRFrameHookCopySnapshot(&after);
    assert(after.requested.enabled==1&&after.requested.structure==.9f);
    // Simulate a retained in-flight frame. Requests still serialize immediately;
    // the real idle-boundary path applies their final state only after draining.
    dispatch_sync(state.queue,^{state.pending.store(1);});
    gate=hold();assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);edit.intensity=.3f;
    assert(NRFrameHookSetParameters(&edit)==NR_NEURAL_OK);assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);
    dispatch_semaphore_signal(gate);drain();NRFrameHookCopySnapshot(&after);
    assert(after.requested.enabled==1&&after.requested.intensity==.3f&&after.applied.intensity==1.25f&&after.settingsPending);
    dispatch_sync(state.queue,^{state.pending.store(0);Pump();});NRFrameHookCopySnapshot(&after);
    assert(!after.settingsPending&&after.applied.enabled==1&&after.applied.intensity==.3f);
    // Unsupported HDR never prevents switching OFF. Switching back ON is a
    // deferred refusal, not a permanent rendering fault.
    dispatch_sync(state.queue,^{state.surfaceSupported=false;PublishSnapshot();});
    assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);drain();NRFrameHookCopySnapshot(&after);assert(!after.requested.enabled&&!after.faulted);
    assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);drain();NRFrameHookCopySnapshot(&after);
    assert(!after.requested.enabled&&!after.applied.enabled&&!after.faulted&&strstr(after.status,"SDR"));
    edit.intensity=NAN;assert(NRFrameHookSetParameters(&edit)==NR_NEURAL_INVALID_ARGUMENT);
    dispatch_sync(state.queue,^{state.disabled.store(true);PublishSnapshot();});
    assert(NRFrameHookToggleEnabled()==NR_NEURAL_FAILED);
    edit.intensity=1;assert(NRFrameHookSetParameters(&edit)==NR_NEURAL_FAILED);
    printf("{\"passed\":true,\"gpuUsed\":false,\"delayedPublicationToggles\":128,\"pairedNetIdentity\":true,\"toggleThenStaleParameters\":true,\"deferredIdleBoundary\":true,\"unsupportedOffAllowed\":true,\"unsupportedOnRejected\":true,\"permanentFaultPreserved\":true,\"bridgeSettingsCalls\":%u}\n",queueBridgeCalls);
    return 0;
}}
static int RecoveryQueueRegression() { @autoreleasepool {
    State &s=S();s.queue=dispatch_queue_create("local.nr.harness.recovery-queue",DISPATCH_QUEUE_SERIAL);
    s.jobs=[NSMutableArray new];s.warming=false;s.surfaceSupported=true;s.installed.store(true);
    s.setSettings=QueueBridgeSettings;s.invalidate=RecoveryInvalidate;
    s.requested={1,1,1,.5f,960,1};s.applied=s.requested;
    dispatch_sync(s.queue,^{
        NRHookJob *old=[NRHookJob new];old.sequence=1;old.capturedAt=NSProcessInfo.processInfo.systemUptime-.6;
        old.producerSubmitted=YES;old.recoveryEpoch=s.recoveryEpoch;
        s.pending.store(1);PauseForTiming(old,@"Fixture producer stall");
        assert(s.recovering&&!s.disabled.load()&&s.recoveryCount==1&&[s.lastRecoveryPhase isEqualToString:@"waiting_for_producer_gpu"]);
        uint64_t epoch=s.recoveryEpoch;
        s.recoveryProbeInFlight=true;s.recoveryProbeID=1;CompleteRecoveryProbe(epoch,1,1,nil);
        assert(s.recovering&&recoveryInvalidations==0); // Retained final GPU work is not drained.
        s.pending.store(0);s.bridgeBusy=YES;s.recoveryProbeInFlight=true;
        CompleteRecoveryProbe(epoch,1,1,nil);assert(s.recovering&&recoveryInvalidations==0); // Late inference still owns work.
        s.bridgeBusy=NO;s.recoveryProbeInFlight=true;s.recoveryProbeID=2;
        CompleteRecoveryProbe(epoch,1,1,nil);assert(s.recoveryProbeInFlight&&s.recovering); // Old probe cannot clear new one.
        CompleteRecoveryProbe(epoch,2,1,nil);assert(!s.recovering&&recoveryInvalidations==1);
        PauseForTiming(old,@"Obsolete commit notification");assert(!s.recovering&&s.recoveryCount==1);
        NRHookJob *final=[NRHookJob new];final.sequence=2;final.capturedAt=NSProcessInfo.processInfo.systemUptime-.6;
        final.finished=YES;final.recoveryEpoch=s.recoveryEpoch;
        PauseForTiming(final,@"Fixture final GPU stall");assert(s.recovering&&[s.lastRecoveryPhase isEqualToString:@"final_gpu"]);
        final.retired=YES;
        s.recoveryProbeInFlight=true;s.recoveryProbeID=3;CompleteRecoveryProbe(s.recoveryEpoch,3,1,nil);
        assert(!s.recovering&&recoveryInvalidations==2);
        PauseForTiming(final,@"Retired commit notification");assert(!s.recovering);
        // A GPU error remains a fault even on an obsolete probe completion.
        CompleteRecoveryProbe(0,0,1,@"Fixture GPU error");assert(s.disabled.load()&&s.errors.load()==1);
        assert(NRFrameHookToggleEnabled()==NR_NEURAL_FAILED);
    });
    printf("{\"passed\":true,\"gpuUsed\":false,\"producerPhase\":true,\"finalPhase\":true,\"pendingAndBridgeDrain\":true,\"oldProbeIgnored\":true,\"staleCommitIgnored\":true,\"lateGPUErrorPermanent\":true,\"invalidations\":%u}\n",recoveryInvalidations);
    return 0;
}}
static int RecoveryCallbackRegression() { @autoreleasepool {
    State &s=S();s.queue=dispatch_queue_create("local.nr.harness.recovery-callbacks",DISPATCH_QUEUE_SERIAL);
    s.jobs=[NSMutableArray new];s.warming=false;s.surfaceSupported=true;s.installed.store(true);s.armed.store(true);
    s.setSettings=QueueBridgeSettings;s.invalidate=RecoveryInvalidate;s.deadlineMS=50;
    s.requested={1,1,1,.5f,960,1};s.applied=s.requested;
    NRHookJob *late=[NRHookJob new];late.sequence=1;late.capturedAt=NSProcessInfo.processInfo.systemUptime-.1;
    late.gameReady=YES;late.producerSubmitted=YES;late.bridgeStarted=late.capturedAt;
    dispatch_sync(s.queue,^{
        s.bridgeBusy=YES;PauseForTiming(late,@"Fixture overdue inference");
        late.finished=YES;late.retired=YES;PublishSnapshot(); // Original fallback already completed.
    });
    NRRecoveryProbeCommand *blocked=[NRRecoveryProbeCommand new];
    dispatch_sync(s.queue,^{ObserveRecoveryProbe((id<MTLCommandBuffer>)blocked);});
    assert(blocked.registrations==0&&s.recovering&&recoveryInvalidations==0); // pending0 alone is insufficient.
    auto edit=s.requested;edit.intensity=1.6f;edit.enabled=1;
    assert(NRFrameHookToggleEnabled()==NR_NEURAL_OK);assert(NRFrameHookSetParameters(&edit)==NR_NEURAL_OK);
    dispatch_sync(s.queue,^{});assert(s.requested.enabled==0&&s.settingsDirty&&s.bridgeBusy);
    CVPixelBufferRef output=nullptr;
    assert(CVPixelBufferCreate(nullptr,8,8,kCVPixelFormatType_32BGRA,nullptr,&output)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(output,0);memset(CVPixelBufferGetBaseAddress(output),42,CVPixelBufferGetDataSize(output));CVPixelBufferUnlockBaseAddress(output,0);
    BridgeFrame(NR_NEURAL_OK,output,1,100,nullptr,(__bridge_retained void*)late);
    dispatch_sync(s.queue,^{});
    assert(!s.bridgeBusy&&s.recovering&&s.late.load()==1&&s.processed.load()==0&&s.errors.load()==0);
    assert(!s.applied.enabled&&s.applied.intensity==1.6f&&!s.settingsDirty&&recoveryInvalidations==0);
    CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
    assert(*(uint8_t*)CVPixelBufferGetBaseAddress(output)==42);CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(output);
    NRRecoveryProbeCommand *abandoned=[NRRecoveryProbeCommand new];
    dispatch_sync(s.queue,^{ObserveRecoveryProbe((id<MTLCommandBuffer>)abandoned);});
    assert(abandoned.registrations==1&&s.recoveryProbeInFlight);
    // No commit/completion: the real production timeout must re-arm the probe.
    usleep(80000);dispatch_sync(s.queue,^{});assert(!s.recoveryProbeInFlight&&s.recovering);
    NRRecoveryProbeCommand *fresh=[NRRecoveryProbeCommand new];
    dispatch_sync(s.queue,^{ObserveRecoveryProbe((id<MTLCommandBuffer>)fresh);});
    uint64_t freshID=s.recoveryProbeID;assert(fresh.registrations==1&&s.recoveryProbeInFlight);
    [abandoned complete];dispatch_sync(s.queue,^{});
    assert(s.recoveryProbeInFlight&&s.recoveryProbeID==freshID&&s.recovering&&recoveryInvalidations==0);
    [fresh complete];dispatch_sync(s.queue,^{});
    assert(!s.recovering&&!s.recoveryProbeInFlight&&!s.disabled.load()&&recoveryInvalidations==1);
    assert(!s.requested.enabled&&!s.applied.enabled&&s.applied.intensity==1.6f); // User Off wins over recovery.
    NRHookJob *failed=[NRHookJob new];failed.finished=YES;failed.retired=YES;failed.bridgeStarted=NSProcessInfo.processInfo.systemUptime;
    dispatch_sync(s.queue,^{s.bridgeBusy=YES;});
    BridgeFrame(NR_NEURAL_FAILED,nullptr,2,0,"Fixture late bridge failure",(__bridge_retained void*)failed);
    dispatch_sync(s.queue,^{});assert(s.disabled.load()&&s.errors.load()==1&&!s.bridgeBusy&&s.late.load()==2);
    printf("{\"passed\":true,\"gpuUsed\":false,\"realCoreCallbacks\":true,\"pendingZeroWaitsForLateInference\":true,\"lateOutputDiscarded\":true,\"uncompletedProbeRearmed\":true,\"lateProbePreservesFreshProbe\":true,\"userOffAndParametersPreserved\":true,\"lateBridgeFailurePermanent\":true,\"historyInvalidations\":%u}\n",recoveryInvalidations);
    return 0;
}}
#endif

struct TestState {
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);
    dispatch_group_t reads=dispatch_group_create();
    dispatch_queue_t analysis=dispatch_queue_create("local.nr.harness-readback",DISPATCH_QUEUE_SERIAL);
    std::atomic<int> status{-1}, errors{0}, readbacks{0}, neuralReadbacks{0};
    std::atomic<int> rawHalfLeftFailures{0};
    std::atomic<float> expectedSplit{.5f};
    std::atomic<int> expectedProcessed{1};
    std::atomic<uint64_t> overlaySequence{0};
    std::mutex lock;
    std::vector<uint64_t> sequence;
    id<MTLDevice> device;
    NSData *original;
    NSUInteger width=0,height=0;
    NSString *output;
    bool saveImage=false,linear=false;
};
static void Ready(int32_t status,const char *error,void *context) {
    TestState *s=(TestState *)context;s->status=status;
    if(error)fprintf(stderr,"%s\n",error);dispatch_semaphore_signal(s->ready);
}
static void Observe(void *commandPointer,void *texturePointer,uint64_t sequence,int32_t processed,void *context) {
    TestState *s=(TestState *)context;
    id<MTLCommandBuffer> command=(__bridge id<MTLCommandBuffer>)commandPointer;
    id<MTLTexture> texture=(__bridge id<MTLTexture>)texturePointer;
    NSUInteger row=s->width*(s->linear?8:4);
    NSUInteger leftEdge=MIN(s->width,(NSUInteger)std::ceil(s->width*s->expectedSplit.load()));
    id<MTLBuffer> pixels=[s->device newBufferWithLength:row*s->height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(s->width,s->height,1) toBuffer:pixels destinationOffset:0
      destinationBytesPerRow:row destinationBytesPerImage:row*s->height];[blit endEncoding];
    dispatch_group_enter(s->reads);
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        dispatch_async(s->analysis, ^{ @autoreleasepool {
            if(done.status==MTLCommandBufferStatusError)s->errors++;
            const uint8_t *output=(const uint8_t *)pixels.contents;
            const uint8_t *original=(const uint8_t *)s->original.bytes;
            double left=0,right=0;uint64_t leftCount=0,rightCount=0;
            if(s->linear) {
                // Check every raw half-float component, including alpha, on
                // the untouched half. Float tolerance would hide a conversion.
                bool identical=true;
                for(NSUInteger y=0;y<s->height;y++)
                    if(memcmp(output+y*row,original+y*row,leftEdge*8)!=0){identical=false;break;}
                if(!identical){s->rawHalfLeftFailures++;s->errors++;}
            }
            for(NSUInteger y=0;y<s->height;y+=3)for(NSUInteger x=0;x<s->width;x+=3) {
                if(fabs((double)x-leftEdge)<4)continue;
                for(int c=0;c<3;c++) {
                    double delta;
                    if(s->linear) {
                        const _Float16 *out=(const _Float16 *)(output+y*row+x*8);
                        const _Float16 *in=(const _Float16 *)(original+y*row+x*8);
                        if(!std::isfinite((float)out[c]))s->errors++;
                        delta=fabs((double)out[c]-(double)in[c])*255.0;
                    } else delta=abs((int)output[y*row+x*4+c]-(int)original[y*row+x*4+c]);
                    if(x<leftEdge){left+=delta;leftCount++;}else{right+=delta;rightCount++;}
                }
            }
            left/=MAX((uint64_t)1,leftCount);right/=MAX((uint64_t)1,rightCount);
            // Identity on the left and changed pixels on the right establishes
            // that actual processing reached this exact drawable, not a panel.
            if(left>.05 || (!processed && right>.05) || (processed && rightCount && right<.02))s->errors++;
            fprintf(stderr,"frame=%llu processed=%d leftMAE=%.5f rightMAE=%.5f\n",sequence,processed,left,right);
            if(processed && s->saveImage) {
                s->saveImage=false;
                NSData *data=[NSData dataWithBytes:output length:row*s->height];
                CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
                CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGImageRef image=CGImageCreate(s->width,s->height,8,32,row,space,
                    kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little,provider,nullptr,false,kCGRenderingIntentDefault);
                CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:s->output],CFSTR("public.png"),1,nullptr);
                if(dest){CGImageDestinationAddImage(dest,image,nullptr);if(!CGImageDestinationFinalize(dest))s->errors++;CFRelease(dest);}else s->errors++;
                CGImageRelease(image);CGColorSpaceRelease(space);CGDataProviderRelease(provider);
            }
            {std::lock_guard<std::mutex> guard(s->lock);s->sequence.push_back(sequence);}
            s->readbacks++;if(processed)s->neuralReadbacks++;
            dispatch_group_leave(s->reads);
        }});
    }];
}
static void ObserveOverlay(void *command,void *drawable,void *context) {
    TestState *s=(TestState*)context;
    id<CAMetalDrawable> target=(__bridge id<CAMetalDrawable>)drawable;
    Observe(command,(__bridge void*)target.texture,++s->overlaySequence,s->expectedProcessed.load(),context);
}
int main(int argc,const char **argv) { @autoreleasepool {
#if defined(NR_FRAME_HOOK_QUEUE_TEST)
    if(argc==2&&!strcmp(argv[1],"--toggle-queue"))return QueueToggleRegression();
    if(argc==2&&!strcmp(argv[1],"--recovery-queue"))return RecoveryQueueRegression();
    if(argc==2&&!strcmp(argv[1],"--recovery-callbacks"))return RecoveryCallbackRegression();
#endif
    if(argc<7){fprintf(stderr,"usage: hook bridge model input.png output.png diagnostics.json [--timeout] [--linear] [--controls]\n");return 2;}
    bool timeoutTest=false,linearTest=false,controlsTest=false,armingTest=false,producerStallTest=false;
    for(int i=7;i<argc;i++) {
        if(!strcmp(argv[i],"--timeout"))timeoutTest=true;
        else if(!strcmp(argv[i],"--linear"))linearTest=true;
        else if(!strcmp(argv[i],"--controls"))controlsTest=true;
        else if(!strcmp(argv[i],"--arming"))armingTest=true;
        else if(!strcmp(argv[i],"--producer-stall"))producerStallTest=true;
        else {fprintf(stderr,"Unknown option: %s\n",argv[i]);return 2;}
    }
    setenv("NR_FRAME_HOOK_TEST","1",1);
    NSString *settingsPath=[@(argv[6]) stringByAppendingString:@".settings.json"];
    if(armingTest) {
        if(timeoutTest||controlsTest)return 2;
        NSString *gate=[@(argv[6]) stringByAppendingString:@".enable-fixture"];
        if(access(gate.fileSystemRepresentation,F_OK)==0)return 2;
        setenv("NR_FRAME_HOOK_ENABLE_FILE",gate.fileSystemRepresentation,1);
        setenv("NR_FRAME_HOOK_SETTINGS_FILE",settingsPath.fileSystemRepresentation,1);
        NSDictionary *fixture=@{@"schemaVersion":@1,@"intensity":@1,@"tone":@1,@"structure":@1,@"split":@.5,
            @"processingLongEdge":@640,@"enabled":@YES};
        [[NSJSONSerialization dataWithJSONObject:fixture options:0 error:nil] writeToFile:settingsPath atomically:YES];
    }
    if(producerStallTest&&(controlsTest||armingTest||timeoutTest))return 2;
    bool controlScenario=controlsTest||armingTest||producerStallTest;
    if(timeoutTest)setenv("NR_FRAME_HOOK_DEADLINE_MS","50",1);
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
    auto start=(decltype(&NRFrameHookStartForTesting))dlsym(lib,"NRFrameHookStartForTesting");
    auto disable=(decltype(&NRFrameHookDisableForTesting))dlsym(lib,"NRFrameHookDisableForTesting");
    auto counters=(decltype(&NRFrameHookCopyCountersForTesting))dlsym(lib,"NRFrameHookCopyCountersForTesting");
    auto observer=(decltype(&NRFrameHookSetObserverForTesting))dlsym(lib,"NRFrameHookSetObserverForTesting");
    auto overlay=(decltype(&NRFrameHookSetOverlayRenderer))dlsym(lib,"NRFrameHookSetOverlayRenderer");
    auto snapshot=(decltype(&NRFrameHookCopySnapshot))dlsym(lib,"NRFrameHookCopySnapshot");
    auto settings=(decltype(&NRFrameHookSetSettings))dlsym(lib,"NRFrameHookSetSettings");
    if(!start||!disable||!counters||!observer)return 2;
    if(controlScenario&&(!overlay||!snapshot||!settings||timeoutTest))return 2;
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[4])],nullptr);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,nullptr):nullptr;
    if(source)CFRelease(source);if(!image)return 2;
    TestState *s=new TestState;s->device=MTLCreateSystemDefaultDevice();
    s->width=CGImageGetWidth(image);s->height=CGImageGetHeight(image);s->output=@(argv[5]);
    s->linear=linearTest;s->saveImage=!timeoutTest&&!linearTest;
    NSMutableData *data=[NSMutableData dataWithLength:s->width*s->height*4];
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap=CGBitmapContextCreate(data.mutableBytes,s->width,s->height,8,s->width*4,color,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
    CGContextDrawImage(bitmap,CGRectMake(0,0,s->width,s->height),image);CGContextRelease(bitmap);CGImageRelease(image);
    s->original=data;
    if(linearTest) {
        NSMutableData *half=[NSMutableData dataWithLength:s->width*s->height*8];
        const uint8_t *bgra=(const uint8_t *)data.bytes;_Float16 *rgba=(_Float16 *)half.mutableBytes;
        for(NSUInteger i=0;i<s->width*s->height;i++) {
            for(int c=0;c<3;c++) {
                double value=(double)bgra[i*4+2-c]/255.0;
                double decoded=value<=0.04045?value/12.92:pow((value+0.055)/1.055,2.4);
                rgba[i*4+c]=(_Float16)decoded;
            }
            rgba[i*4+3]=(_Float16)1;
        }
        s->original=half;
        CGColorSpaceRelease(color);color=CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    }
    if(controlScenario)overlay(ObserveOverlay,s);else observer(Observe,s);
    int result=start(argv[2],argv[3],argv[6],(uint32_t)s->width,(uint32_t)s->height,Ready,s);
    if(result || dispatch_semaphore_wait(s->ready,dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC)) || s->status!=0)return 3;
    MTLPixelFormat format=linearTest?MTLPixelFormatRGBA16Float:MTLPixelFormatBGRA8Unorm;
    CAMetalLayer *layer=[CAMetalLayer layer];layer.device=s->device;layer.pixelFormat=format;
    layer.framebufferOnly=NO;layer.presentsWithTransaction=NO;layer.maximumDrawableCount=3;
    layer.colorspace=color;layer.wantsExtendedDynamicRangeContent=NO;CGColorSpaceRelease(color);
    layer.drawableSize=CGSizeMake(s->width,s->height);
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:s->width height:s->height mipmapped:NO];
    desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> original=[s->device newTextureWithDescriptor:desc];
    [original replaceRegion:MTLRegionMake2D(0,0,s->width,s->height) mipmapLevel:0 withBytes:s->original.bytes bytesPerRow:s->width*(linearTest?8:4)];
    id<MTLCommandQueue> game=[s->device newCommandQueue];
    int frames=controlsTest?10:armingTest?7:producerStallTest?5:6;
    auto emit=[&](int i) { @autoreleasepool {
        id<CAMetalDrawable> drawable=[layer nextDrawable];if(!drawable)return 4;
        id<MTLCommandBuffer> command=[game commandBuffer];
        id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];
        [copy copyFromTexture:original sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                   sourceSize:MTLSizeMake(s->width,s->height,1) toTexture:drawable.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [copy endEncoding];
        if(i%3==0)[command presentDrawable:drawable];else if(i%3==1)[command presentDrawable:drawable atTime:0];
        else [command presentDrawable:drawable afterMinimumDuration:0];
        if(producerStallTest&&i==0)usleep(650000); // Delayed game submission, outside production hook.
        [command commit];
        // Test-only wait: bypass frames have no serial hook semaphore. Avoid
        // reusing this fixture while its observer is still encoding/readback.
        if(controlScenario)[command waitUntilCompleted];
        return 0;
    }};
    bool settingsPassed=true,warmingBypass=false,offPassed=false;
    bool armingPassed=true,persistencePassed=true;
    bool recoveryPassed=true;
    int expectedNeural=frames;
    auto waitApplied=[&](const NRFrameHookSettings &values,bool allowWarming) {
            for(int n=0;n<12000;n++) {
                NRFrameHookSnapshot state{};snapshot(&state);
                if(state.faulted)return false;
                if(!state.settingsPending&&(allowWarming||!state.warming)&&
                    state.applied.enabled==values.enabled&&state.applied.processingLongEdge==values.processingLongEdge&&
                    state.applied.intensity==values.intensity&&state.applied.tone==values.tone&&
                    state.applied.structure==values.structure&&state.applied.split==values.split)return true;
                usleep(10000);
            }return false;
    };
    if(producerStallTest) {
        s->expectedProcessed=0;if(emit(0))return 4;
        NRFrameHookSnapshot state{};snapshot(&state);
        recoveryPassed&=state.recovering&&!state.faulted&&state.counters.pending==0&&state.recoveryCount==1;
        if(emit(1))return 4; // Fresh completed original is the recovery probe.
        for(int i=0;i<100;i++){snapshot(&state);if(!state.recovering)break;usleep(10000);}
        recoveryPassed&=!state.recovering&&!state.faulted&&state.requested.enabled==1;
        s->expectedProcessed=1;if(emit(2)||emit(3)||emit(4))return 4;
        snapshot(&state);recoveryPassed&=!state.faulted&&state.recoveryCount==1;
        expectedNeural=3;
    } else if(armingTest) {
        NRFrameHookSnapshot state{};snapshot(&state);
        armingPassed&=!state.armed&&!state.applied.enabled&&!state.faulted&&state.applied.processingLongEdge==640;
        NRFrameHookSettings values=state.requested;values.enabled=1;
        armingPassed&=settings(&values)==3;
        layer.wantsExtendedDynamicRangeContent=YES;s->expectedProcessed=0;
        if(emit(0))return 4;
        usleep(150000);snapshot(&state);
        armingPassed&=!state.surfaceSupported&&!state.faulted&&settings(&values)==3;
        layer.wantsExtendedDynamicRangeContent=NO;
        if(emit(1))return 4;
        usleep(150000);snapshot(&state);
        armingPassed&=state.surfaceSupported&&!state.faulted&&settings(&values)==0&&waitApplied(values,false);
        s->expectedProcessed=1;if(emit(2))return 4;
        values.enabled=0;armingPassed&=settings(&values)==0&&waitApplied(values,false);
        s->expectedProcessed=0;if(emit(3))return 4;
        layer.wantsExtendedDynamicRangeContent=YES;if(emit(4))return 4;
        usleep(150000);snapshot(&state);values.enabled=1;
        armingPassed&=!state.surfaceSupported&&!state.faulted&&settings(&values)==3;
        layer.wantsExtendedDynamicRangeContent=NO;if(emit(5))return 4;
        usleep(150000);snapshot(&state);armingPassed&=state.surfaceSupported&&!state.faulted;
        values.enabled=1;values.tone=.9f;armingPassed&=settings(&values)==0&&waitApplied(values,false);
        s->expectedProcessed=1;if(emit(6))return 4;
        usleep(600000);
        NSDictionary *saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:settingsPath] options:0 error:nil];
        persistencePassed=saved&&saved[@"enabled"]==nil&&fabs([saved[@"tone"] doubleValue]-.9)<.0001&&
            [saved[@"processingLongEdge"] unsignedIntValue]==640;
        expectedNeural=2;
    } else if(controlsTest) {
        NRFrameHookSettings values{1,1,1,.5f,1920,1};
        if(emit(0))return 4;
        auto invalid=values;invalid.processingLongEdge=777;settingsPassed&=settings(&invalid)==2;
        invalid=values;invalid.tone=NAN;settingsPassed&=settings(&invalid)==2;
        values.enabled=0;settingsPassed&=settings(&values)==0&&waitApplied(values,false);
        s->expectedProcessed=0;
        if(emit(1))return 4;
        NRFrameHookSnapshot off{};snapshot(&off);offPassed=!off.faulted&&!off.applied.enabled;
        // Resolution is applied while no live drawable is retained. A frame
        // emitted during private warmup must remain the exact original.
        values.processingLongEdge=640;values.intensity=0;settingsPassed&=settings(&values)==0&&waitApplied(values,true);
        NRFrameHookSnapshot warm{};snapshot(&warm);warmingBypass=warm.warming;
        if(emit(2))return 4;
        settingsPassed&=waitApplied(values,false);
        values.enabled=1;values.intensity=1;settingsPassed&=settings(&values)==0&&waitApplied(values,false);s->expectedProcessed=1;
        if(emit(3))return 4;
        values.split=0;settingsPassed&=settings(&values)==0&&waitApplied(values,false);s->expectedSplit=0;
        if(emit(4))return 4;
        values.split=1;settingsPassed&=settings(&values)==0&&waitApplied(values,false);s->expectedSplit=1;
        if(emit(5))return 4;
        values.split=.5f;values.intensity=1.2f;values.tone=.8f;values.structure=1.1f;
        settingsPassed&=settings(&values)==0&&waitApplied(values,false);s->expectedSplit=.5f;
        if(emit(6))return 4;
        values.processingLongEdge=960;settingsPassed&=settings(&values)==0&&waitApplied(values,true);
        snapshot(&warm);warmingBypass&=warm.warming;s->expectedProcessed=0;
        if(emit(7))return 4;
        settingsPassed&=waitApplied(values,false);s->expectedProcessed=1;
        if(emit(8)||emit(9))return 4;
        expectedNeural=7;
    } else for(int i=0;i<frames;i++)if(emit(i))return 4;
    NRFrameHookCounters c={};
    for(int i=0;i<600;i++){counters(&c);if(c.pending==0&&c.finalCompleted>=c.accepted)break;usleep(100000);}
    if(dispatch_group_wait(s->reads,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)))return 5;
    counters(&c);
    if(timeoutTest) {
        for(int i=0;i<500&&c.late==0;i++){usleep(10000);counters(&c);}
    }
    bool ordered=true;for(size_t i=1;i<s->sequence.size();i++)if(s->sequence[i]<=s->sequence[i-1])ordered=false;
    bool passed=s->errors==0&&ordered&&c.errors==0&&c.pending==0&&c.peakPending<=3&&c.finalCompleted==c.accepted;
    if(timeoutTest)passed=passed&&c.expired>=1&&c.late>=1&&s->neuralReadbacks==0;
    else passed=passed&&c.accepted==(uint64_t)(expectedNeural+(producerStallTest?1:0))&&c.processed==(uint64_t)expectedNeural&&s->readbacks==frames&&s->neuralReadbacks==expectedNeural;
    if(controlsTest)passed=passed&&settingsPassed&&warmingBypass&&offPassed;
    if(armingTest)passed=passed&&armingPassed&&persistencePassed;
    if(producerStallTest)passed=passed&&recoveryPassed&&c.expired==1&&!c.disabled;
    // The controls fixture intentionally submits original frames while off or
    // warming. Verify all intercepted variants from the hook diagnostics;
    // accepted==frames is therefore not a valid condition for this report.
    NSData *diagnosticData=[NSData dataWithContentsOfFile:@(argv[6])];
    NSDictionary *diagnostics=diagnosticData ? [NSJSONSerialization JSONObjectWithData:diagnosticData options:0 error:nil] : nil;
    uint64_t plain=[diagnostics[@"plainPresent"] unsignedLongLongValue];
    uint64_t timed=[diagnostics[@"timedPresent"] unsignedLongLongValue];
    uint64_t minimum=[diagnostics[@"minimumDurationPresent"] unsignedLongLongValue];
    bool allVariants=!timeoutTest&&passed&&plain>0&&timed>0&&minimum>0;
    NSDictionary *report=@{@"passed":@(passed),@"actualHT":@YES,@"physicalDisplayVerified":@NO,
        @"framesSubmitted":@(frames),@"accepted":@(c.accepted),@"processed":@(c.processed),@"bypassed":@(c.bypassed),
        @"expired":@(c.expired),@"late":@(c.late),@"hookErrors":@(c.errors),@"pending":@(c.pending),@"peakPending":@(c.peakPending),
        @"finalCompleted":@(c.finalCompleted),@"readbacks":@(s->readbacks.load()),@"pixelErrors":@(s->errors.load()),
        @"ordered":@(ordered),@"timeoutTest":@(timeoutTest),@"linearRGBA16FloatTest":@(linearTest),
        @"controlsTest":@(controlsTest),@"settingsPassed":@(settingsPassed),@"warmingBypass":@(warmingBypass),@"offPassed":@(offPassed),
        @"armingTest":@(armingTest),@"armingPassed":@(armingPassed),@"persistencePassed":@(persistencePassed),
        @"producerStallTest":@(producerStallTest),@"recoveryPassed":@(recoveryPassed),
        @"rawHalfLeftFailures":@(s->rawHalfLeftFailures.load()),
        @"presentVariantCounts":@{@"plain":@(plain),@"timed":@(timed),@"minimumDuration":@(minimum)},
        @"allThreePresentVariants":@(allVariants)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputs("\n",stdout);
    return passed?0:6;
}}
