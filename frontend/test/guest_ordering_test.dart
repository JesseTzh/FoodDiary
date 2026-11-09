import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/ui/guest_ordering.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Api> seed() async {
    final api = Api(mock: true);
    await api.init();
    for (final entry in [('番茄炒蛋', '快手菜'), ('清炒时蔬', '素菜')]) {
      await api.request('POST', '/recipes', {
        'title': entry.$1,
        'category': '家常菜',
        'description': '',
        'tags': [entry.$2],
        'ingredients': <String>[],
        'steps': <String>[],
      });
    }
    return api;
  }

  test('share links resolve query and hash routes', () {
    expect(
      guestOrderToken(Uri.parse('https://food.example/#/?guest_order=abc')),
      'abc',
    );
    expect(
      guestOrderToken(Uri.parse('https://food.example/?guest_order=abc')),
      'abc',
    );
    expect(guestOrderToken(Uri.parse('https://food.example/')), isNull);
  });

  test(
    'guest orders persist across logout and retain original titles',
    () async {
      final api = await seed();
      final recipes = await api.request('GET', '/recipes') as List;
      final link = await api.request('POST', '/order-links', {'title': '周末聚餐'});
      final path = '/guest/order/${link['id']}';
      await api.logout();
      expect((await api.request('GET', path))['recipes'], hasLength(2));
      final body = {
        'request_id': 'guest-order-request-001',
        'guest_name': '小王',
        'note': '少盐',
        'items': [
          {'recipe_id': recipes.first['id'], 'quantity': 2},
        ],
      };
      final order = await api.request('POST', '$path/orders', body);
      final retry = await api.request('POST', '$path/orders', body);
      expect(retry['id'], order['id']);
      await api.request('POST', '/auth/login', {'password': 'mock123456'});
      await api.request('DELETE', '/recipes/${recipes.first['id']}');
      final restored = Api(mock: true);
      await restored.init();
      final links = await restored.request('GET', '/order-links') as List;
      expect(links.single['orders'], hasLength(1));
      expect(
        links.single['orders'].single['items'].single['title'],
        recipes.first['title'],
      );
    },
  );

  testWidgets('guest selects tags, adjusts cart and places an order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = await seed();
    final link = await api.request('POST', '/order-links', {'title': '周末聚餐'});
    await api.logout();
    await tester.pumpWidget(
      MaterialApp(
        home: GuestMenuPage(api: api, token: link['id']),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('番茄炒蛋'), findsOneWidget);
    expect(find.text('清炒时蔬'), findsOneWidget);
    await tester.tap(find.text('快手菜').first);
    await tester.pumpAndSettle();
    expect(find.text('清炒时蔬'), findsNothing);
    await tester.tap(find.byTooltip('添加一份'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加一份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('购物车 (2)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '小王');
    await tester.enterText(find.byType(TextField).at(1), '少盐');
    await tester.ensureVisible(find.text('下单 · 共 2 份'));
    await tester.tap(find.text('下单 · 共 2 份'));
    await tester.pumpAndSettle();
    expect(find.text('下单成功'), findsOneWidget);
    expect(find.text('× 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await api.request('POST', '/auth/login', {'password': 'mock123456'});
    await tester.pumpWidget(MaterialApp(home: GuestOrderRecordsPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('1 笔订单'), findsOneWidget);
    expect(find.text('备注：少盐'), findsOneWidget);
    expect(find.text('× 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('records create a link with one week as the default', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final api = await seed();
    await tester.pumpWidget(MaterialApp(home: GuestOrderRecordsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('创建点菜分享'));
    await tester.pumpAndSettle();
    expect(find.text('一周（默认）'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '朋友聚餐');
    await tester.tap(find.text('创建链接'));
    await tester.pumpAndSettle();
    final links = await api.request('GET', '/order-links') as List;
    expect(links.single['title'], '朋友聚餐');
    final remaining = DateTime.parse(links.single['expires_at'])
        .difference(DateTime.now());
    expect(remaining.inSeconds, closeTo(const Duration(days: 7).inSeconds, 10));
    expect(find.text('朋友聚餐'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
