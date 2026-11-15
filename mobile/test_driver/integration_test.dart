import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves screenshots from integration_test/app_test.dart into $FS_SHOTS (default build/screenshots).
Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
        final dir = Platform.environment['FS_SHOTS'] ?? 'build/screenshots';
        final f = File('$dir/$name.png');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
        return true;
      },
    );
