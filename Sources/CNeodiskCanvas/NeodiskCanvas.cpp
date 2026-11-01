// One D3D11 device (hardware, else WARP) and one Direct2D device serve every canvas, so images move freely
// between them. CPU rasters use their own single-threaded factory and never touch the shared device.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <d3d11.h>
#include <dwrite.h>
#include <dxgi1_2.h>
#include <wincodec.h>

#include <cmath>
#include <mutex>
#include <new>
#include <vector>

#include "NeodiskCanvas.h"

namespace {

template <typename T>
class Ref {
public:
    Ref() = default;
    Ref(const Ref &other) : p(other.p) { if (p) p->AddRef(); }
    Ref &operator=(const Ref &other) {
        if (this != &other) {
            Reset();
            p = other.p;
            if (p) p->AddRef();
        }
        return *this;
    }
    ~Ref() { Reset(); }
    void Reset() {
        if (p) p->Release();
        p = nullptr;
    }
    T **Put() {
        Reset();
        return &p;
    }
    T *Get() const { return p; }
    T *operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
    template <typename U>
    HRESULT As(Ref<U> &out) const { return p->QueryInterface(__uuidof(U), reinterpret_cast<void **>(out.Put())); }

private:
    T *p = nullptr;
};

struct Shared {
    std::mutex lock;
    bool attempted = false;
    HRESULT status = E_FAIL;
    bool isSoftware = false;
    Ref<ID3D11Device> d3d;
    Ref<ID3D11DeviceContext> d3dContext;
    Ref<IDXGIDevice1> dxgi;
    Ref<ID2D1Factory1> factory;
    Ref<ID2D1Device> device;
    Ref<IDWriteFactory> dwrite;
    Ref<IDWriteTextFormat> formats[2][64];
    std::mutex formatLock;
};

Shared &shared() {
    static Shared *instance = new Shared();
    return *instance;
}

HRESULT ensureDWrite() {
    Shared &s = shared();
    std::lock_guard<std::mutex> guard(s.formatLock);
    if (s.dwrite) return S_OK;
    return DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                               reinterpret_cast<IUnknown **>(s.dwrite.Put()));
}

/// Created on first use; a removed device is recreated on the next call after `resetShared`.
HRESULT ensureDevice() {
    Shared &s = shared();
    std::lock_guard<std::mutex> guard(s.lock);
    if (s.attempted) return s.status;
    s.attempted = true;

    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                  D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = E_FAIL;
    char forceWarp[4] = {};
    GetEnvironmentVariableA("NEODISK_CANVAS_WARP", forceWarp, sizeof(forceWarp));
    if (forceWarp[0] != '1') {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, ARRAYSIZE(levels),
                               D3D11_SDK_VERSION, s.d3d.Put(), nullptr, s.d3dContext.Put());
    }
    if (FAILED(hr)) {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, ARRAYSIZE(levels),
                               D3D11_SDK_VERSION, s.d3d.Put(), nullptr, s.d3dContext.Put());
    }
    if (FAILED(hr)) return s.status = hr;
    if (FAILED(hr = s.d3d.As(s.dxgi))) return s.status = hr;
    // Fewer queued frames: hover follows the pointer instead of trailing it.
    s.dxgi->SetMaximumFrameLatency(1);

    Ref<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc = {};
    if (SUCCEEDED(s.dxgi->GetAdapter(adapter.Put())) && SUCCEEDED(adapter->GetDesc(&desc))) {
        // The Basic Render Driver (vendor 0x1414, device 0x8c) is WARP behind a hardware driver type.
        s.isSoftware = desc.VendorId == 0x1414;
    }

    D2D1_FACTORY_OPTIONS options = {};
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, __uuidof(ID2D1Factory1), &options,
                           reinterpret_cast<void **>(s.factory.Put()));
    if (FAILED(hr)) return s.status = hr;
    if (FAILED(hr = s.factory->CreateDevice(s.dxgi.Get(), s.device.Put()))) return s.status = hr;
    if (FAILED(hr = ensureDWrite())) return s.status = hr;
    return s.status = S_OK;
}

