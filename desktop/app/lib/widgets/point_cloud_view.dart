// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../service/models.dart';
import '../viewer/orbit_camera.dart';
import 'common.dart';
import 'figure.dart';

enum ColorMode { rgb, range, up }

/// Holds the cloud, camera and view options; repaints the painter when it changes.
class PointCloudController extends ChangeNotifier {
  CloudData? cloud;
  late FrameMapping mapping;
  final OrbitCamera cam = OrbitCamera();
  // display-frame copies of the points (x,y,z per point)
  Float32List _disp = Float32List(0);
  Int32List order = Int32List(0); // draw order (far -> near after a settled sort)
  ColorMode colorMode = ColorMode.rgb;
  double pointSize = 2.5;
  V3 centroid = const V3(0, 0, 0);
  double extent = 1; // 95th-percentile radius around the median: what the view frames
  double fullExtent = 1; // farthest point from the median
  double zMin = 0, zMax = 1, upMin = 0, upMax = 1;

  // ROI (in the scan's own frame)
  List<double>? roiCenter;
  double roiRadius = 0.10;
  Uint8List roiMask = Uint8List(0);
  int roiCount = 0;

  // last projection, for picking
  Float32List sx = Float32List(0), sy = Float32List(0), sz = Float32List(0);
  Size lastSize = Size.zero;
  bool interacting = false;
  Timer? _settle;

  // optional solid surface, drawn instead of the points (same frame, same camera)
  MeshData? mesh;
  Float32List meshDisp = Float32List(0); // display-frame vertices
  Float32List triNormal = Float32List(0); // display-frame unit normal per triangle
  Float32List triUp = Float32List(0), triRange = Float32List(0); // per-triangle height (display up) and range
  Int32List triOrder = Int32List(0); // far -> near after a settled sort

