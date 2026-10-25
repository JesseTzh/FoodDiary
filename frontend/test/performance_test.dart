import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/data/mock_store.dart';
import 'package:fooddiary/main.dart';
import 'package:fooddiary/ui/pages.dart';
import 'package:fooddiary/ui/theme.dart';

class CountingApi extends Api {
  CountingApi() : super(mock: true);
  final reads = <String>[];

  @override
  Future<dynamic> request(String method, String path, [Object? body]) {
    if (method == 'GET') reads.add(path);
    return super.request(method, path, body);
  }
}

Future<CountingApi> seed(int count) async {
  SharedPreferences.setMockInitialValues({
    MockStore.storageKey: jsonEncode({
      'seed_version': 2,
      'next_id': 1000,
      'authenticated': true,
      'profile': {'name': '厨师', 'bio': ''},
      'entries': List.generate(
        count,
        (i) => {
          'id': 'entry-$i',
          'title': '日记$i',
          'cooked_on': '2026-10-23',
          'media': [],
        },
      ),
      'recipes': List.generate(
        count,
        (i) => {
          'id': 'recipe-$i',
          'title': '菜品$i',
          'category': '家常菜',
          'description': '',
          'image': '',
          'ingredients': ['鸡蛋'],
          'steps': ['炒熟'],
          'favorite': false,
          'custom': true,
          'photos': [],
        },
      ),
    }),
  });
  final api = CountingApi();
  await api.init();
  return api;
}

void main() {
  testWidgets('large lists build only nearby cards and remain searchable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = await seed(200);
    await tester.pumpWidget(MaterialApp(home: Kitchen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日记').last);
    await tester.pumpAndSettle();
    final cards = find.byWidgetPredicate(
      (w) => w is TestId && w.value == 'diary-entry',
    );
    expect(cards.evaluate().length, inExclusiveRange(0, 20));
    expect(find.text('日记199'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('日记199'),
      700,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('日记199'), findsOneWidget);
    expect(cards.evaluate().length, lessThan(20));
    await tester.tap(find.text('菜谱').last);
    await tester.pumpAndSettle();
    expect(find.byType(DishPhoto).evaluate().length, inExclusiveRange(0, 30));
    expect(find.text('菜品199'), findsNothing);
    await tester.enterText(find.byType(TextField), '菜品199');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Text && w.data == '菜品199'),
      findsOneWidget,
    );
    expect(find.text('菜品0'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reading and cancelling edits skips refresh; writes refresh', (
    tester,
  ) async {
    final api = await seed(1);
    await tester.pumpWidget(MaterialApp(home: Kitchen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日记').last);
    await tester.pumpAndSettle();
    api.reads.clear();
    await tester.tap(find.text('日记0'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(api.reads, isEmpty);
    await tester.tap(find.text('日记0'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('编辑'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordPage), findsOneWidget);
    api.reads.clear();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(api.reads, isEmpty);
    await tester.tap(find.byTooltip('收藏日记'));
    await tester.pumpAndSettle();
    api.reads.clear();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(api.reads, containsAll(['/entries', '/recipes', '/profile']));
    final entries = await api.request('GET', '/entries');
    expect(entries['items'].single['favorite'], true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('reads and failed writes do not mark data as changed', () async {
    final api = await seed(1);
    await api.request('GET', '/entries');
    expect(api.dataRevision, 0);
    await expectLater(
      api.request('DELETE', '/recipes/missing'),
      throwsA(isA<ApiError>()),
    );
    expect(api.dataRevision, 0);
    await api.request('PATCH', '/recipes/recipe-0/favorite', {
      'favorite': true,
    });
    expect(api.dataRevision, 1);
  });
}