void resetShared() {
    Shared &s = shared();
    std::lock_guard<std::mutex> guard(s.lock);
    s.device.Reset();
    s.factory.Reset();
    s.dxgi.Reset();
    s.d3dContext.Reset();
    s.d3d.Reset();
    s.attempted = false;
    s.status = E_FAIL;
}

IDWriteTextFormat *textFormat(float size, bool bold) {
    Shared &s = shared();
    if (FAILED(ensureDWrite())) return nullptr;
    int slot = static_cast<int>(std::lround(size * 2));
    if (slot < 1) slot = 1;
    if (slot > 63) slot = 63;
    std::lock_guard<std::mutex> guard(s.formatLock);
    Ref<IDWriteTextFormat> &format = s.formats[bold ? 1 : 0][slot];
    if (!format) {
        // Segoe UI Variable is Windows 11's UI face; DirectWrite falls back to Segoe UI where it's missing.
        HRESULT hr = s.dwrite->CreateTextFormat(
            L"Segoe UI Variable Text", nullptr, bold ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, slot / 2.0f, L"", format.Put());
        if (FAILED(hr)) {
            hr = s.dwrite->CreateTextFormat(L"Segoe UI", nullptr,
                                            bold ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_NORMAL,
                                            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, slot / 2.0f, L"",
                                            format.Put());
        }
        if (FAILED(hr)) return nullptr;
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
    }
    return format.Get();
}

D2D1_COLOR_F color(NDColor c) { return D2D1::ColorF(c.r, c.g, c.b, c.a); }

D2D1_RECT_F rectF(NDRect r) { return D2D1::RectF(r.x, r.y, r.x + r.width, r.y + r.height); }

HRESULT buildArc(ID2D1Factory *factory, float cx, float cy, const NDArc &arc, ID2D1PathGeometry **out) {
    float span = arc.end - arc.start;
    if (!(span > 0) || !(arc.outer > arc.inner)) return E_INVALIDARG;
    Ref<ID2D1PathGeometry> path;
    HRESULT hr = factory->CreatePathGeometry(path.Put());
    if (FAILED(hr)) return hr;
    Ref<ID2D1GeometrySink> sink;
    if (FAILED(hr = path->Open(sink.Put()))) return hr;
    // Spans over half a turn are split so each arc segment stays well-defined.
    int steps = span > 3.14159265f ? 2 : 1;
    float step = span / steps;
    auto at = [&](float radius, float angle) {
        return D2D1::Point2F(cx + radius * std::cos(angle), cy + radius * std::sin(angle));
    };
    sink->BeginFigure(at(arc.outer, arc.start), D2D1_FIGURE_BEGIN_FILLED);
    for (int i = 1; i <= steps; ++i) {
        sink->AddArc(D2D1::ArcSegment(at(arc.outer, arc.start + step * i), D2D1::SizeF(arc.outer, arc.outer), 0,
                                      D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
    }
    sink->AddLine(at(arc.inner, arc.end));
    if (arc.inner > 0.5f) {
        for (int i = steps - 1; i >= 0; --i) {
            sink->AddArc(D2D1::ArcSegment(at(arc.inner, arc.start + step * i), D2D1::SizeF(arc.inner, arc.inner), 0,
                                          D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
        }
    }
    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    if (FAILED(hr = sink->Close())) return hr;
    *out = path.Get();
    (*out)->AddRef();
    return S_OK;
}

void paintArcs(ID2D1RenderTarget *target, ID2D1Factory *factory, float cx, float cy, const NDArc *arcs,
               uint32_t count, const float *opacities, NDColor separator, float separatorWidth) {
    Ref<ID2D1SolidColorBrush> fill;
    Ref<ID2D1SolidColorBrush> stroke;
    if (FAILED(target->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0), fill.Put()))) return;
    if (FAILED(target->CreateSolidColorBrush(color(separator), stroke.Put()))) return;
    for (uint32_t i = 0; i < count; ++i) {
        float opacity = opacities ? opacities[i] : 1.0f;
        if (opacity <= 0.001f) continue;
        Ref<ID2D1PathGeometry> path;
        if (FAILED(buildArc(factory, cx, cy, arcs[i], path.Put()))) continue;
        NDColor c = arcs[i].fill;
        c.a *= opacity;
        fill->SetColor(color(c));
        target->FillGeometry(path.Get(), fill.Get());
        if (separatorWidth > 0) {
            NDColor s = separator;
            s.a *= opacity;
            stroke->SetColor(color(s));
            target->DrawGeometry(path.Get(), stroke.Get(), separatorWidth);
        }
    }
}

struct ComScope {
    HRESULT hr;
    ComScope() { hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED); }
    ~ComScope() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
};

} // namespace