  /// Show [m] as a shaded surface (or go back to points with null). Call after [setCloud]: it uses that frame.
  void setMesh(MeshData? m) {
    mesh = m;
    if (m == null) {
      meshDisp = Float32List(0);
      triNormal = Float32List(0);
      triUp = Float32List(0);
      triRange = Float32List(0);
      triOrder = Int32List(0);
      notifyListeners();
      return;
    }
    final nv = m.vertexCount, nt = m.triangleCount;
    meshDisp = Float32List(nv * 3);
    final rng = Float32List(nv);
    for (int i = 0; i < nv; i++) {
      final x = m.xyz[i * 3], y = m.xyz[i * 3 + 1], z = m.xyz[i * 3 + 2];
      final d = mapping.toDisplay(x, y, z);
      meshDisp[i * 3] = d.x;
      meshDisp[i * 3 + 1] = d.y;
      meshDisp[i * 3 + 2] = d.z;
      rng[i] = math.sqrt(x * x + y * y + z * z);
    }
    triNormal = Float32List(nt * 3);
    triUp = Float32List(nt);
    triRange = Float32List(nt);
    final t = m.tris, v = meshDisp;
    for (int k = 0; k < nt; k++) {
      final a = t[k * 3] * 3, b = t[k * 3 + 1] * 3, c = t[k * 3 + 2] * 3;
      final ux = v[b] - v[a], uy = v[b + 1] - v[a + 1], uz = v[b + 2] - v[a + 2];
      final wx = v[c] - v[a], wy = v[c + 1] - v[a + 1], wz = v[c + 2] - v[a + 2];
      var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l > 0) {
        nx /= l;
        ny /= l;
        nz /= l;
      }
      triNormal[k * 3] = nx;
      triNormal[k * 3 + 1] = ny;
      triNormal[k * 3 + 2] = nz;
      triUp[k] = (v[a + 1] + v[b + 1] + v[c + 1]) / 3;
      triRange[k] = (rng[t[k * 3]] + rng[t[k * 3 + 1]] + rng[t[k * 3 + 2]]) / 3;
    }
    triOrder = Int32List.fromList(List<int>.generate(nt, (i) => i));
    resetView();
    sortBackToFront();
  }

  void setCloud(CloudData c) {
    cloud = c;
    mapping = FrameMapping.forFrame(c.frame);
    final n = c.count;
    _disp = Float32List(n * 3);
    double zlo = double.infinity, zhi = -double.infinity, ulo = double.infinity, uhi = -double.infinity;
    for (int i = 0; i < n; i++) {
      final x = c.xyz[i * 3], y = c.xyz[i * 3 + 1], z = c.xyz[i * 3 + 2];
      final d = mapping.toDisplay(x, y, z);
      _disp[i * 3] = d.x;
      _disp[i * 3 + 1] = d.y;
      _disp[i * 3 + 2] = d.z;
      final range = math.sqrt(x * x + y * y + z * z);
      if (range < zlo) zlo = range;
      if (range > zhi) zhi = range;
      if (d.y < ulo) ulo = d.y;
      if (d.y > uhi) uhi = d.y;
    }
    if (n > 0) {
      // Frame on where most points are: median centre and the 95th-percentile distance from it. A few far-off
      // points (or a phone scan whose tracking drifted) must not shrink the real scene to specks. fullExtent keeps
      // the true maximum, which the viewer still states.
      final step = math.max(1, n ~/ 5000);
      final xs = <double>[], ys = <double>[], zs = <double>[];
      for (int i = 0; i < n; i += step) {
        xs.add(_disp[i * 3]);
        ys.add(_disp[i * 3 + 1]);
        zs.add(_disp[i * 3 + 2]);
      }
      double median(List<double> v) => (v..sort())[v.length ~/ 2];
      centroid = V3(median(List.of(xs)), median(List.of(ys)), median(List.of(zs)));
      final dist = <double>[];
      for (int k = 0; k < xs.length; k++) {
        final dx = xs[k] - centroid.x, dy = ys[k] - centroid.y, dz = zs[k] - centroid.z;
        dist.add(math.sqrt(dx * dx + dy * dy + dz * dz));
      }
      dist.sort();
      final p95 = dist[math.min(dist.length - 1, (dist.length * 0.95).floor())];
      fullExtent = dist.last == 0 ? 1 : dist.last;
      extent = p95 == 0 ? fullExtent : p95;
      zMin = zlo;
      zMax = zhi;
      upMin = ulo;
      upMax = uhi;
    }
    order = Int32List.fromList(List<int>.generate(n, (i) => i));
    sx = Float32List(n);
    sy = Float32List(n);
    sz = Float32List(n);
    roiMask = Uint8List(n);
    roiCenter = null;
    roiCount = 0;
    resetView();
  }

  /// Drop the cloud (e.g. the next scan failed to load) so nothing stale is drawn.
  void clear() {
    cloud = null;
    setMesh(null);
    _disp = Float32List(0);
    order = Int32List(0);
    sx = Float32List(0);
    sy = Float32List(0);
    sz = Float32List(0);
    roiMask = Uint8List(0);
    roiCenter = null;
    roiCount = 0;
    notifyListeners();
  }

  void resetView() {
    cam.target = centroid;
    cam.yaw = 0;
    // a surface seen level shows the ground edge-on: look at a phone mesh from a little above
    cam.pitch = mesh != null && !mapping.flipYZ ? 0.45 : 0;
    // start at the sensor position for camera_optical_m (origin), otherwise at 2.2 x extent
    final fromOrigin = mapping.flipYZ ? centroid.length : 0.0;
    cam.distance = fromOrigin > 0.05 ? fromOrigin : extent * 2.2;
    _sortSoon();
    notifyListeners();
  }

  void beginInteraction() {
    interacting = true;
    _settle?.cancel();
  }

  void endInteraction() {
    interacting = false;
    _sortSoon();
  }

  void _sortSoon() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 220), () {
      sortBackToFront();
      notifyListeners();
    });
  }

  /// Painter's algorithm: far points first so near points are drawn over them.
  void sortBackToFront() {
    final c = cloud;
    if (c == null) return;
    final (_, _, f) = cam.basis();
    final eye = cam.eye;
    final n = c.count;
    final depth = Float64List(n);
    for (int i = 0; i < n; i++) {
      depth[i] = (_disp[i * 3] - eye.x) * f.x + (_disp[i * 3 + 1] - eye.y) * f.y + (_disp[i * 3 + 2] - eye.z) * f.z;
    }
    final idx = List<int>.generate(n, (i) => i);
    idx.sort((a, b) => depth[b].compareTo(depth[a]));
    order = Int32List.fromList(idx);
    final m = mesh;
    if (m != null) {
      final nt = m.triangleCount, t = m.tris, v = meshDisp;
      final td = Float64List(nt);
      for (int k = 0; k < nt; k++) {
        final a = t[k * 3] * 3, b = t[k * 3 + 1] * 3, cc = t[k * 3 + 2] * 3;
        td[k] = (v[a] + v[b] + v[cc] - 3 * eye.x) * f.x + (v[a + 1] + v[b + 1] + v[cc + 1] - 3 * eye.y) * f.y +
            (v[a + 2] + v[b + 2] + v[cc + 2] - 3 * eye.z) * f.z;
      }
      final ti = List<int>.generate(nt, (i) => i);
      ti.sort((a, b) => td[b].compareTo(td[a]));
      triOrder = Int32List.fromList(ti);
    }
  }

  void orbit(Offset d) {
    cam.orbit(d.dx, d.dy);
    notifyListeners();
  }

  void pan(Offset d) {
    cam.pan(d.dx, d.dy, lastSize.height == 0 ? 600 : lastSize.height);
    notifyListeners();
  }

  void zoom(double factor) {
    cam.zoom(factor);
    _sortSoon();
    notifyListeners();
  }

  void setColorMode(ColorMode m) {
    colorMode = m;
    notifyListeners();
  }

  void setPointSize(double s) {
    pointSize = s;
    notifyListeners();
  }

  void setRoi(List<double>? center, [double? radius]) {
    roiCenter = center;
    if (radius != null) roiRadius = radius;
    _updateMask();
    notifyListeners();
  }

  void _updateMask() {
    final c = cloud;
    if (c == null) return;
    final n = c.count;
    roiCount = 0;
    if (roiCenter == null) {
      roiMask.fillRange(0, n, 0);
      return;
    }
    final r2 = roiRadius * roiRadius;
    final cx = roiCenter![0], cy = roiCenter![1], cz = roiCenter![2];
    for (int i = 0; i < n; i++) {
      final dx = c.xyz[i * 3] - cx, dy = c.xyz[i * 3 + 1] - cy, dz = c.xyz[i * 3 + 2] - cz;
      final inside = dx * dx + dy * dy + dz * dz <= r2;
      roiMask[i] = inside ? 1 : 0;
      if (inside) roiCount++;
    }
  }

  /// Nearest projected point within [tolPx] of [pos]; among candidates, the one closest to the camera.
  int? pick(Offset pos, {double tolPx = 7}) {
    final c = cloud;
    if (c == null) return null;
    int? best;
    double bestDepth = double.infinity;
    final t2 = tolPx * tolPx;
    for (int i = 0; i < c.count; i++) {
      if (sz[i] <= 0) continue;
      final dx = sx[i] - pos.dx, dy = sy[i] - pos.dy;
      if (dx * dx + dy * dy <= t2 && sz[i] < bestDepth) {
        bestDepth = sz[i];
        best = i;
      }
    }
    return best;
  }

  List<double> pointInScanFrame(int i) {
    final c = cloud!;
    return [c.xyz[i * 3].toDouble(), c.xyz[i * 3 + 1].toDouble(), c.xyz[i * 3 + 2].toDouble()];
  }

  Float32List get displayPoints => _disp;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }
}

