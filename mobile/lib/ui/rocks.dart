// Rock illustrations, drawn as small SVGs. Used sparingly: empty states, rig mode, saving and errors get the
// "Pebble" character; everything else uses plain rock shapes. Outlines are computed per render size so every
// rock has the same 2–2.5 px line whatever its size.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'style.dart';

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

const _outline = '#3A3833';
const _eye = '#2B2A27';
const _body = 'M12 62 C 6 44, 18 22, 40 16 C 58 11, 80 18, 88 36 C 96 54, 86 70, 64 72 C 44 74, 18 74, 12 62 Z';

enum PebbleMood { calm, sleeping, worried }

/// The app's rock character. Keep it to empty states and moments where the screen is otherwise blank.
class Pebble extends StatelessWidget {
  final double width;
  final PebbleMood mood;
  final Color fill;
  final String? semanticLabel;
  const Pebble({super.key, this.width = 120, this.mood = PebbleMood.calm, this.fill = Fs.stone, this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final sw = 2.5 * 100 / width; // 2.5 px on screen
    final f = switch (mood) {
      PebbleMood.calm => '<circle cx="42" cy="46" r="3.4" fill="$_eye"/><circle cx="62" cy="46" r="3.4" fill="$_eye"/>'
          '<path d="M48 55 Q 52 58 56 55" stroke="$_eye" stroke-width="2" fill="none" stroke-linecap="round"/>',
      PebbleMood.sleeping => '<path d="M37 46 Q 42 50 47 46 M57 46 Q 62 50 67 46" stroke="$_eye" stroke-width="2.2" fill="none" stroke-linecap="round"/>'
          '<path d="M48 56 Q 52 58 56 56" stroke="$_eye" stroke-width="2" fill="none" stroke-linecap="round"/>',
      PebbleMood.worried => '<path d="M36 38 L 46 41 M68 38 L 58 41" stroke="$_eye" stroke-width="2" stroke-linecap="round"/>'
          '<circle cx="42" cy="47" r="3.4" fill="$_eye"/><circle cx="62" cy="47" r="3.4" fill="$_eye"/>'
          '<path d="M47 58 Q 52 54 57 58" stroke="$_eye" stroke-width="2" fill="none" stroke-linecap="round"/>',
    };
    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 80">'
        '<path d="$_body" fill="${_hex(fill)}" stroke="$_outline" stroke-width="$sw"/>'
        '<path d="M30 28 C 38 22, 50 20, 58 22" stroke="#FFFFFF" stroke-width="4" stroke-linecap="round" fill="none" opacity="0.5"/>'
        '<ellipse cx="35" cy="54" rx="5" ry="3" fill="#EE9C93" opacity="0.45"/><ellipse cx="69" cy="54" rx="5" ry="3" fill="#EE9C93" opacity="0.45"/>'
        '$f</svg>';
    return SvgPicture.string(svg, width: width, height: width * 0.8, semanticsLabel: semanticLabel, excludeFromSemantics: semanticLabel == null);
  }
}

/// Plain rock shapes (no faces) for each feature type the user can pick.
class RockIcon extends StatelessWidget {
  final String kind; // featureTypes key
  final double width;
  const RockIcon(this.kind, {super.key, this.width = 40});