struct NDImage {
    Ref<ID2D1Bitmap1> bitmap;
};

struct NDText {
    Ref<IDWriteTextLayout> layout;
    float width = 0;
    float height = 0;
    float naturalWidth = 0;
};

struct NDCanvas {
    HWND hwnd = nullptr;
    Ref<IDXGISwapChain1> swapChain;
    Ref<ID2D1DeviceContext> context;
    Ref<ID2D1Bitmap1> target;
    Ref<ID2D1SolidColorBrush> brush;
    uint32_t width = 0;
    uint32_t height = 0;
    float dpi = 96;
    int clipDepth = 0;

    HRESULT bindTarget() {
        target.Reset();
        context->SetTarget(nullptr);
        D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET | (swapChain ? D2D1_BITMAP_OPTIONS_CANNOT_DRAW : D2D1_BITMAP_OPTIONS_NONE),
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, swapChain ? D2D1_ALPHA_MODE_IGNORE : D2D1_ALPHA_MODE_PREMULTIPLIED),
            dpi, dpi);
        HRESULT hr;
        if (swapChain) {
            Ref<IDXGISurface> surface;
            if (FAILED(hr = swapChain->GetBuffer(0, __uuidof(IDXGISurface), reinterpret_cast<void **>(surface.Put()))))
                return hr;
            hr = context->CreateBitmapFromDxgiSurface(surface.Get(), &props, target.Put());
        } else {
            hr = context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &props, target.Put());
        }
        if (FAILED(hr)) return hr;
        context->SetTarget(target.Get());
        context->SetDpi(dpi, dpi);
        return S_OK;
    }
};

extern "C" {

static HRESULT makeContext(NDCanvas *canvas) {
    Shared &s = shared();
    HRESULT hr = s.device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, canvas->context.Put());
    if (FAILED(hr)) return hr;
    return canvas->context->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), canvas->brush.Put());
}

int32_t ndc_canvas_create_hwnd(void *hwnd, uint32_t pixelWidth, uint32_t pixelHeight, float dpi, NDCanvas **out) {
    *out = nullptr;
    HRESULT hr = ensureDevice();
    if (FAILED(hr)) return hr;
    Shared &s = shared();
    NDCanvas *canvas = new (std::nothrow) NDCanvas();
    if (!canvas) return E_OUTOFMEMORY;
    canvas->hwnd = static_cast<HWND>(hwnd);
    canvas->width = pixelWidth ? pixelWidth : 1;
    canvas->height = pixelHeight ? pixelHeight : 1;
    canvas->dpi = dpi;
    if (FAILED(hr = makeContext(canvas))) {
        delete canvas;
        return hr;
    }

    Ref<IDXGIAdapter> adapter;
    Ref<IDXGIFactory2> factory;
    if (SUCCEEDED(hr = s.dxgi->GetAdapter(adapter.Put())))
        hr = adapter->GetParent(__uuidof(IDXGIFactory2), reinterpret_cast<void **>(factory.Put()));
    if (FAILED(hr)) {
        delete canvas;
        return hr;
    }
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = canvas->width;
    desc.Height = canvas->height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    hr = factory->CreateSwapChainForHwnd(s.d3d.Get(), canvas->hwnd, &desc, nullptr, nullptr, canvas->swapChain.Put());
    if (FAILED(hr)) {
        // Flip-discard needs Windows 10; sequential covers the rest.
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        hr = factory->CreateSwapChainForHwnd(s.d3d.Get(), canvas->hwnd, &desc, nullptr, nullptr,
                                             canvas->swapChain.Put());
    }
    if (FAILED(hr)) {
        delete canvas;
        return hr;
    }
    factory->MakeWindowAssociation(canvas->hwnd, DXGI_MWA_NO_ALT_ENTER);
    if (FAILED(hr = canvas->bindTarget())) {
        delete canvas;
        return hr;
    }
    *out = canvas;
    return S_OK;
}