/// Interactive point-cloud view: drag = orbit, shift/right-drag = pan, scroll/pinch = zoom, click = pick ROI centre.
class PointCloudView extends StatefulWidget {
  const PointCloudView({super.key, required this.controller, this.onPick, required this.accent});
  final PointCloudController controller;
  final void Function(int index)? onPick;
  final Color accent;

  @override
  State<PointCloudView> createState() => _PointCloudViewState();
}

class _PointCloudViewState extends State<PointCloudView> {
  Offset? _down;
  bool _moved = false;
  int _buttons = 0;
  double _lastScale = 1;

  bool get _shift =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

  @override
  Widget build(BuildContext context) {
    final ctl = widget.controller;
    return LayoutBuilder(
      builder: (context, box) {
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              ctl.zoom(math.exp(e.scrollDelta.dy * 0.0015));
            }
          },
          onPointerDown: (e) {
            _down = e.localPosition;
            _moved = false;
            _buttons = e.buttons;
            ctl.beginInteraction();
          },
          onPointerMove: (e) {
            if (_down == null) return;
            if ((e.localPosition - _down!).distance > 3) _moved = true;
            if (_buttons & kSecondaryMouseButton != 0 || _buttons & kMiddleMouseButton != 0 || _shift) {
              ctl.pan(e.delta);
            } else {
              ctl.orbit(e.delta);
            }
          },
          onPointerUp: (e) {
            final wasClick = !_moved && _down != null;
            final pos = e.localPosition;
            _down = null;
            ctl.endInteraction();
            if (wasClick && widget.onPick != null && _buttons & kPrimaryMouseButton != 0) {
              final i = ctl.pick(pos);
              if (i != null) widget.onPick!(i);
            }
          },
          onPointerCancel: (_) {
            _down = null;
            ctl.endInteraction();
          },
          onPointerPanZoomStart: (_) {
            _lastScale = 1;
            ctl.beginInteraction();
          },
          onPointerPanZoomUpdate: (e) {
            if (e.scale != _lastScale) {
              ctl.zoom(_lastScale / e.scale);
              _lastScale = e.scale;
            }
            if (e.panDelta != Offset.zero) {
              if (_shift) {
                ctl.pan(e.panDelta);
              } else {
                ctl.orbit(-e.panDelta);
              }
            }
          },
          onPointerPanZoomEnd: (_) => ctl.endInteraction(),
          child: ClipRect(
            child: CustomPaint(
              size: Size(box.maxWidth, box.maxHeight),
              painter: _CloudPainter(ctl, widget.accent, false), // light plot, like the other figures
            ),
          ),
        );
      },
    );
  }
}

