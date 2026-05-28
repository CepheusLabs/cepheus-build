import 'package:cepheus_build_gui/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('build console renders shell', (tester) async {
    await tester.pumpWidget(const CepheusBuildConsoleApp());
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Cepheus Build'), findsOneWidget);
    expect(find.text('Loading console'), findsOneWidget);
  });
}
