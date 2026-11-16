#define COBJMACROS
#define CINTERFACE
#include "CWebView2.h"
#include <stdio.h>
#include <wchar.h>
#include <WebView2.h>

// The SDK declares IIDs but ships no definitions for C; these come from the
// MIDL_INTERFACE uuids in WebView2.h (SDK 1.0.4314.35) and never change.
static const IID IIDEnvironmentCompleted = {0x4e8a3389, 0xc9d8, 0x4bd2, {0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d}};
static const IID IIDControllerCompleted = {0x6c4819f3, 0xc9b7, 0x4260, {0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c}};
static const IID IIDWebMessageReceived = {0x57213f19, 0x00e6, 0x49fa, {0x8e, 0x07, 0x89, 0x8e, 0xa0, 0x1e, 0xcb, 0xd2}};
static const IID IIDNavigationStarting = {0x9adbe429, 0xf36d, 0x432b, {0x9d, 0xdc, 0xf8, 0x88, 0x1f, 0xbd, 0x76, 0xe3}};
static const IID IIDTrySuspendCompleted = {0x00f206a7, 0x9d17, 0x4605, {0x91, 0xf6, 0x4e, 0x8e, 0x4d, 0xe1, 0x92, 0xe3}};
static const IID IIDWebView3 = {0xa0d6df20, 0x3b92, 0x416d, {0xaa, 0x0c, 0x43, 0x7a, 0x9c, 0x72, 0x78, 0x57}};
static const IID IIDController2 = {0xc979903e, 0xd4ca, 0x4228, {0x92, 0xeb, 0x47, 0xee, 0x3f, 0xa9, 0x6e, 0xab}};
static const IID IIDUnknown = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

typedef HRESULT (STDAPICALLTYPE *CreateEnvironmentFunction)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *,
                                                            ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
typedef HRESULT (STDAPICALLTYPE *VersionFunction)(PCWSTR, LPWSTR *);
static CreateEnvironmentFunction createEnvironment;
static VersionFunction runtimeVersion;

struct NVBWebView {
    HWND parent;
    ICoreWebView2Environment *environment;
    ICoreWebView2Controller *controller;
    ICoreWebView2 *webview;
    EventRegistrationToken messageToken, navigationToken;
    wchar_t *hostName, *contentFolder, *startURL, *allowedPrefix;
    COLORREF background;
    BOOL devToolsEnabled;
    void *context;
    NVBReadyCallback ready;
    NVBMessageCallback message;
};

// One COM object layout for every handler: a vtable pointer, a reference count,
// the interface it answers to, and the view it reports to.
typedef struct Handler {
    void *lpVtbl;
    LONG references;
    const IID *iid;
    NVBWebView *view;
} Handler;

static HRESULT STDMETHODCALLTYPE HandlerQueryInterface(void *self, REFIID riid, void **object) {
    Handler *handler = (Handler *)self;
    if (IsEqualIID(riid, &IIDUnknown) || IsEqualIID(riid, handler->iid)) {
        InterlockedIncrement(&handler->references);
        *object = self;
        return S_OK;
    }
    *object = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE HandlerAddRef(void *self) {
    return (ULONG)InterlockedIncrement(&((Handler *)self)->references);
}

static ULONG STDMETHODCALLTYPE HandlerRelease(void *self) {
    LONG remaining = InterlockedDecrement(&((Handler *)self)->references);
    if (remaining == 0) HeapFree(GetProcessHeap(), 0, self);
    return (ULONG)remaining;
}

static Handler *HandlerCreate(void *vtable, const IID *iid, NVBWebView *view) {
    Handler *handler = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(Handler));
    if (!handler) return NULL;
    handler->lpVtbl = vtable;
    handler->references = 1;
    handler->iid = iid;
    handler->view = view;
    return handler;
}

static wchar_t *CopyString(const wchar_t *text) {
    if (!text) return NULL;
    size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
    wchar_t *copy = HeapAlloc(GetProcessHeap(), 0, bytes);
    if (copy) memcpy(copy, text, bytes);
    return copy;
}