class _CloudPainter extends CustomPainter {
  _CloudPainter(this.c, this.accent, this.dark) : super(repaint: c);
  final PointCloudController c;
  final Color accent;
  final bool dark;

  Float32List _pos = Float32List(0);
  Int32List _col = Int32List(0);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF101315) : FsPalette.plot);
    final cloud = c.cloud;
    if (cloud == null) return;
    c.lastSize = size;
    final n = cloud.count;
    if (_pos.length != n * 6) {
      _pos = Float32List(n * 6);
      _col = Int32List(n * 3);
    }
    final (r, u, f) = c.cam.basis();
    final eye = c.cam.eye;
    final fp = c.cam.focalPx(size.height);
    final w2 = size.width / 2, h2 = size.height / 2;
    final s = c.pointSize * 0.9;
    final sxo = s * 0.866, syo = s * 0.5;
    final disp = c.displayPoints;
    final rgb = cloud.rgb;
    final xyz = cloud.xyz;
    final mode = c.colorMode;
    final zr = (c.zMax - c.zMin) == 0 ? 1.0 : (c.zMax - c.zMin);
    final ur = (c.upMax - c.upMin) == 0 ? 1.0 : (c.upMax - c.upMin);
    final ar = (accent.r * 255).round(), ag = (accent.g * 255).round(), ab = (accent.b * 255).round();
    final hasRoi = c.roiCenter != null;
    final meshMode = c.mesh != null;
    int k = 0;
    final order = c.order.length == n ? c.order : Int32List.fromList(List<int>.generate(n, (i) => i));
    for (int oi = 0; oi < n; oi++) {
      final i = order[oi];
      final dx = disp[i * 3] - eye.x, dy = disp[i * 3 + 1] - eye.y, dz = disp[i * 3 + 2] - eye.z;
      final zf = dx * f.x + dy * f.y + dz * f.z;
      if (zf < OrbitCamera.near) {
        c.sz[i] = -1;
        continue;
      }
      final px = w2 + fp * (dx * r.x + dy * r.y + dz * r.z) / zf;
      final py = h2 - fp * (dx * u.x + dy * u.y + dz * u.z) / zf;
      c.sx[i] = px;
      c.sy[i] = py;
      c.sz[i] = zf;
      if (meshMode || px < -10 || py < -10 || px > size.width + 10 || py > size.height + 10) continue;
      int color;
      switch (mode) {
        case ColorMode.rgb:
          color = 0xFF000000 | (rgb[i * 3] << 16) | (rgb[i * 3 + 1] << 8) | rgb[i * 3 + 2];
        case ColorMode.range:
          final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
          color = viridisArgb((math.sqrt(x * x + y * y + z * z) - c.zMin) / zr);
        case ColorMode.up:
          color = viridisArgb((disp[i * 3 + 1] - c.upMin) / ur);
      }
      if (hasRoi && c.roiMask[i] == 1) {
        final cr = (color >> 16) & 0xFF, cg = (color >> 8) & 0xFF, cb = color & 0xFF;
        color = 0xFF000000 | (((cr + ar * 2) ~/ 3) << 16) | (((cg + ag * 2) ~/ 3) << 8) | ((cb + ab * 2) ~/ 3);
      }
      final p = k * 6;
      _pos[p] = px;
      _pos[p + 1] = py - s;
      _pos[p + 2] = px - sxo;
      _pos[p + 3] = py + syo;
      _pos[p + 4] = px + sxo;
      _pos[p + 5] = py + syo;
      final q = k * 3;
      _col[q] = color;
      _col[q + 1] = color;
      _col[q + 2] = color;
      k++;
    }
    if (k > 0) {
      final v = ui.Vertices.raw(
        VertexMode.triangles,
        Float32List.sublistView(_pos, 0, k * 6),
        colors: Int32List.sublistView(_col, 0, k * 3),
      );
      canvas.drawVertices(v, BlendMode.dst, Paint());
      v.dispose();
    }
    if (meshMode) _drawMesh(canvas, size, r, u, f, eye, fp);
    _drawGizmo(canvas, size, r, u);
    _drawScaleBar(canvas, size, fp);
    if (c.roiCenter != null) _drawRoiCenter(canvas, size, r, u, f, eye, fp);
  }

  Float32List _mx = Float32List(0), _my = Float32List(0), _mz = Float32List(0);
  Float32List _tpos = Float32List(0);
  Int32List _tcol = Int32List(0);

  /// Flat-shaded triangles, far to near (painter's algorithm), lit from the camera so both sides show.
  void _drawMesh(Canvas canvas, Size size, V3 r, V3 u, V3 f, V3 eye, double fp) {
    final m = c.mesh!;
    final nv = m.vertexCount, nt = m.triangleCount;
    if (_mx.length != nv) {
      _mx = Float32List(nv);
      _my = Float32List(nv);
      _mz = Float32List(nv);
    }
    if (_tpos.length != nt * 6) {
      _tpos = Float32List(nt * 6);
      _tcol = Int32List(nt * 3);
    }
    final v = c.meshDisp;
    final w2 = size.width / 2, h2 = size.height / 2;
    for (int i = 0; i < nv; i++) {
      final dx = v[i * 3] - eye.x, dy = v[i * 3 + 1] - eye.y, dz = v[i * 3 + 2] - eye.z;
      final zf = dx * f.x + dy * f.y + dz * f.z;
      _mz[i] = zf;
      if (zf < OrbitCamera.near) continue;
      _mx[i] = w2 + fp * (dx * r.x + dy * r.y + dz * r.z) / zf;
      _my[i] = h2 - fp * (dx * u.x + dy * u.y + dz * u.z) / zf;
    }
    // light: a headlight tilted slightly down from above, so slopes read
    var lx = -f.x + u.x * 0.6, ly = -f.y + u.y * 0.6, lz = -f.z + u.z * 0.6;
    final ll = math.sqrt(lx * lx + ly * ly + lz * lz);
    lx /= ll;
    ly /= ll;
    lz /= ll;
    final mode = c.colorMode;
    final zr = (c.zMax - c.zMin) == 0 ? 1.0 : (c.zMax - c.zMin);
    final ur = (c.upMax - c.upMin) == 0 ? 1.0 : (c.upMax - c.upMin);
    final t = m.tris, n = c.triNormal;
    final order = c.triOrder.length == nt ? c.triOrder : Int32List.fromList(List<int>.generate(nt, (i) => i));
    int k = 0;
    for (int oi = 0; oi < nt; oi++) {
      final tri = order[oi];
      final a = t[tri * 3], b = t[tri * 3 + 1], cc = t[tri * 3 + 2];
      if (_mz[a] < OrbitCamera.near || _mz[b] < OrbitCamera.near || _mz[cc] < OrbitCamera.near) continue;
      final ax = _mx[a], ay = _my[a], bx = _mx[b], by = _my[b], cx = _mx[cc], cy = _my[cc];
      if ((ax < 0 && bx < 0 && cx < 0) || (ay < 0 && by < 0 && cy < 0)) continue;
      if ((ax > size.width && bx > size.width && cx > size.width) || (ay > size.height && by > size.height && cy > size.height)) continue;
      int base;
      switch (mode) {
        case ColorMode.rgb:
          base = 0xFFB9B2A4; // no measured colour on the mesh: neutral clay
        case ColorMode.range:
          base = viridisArgb((c.triRange[tri] - c.zMin) / zr);
        case ColorMode.up:
          base = viridisArgb((c.triUp[tri] - c.upMin) / ur);
      }
      final d = (n[tri * 3] * lx + n[tri * 3 + 1] * ly + n[tri * 3 + 2] * lz).abs();
      final sh = 0.32 + 0.68 * d;
      final col = 0xFF000000 |
          ((((base >> 16) & 0xFF) * sh).round() << 16) |
          ((((base >> 8) & 0xFF) * sh).round() << 8) |
          ((base & 0xFF) * sh).round();
      final p = k * 6;
      _tpos[p] = ax;
      _tpos[p + 1] = ay;
      _tpos[p + 2] = bx;
      _tpos[p + 3] = by;
      _tpos[p + 4] = cx;
      _tpos[p + 5] = cy;
      final q = k * 3;
      _tcol[q] = col;
      _tcol[q + 1] = col;
      _tcol[q + 2] = col;
      k++;
    }
    if (k == 0) return;
    final vv = ui.Vertices.raw(VertexMode.triangles, Float32List.sublistView(_tpos, 0, k * 6),
        colors: Int32List.sublistView(_tcol, 0, k * 3));
    canvas.drawVertices(vv, BlendMode.dst, Paint());
    vv.dispose();
  }

  void _drawRoiCenter(Canvas canvas, Size size, V3 r, V3 u, V3 f, V3 eye, double fp) {
    final rc = c.roiCenter!;
    final d = c.mapping.toDisplay(rc[0], rc[1], rc[2]) - eye;
    final zf = d.dot(f);
    if (zf <= OrbitCamera.near) return;
    final p = Offset(size.width / 2 + fp * d.dot(r) / zf, size.height / 2 - fp * d.dot(u) / zf);
    final rad = fp * c.roiRadius / zf;
    canvas.drawCircle(
      p,
      rad,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accent,
    );
    canvas.drawCircle(p, 3, Paint()..color = accent);
  }

  /// Axis triad in ink, bottom left: which way the scan's own axes point in this view.
  void _drawGizmo(Canvas canvas, Size size, V3 r, V3 u) {
    final origin = Offset(54, size.height - 54);
    const len = 30.0;
    final axes = [('+X', c.mapping.toDisplay(1, 0, 0)), ('+Y', c.mapping.toDisplay(0, 1, 0)), ('+Z', c.mapping.toDisplay(0, 0, 1))];
    final halo = Paint()
      ..color = FsPalette.sheet
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = FsPalette.ink
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final (label, v) in axes) {
      final dir = Offset(v.dot(r), -v.dot(u));
      final end = origin + dir * len;
      canvas.drawLine(origin, end, halo);
      canvas.drawLine(origin, end, line);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(fontFamily: fsFont, color: FsPalette.ink, fontSize: 10.5, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final d = end - origin;
      // An axis pointing at or away from the viewer has almost no length on screen; its label sits beside the origin.
      final centre = d.distance > 6 ? end + d / d.distance * 11 : origin + const Offset(-14, -14);
      final box = Rect.fromCenter(center: centre, width: tp.width + 6, height: tp.height + 2);
      canvas.drawRect(box, Paint()..color = FsPalette.sheet.withValues(alpha: 0.9));
      tp.paint(canvas, box.topLeft + const Offset(3, 1));
    }
  }

  /// Scale bar, bottom right. Perspective makes it exact only at the orbit centre (the depth of the target).
  void _drawScaleBar(Canvas canvas, Size size, double fp) {
    if (fp <= 0 || c.cam.distance <= 0) return;
    final mpp = c.cam.distance / fp; // metres per screen pixel at the orbit centre
    final want = 120 * mpp;
    final mag = math.pow(10, (math.log(want) / math.ln10).floor()).toDouble();
    final nice = [5.0, 2.0, 1.0].map((k) => k * mag).firstWhere((v) => v <= want, orElse: () => mag);
    final px = nice / mpp;
    if (px < 30 || px > size.width * 0.5) return;
    final right = size.width - 16, base = size.height - 30;
    final left = right - px;
    final bar = Rect.fromLTWH(left, base, px, 6);
    canvas.drawRect(bar.inflate(10).translate(0, 6), Paint()..color = FsPalette.sheet.withValues(alpha: 0.8));
    for (int i = 0; i < 4; i++) {
      canvas.drawRect(Rect.fromLTWH(left + i * px / 4, base, px / 4, 6), Paint()..color = i.isEven ? FsPalette.ink : FsPalette.sheet);
    }
    canvas.drawRect(
      bar,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = FsPalette.ink
        ..strokeWidth = 1,
    );
    String fmt(double m) {
      if (nice >= 1) return m.toStringAsFixed(m == m.roundToDouble() ? 0 : 1);
      if (nice >= 0.01) return (m * 100).toStringAsFixed((m * 100) == (m * 100).roundToDouble() ? 0 : 1);
      return (m * 1000).toStringAsFixed(0);
    }

    final unit = nice >= 1 ? 'm' : (nice >= 0.01 ? 'cm' : 'mm');
    const st = TextStyle(fontFamily: fsFont, color: FsPalette.ink, fontSize: 10.5, fontFeatures: tnum);
    for (final (frac, label) in [(0.0, '0'), (1.0, '${fmt(nice)} $unit')]) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: st),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = left + frac * px;
      final dx = frac == 1.0 ? x - tp.width : (frac == 0.0 ? x : x - tp.width / 2);
      tp.paint(canvas, Offset(dx, base + 9));
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter old) => old.c != c || old.accent != accent || old.dark != dark;
}
