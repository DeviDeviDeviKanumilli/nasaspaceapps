// Software point-cloud viewer: orbit (one finger), zoom (pinch), pan (two fingers), tap to pick a real point.
// Renders with a z-buffer into an RGBA image, so near points hide far ones. Display only: measurements use
// the full-resolution cloud, not this decimated copy.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/geometry.dart';
import '../core/ply.dart';

enum ColorMode { rgb, height, confidence, shaded }

class Marker {
  final Vec3 p;
  final Color color;
  final String label;
  final double radiusM; // > 0 draws a sphere outline (ROI)
  Marker(this.p, this.color, this.label, {this.radiusM = 0});
}

class CloudViewer extends StatefulWidget {
  final PointCloud cloud;
  final ColorMode mode;
  final double pointSize;
  final List<Marker> markers;
  final List<Vec3> cameraPath;
  final void Function(Vec3 p)? onPick;
  const CloudViewer(
      {super.key, required this.cloud, this.mode = ColorMode.rgb, this.pointSize = 2, this.markers = const [], this.cameraPath = const [], this.onPick});

  @override
  State<CloudViewer> createState() => _CloudViewerState();
}

class _View {
  double yaw = 0.6, pitch = 0.35, dist = 2, fov = 1.0;
  Vec3 target = const Vec3(0, 0, 0);
}

class _CloudViewerState extends State<CloudViewer> {
  final _v = _View();
  ui.Image? _img;
  Size _size = Size.zero;
  bool _rendering = false, _dirty = false;
  Float32List? _sx, _sy, _sz; // last projection (for picking)
  Uint8List? _colors;
  double _scaleStart = 1, _yaw0 = 0, _pitch0 = 0;
  Offset _focal0 = Offset.zero;
  Vec3 _target0 = const Vec3(0, 0, 0);
  int _pointers = 0;
  double _radius = 1;

  @override
  void initState() {
    super.initState();
    _fit();
  }

  @override
  void didUpdateWidget(CloudViewer old) {
    super.didUpdateWidget(old);
    if (old.cloud != widget.cloud) _fit();
    if (old.cloud != widget.cloud || old.mode != widget.mode) _colors = null;
    _schedule();
  }

  void _fit() {
    final xyz = widget.cloud.xyz;
    final n = widget.cloud.length;
    if (n == 0) return;
    // robust centre: median per axis, radius: 90th percentile distance
    List<double> axis(int k) => [for (int i = 0; i < n; i += math.max(1, n ~/ 5000)) xyz[i * 3 + k]]..sort();
    double med(List<double> v) => v[v.length ~/ 2];
    final c = Vec3(med(axis(0)), med(axis(1)), med(axis(2)));
    final d = [for (int i = 0; i < n; i += math.max(1, n ~/ 5000)) (pointAt(xyz, i) - c).length]..sort();
    _radius = math.max(0.05, d[(d.length * 0.9).floor().clamp(0, d.length - 1)]);
    _v.target = c;
    _v.dist = _radius * 2.6;
    _schedule();
  }

  Uint8List _computeColors() {
    final pc = widget.cloud;
    final n = pc.length;
    final out = Uint8List(n * 3);
    if (widget.mode == ColorMode.rgb && pc.rgb != null) return pc.rgb!;
    if (widget.mode == ColorMode.confidence && pc.confidence != null) {
      for (int i = 0; i < n; i++) {
        final c = pc.confidence![i];
        final col = c >= 2 ? const [80, 200, 120] : (c == 1 ? const [240, 190, 60] : const [230, 80, 70]);
        out.setRange(i * 3, i * 3 + 3, col);
      }
      return out;
    }
    if (widget.mode == ColorMode.shaded && pc.faces != null) {
      final nx = Float32List(n), ny = Float32List(n), nz = Float32List(n);
      final f = pc.faces!;
      for (int t = 0; t < f.length ~/ 3; t++) {
        final a = pointAt(pc.xyz, f[t * 3]), b = pointAt(pc.xyz, f[t * 3 + 1]), c = pointAt(pc.xyz, f[t * 3 + 2]);
        final u = b - a, v = c - a;
        final cx = u.y * v.z - u.z * v.y, cy = u.z * v.x - u.x * v.z, cz = u.x * v.y - u.y * v.x;
        for (final k in [f[t * 3], f[t * 3 + 1], f[t * 3 + 2]]) {
          nx[k] += cx;
          ny[k] += cy;
          nz[k] += cz;
        }
      }
      for (int i = 0; i < n; i++) {
        final l = math.sqrt(nx[i] * nx[i] + ny[i] * ny[i] + nz[i] * nz[i]);
        final s = l > 0 ? (0.35 + 0.65 * ((nx[i] * 0.3 + ny[i] * 0.8 + nz[i] * 0.5) / l).abs()) : 0.5;
        final g = (s * 220).round().clamp(0, 255);
        out[i * 3] = g;
        out[i * 3 + 1] = g;
        out[i * 3 + 2] = (g * 1.05).round().clamp(0, 255);
      }
      return out;
    }
    // height colour map along +Y (gravity up)
    double lo = double.infinity, hi = -double.infinity;
    for (int i = 0; i < n; i++) {
      lo = math.min(lo, pc.xyz[i * 3 + 1]);
      hi = math.max(hi, pc.xyz[i * 3 + 1]);
    }
    for (int i = 0; i < n; i++) {
      final t = hi > lo ? (pc.xyz[i * 3 + 1] - lo) / (hi - lo) : 0.5;
      out[i * 3] = (40 + 215 * t).round();
      out[i * 3 + 1] = (90 + 120 * (1 - (2 * t - 1).abs())).round();
      out[i * 3 + 2] = (230 - 190 * t).round();
    }
    return out;
  }

