// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import 'common.dart';

/// Dropdown of saved scans; reloads when the library changes.
class ScanPicker extends StatefulWidget {
  const ScanPicker({super.key, required this.selected, required this.onChanged, this.width = 380});
  final String? selected;
  final ValueChanged<String?> onChanged;
  final double width;

  @override
  State<ScanPicker> createState() => _ScanPickerState();
}

class _ScanPickerState extends State<ScanPicker> {
  List<ScanSummary> _scans = [];
  int _version = -1;

  Future<void> _load(AppState s) async {
    _version = s.scansVersion;
    try {
      final r = asMap(await s.api!.getJson('/api/scans'));
      if (mounted) setState(() => _scans = asList(r['scans']).map((e) => ScanSummary(asMap(e))).toList());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (_version != s.scansVersion && s.api != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(s));
      _version = s.scansVersion;
    }
    final ids = _scans.map((e) => e.id).toSet();
    return SizedBox(
      width: widget.width,
      child: DropdownButtonFormField<String>(
        initialValue: ids.contains(widget.selected) ? widget.selected : null,
        key: ValueKey('${widget.selected}-${_scans.length}'),
        isExpanded: true,
        hint: const Text('Choose a scan'),
        decoration: const InputDecoration(labelText: 'Scan'),
        items: [
          for (final sc in _scans)
            DropdownMenuItem(
              value: sc.id,
              child: Text(
                '${sc.title} (${shortId(sc.id)}), ${originLabel(sc.origin).toLowerCase()}${sc.status == 'complete' ? '' : ', ${sc.status}'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: widget.onChanged,
      ),
    );
  }
}