static void FreeView(NVBWebView *view) {
    if (view->webview) {
        ICoreWebView2_remove_WebMessageReceived(view->webview, view->messageToken);
        ICoreWebView2_remove_NavigationStarting(view->webview, view->navigationToken);
        ICoreWebView2_Release(view->webview);
    }
    if (view->controller) {
        ICoreWebView2Controller_Close(view->controller);
        ICoreWebView2Controller_Release(view->controller);
    }
    if (view->environment) ICoreWebView2Environment_Release(view->environment);
    HeapFree(GetProcessHeap(), 0, view->hostName);
    HeapFree(GetProcessHeap(), 0, view->contentFolder);
    HeapFree(GetProcessHeap(), 0, view->startURL);
    HeapFree(GetProcessHeap(), 0, view->allowedPrefix);
    HeapFree(GetProcessHeap(), 0, view);
}

static void Fail(NVBWebView *view, HRESULT result) {
    NVBReadyCallback ready = view->ready;
    void *context = view->context;
    FreeView(view);
    ready(context, NULL, FAILED(result) ? result : E_FAIL);
}

static BOOL IsAllowed(NVBWebView *view, const wchar_t *uri) {
    size_t length = wcslen(view->allowedPrefix);
    return uri && _wcsnicmp(uri, view->allowedPrefix, length) == 0;
}

// MARK: Events

static HRESULT STDMETHODCALLTYPE MessageInvoke(ICoreWebView2WebMessageReceivedEventHandler *self, ICoreWebView2 *sender,
                                               ICoreWebView2WebMessageReceivedEventArgs *args) {
    NVBWebView *view = ((Handler *)self)->view;
    LPWSTR source = NULL, text = NULL;
    if (SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs_get_Source(args, &source)) && IsAllowed(view, source) &&
        SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs_TryGetWebMessageAsString(args, &text)) && text) {
        view->message(view->context, text);
    }
    CoTaskMemFree(source);
    CoTaskMemFree(text);
    return S_OK;
}

static ICoreWebView2WebMessageReceivedEventHandlerVtbl MessageVtbl = {
    (void *)HandlerQueryInterface, (void *)HandlerAddRef, (void *)HandlerRelease, MessageInvoke};

static HRESULT STDMETHODCALLTYPE NavigationInvoke(ICoreWebView2NavigationStartingEventHandler *self, ICoreWebView2 *sender,
                                                  ICoreWebView2NavigationStartingEventArgs *args) {
    NVBWebView *view = ((Handler *)self)->view;
    LPWSTR uri = NULL;
    if (FAILED(ICoreWebView2NavigationStartingEventArgs_get_Uri(args, &uri)) || !IsAllowed(view, uri)) {
        ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
    }
    CoTaskMemFree(uri);
    return S_OK;
}

static ICoreWebView2NavigationStartingEventHandlerVtbl NavigationVtbl = {
    (void *)HandlerQueryInterface, (void *)HandlerAddRef, (void *)HandlerRelease, NavigationInvoke};

// MARK: Creation

