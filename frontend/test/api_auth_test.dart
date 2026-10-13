import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fooddiary/data/api.dart';

String accessToken(int offset) {
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + offset,
      }),
    ),
  );
  return 'header.$payload.signature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'session': 'old-plaintext-token'});
    FlutterSecureStorage.setMockInitialValues({
      'auth_tokens': jsonEncode({
        'access': accessToken(900),
        'refresh': 'refresh-original',
      }),
    });
  });

  test(
    'concurrent unauthorized requests share one refresh and retry',
    () async {
      var refreshes = 0;
      var initialRequests = 0;
      final renewed = accessToken(1000);
      final client = MockClient((req) async {
        expect(req.headers['X-FoodDiary-Client'], 'app');
        if (req.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          expect(req.headers['Authorization'], 'Bearer refresh-original');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return http.Response(
            '{"data":{"ok":true}}',
            200,
            headers: {
              'x-session-token': renewed,
              'x-refresh-token': 'refresh-next',
            },
          );
        }
        if (req.headers['Authorization'] != 'Bearer $renewed') {
          initialRequests++;
          return http.Response('{"error":{"message":"expired"}}', 401);
        }
        return http.Response('{"data":[]}', 200);
      });
      final api = Api(client: client);
      await api.init();
      expect(api.prefs.containsKey('session'), false);
      await Future.wait([
        api.request('GET', '/entries'),
        api.request('GET', '/stats'),
      ]);
      expect(initialRequests, 2);
      expect(refreshes, 1);
      expect(api.token, renewed);
      expect(
        jsonDecode((await api.secureStorage.read(key: 'auth_tokens'))!)['refresh'],
        'refresh-next',
      );
    },
  );

  test('expired native access refreshes before protected requests', () async {
    FlutterSecureStorage.setMockInitialValues({
      'auth_tokens': jsonEncode({
        'access': accessToken(-60),
        'refresh': 'refresh-original',
      }),
    });
    final paths = <String>[];
    final client = MockClient((req) async {
      paths.add(req.url.path);
      if (req.url.path.endsWith('/auth/refresh')) {
        return http.Response(
          '{"data":{"ok":true}}',
          200,
          headers: {
            'x-session-token': accessToken(900),
            'x-refresh-token': 'refresh-next',
          },
        );
      }
      return http.Response('{"data":[]}', 200);
    });
    final api = Api(client: client);
    await api.init();
    await api.request('GET', '/entries');
    expect(paths, ['/api/v1/auth/refresh', '/api/v1/entries']);
  });

  test(
    'rejected refresh clears secure credentials and stops retrying',
    () async {
      var refreshes = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh')) refreshes++;
        return http.Response('{"error":{"message":"expired"}}', 401);
      });
      final api = Api(client: client);
      await api.init();
      await expectLater(
        api.request('GET', '/entries'),
        throwsA(isA<ApiError>()),
      );
      expect(refreshes, 1);
      expect(api.token, '');
      expect(api.refreshToken, '');
      expect(await api.secureStorage.read(key: 'access_token'), isNull);
      expect(await api.secureStorage.read(key: 'auth_tokens'), isNull);
    },
  );

  test('logout sends refresh credential and clears secure storage', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/api/v1/auth/logout');
      expect(req.headers['Authorization'], 'Bearer refresh-original');
      return http.Response('{"data":{"ok":true}}', 200);
    });
    final api = Api(client: client);
    await api.init();
    await api.logout();
    expect(api.token, '');
    expect(await api.secureStorage.read(key: 'auth_tokens'), isNull);
  });
}