  // camera basis
  (Vec3, Vec3, Vec3, Vec3) _basis() {
    final cp = math.cos(_v.pitch), sp = math.sin(_v.pitch), cy = math.cos(_v.yaw), sy = math.sin(_v.yaw);
    final back = Vec3(cp * sy, sp, cp * cy); // from target to eye
    final eye = _v.target + back * _v.dist;
    final fwd = back * -1;
    var right = Vec3(-fwd.z, 0, fwd.x); // fwd x worldUp
    right = right.length < 1e-6 ? const Vec3(1, 0, 0) : right.unit;
    final up = Vec3(right.y * fwd.z - right.z * fwd.y, right.z * fwd.x - right.x * fwd.z, right.x * fwd.y - right.y * fwd.x);
    return (eye, right, up, fwd);
  }

  double get _focalPx => 0.5 * math.min(_size.width, _size.height) / math.tan(_v.fov / 2);

  Offset? project(Vec3 p) {
    final (eye, right, up, fwd) = _basis();
    final d = p - eye;
    final z = d.dot(fwd);
    if (z <= 0.01) return null;
    return Offset(_size.width / 2 + _focalPx * d.dot(right) / z, _size.height / 2 - _focalPx * d.dot(up) / z);
  }

  void _schedule() {
    if (_rendering) {
      _dirty = true;
      return;
    }
    _render();
  }

  Future<void> _render() async {
    if (_size.isEmpty) return;
    _rendering = true;
    final w = _size.width.round(), h = _size.height.round();
    final pc = widget.cloud;
    final n = pc.length;
    _colors ??= _computeColors();
    final col = _colors!;
    final buf = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      buf[i * 4 + 3] = 0;
    }
    final zb = Float32List(w * h)..fillRange(0, w * h, double.infinity);
    final (eye, r, u, f) = _basis();
    final fp = _focalPx;
    final sx = Float32List(n), sy = Float32List(n), sz = Float32List(n);
    final ps = widget.pointSize.round().clamp(1, 6);
    final half = ps ~/ 2;
    final xyz = pc.xyz;
    for (int i = 0; i < n; i++) {
      final dx = xyz[i * 3] - eye.x, dy = xyz[i * 3 + 1] - eye.y, dz = xyz[i * 3 + 2] - eye.z;
      final z = dx * f.x + dy * f.y + dz * f.z;
      sz[i] = z;
      if (z <= 0.01) {
        sx[i] = -1e9;
        continue;
      }
      final px = w / 2 + fp * (dx * r.x + dy * r.y + dz * r.z) / z;
      final py = h / 2 - fp * (dx * u.x + dy * u.y + dz * u.z) / z;
      sx[i] = px;
      sy[i] = py;
      final ix = px.round(), iy = py.round();
      for (int oy = -half; oy < ps - half; oy++) {
        final yy = iy + oy;
        if (yy < 0 || yy >= h) continue;
        for (int ox = -half; ox < ps - half; ox++) {
          final xx = ix + ox;
          if (xx < 0 || xx >= w) continue;
          final k = yy * w + xx;
          if (z < zb[k]) {
            zb[k] = z;
            buf[k * 4] = col[i * 3];
            buf[k * 4 + 1] = col[i * 3 + 1];
            buf[k * 4 + 2] = col[i * 3 + 2];
            buf[k * 4 + 3] = 255;
          }
        }
      }
    }
    _sx = sx;
    _sy = sy;
    _sz = sz;
    ui.decodeImageFromPixels(buf, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) return;
      setState(() {
        _img?.dispose();
        _img = img;
      });
      _rendering = false;
      if (_dirty) {
        _dirty = false;
        _render();
      }
    });
  }

  void _pick(Offset pos) {
    if (widget.onPick == null || _sx == null) return;
    int best = -1;
    double bestZ = double.infinity;
    const tol = 14.0;
    for (int i = 0; i < _sx!.length; i++) {
      final dx = _sx![i] - pos.dx, dy = _sy![i] - pos.dy;
      if (dx.abs() > tol || dy.abs() > tol) continue;
      if (dx * dx + dy * dy > tol * tol) continue;
      if (_sz![i] < bestZ) {
        bestZ = _sz![i];
        best = i;
      }
    }
    if (best >= 0) widget.onPick!(pointAt(widget.cloud.xyz, best));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final s = Size(c.maxWidth, c.maxHeight);
      if (s != _size) {
        _size = s;
        WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
      }
      return Listener(
        onPointerDown: (_) => _pointers++,
        onPointerUp: (_) => _pointers = math.max(0, _pointers - 1),
        onPointerCancel: (_) => _pointers = math.max(0, _pointers - 1),
        child: GestureDetector(
          onTapUp: (d) => _pick(d.localPosition),
          onDoubleTap: _fit,
          onScaleStart: (d) {
            _scaleStart = _v.dist;
            _yaw0 = _v.yaw;
            _pitch0 = _v.pitch;
            _focal0 = d.focalPoint;
            _target0 = _v.target;
          },
          onScaleUpdate: (d) {
            final delta = d.focalPoint - _focal0;
            if (d.pointerCount >= 2 || _pointers >= 2) {
              _v.dist = (_scaleStart / d.scale).clamp(0.05, 200);
              final (_, r, u, _) = _basis();
              final k = _v.dist / _focalPx;
              _v.target = _target0 - r * (delta.dx * k) + u * (delta.dy * k);
            } else {
              _v.yaw = _yaw0 - delta.dx * 0.008;
              _v.pitch = (_pitch0 + delta.dy * 0.008).clamp(-1.5, 1.5);
            }
            _schedule();
          },
          child: Stack(fit: StackFit.expand, children: [
            Container(color: const Color(0xFFE6EBE2)),
            if (_img != null) RawImage(image: _img, fit: BoxFit.fill),
            CustomPaint(painter: _Overlay(this)),
          ]),
        ),
      );
    });
  }
}