int32_t ndc_canvas_create_offscreen(uint32_t pixelWidth, uint32_t pixelHeight, float dpi, NDCanvas **out) {
    *out = nullptr;
    HRESULT hr = ensureDevice();
    if (FAILED(hr)) return hr;
    NDCanvas *canvas = new (std::nothrow) NDCanvas();
    if (!canvas) return E_OUTOFMEMORY;
    canvas->width = pixelWidth ? pixelWidth : 1;
    canvas->height = pixelHeight ? pixelHeight : 1;
    canvas->dpi = dpi;
    if (FAILED(hr = makeContext(canvas)) || FAILED(hr = canvas->bindTarget())) {
        delete canvas;
        return hr;
    }
    *out = canvas;
    return S_OK;
}

void ndc_canvas_destroy(NDCanvas *canvas) {
    if (!canvas) return;
    if (canvas->context) canvas->context->SetTarget(nullptr);
    delete canvas;
}

int32_t ndc_canvas_resize(NDCanvas *canvas, uint32_t pixelWidth, uint32_t pixelHeight, float dpi) {
    pixelWidth = pixelWidth ? pixelWidth : 1;
    pixelHeight = pixelHeight ? pixelHeight : 1;
    if (pixelWidth == canvas->width && pixelHeight == canvas->height && dpi == canvas->dpi) return S_OK;
    canvas->width = pixelWidth;
    canvas->height = pixelHeight;
    canvas->dpi = dpi;
    canvas->target.Reset();
    canvas->context->SetTarget(nullptr);
    if (canvas->swapChain) {
        HRESULT hr = canvas->swapChain->ResizeBuffers(0, pixelWidth, pixelHeight, DXGI_FORMAT_UNKNOWN, 0);
        if (FAILED(hr)) return hr;
    }
    return canvas->bindTarget();
}

void ndc_adapter_info(NDAdapterInfo *out) {
    *out = {};
    if (FAILED(ensureDevice())) return;
    Shared &s = shared();
    Ref<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc = {};
    if (SUCCEEDED(s.dxgi->GetAdapter(adapter.Put())) && SUCCEEDED(adapter->GetDesc(&desc))) {
        out->vendorID = desc.VendorId;
        for (int i = 0; i < 127 && desc.Description[i]; ++i) out->description[i] = desc.Description[i];
    }
    out->isSoftware = s.isSoftware ? 1 : 0;
}

int32_t ndc_canvas_begin(NDCanvas *canvas, NDColor clear) {
    if (!canvas->target) return E_FAIL;
    canvas->context->BeginDraw();
    canvas->context->SetTransform(D2D1::Matrix3x2F::Identity());
    if (clear.a >= 0) canvas->context->Clear(color(clear));
    canvas->clipDepth = 0;
    return S_OK;
}

int32_t ndc_canvas_end(NDCanvas *canvas, int32_t present) {
    while (canvas->clipDepth > 0) ndc_pop_clip(canvas);
    HRESULT hr = canvas->context->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        resetShared();
        return NDDeviceLost;
    }
    if (FAILED(hr)) return hr;
    if (canvas->swapChain && present != NDPresentNone) {
        hr = canvas->swapChain->Present(present == NDPresentVSync ? 1 : 0, 0);
        if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
            resetShared();
            return NDDeviceLost;
        }
        if (hr == DXGI_STATUS_OCCLUDED) hr = S_OK;
    }
    return hr;
}

void ndc_canvas_finish(NDCanvas *) {
    Shared &s = shared();
    if (!s.d3d) return;
    D3D11_QUERY_DESC desc = {D3D11_QUERY_EVENT, 0};
    Ref<ID3D11Query> query;
    if (FAILED(s.d3d->CreateQuery(&desc, query.Put()))) return;
    s.d3dContext->End(query.Get());
    BOOL done = FALSE;
    while (s.d3dContext->GetData(query.Get(), &done, sizeof(done), 0) == S_FALSE) {
        YieldProcessor();
    }
}

