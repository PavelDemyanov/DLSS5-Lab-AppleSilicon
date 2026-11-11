#import <Foundation/Foundation.h>
#include "NeuralFrameHook.h"
#include "InGameControls.h"

static NSString *StartupPath() {
    const char *p=getenv("NR_FRAME_GAME_STARTUP_LOG");
    return p && p[0]=='/' ? [NSString stringWithUTF8String:p] : nil;
}
static void WriteStartup(int status,NSString *message) {
    NSString *path=StartupPath();if(!path)return;
    NSDictionary *record=@{@"mode":@"experimental in-game HT SDR with live settings, not NVIDIA DLSS",
        @"status":@(status),@"message":message ?: @"",@"pid":@(NSProcessInfo.processInfo.processIdentifier),
        @"panelShortcut":@"Comma physical key during gameplay",@"effectShortcut":@"Period physical key during gameplay",@"expectedGameVersion":@"2.5.0"};
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
}
static void Ready(int32_t status,const char *error,void *) {
    @autoreleasepool {
        WriteStartup(status,status==0 ? @"HT warmed and hook installed; explicit activation required" :
            (error ? [NSString stringWithUTF8String:error] : @"Initialization failed"));
        const char *controls=getenv("NR_FRAME_GAME_CONTROLS");
        if(status==0 && controls && !strcmp(controls,"1")) {
            NRFrameHookSetOverlayRenderer(NRInGameControlsEncode,nullptr);
            InGameControlsStart();
        }
    }
}
__attribute__((constructor)) static void StartGameExperiment() {
    const char *mode=getenv("NR_FRAME_GAME_MODE");
    if(!mode || strcmp(mode,"ht-sdr-serial-experiment"))return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSBundle *bundle=NSBundle.mainBundle;
            if(![bundle.bundleIdentifier isEqualToString:@"com.cdprojektred.cyberpunk.steam"] ||
               ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:@"2.5.0"]) {
                WriteStartup(-1,@"Host is not the verified native Cyberpunk 2.5.0");return;
            }
            const char *serial=getenv("NR_FRAME_HOOK_SERIAL_COMMIT");
            if(!serial || strcmp(serial,"1")){WriteStartup(-1,@"Sequential submission is required");return;}
            unsigned width=(unsigned)strtoul(getenv("NR_FRAME_GAME_WIDTH") ?: "0",nullptr,10);
            unsigned height=(unsigned)strtoul(getenv("NR_FRAME_GAME_HEIGHT") ?: "0",nullptr,10);
            WriteStartup(100,@"Preparing model and three warmup frames; game frames are unchanged");
            int result=NRFrameHookStartForTesting(getenv("NR_FRAME_GAME_BRIDGE"),getenv("NR_FRAME_GAME_MODEL"),
                getenv("NR_FRAME_GAME_LOG"),width,height,Ready,nullptr);
            if(result)WriteStartup(result,@"Frame hook refused initialization");
        }
    });
}