  @override
  Widget build(BuildContext context) {
    final sw = 2 * 100 / width;
    String s(String d, Color c) => '<path d="$d" fill="${_hex(c)}" stroke="$_outline" stroke-width="$sw" stroke-linejoin="round"/>';
    String e(double cx, double cy, double rx, double ry, Color c) =>
        '<ellipse cx="$cx" cy="$cy" rx="$rx" ry="$ry" fill="${_hex(c)}" stroke="$_outline" stroke-width="$sw"/>';
    final body = switch (kind) {
      'boulder' => [
          s('M12 70 C 6 52, 18 30, 40 24 C 58 19, 80 26, 88 44 C 96 62, 86 76, 64 77 C 44 78, 18 78, 12 70 Z', Fs.stone),
          '<path d="M30 36 C 38 30, 50 28, 58 30" stroke="#FFFFFF" stroke-width="4" stroke-linecap="round" fill="none" opacity="0.5"/>',
        ],
      'rock_face' => [
          s('M20 78 L 24 22 C 26 12, 44 8, 62 10 L 78 14 C 86 16, 86 26, 84 36 L 82 78 Z', Fs.slate),
          '<path d="M24 40 L 84 44 M23 60 L 83 62" stroke="#7C858D" stroke-width="3"/>',
        ],
      'outcrop' => [
          '<path d="M4 76 H 96" stroke="#5E8C4E" stroke-width="$sw" stroke-linecap="round"/>',
          s('M16 76 C 20 52, 38 34, 58 36 C 78 38, 86 56, 84 76 Z', Fs.clay),
        ],
      'boulder_field' => [e(26, 62, 20, 15, Fs.stone), e(72, 60, 23, 17, Fs.slate), e(50, 32, 15, 12, Fs.clay)],
      'ground' => [
          s('M4 60 C 30 54, 70 54, 96 60 L 96 78 L 4 78 Z', Fs.sand),
          '<ellipse cx="34" cy="64" rx="7" ry="4" fill="#9C978C"/><ellipse cx="62" cy="68" rx="5" ry="3.5" fill="#9C978C"/><ellipse cx="78" cy="62" rx="4" ry="3" fill="#9C978C"/>',
        ],
      _ => [e(50, 56, 30, 20, Fs.stone), '<path d="M44 52 L 56 52 M50 46 L 50 58" stroke="$_outline" stroke-width="3" stroke-linecap="round"/>'],
    }.join();
    return SvgPicture.string('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 80">$body</svg>', width: width, height: width * 0.8, excludeFromSemantics: true);
  }
}

Color rockColorFor(String featureType) => switch (featureType) {
      'rock_face' => Fs.slate,
      'outcrop' || 'boulder_field' => Fs.clay,
      'ground' => Fs.sand,
      _ => Fs.stone,
    };

/// Laptop with the phone clamped on the back of the lid, cameras looking at a rock.
class RigDrawing extends StatelessWidget {
  final double width;
  const RigDrawing({super.key, this.width = 120});
  @override
  Widget build(BuildContext context) {
    final sw = 2.2 * 80 / width;
    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 50">'
        '<path d="M4 46 H 36" stroke="$_outline" stroke-width="$sw" stroke-linecap="round"/>'
        '<path d="M8 46 L 18 8 L 23 8 L 13 46 Z" fill="#FFFFFF" stroke="$_outline" stroke-width="$sw" stroke-linejoin="round"/>'
        '<rect x="22" y="14" width="7" height="16" rx="2" fill="${_hex(Fs.moss)}"/>'
        '<path d="M31 22 H 46" stroke="${_hex(Fs.moss)}" stroke-width="$sw" stroke-dasharray="3 3" stroke-linecap="round"/>'
        '<ellipse cx="62" cy="40" rx="14" ry="8" fill="${_hex(Fs.stone)}" stroke="$_outline" stroke-width="$sw"/>'
        '</svg>';
    return SvgPicture.string(svg, width: width, height: width * 50 / 80, excludeFromSemantics: true);
  }
}

/// Phone held by hand, walking an arc around a rock.
class HandheldDrawing extends StatelessWidget {
  final double width;
  const HandheldDrawing({super.key, this.width = 120});
  @override
  Widget build(BuildContext context) {
    final sw = 2.2 * 80 / width;
    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 50">'
        '<rect x="8" y="8" width="18" height="32" rx="4" fill="#FFFFFF" stroke="$_outline" stroke-width="$sw"/>'
        '<path d="M30 16 C 50 2, 78 12, 76 30" stroke="#8F9488" stroke-width="$sw" stroke-dasharray="3 4" fill="none" stroke-linecap="round"/>'
        '<ellipse cx="58" cy="40" rx="14" ry="8" fill="${_hex(Fs.stone)}" stroke="$_outline" stroke-width="$sw"/>'
        '</svg>';
    return SvgPicture.string(svg, width: width, height: width * 50 / 80, excludeFromSemantics: true);
  }
}

/// Explore empty state: a rock under the Moon and Mars.
class SkyScene extends StatelessWidget {
  final double width;
  const SkyScene({super.key, this.width = 240});
  @override
  Widget build(BuildContext context) {
    final sw = 2.2 * 260 / width;
    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 260 120">'
        '<circle cx="34" cy="34" r="20" fill="#ECE9E0" stroke="$_outline" stroke-width="$sw"/>'
        '<circle cx="27" cy="29" r="4" fill="#D6D2C6"/><circle cx="41" cy="40" r="5" fill="#D6D2C6"/>'
        '<circle cx="222" cy="28" r="12" fill="#D9825B" stroke="$_outline" stroke-width="$sw"/>'
        '<circle cx="130" cy="14" r="2" fill="#B8BDB0"/><circle cx="232" cy="66" r="2" fill="#B8BDB0"/><circle cx="26" cy="74" r="2" fill="#B8BDB0"/>'
        '<path d="M30 112 H 230" stroke="$_outline" stroke-width="$sw" stroke-linecap="round"/>'
        '</svg>';
    return SvgPicture.string(svg, width: width, height: width * 120 / 260, excludeFromSemantics: true);
  }
}
