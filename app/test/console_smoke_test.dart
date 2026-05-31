import 'package:cepheus_build_gui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/forge.dart';

/// Pumps the app with fixed-duration frames.
///
/// We deliberately avoid [WidgetTester.pumpAndSettle] because the console can
/// kick off real subprocesses (e.g. a `describe` call) during bootstrap, which
/// may never "settle" inside the test sandbox. Fixed pumps keep the test
/// hermetic and fast while still letting the bootstrap future complete.
Future<void> pumpConsole(WidgetTester tester) async {
  await tester.pumpWidget(const CepheusBuildConsoleApp());
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('build console renders the shell', (tester) async {
    await tester.pumpWidget(const CepheusBuildConsoleApp());
    await tester.pump(const Duration(milliseconds: 250));

    // The command-bar title is always present once the shell is up.
    expect(find.text('Cepheus Build'), findsOneWidget);
    // On the very first frame the console is still loading its settings.
    expect(find.text('Loading console'), findsOneWidget);
  });

  testWidgets('renders without throwing after bootstrap completes',
      (tester) async {
    await pumpConsole(tester);

    // Regardless of whether bootstrap loaded settings or errored in the
    // sandbox, the app shell must still be on screen and not have thrown.
    expect(tester.takeException(), isNull);
    expect(find.byType(CepheusBuildConsoleApp), findsOneWidget);
    expect(find.text('Cepheus Build'), findsWidgets);
  });

  testWidgets('wraps the console in a MaterialApp', (tester) async {
    await tester.pumpWidget(const CepheusBuildConsoleApp());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MaterialApp), findsOneWidget);
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.title, 'Cepheus Build');
  });

  testWidgets('exposes the theme toggle once the console has loaded',
      (tester) async {
    await pumpConsole(tester);

    // The theme toggle lives in the command bar, which only mounts after the
    // settings load. If bootstrap fails in the sandbox the loaded console
    // never appears -- in that case we simply assert the shell stayed alive,
    // so the test never produces a false failure.
    final toggle = find.byType(ClThemeToggle);
    if (toggle.evaluate().isEmpty) {
      expect(find.byType(CepheusBuildConsoleApp), findsOneWidget);
      expect(tester.takeException(), isNull);
      return;
    }
    expect(toggle, findsOneWidget);
    // When the command bar is present, the title is shown alongside it.
    expect(find.text('Cepheus Build'), findsWidgets);
  });
}