static HRESULT STDMETHODCALLTYPE ControllerInvoke(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *self,
                                                  HRESULT result, ICoreWebView2Controller *controller) {
    NVBWebView *view = ((Handler *)self)->view;
    if (FAILED(result) || !controller) { Fail(view, result); return S_OK; }
    view->controller = controller;
    ICoreWebView2Controller_AddRef(controller);

    ICoreWebView2Controller2 *controller2 = NULL;
    if (SUCCEEDED(ICoreWebView2Controller_QueryInterface(controller, &IIDController2, (void **)&controller2))) {
        // Matches the page background so the view never flashes white.
        COREWEBVIEW2_COLOR color = {255, GetRValue(view->background), GetGValue(view->background), GetBValue(view->background)};
        ICoreWebView2Controller2_put_DefaultBackgroundColor(controller2, color);
        ICoreWebView2Controller2_Release(controller2);
    }

    HRESULT hr = ICoreWebView2Controller_get_CoreWebView2(controller, &view->webview);
    if (FAILED(hr)) { Fail(view, hr); return S_OK; }

    ICoreWebView2Settings *settings = NULL;
    if (SUCCEEDED(ICoreWebView2_get_Settings(view->webview, &settings))) {
        ICoreWebView2Settings_put_AreHostObjectsAllowed(settings, FALSE);
        ICoreWebView2Settings_put_AreDefaultScriptDialogsEnabled(settings, FALSE);
        ICoreWebView2Settings_put_AreDefaultContextMenusEnabled(settings, view->devToolsEnabled);
        ICoreWebView2Settings_put_AreDevToolsEnabled(settings, view->devToolsEnabled);
        ICoreWebView2Settings_put_IsStatusBarEnabled(settings, FALSE);
        ICoreWebView2Settings_put_IsZoomControlEnabled(settings, FALSE);
        ICoreWebView2Settings_Release(settings);
    }

    ICoreWebView2_3 *webview3 = NULL;
    hr = ICoreWebView2_QueryInterface(view->webview, &IIDWebView3, (void **)&webview3);
    if (FAILED(hr)) { Fail(view, hr); return S_OK; }
    hr = ICoreWebView2_3_SetVirtualHostNameToFolderMapping(webview3, view->hostName, view->contentFolder,
                                                          COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY);
    ICoreWebView2_3_Release(webview3);
    if (FAILED(hr)) { Fail(view, hr); return S_OK; }

    Handler *messages = HandlerCreate(&MessageVtbl, &IIDWebMessageReceived, view);
    Handler *navigation = HandlerCreate(&NavigationVtbl, &IIDNavigationStarting, view);
    if (!messages || !navigation) {
        if (messages) HandlerRelease(messages);
        if (navigation) HandlerRelease(navigation);
        Fail(view, E_OUTOFMEMORY);
        return S_OK;
    }
    ICoreWebView2_add_WebMessageReceived(view->webview, (ICoreWebView2WebMessageReceivedEventHandler *)messages, &view->messageToken);
    ICoreWebView2_add_NavigationStarting(view->webview, (ICoreWebView2NavigationStartingEventHandler *)navigation, &view->navigationToken);
    HandlerRelease(messages);   // the webview holds its own references now
    HandlerRelease(navigation);

    RECT bounds;
    GetClientRect(view->parent, &bounds);
    ICoreWebView2Controller_put_Bounds(controller, bounds);
    hr = ICoreWebView2_Navigate(view->webview, view->startURL);
    if (FAILED(hr)) { Fail(view, hr); return S_OK; }
    view->ready(view->context, view, S_OK);
    return S_OK;
}

static ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl ControllerVtbl = {
    (void *)HandlerQueryInterface, (void *)HandlerAddRef, (void *)HandlerRelease, ControllerInvoke};

static HRESULT STDMETHODCALLTYPE EnvironmentInvoke(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *self,
                                                   HRESULT result, ICoreWebView2Environment *environment) {
    NVBWebView *view = ((Handler *)self)->view;
    if (FAILED(result) || !environment) { Fail(view, result); return S_OK; }
    view->environment = environment;
    ICoreWebView2Environment_AddRef(environment);
    Handler *handler = HandlerCreate(&ControllerVtbl, &IIDControllerCompleted, view);
    if (!handler) { Fail(view, E_OUTOFMEMORY); return S_OK; }
    HRESULT hr = ICoreWebView2Environment_CreateCoreWebView2Controller(
        environment, view->parent, (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *)handler);
    HandlerRelease(handler);
    if (FAILED(hr)) Fail(view, hr);
    return S_OK;
}

static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl EnvironmentVtbl = {
    (void *)HandlerQueryInterface, (void *)HandlerAddRef, (void *)HandlerRelease, EnvironmentInvoke};

// MARK: Public API

HRESULT NVBWebViewLoad(const wchar_t *loaderPath) {
    if (createEnvironment) return S_OK;
    HMODULE module = LoadLibraryExW(loaderPath, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module) return HRESULT_FROM_WIN32(GetLastError());
    createEnvironment = (CreateEnvironmentFunction)(void *)GetProcAddress(module, "CreateCoreWebView2EnvironmentWithOptions");
    runtimeVersion = (VersionFunction)(void *)GetProcAddress(module, "GetAvailableCoreWebView2BrowserVersionString");
    return createEnvironment && runtimeVersion ? S_OK : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}

