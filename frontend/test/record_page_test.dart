import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/data/models.dart';
import 'package:fooddiary/ui/pages.dart';
import 'package:fooddiary/ui/theme.dart';

void main() {
  testWidgets('custom tag input opens on plus and closes after adding', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = Api(mock: true);
    await api.init();
    final entry = Diary({
      'id': 'test-entry',
      'title': '测试晚餐',
      'cooked_on': '2026-10-14',
      'notes': '',
      'category': '家常菜',
      'tags': <String>[],
      'media': <dynamic>[],
      'dishes': [
        {'id': 'dish-1', 'title': '测试晚餐'},
      ],
      'mood': 0,
      'version': 1,
      'rating': 0,
      'favorite': false,
    });
    await tester.pumpWidget(
      MaterialApp(home: RecordPage(api: api, entry: entry)),
    );
    await tester.pumpAndSettle();
    final input = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '添加自定义标签',
    );
    expect(input, findsNothing);
    final plus = find.widgetWithText(Tag, '+');
    await tester.ensureVisible(plus);
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);
    await tester.enterText(input, '少油');
    await tester.ensureVisible(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    final tag = tester.widget<Tag>(find.widgetWithText(Tag, '少油'));
    expect(tag.selected, true);
    expect(tester.takeException(), isNull);
  });
}
