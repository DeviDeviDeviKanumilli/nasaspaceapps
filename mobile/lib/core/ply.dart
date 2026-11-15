// Minimal PLY reader/writer for the files Field Scan and Field Station produce (binary little-endian or ASCII,
// vertex x/y/z plus optional red/green/blue/confidence, optional faces). Pure Dart; unit-tested.
import 'dart:convert';
import 'dart:typed_data';

class PointCloud {
  final Float32List xyz; // n*3, metres
  final Uint8List? rgb; // n*3
  final Uint8List? confidence; // n
  final Uint32List? faces; // m*3 vertex indices (meshes only)
  final List<String> comments;
  PointCloud(this.xyz, {this.rgb, this.confidence, this.faces, this.comments = const []});
  int get length => xyz.length ~/ 3;
}

const _sizes = {
  'char': 1, 'int8': 1, 'uchar': 1, 'uint8': 1,
  'short': 2, 'int16': 2, 'ushort': 2, 'uint16': 2,
  'int': 4, 'int32': 4, 'uint': 4, 'uint32': 4,
  'float': 4, 'float32': 4, 'double': 8, 'float64': 8,
};

class _Prop {
  final String name, type;
  final String? countType; // list
  _Prop(this.name, this.type, [this.countType]);
}

class _Elem {
  final String name;
  final int count;
  final List<_Prop> props = [];
  _Elem(this.name, this.count);
}

num _read(ByteData bd, int off, String t) {
  switch (t) {
    case 'char':
    case 'int8':
      return bd.getInt8(off);
    case 'uchar':
    case 'uint8':
      return bd.getUint8(off);
    case 'short':
    case 'int16':
      return bd.getInt16(off, Endian.little);
    case 'ushort':
    case 'uint16':
      return bd.getUint16(off, Endian.little);
    case 'int':
    case 'int32':
      return bd.getInt32(off, Endian.little);
    case 'uint':
    case 'uint32':
      return bd.getUint32(off, Endian.little);
    case 'float':
    case 'float32':
      return bd.getFloat32(off, Endian.little);
    default:
      return bd.getFloat64(off, Endian.little);
  }
}

