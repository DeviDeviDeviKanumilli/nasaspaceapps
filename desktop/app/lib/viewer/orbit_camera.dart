// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:math' as math;

/// 3-vector helpers on plain doubles (no package needed).
class V3 {
  const V3(this.x, this.y, this.z);
  final double x, y, z;
  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double s) => V3(x * s, y * s, z * s);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  V3 cross(V3 o) => V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  V3 normalized() {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  @override
  String toString() => '(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

/// Maps a scan's coordinate frame into the viewer's display frame (+Y up, camera looking toward -Z).
///
/// camera_optical_m (+X right, +Y down, +Z forward): display = (x, -y, -z), i.e. a 180° rotation about X,
/// so the scene appears upright as seen from the sensor. arkit_session_world is already +Y up (gravity).
class FrameMapping {
  const FrameMapping(this.frameName, this.flipYZ);
  final String frameName;
  final bool flipYZ;

  factory FrameMapping.forFrame(String? name) => FrameMapping(name ?? 'unknown', name == 'camera_optical_m');

  V3 toDisplay(double x, double y, double z) => flipYZ ? V3(x, -y, -z) : V3(x, y, z);
  V3 fromDisplay(V3 p) => flipYZ ? V3(p.x, -p.y, -p.z) : p;

  String get legend => flipYZ
      ? 'Frame camera_optical_m (+X right, +Y down, +Z forward). Shown rotated 180° about X so the scene looks upright; view starts at the sensor.'
      : (frameName == 'arkit_session_world'
            ? 'Frame arkit_session_world (+Y up along measured gravity). Local to the capture session.'
            : 'Frame $frameName (axes as stored in the file).');
}

/// Orbit camera around a target point, perspective projection to screen pixels.
class OrbitCamera {
  OrbitCamera({this.yaw = 0, this.pitch = 0, this.distance = 1, this.target = const V3(0, 0, 0), this.fovYDeg = 50});

  double yaw; // radians, about display +Y
  double pitch; // radians, positive looks down from above
  double distance; // metres from target
  V3 target;
  double fovYDeg;
  static const near = 0.01;

  V3 get eye {
    final cp = math.cos(pitch);
    return target + V3(cp * math.sin(yaw), math.sin(pitch), cp * math.cos(yaw)) * distance;
  }

  /// Orthonormal camera basis: right, up, forward (forward points from the eye toward the target).
  (V3, V3, V3) basis() {
    final f = (target - eye).normalized();
    var r = f.cross(const V3(0, 1, 0));
    if (r.length < 1e-9) r = const V3(1, 0, 0);
    r = r.normalized();
    final u = r.cross(f).normalized();
    return (r, u, f);
  }

  double focalPx(double viewportHeight) => (viewportHeight / 2) / math.tan(fovYDeg * math.pi / 360);

  /// Project a display-frame point. Returns null when behind the near plane. (sx, sy, depthAlongForward).
  (double, double, double)? project(V3 p, double w, double h) {
    final (r, u, f) = basis();
    final d = p - eye;
    final zf = d.dot(f);
    if (zf < near) return null;
    final fp = focalPx(h);
    return (w / 2 + fp * d.dot(r) / zf, h / 2 - fp * d.dot(u) / zf, zf);
  }

  void orbit(double dxPx, double dyPx) {
    yaw -= dxPx * 0.008;
    pitch = (pitch + dyPx * 0.008).clamp(-1.55, 1.55);
  }

  void pan(double dxPx, double dyPx, double viewportHeight) {
    final (r, u, _) = basis();
    final scale = distance / focalPx(viewportHeight);
    target = target - r * (dxPx * scale) + u * (dyPx * scale);
  }

  void zoom(double factor) {
    distance = (distance * factor).clamp(0.02, 500.0);
  }
}
