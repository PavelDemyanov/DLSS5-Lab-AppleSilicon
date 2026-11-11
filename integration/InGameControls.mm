#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include "InGameControls.h"
#include "NeuralFrameHook.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <set>
#include <vector>

namespace {
constexpr float PanelWidth=360, PanelHeight=340;
constexpr uint32_t Sizes[]={640,960,1280,1600,1920};
struct UIState {
    std::mutex lock;
    bool installed=false, visible=false;
    int focus=0, hotkeyStatus=eventNotHandledErr;
    NRFrameHookSnapshot snapshot={};
    NRFrameHookSettings draft={1,1,1,.5,1920,0};
    uint64_t revision=1,encoded=0,renderErrors=0,inputEvents=0,requests=0;
    char error[192]={};
    std::set<unsigned short> swallowedKeys;
    id monitor=nil,inactiveObserver=nil;
    NSTimer *timer=nil;
};
UIState &S(){static UIState *state=new UIState;return *state;}
void Error(NSString *message) {
    UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);
    snprintf(s.error,sizeof(s.error),"%s",message.UTF8String ?: "UI error");
    ++s.renderErrors;++s.revision;
}
bool TestMode(){const char *v=getenv("NR_INGAME_UI_TEST");return v && !strcmp(v,"1");}
void SetVisible(bool visible) {
    NRFrameHookSnapshot latest={};if(visible)NRFrameHookCopySnapshot(&latest);
    UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);
    if(s.visible!=visible)fprintf(stderr,"[HT UI] compact keyboard panel %s\n",visible?"opened":"closed");
    s.visible=visible;s.focus=0;
    if(visible){s.snapshot=latest;s.draft=latest.requested;}
    ++s.revision;
}
void Refresh() {
    // Only the main thread queries the hook. Encode can run on the hook's own
    // serial queue and must not recursively dispatch_sync to that queue.
    NRFrameHookSnapshot snapshot={};NRFrameHookCopySnapshot(&snapshot);
    UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);
    s.snapshot=snapshot;
    s.draft=snapshot.requested;
    ++s.revision;
}
void Apply(NRFrameHookSettings settings) {
    int result=NRFrameHookSetParameters(&settings);
    UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);++s.requests;
    if(result)snprintf(s.error,sizeof(s.error),"Settings were not accepted (code %d)",result);
    else s.error[0]=0;
    ++s.revision;
}
void ToggleProcessing() {
    // This is atomic with parameter edits on the hook queue, independent of
    // publication of the periodic UI snapshot.
    const int result=NRFrameHookToggleEnabled();
    UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);++s.requests;
    if(result)snprintf(s.error,sizeof(s.error),"HT toggle was not accepted (code %d)",result);
    else s.error[0]=0;
    ++s.revision;
    fprintf(stderr,"[HT UI] HT toggle queued; status=%d\n",result);
}
float RowY(int row){return 100+row*34;}
void Adjust(NRFrameHookSettings &v,int row,int direction,bool fine) {
    float step=fine?.01f:.05f;
    if(row==0)v.enabled=!v.enabled;
    else if(row>=1 && row<=3){
        float *value=row==1?&v.intensity:(row==2?&v.tone:&v.structure);
        *value=std::clamp(*value+direction*step,0.f,2.f);
    } else if(row==4){
        int index=0;for(int i=0;i<5;++i)if(Sizes[i]==v.processingLongEdge)index=i;
        v.processingLongEdge=Sizes[std::clamp(index+direction,0,4)];
    } else if(row==5)v.split=std::clamp(v.split+direction*step,0.f,1.f);
}
int ResolutionIndex(unsigned short key) {
    switch(key){case kVK_ANSI_1:return 0;case kVK_ANSI_2:return 1;case kVK_ANSI_3:return 2;case kVK_ANSI_4:return 3;case kVK_ANSI_5:return 4;default:return -1;}
}
int HandleShortcut(NSEvent *event) {
    const unsigned short key=event.keyCode;
    if(key!=kVK_ANSI_Comma && key!=kVK_ANSI_Period)return -1;
    const bool active=TestMode() || NSApp.isActive;
    bool fire=false,open=false;
    {
        UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);
        if(event.type==NSEventTypeKeyUp)return s.swallowedKeys.erase(key)>0;
        const bool owned=s.swallowedKeys.count(key)>0;
        // One action per physical press. A repeat that began in the game (or
        // another app) keeps its original owner, including the eventual release.
        if(event.isARepeat || !active || (event.modifierFlags &
            (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl|NSEventModifierFlagShift)))return owned;
        fire=!owned;open=!s.visible;s.swallowedKeys.insert(key);++s.inputEvents;
    }
    if(fire){
        if(key==kVK_ANSI_Comma)SetVisible(open);
        else ToggleProcessing();
    }
    return 1;
}
bool HandleInput(NSEvent *event) {
    if(!event || (event.type!=NSEventTypeKeyDown && event.type!=NSEventTypeKeyUp))return false;
    const int shortcut=HandleShortcut(event);if(shortcut>=0)return shortcut!=0;
    UIState &s=S();NRFrameHookSettings apply={};bool applyNow=false,toggleNow=false;
    {
        std::lock_guard<std::mutex> guard(s.lock);
        unsigned short key=event.keyCode;
        if(event.type==NSEventTypeKeyUp)return s.swallowedKeys.erase(key)>0;
        bool owned=s.swallowedKeys.count(key)>0;
        // A repeat of a key pressed before opening belongs to the game. Taking
        // ownership here would swallow its release and leave that key held.
        if(event.isARepeat && !owned)return false;
        if(!s.visible)return owned;
        if(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl))return owned;
        int digit=ResolutionIndex(key);
        bool reserved=key==kVK_Escape || key==kVK_Tab || key==kVK_UpArrow || key==kVK_DownArrow ||
            key==kVK_LeftArrow || key==kVK_RightArrow || key==kVK_Return || key==kVK_ANSI_KeypadEnter || (s.focus==4 && digit>=0);
        if(!reserved)return owned;
        s.swallowedKeys.insert(key);++s.inputEvents;
        if(key==kVK_Escape){s.visible=false;fprintf(stderr,"[HT UI] compact panel closed by Escape\n");}
        else if(key==kVK_Tab)s.focus=(s.focus+((event.modifierFlags&NSEventModifierFlagShift)?5:1))%6;
        else if(key==kVK_UpArrow)s.focus=(s.focus+5)%6;
        else if(key==kVK_DownArrow)s.focus=(s.focus+1)%6;
        else if(key==kVK_LeftArrow || key==kVK_RightArrow){
            if(s.focus==0)toggleNow=!event.isARepeat;
            else {Adjust(s.draft,s.focus,key==kVK_RightArrow?1:-1,event.modifierFlags&NSEventModifierFlagShift);applyNow=true;}
        } else if(key==kVK_Return || key==kVK_ANSI_KeypadEnter){
            if(!event.isARepeat){
                if(s.focus==0)toggleNow=true;
                else if(s.focus==4){Adjust(s.draft,s.focus,1,false);applyNow=true;}
            }
        } else if(s.focus==4 && digit>=0){s.draft.processingLongEdge=Sizes[digit];applyNow=true;}
        if(applyNow)apply=s.draft;
        ++s.revision;
    }
    if(applyNow)Apply(apply);
    if(toggleNow)ToggleProcessing();
    return true;
}

