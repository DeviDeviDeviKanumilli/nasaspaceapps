// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:convert';
import 'dart:io';

/// Small OS integrations without plugins: a native file picker and "show in file manager".
class Desktop {
  static String get fileManager => Platform.isWindows ? 'Explorer' : (Platform.isMacOS ? 'Finder' : 'file manager');

  /// Native open-file dialog limited to [extensions] (without dots). Returns null if cancelled or unavailable.
  static Future<String?> pickFile({required String prompt, required List<String> extensions, String? description}) async {
    try {
      if (Platform.isMacOS) {
        // Finder matches .zip by its UTI as well as by extension; keep both so zips stay selectable.
        final types = [...extensions, if (extensions.contains('zip')) 'public.zip-archive'].map((e) => '"$e"').join(', ');
        final r = await Process.run('osascript', ['-e', 'POSIX path of (choose file with prompt "$prompt" of type {$types})']);
        return r.exitCode == 0 ? _clean(r.stdout) : null;
      }
      if (Platform.isWindows) {
        final pattern = extensions.map((e) => '*.$e').join(';');
        final desc = (description ?? prompt).replaceAll("'", "''").replaceAll('|', ' ');
        final script = [
          // UTF-8 out, read as UTF-8 below, so paths with accents or non-Latin names come back intact.
          r'[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
          r'Add-Type -AssemblyName System.Windows.Forms',
          r'$owner = New-Object System.Windows.Forms.Form -Property @{TopMost = $true; ShowInTaskbar = $false}',
          r'$d = New-Object System.Windows.Forms.OpenFileDialog',
          "\$d.Title = '${prompt.replaceAll("'", "''")}'",
          "\$d.Filter = '$desc ($pattern)|$pattern'",
          r'$d.Multiselect = $false',
          r'if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.FileName) }',
        ].join('; ');
        final r = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-Command', script], stdoutEncoding: utf8);
        return r.exitCode == 0 ? _clean(r.stdout) : null;
      }
      final r = await Process.run('zenity', [
        '--file-selection',
        '--title=$prompt',
        '--file-filter=${description ?? 'Files'} | ${extensions.map((e) => '*.$e').join(' ')}',
      ]);
      return r.exitCode == 0 ? _clean(r.stdout) : null;
    } catch (_) {
      return null;
    }
  }

  /// Opens the system file manager with [path] selected (or the folder itself, if [path] is a folder).
  static Future<void> reveal(String path) async {
    try {
      if (Platform.isWindows) {
        final win = path.replaceAll('/', r'\');
        if (FileSystemEntity.isDirectorySync(win)) {
          await Process.run('explorer.exe', [win]);
        } else {
          await Process.run('explorer.exe', ['/select,', win]);
        }
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [FileSystemEntity.isDirectorySync(path) ? path : File(path).parent.path]);
      }
    } catch (_) {}
  }

  static String? _clean(Object? out) {
    final s = '$out'.trim();
    return s.isEmpty ? null : s;
  }
}
