#pragma once
#include <algorithm>
#include <cmath>
#include <memory>
#include <gdiplus.h>

namespace weasel {
// Cache each scaled tile separately: typing can change the window width without
// resampling the large portrait in its fixed corner again.
class NineSliceTileCache {
 public:
  void Reset() {
    for (auto& tile : tiles_) tile.bitmap.reset();
    decoded_.reset();
    source_ = nullptr;
  }
  Gdiplus::Bitmap* Get(int index, Gdiplus::Bitmap& source,
                       int x, int y, int width, int height,
                       int targetWidth, int targetHeight) {
    auto& tile = tiles_[index];
    Gdiplus::Rect sourceRect(x, y, width, height);
    if (tile.bitmap && tile.source == &source &&
        tile.rect.Equals(sourceRect) &&
        tile.bitmap->GetWidth() == targetWidth &&
        tile.bitmap->GetHeight() == targetHeight)
      return tile.bitmap.get();
    // GDI+ otherwise repeatedly converts a PNG-backed image for each tile.
    if (source_ != &source) {
      decoded_.reset(source.Clone(0, 0, static_cast<int>(source.GetWidth()),
                                  static_cast<int>(source.GetHeight()),
                                  PixelFormat32bppPARGB));
      if (!decoded_ || decoded_->GetLastStatus() != Gdiplus::Ok) {
        decoded_.reset();
        return nullptr;
      }
      source_ = &source;
    }
    tile.source = nullptr;
    tile.bitmap.reset(new Gdiplus::Bitmap(targetWidth, targetHeight,
                                         PixelFormat32bppPARGB));
    if (tile.bitmap->GetLastStatus() != Gdiplus::Ok) {
      tile.bitmap.reset();
      return nullptr;
    }
    Gdiplus::Graphics raster(tile.bitmap.get());
    raster.Clear(Gdiplus::Color(0, 0, 0, 0));
    raster.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    raster.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    Gdiplus::ImageAttributes attributes;
    attributes.SetWrapMode(Gdiplus::WrapModeTileFlipXY);
    if (raster.DrawImage(decoded_.get(), Gdiplus::Rect(0, 0, targetWidth, targetHeight),
                         x, y, width, height, Gdiplus::UnitPixel,
                         &attributes) != Gdiplus::Ok) {
      // Dispose Graphics before its bitmap.
      return nullptr;
    }
    tile.source = &source;
    tile.rect = sourceRect;
    return tile.bitmap.get();
  }
 private:
  std::unique_ptr<Gdiplus::Bitmap> decoded_;
  Gdiplus::Bitmap* source_ = nullptr;
  struct Tile {
    std::unique_ptr<Gdiplus::Bitmap> bitmap;
    Gdiplus::Bitmap* source = nullptr;
    Gdiplus::Rect rect;
  } tiles_[9];
};

// Shared source/destination boundaries prevent rounding gaps between tiles.
inline bool DrawNineSlice(Gdiplus::Graphics& graphics,
                          Gdiplus::Bitmap& bitmap,
                          const Gdiplus::Rect& target,
                          int left, int top, int right, int bottom,
                          float scale, NineSliceTileCache* cache = nullptr) {
  const int width = bitmap.GetWidth(), height = bitmap.GetHeight();
  if (bitmap.GetLastStatus() != Gdiplus::Ok || width <= 0 || height <= 0 ||
      left < 0 || top < 0 || right < 0 || bottom < 0 ||
      left >= width || right >= width - left ||
      top >= height || bottom >= height - top ||
      !std::isfinite(scale) || scale <= 0 ||
      target.Width <= 0 || target.Height <= 0)
    return false;
  // Small notification windows shrink all corners uniformly instead of overlap.
  float actual = scale;
  if (left + right > 0)
    actual = (std::min)(actual, float(target.Width) / (left + right));
  if (top + bottom > 0)
    actual = (std::min)(actual, float(target.Height) / (top + bottom));
  const int sx[] = {0, left, width - right, width};
  const int sy[] = {0, top, height - bottom, height};
  const int dx[] = {target.X, target.X + int(std::lround(left * actual)),
                    target.GetRight() - int(std::lround(right * actual)),
                    target.GetRight()};
  const int dy[] = {target.Y, target.Y + int(std::lround(top * actual)),
                    target.GetBottom() - int(std::lround(bottom * actual)),
                    target.GetBottom()};
  Gdiplus::ImageAttributes attributes;
  attributes.SetWrapMode(Gdiplus::WrapModeTileFlipXY);
  auto saved = graphics.Save();
  graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
  bool ok = true;
  if (cache && static_cast<long long>(target.Width) * target.Height > 4 * 1024 * 1024) {
    cache->Reset();
    cache = nullptr;
  }
  for (int y = 0; y < 3; ++y) {
    for (int x = 0; x < 3; ++x) {
      Gdiplus::Rect dest(dx[x], dy[y], dx[x + 1] - dx[x], dy[y + 1] - dy[y]);
      if (dest.Width <= 0 || dest.Height <= 0 ||
          sx[x + 1] == sx[x] || sy[y + 1] == sy[y])
        continue;
      Gdiplus::Bitmap* tile = cache ? cache->Get(y * 3 + x, bitmap,
          sx[x], sy[y], sx[x + 1] - sx[x], sy[y + 1] - sy[y],
          dest.Width, dest.Height) : nullptr;
      if (tile) {
        graphics.SetInterpolationMode(Gdiplus::InterpolationModeNearestNeighbor);
        ok &= graphics.DrawImage(tile, dest, 0, 0, dest.Width, dest.Height,
                                  Gdiplus::UnitPixel) == Gdiplus::Ok;
      } else {
        graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
        ok &= graphics.DrawImage(&bitmap, dest, sx[x], sy[y],
                                sx[x + 1] - sx[x], sy[y + 1] - sy[y],
                                Gdiplus::UnitPixel, &attributes) == Gdiplus::Ok;
      }
    }
  }
  graphics.Restore(saved);
  return ok;
}
}  // namespace weasel
