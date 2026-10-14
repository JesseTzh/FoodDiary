import 'dart:convert';

import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Persistent, opt-in local backend, isolated from real data and credentials.
class MockStore {
  static const storageKey = 'fooddiary:mock:v1';
  final SharedPreferences prefs;
  late Map<String, dynamic> state;
  MockStore(this.prefs) {
    final saved = prefs.getString(storageKey);
    state = jsonDecode(saved ?? jsonEncode(_seed()));
    // Upgrade existing mock sessions without discarding user-created data.
    if (state['seed_version'] != 2) {
      recipes.removeWhere(
        (r) =>
            r['custom'] == false &&
            const ['tomato', 'chicken', 'greens', 'noodles'].contains(r['id']),
      );
      for (final entry in entries) {
        (entry['media'] as List?)?.removeWhere(
          (m) => const [
            'asset:assets/images/tomato.png',
            'asset:assets/images/chicken.png',
            'asset:assets/images/greens.png',
            'asset:assets/images/noodles.png',
          ].contains(m['url']),
        );
      }
      state['seed_version'] = 2;
      prefs.setString(storageKey, jsonEncode(state));
    }
  }
  List<dynamic> get entries => state['entries'];
  List<dynamic> get recipes => state['recipes'];
  Future<void> _save() async {
    if (!await prefs.setString(storageKey, jsonEncode(state))) {
      throw ApiError(507, '本地模拟存储空间不足');
    }
  }

  String _id() => 'mock-${state['next_id']++}';
  dynamic _copy(dynamic value) => jsonDecode(jsonEncode(value));
  Map<String, dynamic> _find(List<dynamic> items, String id) =>
      items.cast<Map<String, dynamic>>().firstWhere(
        (e) => e['id'] == id,
        orElse: () => throw ApiError(404, '未找到记录'),
      );
  void _text(dynamic value, int max) {
    if (value is! String || value.trim().isEmpty || value.runes.length > max) {
      throw ApiError(400, '请填写 1–$max 字的有效内容');
    }
  }

  void _entry(Map<String, dynamic> data) {
    _text(data['title'], 80);
    final date = DateTime.tryParse(data['cooked_on'] as String? ?? '');
    if (date == null ||
        date.toIso8601String().substring(0, 10) != data['cooked_on']) {
      throw ApiError(400, '请选择有效日期');
    }
    if ((data['notes'] as String? ?? '').runes.length > 200 ||
        (data['mood'] as int? ?? 0) < 0 ||
        (data['mood'] as int? ?? 0) > 4) {
      throw ApiError(400, '心得最多 200 字，心情为 0–4');
    }
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    final uri = Uri.parse(path);
    final parts = uri.path.split('/').where((p) => p.isNotEmpty).toList();
    final data = Map<String, dynamic>.from(body as Map? ?? {});
    dynamic result;
    if (path == '/auth/status' && method == 'GET') {
      return {
        'authenticated': state['authenticated'],
        'auth_required': state['auth_required'] ?? true,
      };
    }
    if ((path == '/auth/login' || path == '/auth/setup') && method == 'POST') {
      if (data['password'] != 'mock123456') {
        throw ApiError(401, '模拟环境密码为 mock123456');
      }
      state['authenticated'] = true;
      await _save();
      return {'authenticated': true};
    }
    if (state['authenticated'] != true) throw ApiError(401, '请先登录');
    if (path == '/auth/logout' && method == 'POST') {
      state['authenticated'] = false;
      result = {'ok': true};
    } else if (path == '/auth/refresh' && method == 'POST') {
      return {'authenticated': true};
    } else if (uri.path == '/entries' && method == 'GET') {
      final q = uri.queryParameters;
      final items =
          entries
              .where(
                (e) =>
                    (q['favorite'] != 'true' || e['favorite'] == true) &&
                    (q['month'] == null ||
                        (e['cooked_on'] as String).startsWith(q['month']!)) &&
                    (q['q'] == null ||
                        '${e['title']} ${e['notes']} ${e['tags']}'.contains(
                          q['q']!,
                        )),
              )
              .toList()
            ..sort(
              (a, b) => (b['cooked_on'] as String).compareTo(a['cooked_on']),
            );
      return _copy({'items': items, 'total': items.length});
    } else if (path == '/entries' && method == 'POST') {
      _entry(data);
      final dishes = _resolveDishes(data);
      result = {
        ...data,
        'dishes': dishes,
        'id': _id(),
        'version': 1,
        'favorite': data['favorite'] ?? false,
        'media': <dynamic>[],
      };
      entries.insert(0, result);
    } else if (parts.length >= 2 && parts[0] == 'entries') {
      final entry = _find(entries, parts[1]);
      if (parts.length == 2 && method == 'GET') return _copy(entry);
      if (parts.length == 2 && method == 'PATCH') {
        _entry(data);
        if (data['version'] != entry['version']) {
          throw ApiError(409, '记录已更新，请刷新后重试');
        }
        entry.addAll({
          ...data,
          'id': entry['id'],
          'version': entry['version'] + 1,
          'dishes': _resolveDishes(data),
        });
        result = entry;
      } else if (parts.length == 2 && method == 'DELETE') {
        entries.remove(entry);
        result = {'ok': true};
      } else if (parts.length == 3 &&
          parts[2] == 'favorite' &&
          method == 'PATCH') {
        entry['favorite'] = data['favorite'] == true;
        result = {'favorite': entry['favorite']};
      } else {
        throw ApiError(404, '未实现的模拟接口：$method $path');
      }
    } else if (path == '/recipes' && method == 'GET') {
      return _copy(recipes);
    } else if (path == '/recipes' && method == 'POST') {
      _text(data['title'], 80);
      for (final key in ['ingredients', 'steps']) {
        if (data[key] is! List || (data[key] as List).length > 100) {
          throw ApiError(400, '食材和步骤各最多 100 项');
        }
      }
      result = {
        ...data,
        'id': _id(),
        'custom': true,
        'image': '',
        'favorite': false,
      };
      recipes.insert(0, result);
    } else if (parts.length == 2 &&
        parts[0] == 'recipes' &&
        method == 'PATCH') {
      _text(data['title'], 80);
      for (final key in ['ingredients', 'steps']) {
        if (data[key] is! List || (data[key] as List).length > 100) {
          throw ApiError(400, '食材和步骤各最多 100 项');
        }
      }
      final recipe = _find(recipes, parts[1]);
      for (final key in [
        'title',
        'category',
        'description',
        'ingredients',
        'steps',
      ]) {
        recipe[key] = data[key];
      }
      result = recipe;
    } else if (parts.length == 3 &&
        parts[0] == 'recipes' &&
        parts[2] == 'favorite' &&
        method == 'PATCH') {
      final recipe = _find(recipes, parts[1]);
      recipe['favorite'] = data['favorite'] == true;
      result = {'favorite': recipe['favorite']};
    } else if (parts.length == 3 &&
        parts[0] == 'recipes' &&
        parts[2] == 'cover' &&
        method == 'PATCH') {
      final recipe = _find(recipes, parts[1]);
      recipe['cover_media_id'] = data['media_id'];
      result = {'cover_media_id': data['media_id']};
    } else if (path == '/profile' && (method == 'GET' || method == 'PATCH')) {
      if (method == 'PATCH') {
        _text(data['name'], 30);
        if ((data['bio'] as String? ?? '').runes.length > 100) {
          throw ApiError(400, '简介最多 100 字');
        }
        state['profile'] = {'name': data['name'], 'bio': data['bio'] ?? ''};
      }
      result = {
        ...state['profile'] as Map,
        'entry_count': entries.length,
        'recipe_count': recipes.where((r) => r['custom'] == true).length,
        'favorite_count': recipes.where((r) => r['favorite'] == true).length,
      };
    } else {
      throw ApiError(404, '未实现的模拟接口：$method $path');
    }
    await _save();
    return _copy(result);
  }

