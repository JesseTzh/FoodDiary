import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/data/mock_store.dart';

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

  test(
    'upgrading mock presets preserves personal recipes and diary records',
    () async {
      SharedPreferences.setMockInitialValues({
        MockStore.storageKey: jsonEncode({
          'next_id': 101,
          'authenticated': true,
          'profile': {'name': '厨师', 'bio': ''},
          'entries': [
            {
              'id': 'entry-0',
              'media': [
                {'url': 'asset:assets/images/tomato.png'},
                {'url': 'data:image/png;base64,personal'},
              ],
            },
          ],
          'recipes': [
            {'id': 'tomato', 'custom': false},
            {'id': 'personal', 'custom': true},
          ],
        }),
      });
      final store = MockStore(await SharedPreferences.getInstance());
      expect(store.recipes.single['id'], 'personal');
      expect(store.entries.single['id'], 'entry-0');
      expect(
        store.entries.single['media'].single['url'],
        'data:image/png;base64,personal',
      );
    },
  );

  test(
    'mock supports persistent CRUD, photos, favorites, recipes and profile',
    () async {
      final api = await mockApi();
      final initial = await api.request('GET', '/entries');
      expect(initial['total'], 0);
      expect(await api.request('GET', '/recipes'), isEmpty);
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
      expect(
        detail['media'].single['url'],
        startsWith('data:image/png;base64,'),
      );
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
      expect(profile['favorite_count'], 1);
      await api.request('DELETE', '/entries/$id');
      await expectLater(
        api.request('GET', '/entries/$id'),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)),
      );
    },
  );
  test('a diary can contain multiple reusable dishes with recipe photos and a selected cover', () async {
    final api = await mockApi();
    final entry = await api.request('POST', '/entries', {
      'title': '番茄炒蛋',
      'cooked_on': '2026-10-14',
      'notes': '',
      'mood': 0,
      'tags': [],
      'dishes': [
        {'title': '番茄炒蛋'},
        {'title': '清炒时蔬'},
      ],
    });
    expect((entry['dishes'] as List).length, 2);
    final recipes = await api.request('GET', '/recipes') as List;
    final tomato = recipes.firstWhere((r) => r['title'] == '番茄炒蛋');
    final photo = XFile.fromData(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
      ),
      name: 'dish.png',
    );
    await api.upload(entry['id'], photo, recipeId: tomato['id']);
    final updatedRecipes = await api.request('GET', '/recipes') as List;
    final updated = updatedRecipes.firstWhere((r) => r['id'] == tomato['id']);
    expect((updated['photos'] as List).length, 1);
    await api.request('PATCH', '/recipes/${tomato['id']}/cover', {
      'media_id': updated['photos'][0]['id'],
    });
    final afterCover = (await api.request('GET', '/recipes') as List)
        .firstWhere((r) => r['id'] == tomato['id']);
    expect(afterCover['cover_media_id'], updated['photos'][0]['id']);
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
