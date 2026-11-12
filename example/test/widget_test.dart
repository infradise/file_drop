import 'package:file_drop_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FileDropExampleApp renders dialog buttons and drop zones', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FileDropExampleApp());

    expect(find.text('Open File'), findsOneWidget);
    expect(find.text('Open Multiple'), findsOneWidget);
    expect(find.text('Save File'), findsOneWidget);
    expect(find.text('Save Location'), findsOneWidget);
    expect(find.text('Pick Directory'), findsOneWidget);
    expect(find.text('Open Directory'), findsOneWidget);
    expect(find.text('Clear Temp'), findsOneWidget);
    expect(find.text('Drop Zone A (Always Enabled)'), findsOneWidget);
    expect(find.text('Drop Zone B (Toggleable)'), findsOneWidget);
  });
}