int32_t ndc_canvas_save_png(NDCanvas *canvas, const uint16_t *path) {
    if (!canvas->target) return E_FAIL;
    ComScope com;
    HRESULT hr;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), canvas->dpi, canvas->dpi);
    Ref<ID2D1Bitmap1> readback;
    if (FAILED(hr = canvas->context->CreateBitmap(D2D1::SizeU(canvas->width, canvas->height), nullptr, 0, &props,
                                                  readback.Put())))
        return hr;
    if (FAILED(hr = readback->CopyFromBitmap(nullptr, canvas->target.Get(), nullptr))) return hr;
    D2D1_MAPPED_RECT mapped = {};
    if (FAILED(hr = readback->Map(D2D1_MAP_OPTIONS_READ, &mapped))) return hr;

    Ref<IWICImagingFactory> wic;
    Ref<IWICStream> stream;
    Ref<IWICBitmapEncoder> encoder;
    Ref<IWICBitmapFrameEncode> frame;
    hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.Put()));
    if (SUCCEEDED(hr)) hr = wic->CreateStream(stream.Put());
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(reinterpret_cast<const wchar_t *>(path), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.Put());
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(frame.Put(), nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->SetSize(canvas->width, canvas->height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) {
        // The canvas is opaque by the end of a frame, so premultiplied and straight bytes agree.
        hr = frame->WritePixels(canvas->height, mapped.pitch, mapped.pitch * canvas->height, mapped.bits);
    }
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    readback->Unmap();
    return hr;
}

void ndc_draw_image(NDCanvas *canvas, NDImage *image, NDRect dest, float opacity, int32_t sampling) {
    if (!image || !image->bitmap) return;
    if (sampling == NDImageOpaque) canvas->context->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_COPY);
    canvas->context->DrawBitmap(image->bitmap.Get(), rectF(dest), opacity,
                                sampling == NDImageSmooth ? D2D1_INTERPOLATION_MODE_LINEAR
                                                          : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
                                nullptr, nullptr);
    if (sampling == NDImageOpaque) canvas->context->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
}

void ndc_fill_rect(NDCanvas *canvas, NDRect rect, NDColor c) {
    canvas->brush->SetColor(color(c));
    canvas->context->FillRectangle(rectF(rect), canvas->brush.Get());
}

void ndc_stroke_rect(NDCanvas *canvas, NDRect rect, float width, NDColor c) {
    if (rect.width <= width || rect.height <= width) {
        ndc_fill_rect(canvas, rect, c);
        return;
    }
    canvas->brush->SetColor(color(c));
    float inset = width / 2;
    canvas->context->DrawRectangle(
        D2D1::RectF(rect.x + inset, rect.y + inset, rect.x + rect.width - inset, rect.y + rect.height - inset),
        canvas->brush.Get(), width);
}

void ndc_push_clip(NDCanvas *canvas, NDRect rect) {
    canvas->context->PushAxisAlignedClip(rectF(rect), D2D1_ANTIALIAS_MODE_ALIASED);
    canvas->clipDepth += 1;
}

void ndc_pop_clip(NDCanvas *canvas) {
    if (canvas->clipDepth <= 0) return;
    canvas->context->PopAxisAlignedClip();
    canvas->clipDepth -= 1;
}

void ndc_draw_text(NDCanvas *canvas, NDText *text, float x, float y, NDColor c) {
    if (!text || !text->layout) return;
    canvas->brush->SetColor(color(c));
    canvas->context->DrawTextLayout(D2D1::Point2F(x, y), text->layout.Get(), canvas->brush.Get(),
                                    D2D1_DRAW_TEXT_OPTIONS_NONE);
}

void ndc_draw_arcs(NDCanvas *canvas, float cx, float cy, const NDArc *arcs, uint32_t count, const float *opacities,
                   NDColor separator, float separatorWidth) {
    paintArcs(canvas->context.Get(), shared().factory.Get(), cx, cy, arcs, count, opacities, separator,
              separatorWidth);
}

void ndc_draw_arc_overlay(NDCanvas *canvas, float cx, float cy, NDArc arc, NDColor stroke, float width) {
    Ref<ID2D1PathGeometry> path;
    if (FAILED(buildArc(shared().factory.Get(), cx, cy, arc, path.Put()))) return;
    if (arc.fill.a > 0) {
        canvas->brush->SetColor(color(arc.fill));
        canvas->context->FillGeometry(path.Get(), canvas->brush.Get());
    }
    canvas->brush->SetColor(color(stroke));
    canvas->context->DrawGeometry(path.Get(), canvas->brush.Get(), width);
}

