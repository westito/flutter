// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert' show base64Decode;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:wide_gamut_test/main.dart' as app;

/// BGRA10_XR has ~0.002 step size, so 0.01 is needed for 10-bit formats.
const double _bgra10Epsilon = 0.01;

/// Epsilon for 8-bit formats.
const double _rgba8Epsilon = 0.02;

// See: https://developer.apple.com/documentation/metal/mtlpixelformat/mtlpixelformatbgr10_xr.
double _decodeBGR10(int x) {
  const max = 1.25098;
  const min = -0.752941;
  const intercept = min;
  const double slope = (max - min) / 1024.0;
  return (x * slope) + intercept;
}

bool _isAlmost(double x, double y, double epsilon) {
  return (x - y).abs() < epsilon;
}

double _distanceSquared(double r, double g, double b, List<double> color) {
  return (r - color[0]) * (r - color[0]) +
      (g - color[1]) * (g - color[1]) +
      (b - color[2]) * (b - color[2]);
}

/// Display P3 deep red in extended sRGB (used by iOS/macOS BGRA10_XR format).
/// P3 (1, 0, 0) -> extended sRGB (1.0931, -0.2268, -0.1501)
List<double> _deepRed = <double>[1.0931, -0.2268, -0.1501];

/// Display P3 deep red in native P3 color space (used by Android).
/// When using native P3 color space, P3 red is simply (1, 0, 0).
List<double> _deepRedNativeP3 = <double>[1.0, 0.0, 0.0];

(bool, List<double>) _findBGRA10Color(
  Uint8List bytes,
  int width,
  int height,
  List<double> color, {
  required double epsilon,
}) {
  final byteData = ByteData.sublistView(bytes);
  expect(bytes.lengthInBytes, width * height * 8);
  expect(bytes.lengthInBytes, byteData.lengthInBytes);
  var foundColor = false;
  double minDistance = double.infinity;
  var closestColor = <double>[0, 0, 0];
  for (var i = 0; i < bytes.lengthInBytes; i += 8) {
    final int pixel = byteData.getUint64(i, Endian.host);
    final double blue = _decodeBGR10((pixel >> 6) & 0x3ff);
    final double green = _decodeBGR10((pixel >> 22) & 0x3ff);
    final double red = _decodeBGR10((pixel >> 38) & 0x3ff);
    if (_isAlmost(red, color[0], epsilon) &&
        _isAlmost(green, color[1], epsilon) &&
        _isAlmost(blue, color[2], epsilon)) {
      foundColor = true;
    }
    final double currentDistance = _distanceSquared(red, green, blue, color);
    if (currentDistance < minDistance) {
      minDistance = currentDistance;
      closestColor = <double>[red, green, blue];
    }
  }
  return (foundColor, closestColor);
}

/// Decode 8-bit RGBA format (VK_FORMAT_R8G8B8A8_UNORM).
/// In P3 native mode, colors are stored directly in P3 space.
(bool, List<double>) _findRGBA8Color(
  Uint8List bytes,
  int width,
  int height,
  List<double> color, {
  required double epsilon,
}) {
  expect(bytes.lengthInBytes, width * height * 4);
  var foundColor = false;
  double minDistance = double.infinity;
  var closestColor = <double>[0, 0, 0];
  for (var i = 0; i < bytes.lengthInBytes; i += 4) {
    final double red = bytes[i] / 255.0;
    final double green = bytes[i + 1] / 255.0;
    final double blue = bytes[i + 2] / 255.0;
    if (_isAlmost(red, color[0], epsilon) &&
        _isAlmost(green, color[1], epsilon) &&
        _isAlmost(blue, color[2], epsilon)) {
      foundColor = true;
    }
    final double currentDistance = _distanceSquared(red, green, blue, color);
    if (currentDistance < minDistance) {
      minDistance = currentDistance;
      closestColor = <double>[red, green, blue];
    }
  }
  return (foundColor, closestColor);
}

