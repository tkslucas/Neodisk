// Direct2D and DirectWrite for the window chrome. Each surface draws into a premultiplied DIB through a DC
// render target and copies it into the paint DC as is, so what stays clear shows the window's backdrop.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <commctrl.h>
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <tuple>
#include <vector>

#include "CNeodiskWin.h"
#include "Internal.h"

using Microsoft::WRL::ComPtr;

ID2D1Factory *ndwD2DFactory() {
    static ID2D1Factory *factory = [] {
        ID2D1Factory *created = nullptr;
        D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &created);
        return created;
    }();
    return factory;
}

IDWriteFactory *ndwDWriteFactory() {
    static IDWriteFactory *factory = [] {
        IDWriteFactory *created = nullptr;
        DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                            reinterpret_cast<IUnknown **>(&created));
        return created;
    }();
    return factory;
}

IWICImagingFactory *ndwWICFactory() {
    static IWICImagingFactory *factory = [] {
        IWICImagingFactory *created = nullptr;
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&created));
        return created;
    }();
    return factory;
}

namespace {

bool hasFamily(const wchar_t *name) {
    ComPtr<IDWriteFontCollection> collection;
    if (FAILED(ndwDWriteFactory()->GetSystemFontCollection(&collection))) return false;
    UINT32 index = 0;
    BOOL exists = FALSE;
    return SUCCEEDED(collection->FindFamilyName(name, &index, &exists)) && exists;
}

const wchar_t *familyName(int32_t family) {
    static const wchar_t *text = hasFamily(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    static const wchar_t *display =
        hasFamily(L"Segoe UI Variable Display") ? L"Segoe UI Variable Display" : L"Segoe UI";
    static const wchar_t *icons = hasFamily(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    switch (family) {
    case NDW_FONT_DISPLAY: return display;
    case NDW_FONT_ICONS: return icons;
    default: return text;
    }
}

IDWriteTextFormat *textFormat(const NdwTextStyle &style) {
    static std::map<std::tuple<int, int, int, int>, ComPtr<IDWriteTextFormat>> cache;
    auto key = std::make_tuple(static_cast<int>(std::lround(style.size * 100)), style.weight, style.family, style.align);
    auto found = cache.find(key);
    if (found != cache.end()) return found->second.Get();
    ComPtr<IDWriteTextFormat> format;
    if (FAILED(ndwDWriteFactory()->CreateTextFormat(
            familyName(style.family), nullptr, static_cast<DWRITE_FONT_WEIGHT>(style.weight ? style.weight : 400),
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, style.size > 0 ? style.size : 14, L"", &format))) {
        return nullptr;
    }
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    switch (style.align) {
    case NDW_ALIGN_CENTER: format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER); break;
    case NDW_ALIGN_TRAILING: format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_TRAILING); break;
    default: format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING); break;
    }
    ComPtr<IDWriteInlineObject> ellipsis;
    if (SUCCEEDED(ndwDWriteFactory()->CreateEllipsisTrimmingSign(format.Get(), &ellipsis))) {
        DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        format->SetTrimming(&trimming, ellipsis.Get());
    }
    cache[key] = format;
    return format.Get();
}

IDWriteTypography *tabularFigures() {
    static IDWriteTypography *typography = [] {
        IDWriteTypography *created = nullptr;
        if (SUCCEEDED(ndwDWriteFactory()->CreateTypography(&created))) {
            created->AddFontFeature({DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, 1});
        }
        return created;
    }();
    return typography;
}

ComPtr<IDWriteTextLayout> makeLayout(const uint16_t *text, int32_t length, float width, float height,
                                     const NdwTextStyle &style) {
    ComPtr<IDWriteTextLayout> layout;
    IDWriteTextFormat *format = textFormat(style);
    if (!format || length <= 0) return layout;
    ndwDWriteFactory()->CreateTextLayout(reinterpret_cast<const wchar_t *>(text), static_cast<UINT32>(length),
                                         format, std::max(width, 0.0f), std::max(height, 0.0f), &layout);
    if (layout && style.tabular && tabularFigures()) {
        layout->SetTypography(tabularFigures(), {0, static_cast<UINT32>(length)});
    }
    return layout;
}