NDImage *ndc_image_create(NDCanvas *canvas, const void *pixels, uint32_t width, uint32_t height, uint32_t stride,
                          int32_t isBGRA) {
    if (!width || !height) return nullptr;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(isBGRA ? DXGI_FORMAT_B8G8R8A8_UNORM : DXGI_FORMAT_R8G8B8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED),
        canvas->dpi, canvas->dpi);
    NDImage *image = new (std::nothrow) NDImage();
    if (!image) return nullptr;
    if (FAILED(canvas->context->CreateBitmap(D2D1::SizeU(width, height), pixels, stride, &props,
                                             image->bitmap.Put()))) {
        delete image;
        return nullptr;
    }
    return image;
}

void ndc_image_release(NDImage *image) { delete image; }

NDImage *ndc_image_render_texts(NDCanvas *canvas, uint32_t pixelWidth, uint32_t pixelHeight, NDText *const *texts,
                                const float *origins, uint32_t count, NDColor textColor, float haloRadius,
                                NDColor haloColor) {
    if (!pixelWidth || !pixelHeight) return nullptr;
    ID2D1DeviceContext *context = canvas->context.Get();
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        canvas->dpi, canvas->dpi);
    Ref<ID2D1Bitmap1> glyphs;
    if (FAILED(context->CreateBitmap(D2D1::SizeU(pixelWidth, pixelHeight), nullptr, 0, &props, glyphs.Put())))
        return nullptr;

    Ref<ID2D1Image> previous;
    context->GetTarget(previous.Put());
    context->SetTarget(glyphs.Get());
    context->BeginDraw();
    context->SetTransform(D2D1::Matrix3x2F::Identity());
    context->Clear(D2D1::ColorF(0, 0, 0, 0));
    // A transparent target can't take ClearType's per-channel coverage.
    context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    canvas->brush->SetColor(color(textColor));
    for (uint32_t i = 0; i < count; ++i) {
        if (!texts[i] || !texts[i]->layout) continue;
        context->DrawTextLayout(D2D1::Point2F(origins[2 * i], origins[2 * i + 1]), texts[i]->layout.Get(),
                                canvas->brush.Get(), D2D1_DRAW_TEXT_OPTIONS_NONE);
    }
    HRESULT hr = context->EndDraw();
    context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_DEFAULT);

    Ref<ID2D1Bitmap1> result = glyphs;
    if (SUCCEEDED(hr) && haloRadius > 0) {
        Ref<ID2D1Effect> shadow;
        Ref<ID2D1Bitmap1> composed;
        if (SUCCEEDED(context->CreateEffect(CLSID_D2D1Shadow, shadow.Put())) &&
            SUCCEEDED(context->CreateBitmap(D2D1::SizeU(pixelWidth, pixelHeight), nullptr, 0, &props,
                                            composed.Put()))) {
            shadow->SetInput(0, glyphs.Get());
            shadow->SetValue(D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION, haloRadius / 2);
            shadow->SetValue(D2D1_SHADOW_PROP_COLOR, D2D1::Vector4F(haloColor.r, haloColor.g, haloColor.b, haloColor.a));
            context->SetTarget(composed.Get());
            context->BeginDraw();
            context->SetTransform(D2D1::Matrix3x2F::Identity());
            context->Clear(D2D1::ColorF(0, 0, 0, 0));
            context->DrawImage(shadow.Get());
            // The halo is faint at radius 2; a second pass gets it close to a hard outline's legibility.
            context->DrawImage(shadow.Get());
            context->DrawBitmap(glyphs.Get());
            if (SUCCEEDED(context->EndDraw())) result = composed;
        }
    }
    context->SetTarget(previous.Get());
    if (FAILED(hr)) return nullptr;
    NDImage *image = new (std::nothrow) NDImage();
    if (!image) return nullptr;
    image->bitmap = result;
    return image;
}