HRESULT NVBWebViewRuntimeVersion(wchar_t **version) {
    if (!runtimeVersion) return E_NOT_VALID_STATE;
    return runtimeVersion(NULL, version);
}

HRESULT NVBWebViewCreate(HWND parent, const wchar_t *userDataFolder, const wchar_t *hostName,
                         const wchar_t *contentFolder, const wchar_t *startURL,
                         COLORREF background, BOOL devToolsEnabled,
                         void *context, NVBReadyCallback ready, NVBMessageCallback message) {
    if (!createEnvironment) return E_NOT_VALID_STATE;
    NVBWebView *view = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(NVBWebView));
    if (!view) return E_OUTOFMEMORY;
    view->parent = parent;
    view->hostName = CopyString(hostName);
    view->contentFolder = CopyString(contentFolder);
    view->startURL = CopyString(startURL);
    size_t prefixLength = wcslen(hostName) + 10;
    view->allowedPrefix = HeapAlloc(GetProcessHeap(), 0, prefixLength * sizeof(wchar_t));
    if (view->allowedPrefix) swprintf(view->allowedPrefix, prefixLength, L"https://%s/", hostName);
    view->background = background;
    view->devToolsEnabled = devToolsEnabled;
    view->context = context;
    view->ready = ready;
    view->message = message;
    if (!view->hostName || !view->contentFolder || !view->startURL || !view->allowedPrefix) {
        FreeView(view);
        return E_OUTOFMEMORY;
    }
    Handler *handler = HandlerCreate(&EnvironmentVtbl, &IIDEnvironmentCompleted, view);
    if (!handler) { FreeView(view); return E_OUTOFMEMORY; }
    HRESULT hr = createEnvironment(NULL, userDataFolder, NULL,
                                   (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *)handler);
    HandlerRelease(handler);
    if (FAILED(hr)) FreeView(view);  // no callback will come
    return hr;
}

void NVBWebViewSetBounds(NVBWebView *view, RECT bounds) {
    ICoreWebView2Controller_put_Bounds(view->controller, bounds);
}

void NVBWebViewSetVisible(NVBWebView *view, BOOL visible) {
    ICoreWebView2Controller_put_IsVisible(view->controller, visible);
}

void NVBWebViewFocus(NVBWebView *view) {
    ICoreWebView2Controller_MoveFocus(view->controller, COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

HRESULT NVBWebViewPostJSON(NVBWebView *view, const wchar_t *json) {
    return ICoreWebView2_PostWebMessageAsJson(view->webview, json);
}

static HRESULT STDMETHODCALLTYPE SuspendInvoke(ICoreWebView2TrySuspendCompletedHandler *self, HRESULT result, BOOL suspended) {
    return S_OK;
}

static ICoreWebView2TrySuspendCompletedHandlerVtbl SuspendVtbl = {
    (void *)HandlerQueryInterface, (void *)HandlerAddRef, (void *)HandlerRelease, SuspendInvoke};

HRESULT NVBWebViewTrySuspend(NVBWebView *view) {
    ICoreWebView2_3 *webview3 = NULL;
    HRESULT hr = ICoreWebView2_QueryInterface(view->webview, &IIDWebView3, (void **)&webview3);
    if (FAILED(hr)) return hr;
    Handler *handler = HandlerCreate(&SuspendVtbl, &IIDTrySuspendCompleted, view);
    hr = handler ? ICoreWebView2_3_TrySuspend(webview3, (ICoreWebView2TrySuspendCompletedHandler *)handler) : E_OUTOFMEMORY;
    if (handler) HandlerRelease(handler);
    ICoreWebView2_3_Release(webview3);
    return hr;
}

UINT32 NVBWebViewBrowserProcessID(NVBWebView *view) {
    UINT32 pid = 0;
    if (view->webview) ICoreWebView2_get_BrowserProcessId(view->webview, &pid);
    return pid;
}

void NVBWebViewClose(NVBWebView *view) {
    if (view) FreeView(view);
}
