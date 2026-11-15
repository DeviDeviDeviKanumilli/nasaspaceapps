// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:math' as math;

import 'package:field_station/viewer/orbit_camera.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('optical frame maps to display upright (Y down -> up, Z forward -> -Z)', () {
    final m = FrameMapping.forFrame('camera_optical_m');
    final d = m.toDisplay(0.1, 0.2, 1.5);
    expect(d.x, 0.1);
    expect(d.y, -0.2);
    expect(d.z, -1.5);
    final back = m.fromDisplay(d);
    expect(back.y, closeTo(0.2, 1e-12));
    expect(FrameMapping.forFrame('arkit_session_world').flipYZ, isFalse);
  });

  test('camera at the sensor sees the target at the image centre', () {
    final m = FrameMapping.forFrame('camera_optical_m');
    final target = m.toDisplay(0, 0, 2);
    final cam = OrbitCamera(target: target, distance: 2);
    expect(cam.eye.length, closeTo(0, 1e-9));
    final p = cam.project(target, 800, 600)!;
    expect(p.$1, closeTo(400, 1e-9));
    expect(p.$2, closeTo(300, 1e-9));
    expect(p.$3, closeTo(2, 1e-9));
  });

  test('pinhole projection matches focal length; up in the scene is up on screen', () {
    final m = FrameMapping.forFrame('camera_optical_m');
    final cam = OrbitCamera(target: m.toDisplay(0, 0, 2), distance: 2, fovYDeg: 60);
    final f = cam.focalPx(600);
    expect(f, closeTo(300 / math.tan(math.pi / 6), 1e-9));
    // optical +X right at Z=2, 0.5 m -> right of centre by f*0.25
    final right = cam.project(m.toDisplay(0.5, 0, 2), 800, 600)!;
    expect(right.$1, closeTo(400 + f * 0.25, 1e-6));
    // optical -Y is up in the world seen by the camera -> above centre (smaller sy)
    final up = cam.project(m.toDisplay(0, -0.5, 2), 800, 600)!;
    expect(up.$2, closeTo(300 - f * 0.25, 1e-6));
  });

  test('points behind the camera are culled; orbit keeps distance; pitch is clamped', () {
    final cam = OrbitCamera(target: const V3(0, 0, -2), distance: 2);
    expect(cam.project(const V3(0, 0, 1), 800, 600), isNull);
    cam.orbit(100, 50);
    expect((cam.eye - cam.target).length, closeTo(2, 1e-9));
    cam.orbit(0, 100000);
    expect(cam.pitch, lessThanOrEqualTo(1.55));
    cam.zoom(0.5);
    expect(cam.distance, closeTo(1, 1e-9));
  });

  test('pan moves the target in the view plane', () {
    final cam = OrbitCamera(target: const V3(0, 0, 0), distance: 2);
    final before = cam.project(const V3(0, 0, 0), 800, 600)!;
    cam.pan(10, 0, 600);
    final after = cam.project(const V3(0, 0, 0), 800, 600)!;
    expect(after.$1 - before.$1, closeTo(10, 1e-6));
  });
}
