// Process setup, uxtheme, the folder picker, and window capture to PNG.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shobjidl.h>
#include <uxtheme.h>
#include <wincodec.h>
#include <wrl/client.h>
// Defines PROPID_ACC_NAME and the other annotation GUIDs here rather than needing them from a library.
#include <initguid.h>
#include <oleacc.h>

#include <vector>

#include "CNeodiskWin.h"
#include "Internal.h"

using Microsoft::WRL::ComPtr;

extern "C" int32_t ndw_initialize(void) {
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES | ICC_BAR_CLASSES};
    InitCommonControlsEx(&controls);
    return SUCCEEDED(result) ? 0 : -1;
}

extern "C" void ndw_set_app_dark_mode(int32_t dark) {
    // uxtheme exports these by ordinal only (Windows 10 1903 and later); they're how popup menus follow the
    // dark theme. Absent, menus stay light and nothing else changes.
    using SetPreferredAppMode = int(WINAPI *)(int);
    using FlushMenuThemes = void(WINAPI *)();
    static HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;
    auto setMode = reinterpret_cast<SetPreferredAppMode>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
    auto flush = reinterpret_cast<FlushMenuThemes>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(136)));
    if (setMode) setMode(dark ? 2 : 3); // ForceDark : ForceLight
    if (flush) flush();
}

extern "C" int32_t ndw_set_window_theme(void *hwnd, const uint16_t *app_name, const uint16_t *id_list) {
    return SUCCEEDED(SetWindowTheme(static_cast<HWND>(hwnd), reinterpret_cast<LPCWSTR>(app_name),
                                    reinterpret_cast<LPCWSTR>(id_list)))
               ? 0
               : -1;
}

extern "C" int32_t ndw_set_accessible_name(void *hwnd, const uint16_t *name) {
    ComPtr<IAccPropServices> services;
    if (FAILED(CoCreateInstance(CLSID_AccPropServices, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&services)))) {
        return -1;
    }
    return SUCCEEDED(services->SetHwndPropStr(static_cast<HWND>(hwnd), OBJID_CLIENT, CHILDID_SELF, PROPID_ACC_NAME,
                                              reinterpret_cast<LPCWSTR>(name)))
               ? 0
               : -1;
}

extern "C" int32_t ndw_set_accessible_value(void *hwnd, const uint16_t *value) {
    ComPtr<IAccPropServices> services;
    if (FAILED(CoCreateInstance(CLSID_AccPropServices, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&services)))) {
        return -1;
    }
    if (FAILED(services->SetHwndPropStr(static_cast<HWND>(hwnd), OBJID_CLIENT, CHILDID_SELF, PROPID_ACC_VALUE,
                                        reinterpret_cast<LPCWSTR>(value)))) {
        return -1;
    }
    NotifyWinEvent(EVENT_OBJECT_VALUECHANGE, static_cast<HWND>(hwnd), OBJID_CLIENT, CHILDID_SELF);
    return 0;
}

extern "C" int32_t ndw_track_popup_menu(void *menu, int32_t x, int32_t y, void *owner) {
    return static_cast<int32_t>(TrackPopupMenu(static_cast<HMENU>(menu), TPM_RETURNCMD | TPM_RIGHTBUTTON, x, y, 0,
                                               static_cast<HWND>(owner), nullptr));
}

extern "C" int32_t ndw_pick_folder(void *owner, const uint16_t *title, uint16_t *out, int32_t capacity) {
    ComPtr<IFileOpenDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
        return 0;
    }
    FILEOPENDIALOGOPTIONS options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    if (title) dialog->SetTitle(reinterpret_cast<LPCWSTR>(title));
    if (FAILED(dialog->Show(static_cast<HWND>(owner)))) return 0;
    ComPtr<IShellItem> item;
    if (FAILED(dialog->GetResult(&item))) return 0;
    PWSTR path = nullptr;
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) || !path) return 0;
    int32_t length = static_cast<int32_t>(wcslen(path));
    int32_t picked = 0;
    if (length < capacity) {
        memcpy(out, path, (length + 1) * sizeof(wchar_t));
        picked = 1;
    }
    CoTaskMemFree(path);
    return picked;
}

namespace {

HRESULT savePNG(const wchar_t *path, int width, int height, const uint8_t *bgra) {
    IWICImagingFactory *factory = ndwWICFactory();
    if (!factory) return E_FAIL;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    HRESULT result = factory->CreateStream(&stream);
    if (SUCCEEDED(result)) result = stream->InitializeFromFilename(path, GENERIC_WRITE);
    if (SUCCEEDED(result)) result = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(result)) result = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(result)) result = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(result)) result = frame->Initialize(nullptr);
    if (SUCCEEDED(result)) result = frame->SetSize(width, height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(result)) result = frame->SetPixelFormat(&format);
    if (SUCCEEDED(result)) {
        result = frame->WritePixels(height, width * 4, width * height * 4, const_cast<BYTE *>(bgra));
    }
    if (SUCCEEDED(result)) result = frame->Commit();
    if (SUCCEEDED(result)) result = encoder->Commit();
    return result;
}

} // namespace

extern "C" int32_t ndw_capture_window_png(void *hwnd, const uint16_t *path, int32_t from_screen) {
    HWND window = static_cast<HWND>(hwnd);
    RECT bounds = {};
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &bounds, sizeof(bounds)))) {
        GetWindowRect(window, &bounds);
    }
    int width = bounds.right - bounds.left;
    int height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0) return -1;

    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HDC memoryDC = CreateCompatibleDC(nullptr);
    HBITMAP dib = CreateDIBSection(memoryDC, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dib) {
        DeleteDC(memoryDC);
        return -1;
    }
    HGDIOBJ previous = SelectObject(memoryDC, dib);
    BOOL ok = FALSE;
    if (from_screen) {
        HDC screen = GetDC(nullptr);
        ok = BitBlt(memoryDC, 0, 0, width, height, screen, bounds.left, bounds.top, SRCCOPY | CAPTUREBLT);
        ReleaseDC(nullptr, screen);
    } else {
        ok = PrintWindow(window, memoryDC, PW_RENDERFULLCONTENT);
    }
    GdiFlush();
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    memcpy(pixels.data(), bits, pixels.size());
    for (size_t index = 3; index < pixels.size(); index += 4) pixels[index] = 255;
    SelectObject(memoryDC, previous);
    DeleteObject(dib);
    DeleteDC(memoryDC);
    if (!ok) return -1;
    return SUCCEEDED(savePNG(reinterpret_cast<const wchar_t *>(path), width, height, pixels.data())) ? 0 : -1;
}
