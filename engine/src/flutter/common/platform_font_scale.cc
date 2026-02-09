// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/common/platform_font_scale.h"

#include <atomic>

namespace flutter {

namespace {
// Atomic double for thread-safe access from UI and platform threads.
std::atomic<double> g_platform_font_scale{1.0};
}  // namespace

void SetPlatformFontScale(double scale) {
  g_platform_font_scale.store(scale, std::memory_order_relaxed);
}

double GetPlatformFontScale() {
  return g_platform_font_scale.load(std::memory_order_relaxed);
}

}  // namespace flutter
