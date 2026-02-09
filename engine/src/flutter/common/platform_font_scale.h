// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_COMMON_PLATFORM_FONT_SCALE_H_
#define FLUTTER_COMMON_PLATFORM_FONT_SCALE_H_

namespace flutter {

/// Sets a platform-specific font scale factor applied to all font sizes in the
/// text rendering pipeline.
///
/// On Linux, GTK/Pango interprets font sizes as typographic points
/// (1pt = DPI/72 pixels), while Flutter interprets them as logical pixels.
/// The embedder should call this with `screen_dpi / 72.0` so that
/// `fontSize: N` in Dart renders at the same visual size as `Npt` in native
/// toolkit apps.
///
/// Defaults to 1.0 (no scaling). Thread-safe.
void SetPlatformFontScale(double scale);

/// Returns the current platform font scale factor.
/// Thread-safe.
double GetPlatformFontScale();

}  // namespace flutter

#endif  // FLUTTER_COMMON_PLATFORM_FONT_SCALE_H_