/// Decode 10-bit A2B10G10R10 format (VK_FORMAT_A2B10G10R10_UNORM_PACK32).
/// On Android Vulkan, this uses Display P3 color space with normalized [0,1] range.
(bool, List<double>) _findA2B10G10R10Color(
  Uint8List bytes,
  int width,
  int height,
  List<double> color, {
  required double epsilon,
}) {
  final byteData = ByteData.sublistView(bytes);
  expect(bytes.lengthInBytes, width * height * 4);
  var foundColor = false;
  double minDistance = double.infinity;
  var closestColor = <double>[0, 0, 0];
  for (var i = 0; i < bytes.lengthInBytes; i += 4) {
    final int pixel = byteData.getUint32(i, Endian.little);
    // A2B10G10R10 format: 2-bit alpha, 10-bit blue, 10-bit green, 10-bit red
    final double red = (pixel & 0x3ff) / 1023.0;
    final double green = ((pixel >> 10) & 0x3ff) / 1023.0;
    final double blue = ((pixel >> 20) & 0x3ff) / 1023.0;
    if (_isAlmost(red, color[0], epsilon) &&
        _isAlmost(green, color[1], epsilon) &&
        _isAlmost(blue, color[2], epsilon)) {
      foundColor = true;
    }
    final double currentDistance = _distanceSquared(red, green, blue, color);
    if (currentDistance < minDistance) {
      minDistance = currentDistance;
      closestColor = <double>[red, green, blue];
    }
  }
  return (foundColor, closestColor);
}

/// Returns the expected deep red color based on the pixel format.
/// iOS/macOS BGRA10_XR uses extended sRGB, Android uses native P3.
List<double> _getExpectedDeepRed(String format) {
  switch (format) {
    case 'MTLPixelFormatBGRA10_XR':
      // iOS/macOS uses extended sRGB where P3 red has values outside [0,1]
      return _deepRed;
    case 'VK_FORMAT_R8G8B8A8_UNORM':
    case 'VK_FORMAT_A2B10G10R10_UNORM_PACK32':
    case 'AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM':
    case 'AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM':
      // Android uses native P3 color space where P3 red is (1, 0, 0)
      return _deepRedNativeP3;
    default:
      return _deepRed;
  }
}

(bool, List<double>) _findColor(
  List<dynamic> result,
  List<double> color, {
  double? epsilon,
}) {
  expect(result, isNotNull);
  expect(result.length, 4);
  final [int width, int height, String format, Uint8List bytes] = result;

  switch (format) {
    case 'MTLPixelFormatBGRA10_XR':
      return _findBGRA10Color(
        bytes,
        width,
        height,
        color,
        epsilon: epsilon ?? _bgra10Epsilon,
      );
    case 'VK_FORMAT_R8G8B8A8_UNORM':
    case 'AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM':
      return _findRGBA8Color(
        bytes,
        width,
        height,
        color,
        epsilon: epsilon ?? _rgba8Epsilon,
      );
    case 'VK_FORMAT_A2B10G10R10_UNORM_PACK32':
    case 'AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM':
      return _findA2B10G10R10Color(
        bytes,
        width,
        height,
        color,
        epsilon: epsilon ?? _bgra10Epsilon,
      );
    default:
      throw UnsupportedError('Unsupported pixel format: $format');
  }
}

class _HasColor extends Matcher {
  const _HasColor(this.color, {this.epsilon});

  final List<double> color;
  final double? epsilon;

  @override
  bool matches(dynamic item, Map<dynamic, dynamic> matchState) {
    final (bool found, List<double> closest) = _findColor(
      item as List<dynamic>,
      color,
      epsilon: epsilon,
    );
    matchState['closest'] = closest;
    return found;
  }

  @override
  Description describe(Description description) {
    return description.add('contains color $color');
  }

  @override
  Description describeMismatch(
    dynamic item,
    Description mismatchDescription,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) {
    final closest = matchState['closest'] as List<double>?;
    if (closest == null) {
      return mismatchDescription.add(
        'could not find any colors (unsupported pixel format?)',
      );
    }
    return mismatchDescription.add('closest color to $color was $closest');
  }
}

/// A matcher that looks for Display P3 deep red, automatically adjusting
/// the expected color value based on the pixel format (extended sRGB for
/// iOS/macOS, native P3 for Android).
class _HasDeepRed extends Matcher {
  const _HasDeepRed({this.epsilon});