struct DrawState {NRFrameHookSnapshot snapshot;NRFrameHookSettings draft;int focus;uint64_t revision;char error[192];};
void Fill(CGContextRef c,CGRect r,float red,float green,float blue,float alpha=1){CGContextSetRGBFillColor(c,red,green,blue,alpha);CGContextFillRect(c,r);}
void Text(CGContextRef c,NSString *string,float x,float y,float size=16,float red=.91,float green=.94,float blue=.98) {
    CTFontRef font=CTFontCreateWithName(CFSTR("Helvetica"),size,nullptr);
    CGColorRef color=CGColorCreateGenericRGB(red,green,blue,1);
    NSDictionary *attrs=@{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font,(__bridge NSString *)kCTForegroundColorAttributeName:(__bridge id)color};
    NSAttributedString *attributed=[[NSAttributedString alloc]initWithString:string ?: @"" attributes:attrs];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGContextSaveGState(c);CGContextTranslateCTM(c,x,y);CGContextScaleCTM(c,1,-1);CGContextSetTextPosition(c,0,0);CTLineDraw(line,c);CGContextRestoreGState(c);
    CFRelease(line);CGColorRelease(color);CFRelease(font);
}
id<MTLTexture> Image(id<MTLDevice> device,const DrawState &state) {
    const size_t width=720,height=680,stride=width*4;
    std::vector<uint8_t> bytes(stride*height,0);
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c=CGBitmapContextCreate(bytes.data(),width,height,8,stride,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(color);if(!c)return nil;
    CGContextScaleCTM(c,2,2);CGContextTranslateCTM(c,0,PanelHeight);CGContextScaleCTM(c,1,-1);
    Fill(c,CGRectMake(0,0,PanelWidth,PanelHeight),.025,.035,.055,.94);
    Fill(c,CGRectMake(0,0,3,PanelHeight),.10,.85,.75);
    Text(c,@"HT Settings",15,28,19);
    Text(c,@", menu   . HT",246,26,11,.58,.71,.79);
    Text(c,[NSString stringWithFormat:@"HT: %.1f fps   ·   %.0f ms",state.snapshot.processedFPS,state.snapshot.timings.totalMilliseconds],15,50,12);
    NSString *status;
    if(state.snapshot.faulted)status=@"HT stopped. Restart the game.";
    else if(state.snapshot.recovering)status=state.draft.enabled ?
        @"Frame delayed. HT will resume automatically." : @"HT is off. Showing the original.";
    else if(state.snapshot.warming)status=@"Preparing… Showing the original.";
    else if(state.snapshot.settingsPending)status=@"Applying settings…";
    else if(state.error[0])status=@"Change not applied. Please try again.";
    else if(!state.snapshot.surfaceSupported)status=@"SDR required: turn off HDR in the game.";
    else if(!state.draft.enabled)status=@"HT is off. Showing the original.";
    else status=@"HT is on";
    Text(c,status,15,72,11,state.snapshot.faulted?.98:.62,state.snapshot.faulted?.5:.77,.74);
    NSString *names[]={@"HT processing",@"Intensity",@"Local tone",@"Structure",@"Resolution (1–5)",@"Original on left"};
    for(int row=0;row<6;++row){
        float y=RowY(row);
        if(state.focus==row)Fill(c,CGRectMake(10,y-19,340,30),.08,.17,.22);
        Text(c,names[row],16,y+3,12);
        if(row==0){Text(c,state.draft.enabled?@"On":@"Off",148,y+3,13,.35,.94,.80);continue;}
        if(row==4){
            for(int i=0;i<5;++i){float x=126+i*43;if(Sizes[i]==state.draft.processingLongEdge)Fill(c,CGRectMake(x,y-15,41,25),.08,.4,.40);Text(c,[NSString stringWithFormat:@"%u",Sizes[i]],x+5,y+3,11);}
            continue;
        }
        float v=row==1?state.draft.intensity:row==2?state.draft.tone:row==3?state.draft.structure:state.draft.split;
        float fraction=v/(row==5?1:2);
        Fill(c,CGRectMake(148,y-3,164,5),.18,.23,.29);
        Fill(c,CGRectMake(148,y-3,164*fraction,5),.12,.75,.68);
        Fill(c,CGRectMake(145+164*fraction,y-8,6,15),.75,.98,.94);
        Text(c,[NSString stringWithFormat:@"%.2f",v],318,y+3,11);
    }
    Text(c,@"Tab / ↑↓ select   ←→ adjust",15,306,11,.65,.75,.82);
    Text(c,@"Enter select   Shift fine   Esc close",15,327,10,.65,.75,.82);
    CGContextRelease(c);
    // CoreGraphics bytes are premultiplied encoded sRGB. Preserve them for the
    // game's BGRA8Unorm/sRGB target; convert explicitly for linear targets.
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[device newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:bytes.data() bytesPerRow:stride];
    return texture;
}
struct GPUState {
    std::mutex lock;id<MTLDevice> device=nil;id<MTLLibrary> library=nil;
    NSMutableDictionary<NSNumber*,id<MTLRenderPipelineState>> *pipelines=[NSMutableDictionary dictionary];
    id<MTLTexture> image=nil;uint64_t revision=0;
};
GPUState &GPU(){static GPUState *state=new GPUState;return *state;}
bool OutputTransfer(id<CAMetalDrawable> drawable,uint32_t &linear) {
    if(![drawable respondsToSelector:@selector(layer)] || !drawable.layer.colorspace)return false;
    CFStringRef name=CGColorSpaceCopyName(drawable.layer.colorspace);
    bool srgb=name && (CFEqual(name,kCGColorSpaceSRGB) || CFEqual(name,kCGColorSpaceExtendedSRGB));
    bool linearSRGB=name && (CFEqual(name,kCGColorSpaceLinearSRGB) || CFEqual(name,kCGColorSpaceExtendedLinearSRGB));
    if(name)CFRelease(name);
    MTLPixelFormat format=drawable.texture.pixelFormat;
    if((format==MTLPixelFormatBGRA8Unorm || format==MTLPixelFormatRGBA16Float) && srgb){linear=0;return true;}
    if((format==MTLPixelFormatRGBA16Float && linearSRGB) || (format==MTLPixelFormatBGRA8Unorm_sRGB && srgb)){linear=1;return true;}
    return false;
}
id<MTLRenderPipelineState> Pipeline(GPUState &g,id<MTLDevice> device,MTLPixelFormat format) {
    if(g.device!=device){g.device=device;g.library=nil;g.image=nil;g.revision=0;[g.pipelines removeAllObjects];}
    if(id<MTLRenderPipelineState> pipeline=g.pipelines[@(format)])return pipeline;
    NSError *error=nil;
    if(!g.library){
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nstruct V{float4 p [[position]];float2 uv;};\nvertex V nr_ui_v(uint i [[vertex_id]],constant float4 &r [[buffer(0)]]){float2 q[6]={float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};V o;float2 a=q[i];o.p=float4(r.xy+a*r.zw,0,1);o.uv=a;return o;}\nfragment float4 nr_ui_f(V v [[stage_in]],texture2d<float> t [[texture(0)]],constant uint &linearOutput [[buffer(0)]]){constexpr sampler s(filter::linear,address::clamp_to_edge);float4 c=t.sample(s,v.uv);if(linearOutput && c.a>0){float3 u=clamp(c.rgb/c.a,0.0f,1.0f);u=select(pow((u+0.055f)/1.055f,float3(2.4f)),u/12.92f,u<=0.04045f);c.rgb=u*c.a;}return c;}";
        g.library=[device newLibraryWithSource:source options:nil error:&error];
        if(!g.library){Error(error.localizedDescription);return nil;}
    }
    MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction=[g.library newFunctionWithName:@"nr_ui_v"];
    descriptor.fragmentFunction=[g.library newFunctionWithName:@"nr_ui_f"];
    descriptor.colorAttachments[0].pixelFormat=format;
    descriptor.colorAttachments[0].blendingEnabled=YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if(!pipeline){Error(error.localizedDescription);return nil;}
    g.pipelines[@(format)]=pipeline;return pipeline;
}
} // namespace

