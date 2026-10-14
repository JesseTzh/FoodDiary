import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final inset in [0.0, 24.0, 48.0]) {
    testWidgets('navigation clears gesture area with bottom inset $inset', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(bottom: inset);
      tester.view.viewPadding = FakeViewPadding(bottom: inset);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final api = Api(mock: true);
      await api.init();
      await tester.pumpWidget(MaterialApp(home: Kitchen(api: api)));
      await tester.pumpAndSettle();
      final nav = find.ancestor(
        of: find.text('首页'),
        matching: find.byType(InkWell),
      );
      expect(
        tester.getRect(nav).bottom,
        lessThanOrEqualTo(844 - (inset > 34 ? inset : 34)),
      );
      for (final label in ['日记', '菜谱', '我的', '首页']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