D2D1_COLOR_F color(NdwRGBA c) { return D2D1::ColorF(c.r, c.g, c.b, c.a); }
D2D1_RECT_F rectF(NdwRect r) { return D2D1::RectF(r.x, r.y, r.x + r.w, r.y + r.h); }

} // namespace

struct NdwGfx {
    ComPtr<ID2D1RenderTarget> target;
    ComPtr<ID2D1SolidColorBrush> brush;
    ComPtr<IWICBitmap> wicBitmap;
    int clipDepth = 0;

    ID2D1SolidColorBrush *paint(NdwRGBA c) {
        if (!brush) target->CreateSolidColorBrush(color(c), &brush);
        else brush->SetColor(color(c));
        return brush.Get();
    }
};

struct NdwSurface {
    HWND hwnd = nullptr;
    ComPtr<ID2D1DCRenderTarget> target;
    HDC memoryDC = nullptr;
    HBITMAP dib = nullptr;
    HGDIOBJ previousBitmap = nullptr;
    int dibWidth = 0;
    int dibHeight = 0;
    HDC paintDC = nullptr;
    RECT dirty = {};
    NdwGfx gfx;

    bool ensureDIB(int width, int height) {
        if (dib && width <= dibWidth && height <= dibHeight) return true;
        releaseDIB();
        BITMAPINFO info = {};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = std::max(width, dibWidth);
        info.bmiHeader.biHeight = -std::max(height, dibHeight);
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        void *bits = nullptr;
        memoryDC = CreateCompatibleDC(nullptr);
        dib = CreateDIBSection(memoryDC, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (!dib) return false;
        previousBitmap = SelectObject(memoryDC, dib);
        dibWidth = info.bmiHeader.biWidth;
        dibHeight = -info.bmiHeader.biHeight;
        return true;
    }

    void releaseDIB() {
        if (memoryDC) {
            if (previousBitmap) SelectObject(memoryDC, previousBitmap);
            DeleteDC(memoryDC);
        }
        if (dib) DeleteObject(dib);
        memoryDC = nullptr;
        dib = nullptr;
        previousBitmap = nullptr;
    }
};

extern "C" NdwSurface *ndw_surface_create(void *hwnd) {
    auto surface = new NdwSurface();
    surface->hwnd = static_cast<HWND>(hwnd);
    return surface;
}

extern "C" void ndw_surface_destroy(NdwSurface *surface) {
    if (!surface) return;
    surface->releaseDIB();
    delete surface;
}

extern "C" NdwGfx *ndw_surface_begin(NdwSurface *surface, void *hdc, int32_t x, int32_t y, int32_t width,
                                     int32_t height) {
    if (!surface || width <= 0 || height <= 0) return nullptr;
    if (!surface->ensureDIB(width, height)) return nullptr;
    if (!surface->target) {
        // Software: the chrome is small, and it keeps the readback into the DIB off the GPU queue.
        auto properties = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
        if (FAILED(ndwD2DFactory()->CreateDCRenderTarget(&properties, &surface->target))) return nullptr;
        surface->gfx.brush.Reset();
        // ClearType needs an opaque background; on the backdrop it's grayscale, as in the system's own apps.
        surface->target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    }
    RECT bounds = {0, 0, width, height};
    if (FAILED(surface->target->BindDC(surface->memoryDC, &bounds))) return nullptr;
    surface->paintDC = static_cast<HDC>(hdc);
    surface->dirty = {x, y, x + width, y + height};
    surface->gfx.target = surface->target;
    surface->gfx.clipDepth = 0;
    surface->target->BeginDraw();
    surface->target->SetTransform(D2D1::Matrix3x2F::Translation(static_cast<float>(-x), static_cast<float>(-y)));
    surface->target->Clear(D2D1::ColorF(0, 0, 0, 0));
    return &surface->gfx;
}

extern "C" int32_t ndw_surface_end(NdwSurface *surface) {
    if (!surface || !surface->target) return -1;
    while (surface->gfx.clipDepth > 0) ndw_pop_clip(&surface->gfx);
    HRESULT result = surface->target->EndDraw();
    if (result == D2DERR_RECREATE_TARGET) {
        surface->target.Reset();
        surface->gfx.brush.Reset();
        InvalidateRect(surface->hwnd, nullptr, FALSE);
        return -1;
    }
    GdiFlush();
    RECT &dirty = surface->dirty;
    BitBlt(surface->paintDC, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top,
           surface->memoryDC, 0, 0, SRCCOPY);
    surface->paintDC = nullptr;
    return SUCCEEDED(result) ? 0 : -1;
}

extern "C" NdwGfx *ndw_bitmap_begin(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || !ndwWICFactory()) return nullptr;
    auto gfx = new NdwGfx();
    if (FAILED(ndwWICFactory()->CreateBitmap(width, height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad,
                                             &gfx->wicBitmap))) {
        delete gfx;
        return nullptr;
    }
    auto properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96, 96);
    if (FAILED(ndwD2DFactory()->CreateWicBitmapRenderTarget(gfx->wicBitmap.Get(), &properties, &gfx->target))) {
        delete gfx;
        return nullptr;
    }
    gfx->target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    gfx->target->BeginDraw();
    gfx->target->Clear(D2D1::ColorF(0, 0, 0, 0));
    return gfx;
}