int32_t NRInGameControlsInstall(void) {
    if(!NSThread.isMainThread || !NSApp)return -1;
    UIState &s=S();if(s.installed)return 0;
    Refresh();
    NSEventMask mask=NSEventMaskKeyDown|NSEventMaskKeyUp;
    s.monitor=[NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event){return HandleInput(event)?nil:event;}];
    if(!s.monitor)return -2;
    {std::lock_guard<std::mutex> guard(s.lock);s.hotkeyStatus=0;}
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    s.inactiveObserver=[center addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *){
        SetVisible(false);
        // Key/button releases can be delivered to the other application. Do not
        // retain those identities and swallow an unrelated later game release.
        UIState &state=S();std::lock_guard<std::mutex> guard(state.lock);
        state.swallowedKeys.clear();
    }];
    s.timer=[NSTimer timerWithTimeInterval:.15 repeats:YES block:^(NSTimer *){Refresh();}];
    [NSRunLoop.mainRunLoop addTimer:s.timer forMode:NSRunLoopCommonModes];
    {std::lock_guard<std::mutex> guard(s.lock);s.installed=true;}
    return 0;
}
void InGameControlsStart(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        int result=NRInGameControlsInstall();
        fprintf(stderr,"[HT UI] installation status=%d; comma=panel period=HT; foreground keyboard controls\n",result);
    });
}
void NRInGameControlsShutdown(void) {
    if(!NSThread.isMainThread)return;UIState &s=S();SetVisible(false);
    [s.timer invalidate];s.timer=nil;if(s.monitor){[NSEvent removeMonitor:s.monitor];s.monitor=nil;}
    if(s.inactiveObserver)[NSNotificationCenter.defaultCenter removeObserver:s.inactiveObserver];
    s.inactiveObserver=nil;
    std::lock_guard<std::mutex> guard(s.lock);s.installed=false;
}
void NRInGameControlsSetVisible(int32_t visible){if(NSThread.isMainThread)SetVisible(visible!=0);}
void NRInGameControlsEncode(void *command,void *drawable,void *) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb=(__bridge id<MTLCommandBuffer>)command;
        id<CAMetalDrawable> d=(__bridge id<CAMetalDrawable>)drawable;
        if(!cb || !d || ![d respondsToSelector:@selector(texture)] || cb.status>=MTLCommandBufferStatusCommitted)return;
        DrawState state={};double scale=1,x=0,y=0;
        {UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);if(!s.visible)return;
            scale=std::min({1.0,std::max(1.0,(double)d.texture.width-48)/PanelWidth,std::max(1.0,(double)d.texture.height-48)/PanelHeight});
            x=std::max(0.0,(double)d.texture.width-24-PanelWidth*scale);
            y=std::max(0.0,(double)d.texture.height-24-PanelHeight*scale);
            state.snapshot=s.snapshot;state.draft=s.draft;state.focus=s.focus;
            state.revision=s.revision;memcpy(state.error,s.error,sizeof(state.error));
        }
        uint32_t linearOutput=0;
        if(!OutputTransfer(d,linearOutput)){Error(@"The panel requires SDR sRGB or linear-sRGB");return;}
        GPUState &g=GPU();std::lock_guard<std::mutex> guard(g.lock);
        id<MTLRenderPipelineState> pipeline=Pipeline(g,cb.device,d.texture.pixelFormat);if(!pipeline)return;
        if(!g.image || g.revision!=state.revision){g.image=Image(cb.device,state);g.revision=state.revision;}
        if(!g.image){Error(@"Could not prepare the panel image");return;}
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:pass];
        if(!encoder){Error(@"Could not add the panel to the game frame");return;}
        float rect[4]={(float)(2*x/d.texture.width-1),(float)(1-2*y/d.texture.height),(float)(2*PanelWidth*scale/d.texture.width),(float)(-2*PanelHeight*scale/d.texture.height)};
        [encoder setRenderPipelineState:pipeline];[encoder setVertexBytes:rect length:sizeof(rect) atIndex:0];
        [encoder setFragmentTexture:g.image atIndex:0];[encoder setFragmentBytes:&linearOutput length:sizeof(linearOutput) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];[encoder endEncoding];
        // Game bypass buffers may use retainedReferences=false. A later UI
        // revision replaces our cached texture before this buffer runs. The
        // completion block owns these immutable resources even in that mode,
        // and releases them if the uncommitted command buffer is discarded.
        __block NSArray *resources=@[g.image,pipeline];
        [cb addCompletedHandler:^(id<MTLCommandBuffer>){resources=nil;}];
        UIState &s=S();std::lock_guard<std::mutex> lock(s.lock);++s.encoded;
    }
}
void NRInGameControlsCopyDiagnostics(NRInGameControlsDiagnostics *out){
    if(!out)return;UIState &s=S();std::lock_guard<std::mutex> guard(s.lock);*out={};
    out->encodedFrames=s.encoded;out->renderErrors=s.renderErrors;out->inputEvents=s.inputEvents;out->settingRequests=s.requests;
    out->installed=s.installed;out->visible=s.visible;out->keyboardOnly=1;out->focusedRow=s.focus;out->hotkeyStatus=s.hotkeyStatus;memcpy(out->lastError,s.error,sizeof(out->lastError));
}
int32_t NRInGameControlsHandleEventForTesting(void *event){return TestMode() && NSThread.isMainThread ? HandleInput((__bridge NSEvent *)event):0;}
void NRInGameControlsRefreshForTesting(void){if(TestMode() && NSThread.isMainThread)Refresh();}
