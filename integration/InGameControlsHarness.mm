#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#include "InGameControls.h"
#include "NeuralFrameHook.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

static NRFrameHookSnapshot state={};
static int requests=0;
extern "C" void NRFrameHookCopySnapshot(NRFrameHookSnapshot *out){*out=state;}
extern "C" int32_t NRFrameHookSetSettings(const NRFrameHookSettings *settings){
    state.requested=*settings;state.applied=*settings;++requests;return 0;
}
extern "C" int32_t NRFrameHookToggleEnabled(){
    state.requested.enabled=!state.requested.enabled;state.applied=state.requested;++requests;return 0;
}
extern "C" int32_t NRFrameHookSetParameters(const NRFrameHookSettings *settings){
    int enabled=state.requested.enabled;state.requested=*settings;state.requested.enabled=enabled;
    state.applied=state.requested;++requests;return 0;
}
@interface UIHarnessDrawable:NSObject<CAMetalDrawable>
@property(nonatomic,strong)id<MTLTexture> texture;
@property(nonatomic,strong)CAMetalLayer *layer;
@end
@implementation UIHarnessDrawable
-(NSUInteger)drawableID{return 1;}
-(CFTimeInterval)presentedTime{return 0;}
-(void)present{}
-(void)presentAtTime:(CFTimeInterval)time{(void)time;}
-(void)presentAfterMinimumDuration:(CFTimeInterval)duration{(void)duration;}
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler{(void)handler;}
@end
static int Key(unsigned short code,NSEventType type=NSEventTypeKeyDown,NSEventModifierFlags flags=0,bool repeat=false){
    NSEvent *event=[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:repeat keyCode:code];
    return NRInGameControlsHandleEventForTesting((__bridge void*)event);
}
static void Press(unsigned short code){assert(Key(code)==1);assert(Key(code,NSEventTypeKeyUp)==1);}
static int Mouse(CGEventType type,int dx=0,int dy=0){
    CGEventRef raw=CGEventCreateMouseEvent(nullptr,type,CGPointZero,kCGMouseButtonLeft);
    CGEventSetIntegerValueField(raw,kCGMouseEventDeltaX,dx);CGEventSetIntegerValueField(raw,kCGMouseEventDeltaY,dy);
    NSEvent *event=[NSEvent eventWithCGEvent:raw];CFRelease(raw);assert(event);
    return NRInGameControlsHandleEventForTesting((__bridge void*)event);
}
static void PNG(const std::vector<uint8_t>&bytes,size_t width,size_t height,NSString *path){
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef data=CFDataCreate(nullptr,bytes.data(),bytes.size());CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,nullptr,false,kCGRenderingIntentDefault);
    CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,nullptr);
    CGImageDestinationAddImage(destination,image,nullptr);assert(CGImageDestinationFinalize(destination));
    CFRelease(destination);CGImageRelease(image);CGDataProviderRelease(provider);CFRelease(data);CGColorSpaceRelease(color);
}
static UIHarnessDrawable *Render(id<MTLDevice>device,id<MTLCommandQueue>queue,MTLPixelFormat format,bool open,NSMutableArray<id<MTLCommandBuffer>> *deferred=nil){
    NRInGameControlsSetVisible(open);
    UIHarnessDrawable *d=[UIHarnessDrawable new];d.layer=[CAMetalLayer layer];d.layer.device=device;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(format==MTLPixelFormatRGBA16Float?kCGColorSpaceExtendedLinearSRGB:kCGColorSpaceSRGB);
    d.layer.colorspace=space;CGColorSpaceRelease(space);
    MTLTextureDescriptor *description=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:2336 height:1460 mipmapped:NO];
    description.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;description.storageMode=MTLStorageModeShared;
    d.texture=[device newTextureWithDescriptor:description];assert(d.texture);
    id<MTLCommandBuffer>command=deferred?[queue commandBufferWithUnretainedReferences]:[queue commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(.1,.2,.3,1);[[command renderCommandEncoderWithDescriptor:pass]endEncoding];
    NRInGameControlsEncode((__bridge void*)command,(__bridge void*)d,nullptr);
    if(deferred){assert(!command.retainedReferences);[deferred addObject:command];return d;}
    [command commit];[command waitUntilCompleted];assert(command.status==MTLCommandBufferStatusCompleted);
    return d;
}
int main(int argc,const char **argv){@autoreleasepool{
    assert(argc==2);setenv("NR_INGAME_UI_TEST","1",1);
    state.requested={1,1,1,.5,1920,0};state.applied=state.requested;
    state.surfaceSupported=1;
    state.processedFPS=7.8;state.presentFPS=59.9;state.timings.totalMilliseconds=125;
    snprintf(state.status,sizeof(state.status),"Ready — settings applied");
    NRInGameControlsRefreshForTesting();
    assert(Key(kVK_ANSI_W)==0);assert(Key(kVK_ANSI_W,NSEventTypeKeyUp)==0);
    // Plain physical comma/period are available with the panel closed. They
    // retain key-up ownership but never repeat actions while a key is held.
    NRInGameControlsDiagnostics shortcuts={};
    int beforeShortcuts=requests;NRFrameHookSettings saved=state.requested;
    assert(Key(kVK_ANSI_Comma,NSEventTypeKeyDown,NSEventModifierFlagShift)==0);
    assert(Key(kVK_ANSI_Comma,NSEventTypeKeyUp,NSEventModifierFlagShift)==0);
    assert(Key(kVK_ANSI_Period,NSEventTypeKeyDown,NSEventModifierFlagCommand)==0);
    assert(Key(kVK_ANSI_Period,NSEventTypeKeyUp,NSEventModifierFlagCommand)==0);
    assert(Key(kVK_ANSI_Comma,NSEventTypeKeyDown,0,true)==0);
    assert(Key(kVK_ANSI_Comma,NSEventTypeKeyUp)==0);
    assert(Key(kVK_ANSI_Period)==1);assert(state.requested.enabled==!saved.enabled);
    assert(Key(kVK_ANSI_Period,NSEventTypeKeyDown,0,true)==1);
    assert(Key(kVK_ANSI_Period)==1);assert(requests==beforeShortcuts+1);
    assert(Key(kVK_ANSI_Period,NSEventTypeKeyUp,NSEventModifierFlagShift)==1);
    Press(kVK_ANSI_Period);assert(requests==beforeShortcuts+2 && state.requested.enabled==saved.enabled);
    assert(state.requested.intensity==saved.intensity && state.requested.tone==saved.tone &&
           state.requested.structure==saved.structure && state.requested.split==saved.split &&
           state.requested.processingLongEdge==saved.processingLongEdge);
    NRInGameControlsCopyDiagnostics(&shortcuts);assert(!shortcuts.visible);
    assert(Key(kVK_ANSI_Comma)==1);NRInGameControlsCopyDiagnostics(&shortcuts);assert(shortcuts.visible);
    assert(Key(kVK_ANSI_Comma,NSEventTypeKeyDown,0,true)==1);
    NRInGameControlsCopyDiagnostics(&shortcuts);assert(shortcuts.visible);
    Press(kVK_Escape);assert(Key(kVK_ANSI_Comma,NSEventTypeKeyDown,0,true)==1);
    assert(Key(kVK_ANSI_Comma,NSEventTypeKeyUp)==1);
    Press(kVK_ANSI_Comma);NRInGameControlsCopyDiagnostics(&shortcuts);assert(shortcuts.visible);
    Press(kVK_ANSI_Period);NRInGameControlsCopyDiagnostics(&shortcuts);assert(shortcuts.visible);
    // A slider edit before the next UI refresh must not undo the just-queued
    // toggle by publishing the stale enabled bit from the UI draft.
    Press(kVK_Tab);Press(kVK_RightArrow);assert(state.requested.enabled==!saved.enabled);
    Press(kVK_LeftArrow);assert(state.requested.enabled==!saved.enabled);
    Press(kVK_ANSI_Period);assert(state.requested.enabled==saved.enabled);
    Press(kVK_ANSI_Comma);NRInGameControlsCopyDiagnostics(&shortcuts);assert(!shortcuts.visible);
    assert(Key(kVK_ANSI_H,NSEventTypeKeyDown,NSEventModifierFlagCommand|NSEventModifierFlagOption)==0);
    assert(Key(kVK_ANSI_H,NSEventTypeKeyUp,NSEventModifierFlagCommand|NSEventModifierFlagOption)==0);
    // Existing tests below start with an unmodified settings/request baseline.
    requests=beforeShortcuts;
    NRInGameControlsSetVisible(1);
    assert(Key(kVK_ANSI_W)==0);assert(Key(kVK_ANSI_W,NSEventTypeKeyUp)==0);
    assert(Key(kVK_Space)==0);assert(Key(kVK_Space,NSEventTypeKeyUp)==0);
    assert(Key(kVK_Tab,NSEventTypeKeyDown,NSEventModifierFlagCommand)==0);
    assert(Key(kVK_Tab,NSEventTypeKeyUp,NSEventModifierFlagCommand)==0);
    assert(Key(kVK_LeftArrow,NSEventTypeKeyDown,NSEventModifierFlagOption)==0);
    assert(Key(kVK_LeftArrow,NSEventTypeKeyUp,NSEventModifierFlagOption)==0);
    // A game arrow already held before opening must keep its repeat and release.
    assert(Key(kVK_RightArrow,NSEventTypeKeyDown,0,true)==0);
    assert(Key(kVK_RightArrow,NSEventTypeKeyUp)==0);assert(requests==0);
    assert(Mouse(kCGEventMouseMoved,80,-84)==0);assert(Mouse(kCGEventLeftMouseDown)==0);
    assert(Mouse(kCGEventLeftMouseDragged,170,0)==0);assert(Mouse(kCGEventLeftMouseUp)==0);
    CGEventRef scroll=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitLine,1,1);
    NSEvent *scrollEvent=[NSEvent eventWithCGEvent:scroll];CFRelease(scroll);
    assert(NRInGameControlsHandleEventForTesting((__bridge void*)scrollEvent)==0);
    Press(kVK_Return);assert(state.requested.enabled==1);
    Press(kVK_Return);assert(state.requested.enabled==0);
    Press(kVK_Tab);Press(kVK_RightArrow);assert(fabs(state.requested.intensity-1.05)<.001);
    assert(Key(kVK_RightArrow,NSEventTypeKeyDown,NSEventModifierFlagShift)==1);
    assert(Key(kVK_RightArrow,NSEventTypeKeyUp,NSEventModifierFlagShift)==1);
    assert(fabs(state.requested.intensity-1.06)<.001);
    Press(kVK_DownArrow);Press(kVK_LeftArrow);assert(fabs(state.requested.tone-.95)<.001);
    Press(kVK_DownArrow);Press(kVK_RightArrow);assert(fabs(state.requested.structure-1.05)<.001);
    Press(kVK_DownArrow);Press(kVK_ANSI_1);assert(state.requested.processingLongEdge==640);
    Press(kVK_Return);assert(state.requested.processingLongEdge==960);
    Press(kVK_ANSI_5);assert(state.requested.processingLongEdge==1920);
    assert(Key(kVK_ANSI_1)==1);Press(kVK_Tab); // Keep owned repeat after focus changes.
    assert(Key(kVK_ANSI_1,NSEventTypeKeyDown,0,true)==1);assert(Key(kVK_ANSI_1,NSEventTypeKeyUp)==1);
    assert(Key(kVK_ANSI_2)==0);assert(Key(kVK_ANSI_2,NSEventTypeKeyUp)==0);
    Press(kVK_LeftArrow);assert(fabs(state.requested.split-.45)<.001);
    assert(Key(kVK_RightArrow)==1);Press(kVK_Escape);
    assert(Key(kVK_RightArrow,NSEventTypeKeyDown,0,true)==1);assert(Key(kVK_RightArrow,NSEventTypeKeyUp)==1);
    assert(Key(kVK_ANSI_W)==0);assert(Key(kVK_ANSI_W,NSEventTypeKeyUp)==0);
    NRInGameControlsRefreshForTesting();
    id<MTLDevice>device=MTLCreateSystemDefaultDevice();assert(device);id<MTLCommandQueue>queue=[device newCommandQueue];
    UIHarnessDrawable *closed=Render(device,queue,MTLPixelFormatBGRA8Unorm,false);
    std::vector<uint8_t>bytes(2336*1460*4);[closed.texture getBytes:bytes.data() bytesPerRow:2336*4 fromRegion:MTLRegionMake2D(0,0,2336,1460) mipmapLevel:0];
    for(size_t i=0;i<bytes.size();i+=4){assert(abs((int)bytes[i]-77)<=1 && abs((int)bytes[i+1]-51)<=1 && abs((int)bytes[i+2]-26)<=1 && bytes[i+3]==255);}
    UIHarnessDrawable *visible=Render(device,queue,MTLPixelFormatBGRA8Unorm,true);
    [visible.texture getBytes:bytes.data() bytesPerRow:2336*4 fromRegion:MTLRegionMake2D(0,0,2336,1460) mipmapLevel:0];
    assert(abs((int)bytes[0]-77)<=1 && abs((int)bytes[2]-26)<=1);
    size_t index=(1136*2336+1953)*4; // Opaque cyan left edge, no glyph or cursor.
    assert(abs((int)bytes[index]-191)<3 && abs((int)bytes[index+1]-217)<3 && abs((int)bytes[index+2]-26)<3);
    PNG(bytes,2336,1460,[[NSString stringWithUTF8String:argv[1]]stringByAppendingPathComponent:@"controls-sdr.png"]);
    UIHarnessDrawable *linear=Render(device,queue,MTLPixelFormatRGBA16Float,true);
    std::vector<_Float16>floats(2336*1460*4);[linear.texture getBytes:floats.data() bytesPerRow:2336*8 fromRegion:MTLRegionMake2D(0,0,2336,1460) mipmapLevel:0];
    auto decode=[](float x){return x<=.04045f?x/12.92f:powf((x+.055f)/1.055f,2.4f);};
    assert(fabs((float)floats[index]-decode(bytes[index+2]/255.f))<.005);
    assert(fabs((float)floats[index+1]-decode(bytes[index+1]/255.f))<.005);
    assert(fabs((float)floats[index+2]-decode(bytes[index]/255.f))<.005);
    // Replace the cached UI image before either unretained command is committed.
    // Completion handlers, not the command's resource retention, keep it alive.
    NSMutableArray<id<MTLCommandBuffer>> *pending=[NSMutableArray array];
    UIHarnessDrawable *first=nil,*second=nil;
    @autoreleasepool{first=Render(device,queue,MTLPixelFormatBGRA8Unorm,true,pending);}
    NRInGameControlsRefreshForTesting();
    @autoreleasepool{second=Render(device,queue,MTLPixelFormatRGBA16Float,true,pending);}
    for(id<MTLCommandBuffer> command in pending)[command commit];
    [pending.lastObject waitUntilCompleted];
    for(id<MTLCommandBuffer> command in pending)assert(command.status==MTLCommandBufferStatusCompleted);
    [first.texture getBytes:bytes.data() bytesPerRow:2336*4 fromRegion:MTLRegionMake2D(0,0,2336,1460) mipmapLevel:0];
    assert(abs((int)bytes[index+1]-217)<3);
    [second.texture getBytes:floats.data() bytesPerRow:2336*8 fromRegion:MTLRegionMake2D(0,0,2336,1460) mipmapLevel:0];
    assert(fabs((float)floats[index+1]-decode(bytes[index+1]/255.f))<.005);
    NRInGameControlsDiagnostics d={};NRInGameControlsCopyDiagnostics(&d);assert(d.encodedFrames==4 && d.renderErrors==0);
    printf("PASS: comma panel and period HT shortcuts open/closed, modifiers, single action per hold, release ownership, parameter preservation; compact bottom-right UI; active gameplay WASD/Space/mouse/scroll/shortcuts pass through; all reserved keyboard settings; preheld repeat and owned release pairing; closed pixels unchanged; BGRA80 + linear115 transfer; unretained resources; no render errors. requests=%d encoded=%llu\n",requests,(unsigned long long)d.encodedFrames);
    return 0;
}}