  List<Map<String, dynamic>> _resolveDishes(Map<String, dynamic> data) {
    final dishes = List<Map<String, dynamic>>.from(data['dishes'] ?? []);
    for (final dish in dishes) {
      Map? found;
      for (final recipe in recipes) {
        if (recipe['id'] == dish['id'] ||
            recipe['title'].toString().toLowerCase() ==
                dish['title'].toString().toLowerCase()) {
          found = recipe;
          break;
        }
      }
      if (found != null) {
        dish['id'] = found['id'];
        dish['title'] = found['title'];
      } else {
        dish['id'] = _id();
        recipes.insert(0, {
          'id': dish['id'],
          'title': dish['title'],
          'category': data['category'] ?? '家常菜',
          'description': '',
          'image': '',
          'ingredients': [],
          'steps': [],
          'favorite': false,
          'custom': true,
          'photos': <dynamic>[],
          'cover_media_id': '',
        });
      }
    }
    return dishes;
  }

  Future<void> upload(String id, XFile file, {String? recipeId}) async {
    if (state['authenticated'] != true) throw ApiError(401, '请先登录');
    final media = _find(entries, id)['media'] as List;
    if (media.length >= 9) throw ApiError(400, '最多可以保存 9 张照片');
    final bytes = await file.readAsBytes();
    if (bytes.length > 20 * 1024 * 1024) throw ApiError(400, '单张照片不能超过 20 MB');
    final png = bytes.length >= 8 && bytes[0] == 137 && bytes[1] == 80;
    final jpeg = bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216;
    final gif =
        bytes.length >= 6 &&
        ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF';
    final webp =
        bytes.length >= 12 &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
    if (!png && !jpeg && !gif && !webp) {
      throw ApiError(400, '照片仅支持 JPEG、PNG、WebP、GIF');
    }
    final type = png
        ? 'png'
        : jpeg
        ? 'jpeg'
        : gif
        ? 'gif'
        : 'webp';
    media.add({
      'id': _id(),
      'url': 'data:image/$type;base64,${base64Encode(bytes)}',
      'recipe_id': recipeId,
    });
    if (recipeId != null) {
      final recipe = recipes.cast<Map>().firstWhere((r) => r['id'] == recipeId);
      final recipePhotos = (recipe['photos'] as List? ?? <dynamic>[]);
      recipePhotos.add(media.last);
      recipe['photos'] = recipePhotos;
      recipe['cover_media_id'] = media.last['id'];
    }
    await _save();
  }

  Map<String, dynamic> _seed() => {
    'seed_version': 2,
    'next_id': 100,
    'authenticated': true,
    'profile': {'name': '小虎和小鼠', 'bio': '一起做饭，一起变好 ♥'},
    'entries': <dynamic>[],
    'recipes': <dynamic>[],
  };
}
