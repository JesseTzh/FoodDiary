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
  }
  List<dynamic> get entries => state['entries'];
  List<dynamic> get recipes => state['recipes'];
  List<dynamic> get groceries => state['groceries'];
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
      result = {
        ...data,
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
        'image': 'tomato',
        'favorite': false,
      };
      recipes.insert(0, result);
    } else if (parts.length == 3 &&
        parts[0] == 'recipes' &&
        parts[2] == 'favorite' &&
        method == 'PATCH') {
      final recipe = _find(recipes, parts[1]);
      recipe['favorite'] = data['favorite'] == true;
      result = {'favorite': recipe['favorite']};
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
    } else if (path == '/groceries' && method == 'GET') {
      return _copy(groceries);
    } else if (path == '/groceries' && method == 'POST') {
      _text(data['name'], 80);
      result = {'id': _id(), 'name': data['name'], 'checked': false};
      groceries.insert(0, result);
    } else if (parts.length == 2 &&
        parts[0] == 'groceries' &&
        (method == 'PATCH' || method == 'DELETE')) {
      final item = _find(groceries, parts[1]);
      if (method == 'DELETE') {
        groceries.remove(item);
      } else {
        item['checked'] = data['checked'] == true;
      }
      result = method == 'DELETE' ? {'ok': true} : {'checked': item['checked']};
    } else {
      throw ApiError(404, '未实现的模拟接口：$method $path');
    }
    await _save();
    return _copy(result);
  }

  Future<void> upload(String id, XFile file) async {
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
    });
    await _save();
  }

  Map<String, dynamic> _seed() {
    final today = DateTime.now();
    final dishes = [
      ['tomato', '番茄炒蛋', '家常菜', '番茄 2 个', '鸡蛋 3 个'],
      ['chicken', '宫保鸡丁', '肉类', '鸡胸肉 250g', '花生 50g'],
      ['greens', '清炒时蔬', '素菜', '青菜 300g', '蒜 2 瓣'],
      ['noodles', '酸辣土豆丝', '家常菜', '土豆 2 个', '辣椒 1 个'],
    ];
    return {
      'next_id': 100,
      'authenticated': true,
      'profile': {'name': '小虎和小鼠', 'bio': '一起做饭，一起变好 ♥'},
      'entries': List.generate(
        3,
        (i) => {
          'id': 'entry-$i',
          'title': dishes[i][1],
          'cooked_on': today
              .subtract(Duration(days: i * 20))
              .toIso8601String()
              .substring(0, 10),
          'meal': '晚餐',
          'category': dishes[i][2],
          'notes': '今天也认真做饭了，留下这份美味的回忆。',
          'tags': [dishes[i][2], '晚餐'],
          'mood': i,
          'version': 1,
          'favorite': i == 0,
          'media': [
            {'url': 'asset:assets/images/${dishes[i][0]}.png'},
          ],
        },
      ),
      'recipes': dishes
          .map(
            (d) => {
              'id': d[0],
              'image': d[0],
              'title': d[1],
              'category': d[2],
              'description': '简单好做的家常味道。',
              'ingredients': [d[3], d[4], '盐适量'],
              'steps': ['洗净食材，切好备用。', '热锅下油，加入食材翻炒。', '调味后装盘，趁热享用。'],
              'favorite': d[0] == 'tomato',
              'custom': false,
            },
          )
          .toList(),
      'groceries': [
        {'id': 'grocery-1', 'name': '鸡蛋一盒', 'checked': false},
        {'id': 'grocery-2', 'name': '番茄 2 个', 'checked': true},
      ],
    };
  }
}
