#ifndef NR_IN_GAME_CONTROLS_H
#define NR_IN_GAME_CONTROLS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Call on the AppKit main thread once NSApplication exists. No window, event
// tap, Accessibility access, global input monitor or cursor capture is created.
// Plain physical comma toggles the panel; period toggles HT even when closed.
// Only the foreground game receives these local shortcuts (RU layout: Б/Ю).
// Inside the panel: Tab/arrows/Enter/Escape and 1..5 on the size row. Other keys,
// mouse, scroll and modified shortcuts remain available to the game.
// Return 0 once the local keyboard monitor is installed.
int32_t NRInGameControlsInstall(void);
// Convenience entry point: internally dispatches installation to main. Call
// only after the game host gate. The caller registers the render callback.
void InGameControlsStart(void);
void NRInGameControlsShutdown(void); // Main thread; removes owned event handlers.
void NRInGameControlsSetVisible(int32_t visible); // Main thread.

// Compatible with NRFrameHookOverlayCallback. Append AFTER HT, including the
// off/bypass path. Never commits, presents, waits, or calls the hook's state API.
void NRInGameControlsEncode(void *commandBuffer, void *drawable, void *context);

typedef struct NRInGameControlsDiagnostics {
    uint64_t encodedFrames, renderErrors, inputEvents, settingRequests;
    int32_t installed, visible, keyboardOnly, focusedRow, hotkeyStatus;
    char lastError[192];
} NRInGameControlsDiagnostics;
void NRInGameControlsCopyDiagnostics(NRInGameControlsDiagnostics *output);

// Own harness only (NR_INGAME_UI_TEST=1), uses the production event handler and
// settings poll without installing a monitor or touching another application.
int32_t NRInGameControlsHandleEventForTesting(void *nsEvent);
void NRInGameControlsRefreshForTesting(void);
#ifdef __cplusplus
}
#endif
#endif