/// Parses a PLY file. [maxPoints] > 0 keeps every k-th vertex (deterministic stride) so a large cloud can be
/// shown on a phone; faces are dropped when vertices are strided.
PointCloud parsePly(Uint8List bytes, {int maxPoints = 0}) {
  // header
  final marker = utf8.encode('end_header');
  int hEnd = -1;
  for (int i = 0; i < bytes.length - marker.length && i < 65536; i++) {
    bool ok = true;
    for (int k = 0; k < marker.length; k++) {
      if (bytes[i + k] != marker[k]) {
        ok = false;
        break;
      }
    }
    if (ok) {
      hEnd = i + marker.length;
      while (hEnd < bytes.length && bytes[hEnd] != 0x0A) {
        hEnd++;
      }
      hEnd++;
      break;
    }
  }
  if (hEnd < 0) throw const FormatException('not a PLY file (no end_header)');
  final header = latin1.decode(bytes.sublist(0, hEnd)).split('\n').map((l) => l.trim()).toList();
  if (header.first != 'ply') throw const FormatException('not a PLY file');
  String format = '';
  final elems = <_Elem>[];
  final comments = <String>[];
  for (final l in header) {
    final p = l.split(RegExp(r'\s+'));
    if (p.first == 'format') format = p[1];
    if (p.first == 'comment') comments.add(l.substring(7).trim());
    if (p.first == 'element') elems.add(_Elem(p[1], int.parse(p[2])));
    if (p.first == 'property' && elems.isNotEmpty) {
      if (p[1] == 'list') {
        elems.last.props.add(_Prop(p[4], p[3], p[2]));
      } else {
        elems.last.props.add(_Prop(p[2], p[1]));
      }
    }
  }
  final vEl = elems.firstWhere((e) => e.name == 'vertex', orElse: () => throw const FormatException('no vertex element'));
  final n = vEl.count;
  final stride = (maxPoints > 0 && n > maxPoints) ? (n / maxPoints).ceil() : 1;
  final outN = (n + stride - 1) ~/ stride;
  final names = vEl.props.map((p) => p.name).toList();
  final hasRgb = names.contains('red') && names.contains('green') && names.contains('blue');
  final hasConf = names.contains('confidence');
  final xyz = Float32List(outN * 3);
  final rgb = hasRgb ? Uint8List(outN * 3) : null;
  final conf = hasConf ? Uint8List(outN) : null;
  Uint32List? faces;

  if (format == 'binary_little_endian') {
    final bd = ByteData.sublistView(bytes);
    int off = hEnd;
    // vertex layout must be fixed-size
    final offs = <String, int>{};
    int vsize = 0;
    for (final p in vEl.props) {
      if (p.countType != null) throw const FormatException('list property in vertex element');
      offs[p.name] = vsize;
      vsize += _sizes[p.type]!;
    }
    final types = {for (final p in vEl.props) p.name: p.type};
    for (final e in elems) {
      if (e.name == 'vertex') {
        int o = 0;
        for (int i = 0; i < n; i += stride) {
          final b = off + i * vsize;
          xyz[o * 3] = _read(bd, b + offs['x']!, types['x']!).toDouble();
          xyz[o * 3 + 1] = _read(bd, b + offs['y']!, types['y']!).toDouble();
          xyz[o * 3 + 2] = _read(bd, b + offs['z']!, types['z']!).toDouble();
          if (rgb != null) {
            rgb[o * 3] = _read(bd, b + offs['red']!, types['red']!).toInt();
            rgb[o * 3 + 1] = _read(bd, b + offs['green']!, types['green']!).toInt();
            rgb[o * 3 + 2] = _read(bd, b + offs['blue']!, types['blue']!).toInt();
          }
          if (conf != null) conf[o] = _read(bd, b + offs['confidence']!, types['confidence']!).toInt();
          o++;
        }
        off += n * vsize;
      } else if (e.name == 'face' && stride == 1) {
        final f = <int>[];
        for (int i = 0; i < e.count; i++) {
          for (final p in e.props) {
            if (p.countType != null) {
              final c = _read(bd, off, p.countType!).toInt();
              off += _sizes[p.countType!]!;
              final idx = <int>[];
              for (int k = 0; k < c; k++) {
                idx.add(_read(bd, off, p.type).toInt());
                off += _sizes[p.type]!;
              }
              for (int k = 1; k + 1 < idx.length; k++) {
                f.addAll([idx[0], idx[k], idx[k + 1]]);
              }
            } else {
              off += _sizes[p.type]!;
            }
          }
        }
        faces = Uint32List.fromList(f);
      } else {
        break; // unknown element after vertices: stop (we have what we need)
      }
    }
  } else if (format == 'ascii') {
    final lines = latin1.decode(bytes.sublist(hEnd)).split('\n');
    int li = 0;
    final idx = {for (int k = 0; k < names.length; k++) names[k]: k};
    for (final e in elems) {
      if (e.name == 'vertex') {
        int o = 0;
        for (int i = 0; i < n; i++, li++) {
          if (i % stride != 0) continue;
          final p = lines[li].trim().split(RegExp(r'\s+'));
          xyz[o * 3] = double.parse(p[idx['x']!]);
          xyz[o * 3 + 1] = double.parse(p[idx['y']!]);
          xyz[o * 3 + 2] = double.parse(p[idx['z']!]);
          if (rgb != null) {
            rgb[o * 3] = int.parse(p[idx['red']!]);
            rgb[o * 3 + 1] = int.parse(p[idx['green']!]);
            rgb[o * 3 + 2] = int.parse(p[idx['blue']!]);
          }
          if (conf != null) conf[o] = int.parse(p[idx['confidence']!]);
          o++;
        }
      } else if (e.name == 'face' && stride == 1) {
        final f = <int>[];
        for (int i = 0; i < e.count; i++, li++) {
          final p = lines[li].trim().split(RegExp(r'\s+')).map(int.parse).toList();
          for (int k = 2; k < p[0]; k++) {
            f.addAll([p[1], p[k], p[k + 1]]);
          }
        }
        faces = Uint32List.fromList(f);
      } else {
        li += e.count;
      }
    }
  } else {
    throw FormatException('unsupported PLY format $format');
  }
  return PointCloud(xyz, rgb: rgb, confidence: conf, faces: faces, comments: comments);
}

/// Binary little-endian PLY with x y z (float) and optional red green blue confidence (uchar).
Uint8List writePly(PointCloud pc, {List<String> comments = const []}) {
  final n = pc.length;
  final sb = StringBuffer('ply\nformat binary_little_endian 1.0\n');
  for (final c in comments) {
    sb.write('comment ${c.replaceAll('\n', ' ')}\n');
  }
  sb.write('element vertex $n\nproperty float x\nproperty float y\nproperty float z\n');
  if (pc.rgb != null) sb.write('property uchar red\nproperty uchar green\nproperty uchar blue\n');
  if (pc.confidence != null) sb.write('property uchar confidence\n');
  sb.write('end_header\n');
  final head = utf8.encode(sb.toString());
  final vsize = 12 + (pc.rgb != null ? 3 : 0) + (pc.confidence != null ? 1 : 0);
  final out = Uint8List(head.length + n * vsize);
  out.setRange(0, head.length, head);
  final bd = ByteData.sublistView(out);
  int off = head.length;
  for (int i = 0; i < n; i++) {
    bd.setFloat32(off, pc.xyz[i * 3], Endian.little);
    bd.setFloat32(off + 4, pc.xyz[i * 3 + 1], Endian.little);
    bd.setFloat32(off + 8, pc.xyz[i * 3 + 2], Endian.little);
    int o = off + 12;
    if (pc.rgb != null) {
      out[o] = pc.rgb![i * 3];
      out[o + 1] = pc.rgb![i * 3 + 1];
      out[o + 2] = pc.rgb![i * 3 + 2];
      o += 3;
    }
    if (pc.confidence != null) out[o] = pc.confidence![i];
    off += vsize;
  }
  return out;
}
