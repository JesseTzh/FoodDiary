import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<Api> mockApi() async {
    final api = Api(
      mock: true,
      client: MockClient(
        (_) async => throw StateError('Mock must never use HTTP'),
      ),
    );
    await api.init();
    return api;
  }

  test('mock supports persistent CRUD, photos, favorites, recipes, profile and groceries', () async {
    final api = await mockApi();
    final initial = await api.request('GET', '/entries');
    expect(initial['total'], 3);
    final body = {
      'title': '测试晚餐',
      'cooked_on': '2026-10-14',
      'notes': '',
      'mood': 0,
      'tags': ['晚餐'],
    };
    final entry = await api.request('POST', '/entries', body);
    final id = entry['id'];
    final edited = await api.request('PATCH', '/entries/$id', {
      ...body,
      'title': '修改晚餐',
      'version': 1,
    });
    expect(edited['version'], 2);
    await expectLater(
      api.request('PATCH', '/entries/$id', {...body, 'version': 1}),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 409)),
    );
    await api.upload(
      id,
      XFile.fromData(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
        ),
        name: 'photo.png',
      ),
    );
    await api.request('PATCH', '/entries/$id/favorite', {'favorite': true});
    final reloaded = await mockApi();
    final detail = await reloaded.request('GET', '/entries/$id');
    expect(detail['media'].single['url'], startsWith('data:image/png;base64,'));
    expect(detail['favorite'], true);
    expect(
      (await api.request('GET', '/entries?q=修改&favorite=true'))['total'],
      1,
    );
    final recipe = await api.request('POST', '/recipes', {
      'title': '自制汤',
      'category': '汤类',
      'description': '',
      'ingredients': ['水'],
      'steps': ['煮开'],
    });
    await api.request('PATCH', '/recipes/${recipe['id']}/favorite', {
      'favorite': true,
    });
    final profile = await api.request('PATCH', '/profile', {
      'name': '测试厨师',
      'bio': '你好',
    });
    expect(profile['recipe_count'], 1);
    expect(profile['favorite_count'], 2);
    final grocery = await api.request('POST', '/groceries', {'name': '豆腐'});
    await api.request('PATCH', '/groceries/${grocery['id']}', {
      'checked': true,
    });
    expect((await api.request('GET', '/groceries')).first['checked'], true);
    await api.request('DELETE', '/groceries/${grocery['id']}');
    await api.request('DELETE', '/entries/$id');
    await expectLater(
      api.request('GET', '/entries/$id'),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)),
    );
  });
  test(
    'mock logout and login remain isolated from production credentials',
    () async {
      final api = await mockApi();
      await api.prefs.setString('session', 'real-session');
      await api.logout();
      expect(
        (await api.request('GET', '/auth/status'))['authenticated'],
        false,
      );
      await expectLater(
        api.request('GET', '/recipes'),
        throwsA(isA<ApiError>()),
      );
      await expectLater(
        api.request('POST', '/auth/login', {'password': 'wrong'}),
        throwsA(isA<ApiError>()),
      );
      await api.request('POST', '/auth/login', {'password': 'mock123456'});
      expect((await api.request('GET', '/auth/status'))['authenticated'], true);
      expect(api.prefs.getString('session'), 'real-session');
    },
  );
}
