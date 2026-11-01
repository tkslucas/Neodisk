// Shared between the shim's own files only.

#pragma once

struct ID2D1Factory;
struct IDWriteFactory;
struct IWICImagingFactory;

ID2D1Factory *ndwD2DFactory();
IDWriteFactory *ndwDWriteFactory();
IWICImagingFactory *ndwWICFactory();
