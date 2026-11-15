// End-to-end UI test on the iOS simulator (no camera, LiDAR, ARKit or Bluetooth there).
// Run: flutter drive --driver=test_driver/integration_test.dart --target=integration_test/app_test.dart -d <simulator id>
// Screenshots go to $FS_SHOTS (default build/screenshots). Uses the SYNTHETIC fixture, never real data.
import 'dart:convert';
import 'dart:io';

import 'package:field_scan/core/app_state.dart';
import 'package:field_scan/core/scan_record.dart';
import 'package:field_scan/main.dart' as app;
import 'package:field_scan/screens/capture_screen.dart';
import 'package:field_scan/widgets/cloud_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester t, [int ms = 600]) async {
    for (int i = 0; i < ms ~/ 50; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester t, Finder f, {int seconds = 20}) async {
    for (int i = 0; i < seconds * 10; i++) {
      if (f.evaluate().isNotEmpty) return;
      await t.pump(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for $f');
  }

  Future<void> shot(String name) async {
    await binding.takeScreenshot(name);
  }

  Future<void> tab(WidgetTester t, String label) async {
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await wait(t);
  }

  Future<void> tapVisible(WidgetTester t, Finder f) async {
    // lazily built list rows: scroll the visible page until the target exists
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    for (int i = 0; i < 20 && f.evaluate().isEmpty; i++) {
      await t.dragFrom(Offset(size.width / 2, size.height * 0.75), const Offset(0, -250));
      await wait(t, 300);
    }
    await t.ensureVisible(f);
    await wait(t, 300);
    await t.tap(f);
    await wait(t);
  }

  Future<void> label(WidgetTester t, String text) async {
    final field = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await until(t, field);
    await t.enterText(field, text);
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Save')));
    await wait(t, 800);
  }

  Future<ScanRecord> reload(String id) async {
    await AppState.I.refresh();
    return AppState.I.scans.firstWhere((s) => s.id == id);
  }

  testWidgets('Field Scan on the simulator', (t) async {
    // start as a first launch so the two-page intro shows
    final docs = await getApplicationDocumentsDirectory();
    final settings = File('${docs.path}/settings.json');
    if (settings.existsSync()) {
      final j = jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      settings.writeAsStringSync(jsonEncode({...j, 'introSeen': false}));
    }
    app.main();

    // 0. intro: two pages, then the tabs; remembered afterwards
    await until(t, find.text('Measure rocks in 3D'));
    await wait(t, 800);
    await shot('00_intro_1');
    await t.tap(find.widgetWithText(FilledButton, 'Next'));
    await until(t, find.text('Private by default'));
    await wait(t, 800);
    await shot('00_intro_2');
    await t.tap(find.widgetWithText(FilledButton, 'Get started'));
    await until(t, find.byType(NavigationBar));
    expect(AppState.I.introSeen, isTrue);
    await wait(t, 1000); // let the fade into the tabs finish
    final scansDir = AppState.I.library.root;
    if (scansDir.existsSync()) scansDir.deleteSync(recursive: true);
    await AppState.I.refresh();
    await wait(t);

    // 1. Scan tab: the simulator has no ARKit, the app must say so instead of crashing
    expect(find.textContaining('ARKit is not available on iOS Simulator'), findsOneWidget);
    await shot('01_scan_tab_no_arkit');

    // 2. a crashed capture (keyframes but no scan.json) is recovered as incomplete
    final crash = AppState.I.library.newScanDir('crash-test')..createSync(recursive: true);
    File('${crash.path}/keyframes.jsonl').writeAsStringSync('{"type":"keyframe","index":1}\n');
    // 3. Settings: add two SYNTHETIC scans
    await tab(t, 'Settings');
    expect(find.textContaining('ARKit world tracking'), findsOneWidget);
    await shot('02_settings');
    final add = find.text('Add a SYNTHETIC test scan');
    await tapVisible(t, add);
    await tapVisible(t, add);
    await wait(t, 1000);

    // 4. Library lists both fixtures and the recovered scan
    await tab(t, 'Library');
    await until(t, find.text('incomplete'));
    expect(find.text('synthetic fixture'), findsNWidgets(2));
    await shot('03_library');

    final ids = <String>[];
    for (int k = 0; k < 2; k++) {
      // open the k-th synthetic scan
      await t.tap(find.text('SYNTHETIC boulder (test fixture)').at(k));
      await until(t, find.byType(CloudViewer));
      await until(t, find.textContaining('shown'));
      await wait(t, 1500);
      final viewer = find.byType(CloudViewer);
      final c = t.getCenter(viewer);
      if (k == 0) await shot('04_detail_viewer');

      // orbit gesture must not throw
      await t.dragFrom(c, const Offset(60, 20));
      await wait(t, 800);

      // 5. distance between two tapped points
      await t.tap(find.text('Distance'));
      await wait(t);
      await t.tapAt(c + const Offset(-90, 30));
      await wait(t, 700);
      await t.tapAt(c + const Offset(90, 30));
      await wait(t, 700);
      expect(find.textContaining(' cm'), findsWidgets);
      if (k == 0) await shot('05_distance');
      await t.tap(find.widgetWithText(FilledButton, 'Save'));
      await wait(t);
      await label(t, 'pole check');

      // 6. surface ROI plane fit
      await t.tap(find.text('Surface'));
      await wait(t);
      await t.tapAt(c + const Offset(0, -10));
      await wait(t, 900);
      await until(t, find.text('Roughness (RMS of plane residuals)'));
      if (k == 0) await shot('06_surface_fit');
      await tapVisible(t, find.widgetWithText(FilledButton, 'Save'));
      await label(t, 'boulder top');

      final r = AppState.I.scans.where((s) => s.synthetic).elementAt(k);
      ids.add(r.id);
      final saved = jsonDecode(File('${r.dir.path}/scan.json').readAsStringSync()) as Map<String, dynamic>;
      final names = [for (final m in saved['measurements'] as List) '${m['label']}/${m['name']}'];
      expect(names, containsAll(['pole check/distance', 'boulder top/plane_fit_roughness', 'boulder top/plane_tilt_from_horizontal']));
      final d = (saved['measurements'] as List).firstWhere((m) => m['name'] == 'distance');
      expect((d['value'] as num) > 0.05 && (d['value'] as num) < 3, isTrue, reason: 'distance ${d['value']} m');

      // 7. SHA-256 verification
      await tapVisible(t, find.text('Verify SHA-256'));
      await until(t, find.textContaining('files match their hashes'));
      if (k == 0) await shot('07_verify');

      // 8. contribution draft (first scan only)
      if (k == 0) {
        await tapVisible(t, find.text('Prepare contribution'));
        await until(t, find.text('Prepare contribution'));
        await until(t, find.text('Location'));
        await t.tap(find.text('No'));
        await wait(t, 300);
        final credit = find.widgetWithText(TextField, 'Credit as');
        await tapVisible(t, credit); // lower in the form: scroll it into view first
        await t.enterText(credit, 'Team Vancomycin');
        await wait(t, 300);
        await shot('08_contribute');
        await tapVisible(t, find.textContaining('I made this scan'));
        await tapVisible(t, find.textContaining('I agree to submit'));
        await tapVisible(t, find.text('Save draft on this phone'));
        await wait(t, 1200);
        final rr = await reload(r.id);
        expect(rr.publication, 'draft_local');
        expect(rr.has('catalog_draft.json'), isTrue);
        final draft = jsonDecode(rr.file('catalog_draft.json').readAsStringSync());
        expect(draft['status'], 'draft_local');
        expect(draft['location_precision'], 'hidden');
      }
      // back to the library
      await t.pageBack();
      await wait(t, 800);
    }

    // 9. repeat-scan comparison groups the same labels across the two scans
    await AppState.I.refresh();
    await wait(t);
    await t.tap(find.widgetWithText(OutlinedButton, 'Compare'));
    await until(t, find.textContaining('n = 2'));
    await wait(t, 1000); // let the page transition finish
    expect(find.textContaining('± 0.0 mm SD'), findsWidgets); // identical fixtures, identical taps
    await shot('09_compare');
    await t.pageBack();
    await wait(t);

    // 10. Explore and Connect render; Bluetooth search fails gracefully on the simulator
    await tab(t, 'Explore');
    expect(find.text('No public catalog yet'), findsOneWidget);
    await shot('10_explore');
    await tab(t, 'Connect');
    await t.tap(find.text('Find Field Station'));
    await until(t, find.textContaining('Bluetooth'), seconds: 8);
    await wait(t, 3500);
    expect(find.textContaining('PlatformException'), findsNothing);
    await shot('11_connect');

    // 11. capture screen error path: no AR session on the simulator -> clear message, no crash
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute(builder: (_) => CaptureScreen(setup: ScanSetup(title: 'Sim test'))));
    await until(t, find.text('Start'));
    await wait(t, 800);
    await t.tap(find.widgetWithText(FilledButton, 'Start'));
    await until(t, find.textContaining('Could not start'));
    expect(find.byType(UiKitView), findsNothing); // no camera view without ARKit
    await shot('12_capture_error');
    await t.tap(find.byTooltip('Close'));
    await wait(t, 800);
  });
}
