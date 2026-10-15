import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/main.dart';
import 'package:fooddiary/ui/server_configuration_page.dart';

const status = '{"data":{"authenticated":false,"auth_required":true}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('validates full URLs and normalizes trailing slashes', () {
    expect(
      Api.normalizeServerAddress(' https://food.example.com/ '),
      'https://food.example.com',
    );
    expect(
      Api.normalizeServerAddress('http://10.0.2.2:8080/kitchen/'),
      'http://10.0.2.2:8080/kitchen',
    );
    for (final value in [
      '',
      'food.example.com',
      'ftp://food.example.com',
      'https://user:password@food.example.com',
      'https://food.example.com?token=secret',
      'https://food.example.com/#test',
      'https://bad host.com',
    ]) {
      expect(() => Api.normalizeServerAddress(value), throwsFormatException);
    }
  });

  test(
    'checks new server anonymously, clears old tokens and restores address',
    () async {
      SharedPreferences.setMockInitialValues({
        'server_base_url': 'https://old.example.com',
      });
      FlutterSecureStorage.setMockInitialValues({
        'auth_tokens': jsonEncode({
          'access': 'old-access',
          'refresh': 'old-refresh',
        }),
      });
      final api = Api(
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://new.example.com/api/v1/auth/status',
          );
          expect(request.headers['Authorization'], isNull);
          expect(request.headers['X-FoodDiary-Client'], 'app');
          return http.Response(status, 200);
        }),
      );
      await api.init();
      expect(api.needsServerConfiguration, false);
      await api.configureServer(' https://new.example.com/ ');
      expect(api.base, 'https://new.example.com');
      expect(api.token, isEmpty);
      expect(api.refreshToken, isEmpty);
      expect(await api.secureStorage.read(key: 'auth_tokens'), isNull);
      final restarted = Api();
      await restarted.init();
      expect(restarted.base, api.base);
      expect(restarted.needsServerConfiguration, false);
    },
  );

  test(
    'failed connection does not replace saved address or credentials',
    () async {
      SharedPreferences.setMockInitialValues({
        'server_base_url': 'https://old.example.com',
      });
      final api = Api(
        client: MockClient(
          (_) async => http.Response('<html>Wrong server</html>', 200),
        ),
      );
      await api.init();
      api.token = 'existing-token';
      await expectLater(
        api.configureServer('https://wrong.example.com'),
        throwsFormatException,
      );
      expect(api.base, 'https://old.example.com');
      expect(api.prefs.getString('server_base_url'), api.base);
      expect(api.token, 'existing-token');
    },
  );

  test(
    'non-Android and mock modes bypass saved Android configuration',
    () async {
      SharedPreferences.setMockInitialValues({
        'server_base_url': 'https://android.example.com',
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final native = Api();
      await native.init();
      expect(native.canConfigureServer, false);
      expect(native.base, isNot('https://android.example.com'));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final mock = Api(mock: true);
      await mock.init();
      expect(mock.canConfigureServer, false);
      expect(mock.needsServerConfiguration, false);
      expect(mock.base, 'mock://local');
    },
  );

  testWidgets(
    'first launch waits for address, connects and offers reconfiguration',
    (tester) async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(status, 200);
      });
      final api = Api(client: client);
      await tester.pumpWidget(FoodDiaryApp(api: api));
      await tester.pumpAndSettle();
      expect(find.byType(ServerConfigurationPage), findsOneWidget);
      expect(requests, 0);
      await tester.enterText(find.byType(TextField), 'invalid');
      await tester.tap(find.text('连接并保存'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(api.needsServerConfiguration, true);
      await tester.enterText(
        find.byType(TextField),
        'https://food.example.com/',
      );
      await tester.tap(find.text('连接并保存'));
      await tester.pumpAndSettle();
      expect(find.text('进入小厨房'), findsOneWidget);
      expect(api.needsServerConfiguration, false);
      await tester.tap(find.text('修改后端地址'));
      await tester.pumpAndSettle();
      expect(find.byType(ServerConfigurationPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://food.example.com',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      final restarted = Api(client: client);
      await tester.pumpWidget(FoodDiaryApp(api: restarted));
      await tester.pumpAndSettle();
      expect(find.byType(ServerConfigurationPage), findsNothing);
      expect(find.text('进入小厨房'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