NDText *ndc_text_create(const uint16_t *utf16, uint32_t length, float fontSize, int32_t bold, float maxWidth,
                        int32_t alignment) {
    IDWriteTextFormat *format = textFormat(fontSize, bold != 0);
    if (!format) return nullptr;
    NDText *text = new (std::nothrow) NDText();
    if (!text) return nullptr;
    const wchar_t *chars = reinterpret_cast<const wchar_t *>(utf16);
    HRESULT hr = shared().dwrite->CreateTextLayout(chars, length, format, maxWidth > 0 ? maxWidth : 100000.0f,
                                                   100000.0f, text->layout.Put());
    if (FAILED(hr)) {
        delete text;
        return nullptr;
    }
    DWRITE_TEXT_METRICS metrics = {};
    text->layout->GetMetrics(&metrics);
    text->naturalWidth = metrics.widthIncludingTrailingWhitespace;
    if (maxWidth > 0) {
        if (text->naturalWidth > maxWidth) {
            Ref<IDWriteInlineObject> ellipsis;
            if (SUCCEEDED(shared().dwrite->CreateEllipsisTrimmingSign(format, ellipsis.Put()))) {
                DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
                text->layout->SetTrimming(&trimming, ellipsis.Get());
            }
        }
        text->layout->SetTextAlignment(alignment == 1   ? DWRITE_TEXT_ALIGNMENT_CENTER
                                       : alignment == 2 ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                                        : DWRITE_TEXT_ALIGNMENT_LEADING);
        text->layout->GetMetrics(&metrics);
        text->width = metrics.width < maxWidth ? metrics.width : maxWidth;
    } else {
        text->width = metrics.widthIncludingTrailingWhitespace;
        text->layout->SetMaxWidth(text->width + 1);
        if (alignment == 1) text->layout->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    }
    text->height = metrics.height;
    return text;
}

void ndc_text_release(NDText *text) { delete text; }

void ndc_text_metrics(NDText *text, float *width, float *height, float *naturalWidth) {
    if (width) *width = text->width;
    if (height) *height = text->height;
    if (naturalWidth) *naturalWidth = text->naturalWidth;
}

float ndc_text_measure(const uint16_t *utf16, uint32_t length, float fontSize, int32_t bold) {
    IDWriteTextFormat *format = textFormat(fontSize, bold != 0);
    if (!format) return 0;
    Ref<IDWriteTextLayout> layout;
    if (FAILED(shared().dwrite->CreateTextLayout(reinterpret_cast<const wchar_t *>(utf16), length, format, 100000.0f,
                                                 100000.0f, layout.Put())))
        return 0;
    DWRITE_TEXT_METRICS metrics = {};
    layout->GetMetrics(&metrics);
    return metrics.widthIncludingTrailingWhitespace;
}

int32_t ndc_rasterize_arcs(uint32_t pixelWidth, uint32_t pixelHeight, float scale, float cx, float cy,
                           const NDArc *arcs, uint32_t count, NDColor separator, float separatorWidth,
                           NDColor background, void *pixels, uint32_t stride) {
    ComScope com;
    HRESULT hr;
    Ref<ID2D1Factory> factory;
    D2D1_FACTORY_OPTIONS options = {};
    if (FAILED(hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), &options,
                                      reinterpret_cast<void **>(factory.Put()))))
        return hr;
    Ref<IWICImagingFactory> wic;
    if (FAILED(hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                     IID_PPV_ARGS(wic.Put()))))
        return hr;
    Ref<IWICBitmap> bitmap;
    if (FAILED(hr = wic->CreateBitmap(pixelWidth, pixelHeight, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad,
                                      bitmap.Put())))
        return hr;
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f * scale, 96.0f * scale);
    Ref<ID2D1RenderTarget> target;
    if (FAILED(hr = factory->CreateWicBitmapRenderTarget(bitmap.Get(), &props, target.Put()))) return hr;
    target->BeginDraw();
    target->Clear(color(background));
    paintArcs(target.Get(), factory.Get(), cx, cy, arcs, count, nullptr, separator, separatorWidth);
    if (FAILED(hr = target->EndDraw())) return hr;
    WICRect rect = {0, 0, static_cast<INT>(pixelWidth), static_cast<INT>(pixelHeight)};
    return bitmap->CopyPixels(&rect, stride, stride * pixelHeight, static_cast<BYTE *>(pixels));
}

} // extern "C"
