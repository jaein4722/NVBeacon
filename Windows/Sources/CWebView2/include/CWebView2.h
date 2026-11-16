// A small C API over the WebView2 COM interfaces, so Swift never has to build
// COM objects or vtables by hand. Every function must be called on the STA UI
// thread that created the view, and callbacks arrive on that same thread.
#ifndef NVBEACON_CWEBVIEW2_H
#define NVBEACON_CWEBVIEW2_H

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NVBWebView NVBWebView;

/// Called once when creation finishes. On failure `view` is NULL and the caller owns nothing.
typedef void (*NVBReadyCallback)(void *context, NVBWebView *view, HRESULT result);
/// Called for each message the page sends with `chrome.webview.postMessage(string)`.
typedef void (*NVBMessageCallback)(void *context, const wchar_t *message);

/// Loads WebView2Loader.dll from `loaderPath` (once per process).
HRESULT NVBWebViewLoad(const wchar_t *loaderPath);

/// The installed Evergreen runtime version; free with CoTaskMemFree. Fails when no runtime is installed.
HRESULT NVBWebViewRuntimeVersion(wchar_t **version);

/// Creates a child WebView2 filling `parent`, serving `contentFolder` at https://<hostName>/
/// and navigating to `startURL`. Only that host may be navigated to or send messages.
HRESULT NVBWebViewCreate(HWND parent, const wchar_t *userDataFolder, const wchar_t *hostName,
                         const wchar_t *contentFolder, const wchar_t *startURL,
                         COLORREF background, BOOL devToolsEnabled,
                         void *context, NVBReadyCallback ready, NVBMessageCallback message);

void NVBWebViewSetBounds(NVBWebView *view, RECT bounds);
void NVBWebViewSetVisible(NVBWebView *view, BOOL visible);
void NVBWebViewFocus(NVBWebView *view);
HRESULT NVBWebViewPostJSON(NVBWebView *view, const wchar_t *json);
/// Best effort; the view must be hidden first. Resumes automatically when shown.
HRESULT NVBWebViewTrySuspend(NVBWebView *view);
UINT32 NVBWebViewBrowserProcessID(NVBWebView *view);
/// Closes the controller and releases everything. `view` is invalid afterwards.
void NVBWebViewClose(NVBWebView *view);

#ifdef __cplusplus
}
#endif

#endif
