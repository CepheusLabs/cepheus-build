import 'package:cepheus_build_gui/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/forge.dart';

void main() {
  testWidgets('build console renders shell', (tester) async {
    await tester.pumpWidget(const CepheusBuildConsoleApp());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Cepheus Build'), findsOneWidget);
    expect(find.text('History'), findsWidgets);

    expect(
      tester
          .widget<ClNavPill>(find.widgetWithText(ClNavPill, 'Console'))
          .selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(ClNavPill, 'History'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      tester
          .widget<ClNavPill>(find.widgetWithText(ClNavPill, 'History'))
          .selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(ClNavPill, 'Console'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester
          .widget<ClNavPill>(find.widgetWithText(ClNavPill, 'Console'))
          .selected,
      isTrue,
    );
  });
}