class _Overlay extends CustomPainter {
  final _CloudViewerState s;
  _Overlay(this.s);

  @override
  void paint(Canvas canvas, Size size) {
    if (s._size.isEmpty) return;
    // camera path
    final path = s.widget.cameraPath;
    if (path.length > 1) {
      final p = Paint()
        ..color = const Color(0x992C79B0)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      Offset? prev;
      for (final c in path) {
        final o = s.project(c);
        if (o != null && prev != null) canvas.drawLine(prev, o, p);
        prev = o;
      }
    }
    for (final m in s.widget.markers) {
      final o = s.project(m.p);
      if (o == null) continue;
      if (m.radiusM > 0) {
        final edge = s.project(m.p + Vec3(0, m.radiusM, 0));
        if (edge != null) {
          canvas.drawCircle(o, (edge - o).distance, Paint()
            ..color = m.color.withValues(alpha: 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
        }
      }
      canvas.drawCircle(o, 5, Paint()..color = m.color);
      canvas.drawCircle(o, 6, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      if (m.label.isNotEmpty) {
        final tp = TextPainter(
            text: TextSpan(text: m.label, style: TextStyle(color: m.color, fontSize: 12, fontWeight: FontWeight.w600)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, o + const Offset(8, -16));
      }
    }
    // lines between consecutive distance markers labelled A/B
    final ms = s.widget.markers.where((m) => m.radiusM == 0).toList();
    for (int i = 0; i + 1 < ms.length; i += 2) {
      final a = s.project(ms[i].p), b = s.project(ms[i + 1].p);
      if (a != null && b != null) {
        canvas.drawLine(a, b, Paint()
          ..color = ms[i].color
          ..strokeWidth = 2);
      }
    }
    // scale bar at the orbit target depth
    final fp = s._focalPx;
    final len = _niceLength(s._v.dist * size.width * 0.25 / fp);
    final px = fp * len / s._v.dist;
    final y = size.height - 18;
    final paint = Paint()
      ..color = const Color(0xFF3B3E36)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(16, y), Offset(16 + px, y), paint);
    canvas.drawLine(Offset(16, y - 5), Offset(16, y + 5), paint);
    canvas.drawLine(Offset(16 + px, y - 5), Offset(16 + px, y + 5), paint);
    final tp = TextPainter(
        text: TextSpan(text: len >= 1 ? '${len.toStringAsFixed(0)} m' : '${(len * 100).toStringAsFixed(0)} cm',
            style: const TextStyle(color: Color(0xFF3B3E36), fontSize: 11, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(16, y - 20));
    final note = TextPainter(
        text: const TextSpan(text: 'scale at orbit centre', style: TextStyle(color: Color(0xFF5F635A), fontSize: 9)),
        textDirection: TextDirection.ltr)
      ..layout();
    note.paint(canvas, Offset(22 + px, y - 6));
  }

  double _niceLength(double x) {
    final e = math.pow(10, (math.log(x) / math.ln10).floor()).toDouble();
    for (final m in [1, 2, 5, 10]) {
      if (m * e >= x * 0.7) return m * e;
    }
    return 10 * e;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