extern "C" int32_t ndw_bitmap_end(NdwGfx *gfx, uint8_t *bgra_out) {
    if (!gfx) return -1;
    while (gfx->clipDepth > 0) ndw_pop_clip(gfx);
    HRESULT result = gfx->target->EndDraw();
    if (SUCCEEDED(result) && bgra_out) {
        UINT width = 0, height = 0;
        gfx->wicBitmap->GetSize(&width, &height);
        result = gfx->wicBitmap->CopyPixels(nullptr, width * 4, width * height * 4, bgra_out);
    }
    delete gfx;
    return SUCCEEDED(result) ? 0 : -1;
}

extern "C" void ndw_fill_rect(NdwGfx *gfx, NdwRect rect, NdwRGBA c) {
    if (!gfx || c.a <= 0) return;
    gfx->target->FillRectangle(rectF(rect), gfx->paint(c));
}

extern "C" void ndw_fill_rounded(NdwGfx *gfx, NdwRect rect, float radius, NdwRGBA c) {
    if (!gfx || c.a <= 0) return;
    gfx->target->FillRoundedRectangle(D2D1::RoundedRect(rectF(rect), radius, radius), gfx->paint(c));
}

extern "C" void ndw_stroke_rounded(NdwGfx *gfx, NdwRect rect, float radius, float width, NdwRGBA c) {
    if (!gfx || c.a <= 0) return;
    // Centered on the pixel grid, so a 1 px stroke stays one pixel wide.
    NdwRect inset = {rect.x + width / 2, rect.y + width / 2, rect.w - width, rect.h - width};
    gfx->target->DrawRoundedRectangle(D2D1::RoundedRect(rectF(inset), radius, radius), gfx->paint(c), width);
}

extern "C" void ndw_fill_ellipse(NdwGfx *gfx, NdwRect rect, NdwRGBA c) {
    if (!gfx || c.a <= 0) return;
    gfx->target->FillEllipse(
        D2D1::Ellipse(D2D1::Point2F(rect.x + rect.w / 2, rect.y + rect.h / 2), rect.w / 2, rect.h / 2),
        gfx->paint(c));
}

extern "C" void ndw_line(NdwGfx *gfx, float x0, float y0, float x1, float y1, float width, NdwRGBA c) {
    if (!gfx || c.a <= 0) return;
    gfx->target->DrawLine(D2D1::Point2F(x0, y0), D2D1::Point2F(x1, y1), gfx->paint(c), width);
}