  final double? epsilon;

  @override
  bool matches(dynamic item, Map<dynamic, dynamic> matchState) {
    final result = item as List<dynamic>;
    final String format = result[2] as String;
    final expectedColor = _getExpectedDeepRed(format);
    final (bool found, List<double> closest) = _findColor(
      result,
      expectedColor,
      epsilon: epsilon,
    );
    matchState['closest'] = closest;
    matchState['expected'] = expectedColor;
    matchState['format'] = format;
    return found;
  }

  @override
  Description describe(Description description) {
    return description.add('contains Display P3 deep red');
  }

  @override
  Description describeMismatch(
    dynamic item,
    Description mismatchDescription,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) {
    final closest = matchState['closest'] as List<double>?;
    final expected = matchState['expected'] as List<double>?;
    final format = matchState['format'] as String?;
    if (closest == null) {
      return mismatchDescription.add(
        'could not find any colors (unsupported pixel format?)',
      );
    }
    return mismatchDescription.add(
      'closest color to P3 red $expected was $closest (format: $format)',
    );
  }
}

/// Precache the Display P3 test image so it is fully decoded before we take a
/// screenshot. Must be called after [pumpAndSettle] so a [BuildContext] exists.
Future<void> _precacheP3Image(WidgetTester tester) async {
  final BuildContext context = tester.element(find.byType(app.MyApp));
  await tester.runAsync(
    () => precacheImage(MemoryImage(base64Decode(app.displayP3Logo)), context),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('end-to-end test', () {
    const screenshotChannel = MethodChannel('flutter/screenshot');

    testWidgets('look for display p3 deepest red', (WidgetTester tester) async {
      app.run(app.Setup.image);
      await tester.pumpAndSettle();
      await _precacheP3Image(tester);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed());
    });

    testWidgets('look for display p3 deepest red (saveLayer)', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.canvasSaveLayer);
      await tester.pumpAndSettle();
      await _precacheP3Image(tester);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed());
    });

    testWidgets('p3 deepest red via codec API (ImageDescriptor)', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.codecImage);
      await tester.pumpAndSettle();
      // Wait for async _loadCodecImage() to complete and rebuild
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed());
    });

    testWidgets('no p3 deepest red without image', (WidgetTester tester) async {
      app.run(app.Setup.none);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, isNot(const _HasDeepRed()));
      expect(result, isNot(const _HasColor(<double>[0.0, 1.0, 0.0])));
    });

    testWidgets('p3 deepest red with blur', (WidgetTester tester) async {
      app.run(app.Setup.blur);
      await tester.pumpAndSettle();
      await _precacheP3Image(tester);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed());
      expect(result, const _HasColor(<double>[0.0, 1.0, 0.0]));
    });

    testWidgets('draw image with wide gamut works', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.drawnImage);
      await tester.pumpAndSettle();
      // Wait for async _drawImage() to complete and rebuild
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasColor(<double>[0.0, 1.0, 0.0]));
    });

    testWidgets('draw container with wide gamut works', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.container);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed());
    });

    testWidgets('draw wide gamut linear gradient works', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.linearGradient);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;

      // Gradients need larger epsilon due to pixel sampling between gradient stops.
      expect(result, const _HasDeepRed(epsilon: 0.02));
    });

    testWidgets('draw wide gamut radial gradient works', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.radialGradient);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed(epsilon: 0.05));
    });

    testWidgets('draw wide gamut conical gradient works', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.conicalGradient);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      expect(result, const _HasDeepRed(epsilon: 0.05));
    });

    testWidgets('draw wide gamut sweep gradient works', (
      WidgetTester tester,
    ) async {
      app.run(app.Setup.sweepGradient);
      await tester.pumpAndSettle();

      final result =
          await screenshotChannel.invokeMethod('test') as List<Object?>;
      // Sweep gradient endpoint may not be sampled exactly at a pixel center.
      expect(result, const _HasDeepRed(epsilon: 0.02));
    });
  });
}
