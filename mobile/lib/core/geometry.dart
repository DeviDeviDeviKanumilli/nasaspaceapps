// Local geometry measurements on a metric point cloud in arkit_session_world (+Y up = measured gravity).
// Pure Dart; every function is unit-tested against synthetic geometry in test/geometry_test.dart.
import 'dart:math' as math;
import 'dart:typed_data';

class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  double get length => math.sqrt(dot(this));
  Vec3 get unit => this * (1 / length);
  List<double> toList() => [x, y, z];
  @override
  String toString() => '(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

Vec3 pointAt(Float32List xyz, int i) => Vec3(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2]);

/// Indices of points within [radius] of [c].
List<int> pointsInSphere(Float32List xyz, Vec3 c, double radius) {
  final r2 = radius * radius;
  final out = <int>[];
  for (int i = 0; i < xyz.length ~/ 3; i++) {
    final dx = xyz[i * 3] - c.x, dy = xyz[i * 3 + 1] - c.y, dz = xyz[i * 3 + 2] - c.z;
    if (dx * dx + dy * dy + dz * dz <= r2) out.add(i);
  }
  return out;
}

/// Eigen-decomposition of a symmetric 3x3 matrix (cyclic Jacobi). Returns eigenvalues ascending and
/// matching unit eigenvectors.
(List<double>, List<Vec3>) symEig3(List<List<double>> m) {
  final a = [for (final r in m) [...r]];
  final v = [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0]
  ];
  for (int sweep = 0; sweep < 50; sweep++) {
    final off = a[0][1].abs() + a[0][2].abs() + a[1][2].abs();
    if (off < 1e-15) break;
    for (int p = 0; p < 2; p++) {
      for (int q = p + 1; q < 3; q++) {
        if (a[p][q].abs() < 1e-18) continue;
        final theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
        final t = theta.sign == 0 ? 1.0 : theta.sign / (theta.abs() + math.sqrt(theta * theta + 1));
        final c = 1 / math.sqrt(t * t + 1), s = t * c;
        for (int k = 0; k < 3; k++) {
          final akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (int k = 0; k < 3; k++) {
          final apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (int k = 0; k < 3; k++) {
          final vkp = v[k][p], vkq = v[k][q];
          v[k][p] = c * vkp - s * vkq;
          v[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  final idx = [0, 1, 2]..sort((i, j) => a[i][i].compareTo(a[j][j]));
  return (
    [for (final i in idx) a[i][i]],
    [for (final i in idx) Vec3(v[0][i], v[1][i], v[2][i]).unit]
  );
}

class PlaneFit {
  final Vec3 centroid;
  final Vec3 normal; // unit; oriented toward [towards] if given, else +Y-ish
  final double rmsResidual; // m, orthogonal
  final double p95AbsResidual; // m
  final double maxAbove, maxBelow; // m along normal (>= 0 each)
  final int nUsed, nInput, rejected;
  final double tiltFromHorizontalDeg; // angle between plane and horizontal (0 = flat ground, 90 = vertical face)
  final double majorExtent, minorExtent; // in-plane extents of used points, m
  PlaneFit(this.centroid, this.normal, this.rmsResidual, this.p95AbsResidual, this.maxAbove, this.maxBelow, this.nUsed,
      this.nInput, this.rejected, this.tiltFromHorizontalDeg, this.majorExtent, this.minorExtent);
}

/// Total-least-squares plane (PCA). If [robust], points with |residual| > 3*rms are removed and the plane refit,
/// up to 3 times (reported in [PlaneFit.rejected]). [towards] orients the normal (e.g. mean camera position) so
/// "above" means toward the observer.
PlaneFit? fitPlane(Float32List xyz, List<int> idx, {bool robust = false, Vec3? towards}) {
  var use = idx;
  if (use.length < 10) return null;
  late Vec3 c, n;
  late List<double> ev;
  late List<Vec3> evec;
  int rejected = 0;
  for (int iter = 0; iter < (robust ? 4 : 1); iter++) {
    double sx = 0, sy = 0, sz = 0;
    for (final i in use) {
      sx += xyz[i * 3];
      sy += xyz[i * 3 + 1];
      sz += xyz[i * 3 + 2];
    }
    final k = use.length.toDouble();
    c = Vec3(sx / k, sy / k, sz / k);
    double xx = 0, xy = 0, xz = 0, yy = 0, yz = 0, zz = 0;
    for (final i in use) {
      final dx = xyz[i * 3] - c.x, dy = xyz[i * 3 + 1] - c.y, dz = xyz[i * 3 + 2] - c.z;
      xx += dx * dx;
      xy += dx * dy;
      xz += dx * dz;
      yy += dy * dy;
      yz += dy * dz;
      zz += dz * dz;
    }
    (ev, evec) = symEig3([
      [xx / k, xy / k, xz / k],
      [xy / k, yy / k, yz / k],
      [xz / k, yz / k, zz / k]
    ]);
    n = evec[0];
    if (!robust || iter == 3) break;
    final rms = math.sqrt(math.max(0, ev[0]));
    final keep = <int>[];
    for (final i in use) {
      if ((pointAt(xyz, i) - c).dot(n).abs() <= 3 * rms) keep.add(i);
    }
    if (keep.length == use.length || keep.length < 10) break;
    rejected += use.length - keep.length;
    use = keep;
  }
  if (towards != null) {
    if ((towards - c).dot(n) < 0) n = n * -1;
  } else if (n.y < 0) {
    n = n * -1;
  }
  final res = <double>[];
  double above = 0, below = 0, sq = 0;
  double minA = double.infinity, maxA = -double.infinity, minB = double.infinity, maxB = -double.infinity;
  final a1 = evec[2], a2 = evec[1];
  for (final i in use) {
    final d = pointAt(xyz, i) - c;
    final r = d.dot(n);
    res.add(r.abs());
    sq += r * r;
    if (r > above) above = r;
    if (-r > below) below = -r;
    final pa = d.dot(a1), pb = d.dot(a2);
    minA = math.min(minA, pa);
    maxA = math.max(maxA, pa);
    minB = math.min(minB, pb);
    maxB = math.max(maxB, pb);
  }
  res.sort();
  final p95 = res[math.min(res.length - 1, (0.95 * (res.length - 1)).round())];
  final tilt = math.acos(math.min(1.0, n.y.abs())) * 180 / math.pi;
  return PlaneFit(c, n, math.sqrt(sq / use.length), p95, above, below, use.length, idx.length, rejected, tilt, maxA - minA,
      maxB - minB);
}

class Extents {
  final double vertical, horizontalMajor, horizontalMinor;
  final Vec3 min, max;
  final int n;
  Extents(this.vertical, this.horizontalMajor, this.horizontalMinor, this.min, this.max, this.n);
}

/// Extent of the observed points: vertical along +Y (gravity), horizontal along the principal axes of the
/// points projected on the horizontal plane (so it does not depend on the arbitrary ARKit heading).
/// [trim] ignores that fraction of points at each end of each axis (outlier tolerance), e.g. 0.01.
Extents extents(Float32List xyz, List<int> idx, {double trim = 0.0}) {
  final n = idx.length;
  double mx = 0, mz = 0;
  for (final i in idx) {
    mx += xyz[i * 3];
    mz += xyz[i * 3 + 2];
  }
  mx /= n;
  mz /= n;
  double sxx = 0, sxz = 0, szz = 0;
  for (final i in idx) {
    final dx = xyz[i * 3] - mx, dz = xyz[i * 3 + 2] - mz;
    sxx += dx * dx;
    sxz += dx * dz;
    szz += dz * dz;
  }
  final ang = 0.5 * math.atan2(2 * sxz, sxx - szz);
  final ux = math.cos(ang), uz = math.sin(ang);
  final ys = <double>[], aa = <double>[], bb = <double>[];
  double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  double maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
  for (final i in idx) {
    final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
    ys.add(y);
    aa.add((x - mx) * ux + (z - mz) * uz);
    bb.add(-(x - mx) * uz + (z - mz) * ux);
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    minZ = math.min(minZ, z);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
    maxZ = math.max(maxZ, z);
  }
  double span(List<double> v) {
    v.sort();
    final k = (trim * (v.length - 1)).round();
    return v[v.length - 1 - k] - v[k];
  }

  final a = span(aa), b = span(bb);
  return Extents(span(ys), math.max(a, b), math.min(a, b), Vec3(minX, minY, minZ), Vec3(maxX, maxY, maxZ), n);
}

double distance(Vec3 a, Vec3 b) => (a - b).length;

class SummaryStats {
  final int n;
  final double mean, sd, min, max;
  SummaryStats(this.n, this.mean, this.sd, this.min, this.max);
  static SummaryStats? of(List<double> v) {
    if (v.isEmpty) return null;
    final m = v.reduce((a, b) => a + b) / v.length;
    final sd = v.length > 1 ? math.sqrt(v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / (v.length - 1)) : 0.0;
    return SummaryStats(v.length, m, sd, v.reduce(math.min), v.reduce(math.max));
  }
}