extern "C" void ndw_fill_stripes(NdwGfx *gfx, NdwRect rect, float radius, float period, float phase, NdwRGBA c) {
    if (!gfx || c.a <= 0 || rect.w <= 0 || rect.h <= 0 || period <= 1) return;
    ComPtr<ID2D1RoundedRectangleGeometry> mask;
    ComPtr<ID2D1PathGeometry> stripes;
    ComPtr<ID2D1GeometrySink> sink;
    if (FAILED(ndwD2DFactory()->CreateRoundedRectangleGeometry(
            D2D1::RoundedRect(rectF(rect), radius, radius), &mask)) ||
        FAILED(ndwD2DFactory()->CreatePathGeometry(&stripes)) || FAILED(stripes->Open(&sink))) {
        return;
    }
    float offset = std::fmod(phase, period);
    if (offset < 0) offset += period;
    float half = period / 2;
    for (float x = rect.x - rect.h - period + offset; x < rect.x + rect.w; x += period) {
        sink->BeginFigure(D2D1::Point2F(x, rect.y + rect.h), D2D1_FIGURE_BEGIN_FILLED);
        D2D1_POINT_2F points[] = {
            D2D1::Point2F(x + rect.h, rect.y),
            D2D1::Point2F(x + rect.h + half, rect.y),
            D2D1::Point2F(x + half, rect.y + rect.h),
        };
        sink->AddLines(points, 3);
        sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    }
    sink->Close();
    ComPtr<ID2D1Layer> layer;
    if (FAILED(gfx->target->CreateLayer(&layer))) return;
    gfx->target->PushLayer(D2D1::LayerParameters(rectF(rect), mask.Get()), layer.Get());
    gfx->target->FillGeometry(stripes.Get(), gfx->paint(c));
    gfx->target->PopLayer();
}

extern "C" void ndw_push_clip(NdwGfx *gfx, NdwRect rect) {
    if (!gfx) return;
    gfx->target->PushAxisAlignedClip(rectF(rect), D2D1_ANTIALIAS_MODE_ALIASED);
    gfx->clipDepth += 1;
}

extern "C" void ndw_pop_clip(NdwGfx *gfx) {
    if (!gfx || gfx->clipDepth == 0) return;
    gfx->target->PopAxisAlignedClip();
    gfx->clipDepth -= 1;
}

extern "C" void ndw_text(NdwGfx *gfx, const uint16_t *text, int32_t length, NdwRect rect, NdwTextStyle style,
                         NdwRGBA c) {
    if (!gfx || c.a <= 0) return;
    auto layout = makeLayout(text, length, rect.w, rect.h, style);
    if (!layout) return;
    gfx->target->DrawTextLayout(D2D1::Point2F(rect.x, rect.y), layout.Get(), gfx->paint(c),
                                D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

extern "C" float ndw_text_width(const uint16_t *text, int32_t length, NdwTextStyle style) {
    auto layout = makeLayout(text, length, 100000, 1000, style);
    if (!layout) return 0;
    DWRITE_TEXT_METRICS metrics = {};
    layout->GetMetrics(&metrics);
    return metrics.widthIncludingTrailingWhitespace;
}

extern "C" void *ndw_glyph_image_list(const uint16_t *glyphs, int32_t count, int32_t width, int32_t height,
                                      float glyph_size, NdwRGBA c) {
    if (count <= 0 || width <= 0 || height <= 0) return nullptr;
    HIMAGELIST list = ImageList_Create(width, height, ILC_COLOR32, count, 0);
    if (!list) return nullptr;
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    for (int32_t index = 0; index < count; index++) {
        NdwGfx *gfx = ndw_bitmap_begin(width, height);
        if (!gfx) break;
        if (glyphs[index] != ' ') {
            NdwTextStyle style = {glyph_size, 400, NDW_FONT_ICONS, NDW_ALIGN_CENTER, 0};
            ndw_text(gfx, &glyphs[index], 1, {0, 0, static_cast<float>(width), static_cast<float>(height)}, style, c);
        }
        if (ndw_bitmap_end(gfx, pixels.data()) != 0) break;
        // An image list reads a 32-bit image whose alpha is zero everywhere as opaque (black): keep one
        // pixel faintly set so a blank glyph stays blank.
        bool anyAlpha = false;
        for (size_t i = 3; i < pixels.size(); i += 4) anyAlpha = anyAlpha || pixels[i] != 0;
        if (!anyAlpha) pixels[3] = 1;
        BITMAPINFO info = {};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        void *bits = nullptr;
        HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (!bitmap) break;
        memcpy(bits, pixels.data(), pixels.size());
        ImageList_Add(list, bitmap, nullptr);
        DeleteObject(bitmap);
    }
    return list;
}
