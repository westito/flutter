// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/linux/fl_display_monitor.h"
#include "flutter/common/platform_font_scale.h"
#include "flutter/shell/platform/linux/fl_engine_private.h"

struct _FlDisplayMonitor {
  GObject parent_instance;

  // Engine being updated.
  GWeakRef engine;

  // Display being monitored.
  GdkDisplay* display;

  // Mapping of GdkMonitor to display IDs.
  GHashTable* display_ids_by_monitor;

  // Next ID to assign to a new monitor.
  FlutterEngineDisplayId next_display_id;
};

G_DEFINE_TYPE(FlDisplayMonitor, fl_display_monitor, G_TYPE_OBJECT)

// Points per inch — fixed typographic constant.
static constexpr gdouble kPointsPerInch = 72.0;

// Default screen DPI on Linux when GDK reports -1 (unset).
static constexpr gdouble kDefaultDpi = 96.0;

// Set a fixed platform font scale to convert typographic points to logical
// pixels: 1pt = 1/72 inch, 1 logical pixel = 1/96 inch, so the constant
// scale is 96/72.  The user's text-scaling-factor preference is handled
// separately by the Flutter framework via textScaleFactor from the
// flutter/settings channel, so we intentionally do NOT fold
// gdk_screen_get_resolution() into this value (that would double-scale).
static void set_fixed_font_scale() {
  flutter::SetPlatformFontScale(kDefaultDpi / kPointsPerInch);
}

// Send the current monitor state to the engine.
static void notify_display_update(FlDisplayMonitor* self) {
  g_autoptr(FlEngine) engine = FL_ENGINE(g_weak_ref_get(&self->engine));
  if (engine == nullptr) {
    return;
  }

  int n_monitors = gdk_display_get_n_monitors(self->display);
  g_autofree FlutterEngineDisplay* displays =
      g_new0(FlutterEngineDisplay, n_monitors);
  for (int i = 0; i < n_monitors; i++) {
    FlutterEngineDisplay* display = &displays[i];

    GdkMonitor* monitor = gdk_display_get_monitor(self->display, i);
    FlutterEngineDisplayId display_id = GPOINTER_TO_INT(
        g_hash_table_lookup(self->display_ids_by_monitor, monitor));
    if (display_id == 0) {
      display_id = self->next_display_id;
      g_hash_table_insert(self->display_ids_by_monitor, g_object_ref(monitor),
                          GINT_TO_POINTER(display_id));
      self->next_display_id++;
    }

    GdkRectangle geometry;
    gdk_monitor_get_geometry(monitor, &geometry);

    display->struct_size = sizeof(FlutterEngineDisplay);
    display->display_id = display_id;
    display->single_display = false;
    display->refresh_rate = gdk_monitor_get_refresh_rate(monitor) / 1000.0;
    display->width = geometry.width;
    display->height = geometry.height;
    display->device_pixel_ratio = gdk_monitor_get_scale_factor(monitor);
  }

  fl_engine_notify_display_update(engine, displays, n_monitors);
}

static void monitor_added_cb(FlDisplayMonitor* self, GdkMonitor* monitor) {
  notify_display_update(self);
}

static void monitor_removed_cb(FlDisplayMonitor* self, GdkMonitor* monitor) {
  g_hash_table_remove(self->display_ids_by_monitor, monitor);
  notify_display_update(self);
}

static void fl_display_monitor_dispose(GObject* object) {
  FlDisplayMonitor* self = FL_DISPLAY_MONITOR(object);

  g_weak_ref_clear(&self->engine);
  g_clear_object(&self->display);
  g_clear_pointer(&self->display_ids_by_monitor, g_hash_table_unref);

  G_OBJECT_CLASS(fl_display_monitor_parent_class)->dispose(object);
}

static void fl_display_monitor_class_init(FlDisplayMonitorClass* klass) {
  GObjectClass* object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = fl_display_monitor_dispose;
}

static void fl_display_monitor_init(FlDisplayMonitor* self) {
  self->display_ids_by_monitor = g_hash_table_new_full(
      g_direct_hash, g_direct_equal, g_object_unref, nullptr);
  self->next_display_id = 1;
}

FlDisplayMonitor* fl_display_monitor_new(FlEngine* engine,
                                         GdkDisplay* display) {
  FlDisplayMonitor* self =
      FL_DISPLAY_MONITOR(g_object_new(fl_display_monitor_get_type(), nullptr));
  g_weak_ref_init(&self->engine, engine);
  self->display = GDK_DISPLAY(g_object_ref(display));
  return self;
}

void fl_display_monitor_start(FlDisplayMonitor* self) {
  g_return_if_fail(FL_IS_DISPLAY_MONITOR(self));

  g_signal_connect_object(self->display, "monitor-added",
                          G_CALLBACK(monitor_added_cb), self,
                          G_CONNECT_SWAPPED);
  g_signal_connect_object(self->display, "monitor-removed",
                          G_CALLBACK(monitor_removed_cb), self,
                          G_CONNECT_SWAPPED);

  // Convert typographic points to logical pixels (fixed 96/72 ratio).
  set_fixed_font_scale();

  notify_display_update(self);
}

FlutterEngineDisplayId fl_display_monitor_get_display_id(FlDisplayMonitor* self,
                                                         GdkMonitor* monitor) {
  g_return_val_if_fail(FL_IS_DISPLAY_MONITOR(self), 0);
  return GPOINTER_TO_INT(
      g_hash_table_lookup(self->display_ids_by_monitor, monitor));
}
