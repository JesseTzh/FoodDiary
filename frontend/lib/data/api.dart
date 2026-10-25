import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mock_store.dart';

import 'client_stub.dart' if (dart.library.js_interop) 'client_web.dart';

class Api {
  static const configuredBase = String.fromEnvironment('API_BASE_URL');
  final http.Client client;
  final bool mock;
  MockStore? _mockStore;
  Api({http.Client? client, this.mock = const bool.fromEnvironment('MOCK_API')})
    : client = client ?? makeClient();
  late SharedPreferences prefs;
  String base = '';
  String token = '';
  String refreshToken = '';
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();
  Future<bool>? _refreshing;
  int _tokenGeneration = 0;
  int _dataRevision = 0;

  /// Changes only after successful data writes, including photo uploads.
  /// A caller can compare this across nested routes, even after a partial save.
  int get dataRevision => _dataRevision;
  bool get canConfigureServer =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !mock;
  bool get needsServerConfiguration =>
      canConfigureServer && prefs.getString('server_base_url') == null;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    base = configuredBase.isNotEmpty
        ? configuredBase
        : (kIsWeb ? Uri.base.origin : 'http://10.0.2.2:8080');
    if (mock) {
      base = 'mock://local';
      _mockStore = MockStore(prefs);
      return;
    }
    if (canConfigureServer) {
      base = prefs.getString('server_base_url') ?? configuredBase;
    }
    // Legacy plaintext credentials are intentionally invalidated by the upgrade.
    await prefs.remove('session');
    if (!kIsWeb) {
      final stored = await secureStorage.read(key: 'auth_tokens');
      if (stored != null) {
        try {
          final pair = jsonDecode(stored) as Map<String, dynamic>;
          token = pair['access'] as String;
          refreshToken = pair['refresh'] as String;
        } catch (_) {
          await _clearTokens();
        }
      }
    }
  }

  static String normalizeServerAddress(String input) {
    final value = input.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(value)) {
      throw const FormatException('请输入完整的后端地址，如 https://food.example.com');
    }
    if (kReleaseMode && uri.scheme != 'https') {
      throw const FormatException('正式版请使用 HTTPS 地址');
    }
    return value;
  }

  Future<void> configureServer(String input) async {
    if (!canConfigureServer) throw StateError('当前平台不支持配置后端地址');
    final next = normalizeServerAddress(input);
    // Probe without credentials: a new server must never receive the old tokens.
    final response = await client
        .get(
          Uri.parse('$next/api/v1/auth/status'),
          headers: {'X-FoodDiary-Client': 'app'},
        )
        .timeout(const Duration(seconds: 20));
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const FormatException('服务器响应异常，请检查后端地址');
    }
    if (response.statusCode != 200 ||
        data is! Map ||
        data['data'] is! Map ||
        data['data']['authenticated'] is! bool ||
        data['data']['auth_required'] is! bool) {
      throw const FormatException('未找到做饭日记服务，请检查后端地址');
    }
    if (next != base) await _clearTokens();
    if (!await prefs.setString('server_base_url', next)) {
      throw Exception('地址保存失败，请重试');
    }
    base = next;
  }

  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (!kIsWeb) 'X-FoodDiary-Client': 'app',
    if (!kIsWeb && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
  String url(String path) => '$base$path';
  Future<void> _saveTokens(http.Response res) async {
    if (kIsWeb || res.statusCode >= 400) return;
    final access = res.headers['x-session-token'];
    final refresh = res.headers['x-refresh-token'];
    if (access != null && refresh != null) {
      // Store the rotating pair together so an interrupted write cannot mix
      // a new access token with an already consumed refresh credential.
      await secureStorage.write(
        key: 'auth_tokens',
        value: jsonEncode({'access': access, 'refresh': refresh}),
      );
      token = access;
      refreshToken = refresh;
      _tokenGeneration++;
    }
  }

  Future<http.Response> _send(String method, String path, Object? body) async {
    final req = http.Request(method, Uri.parse(url('/api/v1$path')))
      ..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    await _saveTokens(res);
    return res;
  }

  Future<bool> _refresh() => _refreshing ??= _doRefresh().whenComplete(() {
    _refreshing = null;
  });

  Future<bool> _doRefresh() async {
    if (!kIsWeb && refreshToken.isEmpty) return false;
    final req = http.Request('POST', Uri.parse(url('/api/v1/auth/refresh')));
    if (!kIsWeb) {
      req.headers['X-FoodDiary-Client'] = 'app';
      req.headers['Authorization'] = 'Bearer $refreshToken';
    }
    final res = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    if (res.statusCode == 401) {
      await _clearTokens();
      return false;
    }
    if (res.statusCode != 200) {
      throw ApiError(res.statusCode, '登录续期失败，请稍后重试');
    }
    await _saveTokens(res);
    if (kIsWeb) _tokenGeneration++;
    return true;
  }

  // Renew before native image requests also use the access credential.
  Future<void> _ensureAccess() async {
    if (kIsWeb || refreshToken.isEmpty) return;
    var expired = true;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
      ) as Map<String, dynamic>;
      expired =
          (payload['exp'] as num).toInt() <=
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30;
    } catch (_) {
      // This inspection is only a refresh hint; the server validates JWTs.
    }
    if (expired) await _refresh();
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    final result = await _request(method, path, body);
    if (const {'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method) &&
        !path.startsWith('/auth/')) {
      _dataRevision++;
    }
    return result;
  }

  Future<dynamic> _request(String method, String path, Object? body) async {
    if (mock) return _mockStore!.request(method, path, body);
    final canRefresh = !path.startsWith('/auth/') || path == '/auth/status';
    if (canRefresh) await _ensureAccess();
    final generation = _tokenGeneration;
    var res = await _send(method, path, body);
    dynamic value;
    try {
      value = jsonDecode(utf8.decode(res.bodyBytes));
      final unauthenticatedStatus =
          path == '/auth/status' && value['data']?['authenticated'] == false;
      if (canRefresh && (res.statusCode == 401 || unauthenticatedStatus)) {
        if (_tokenGeneration != generation || await _refresh()) {
          res = await _send(method, path, body);
          value = jsonDecode(utf8.decode(res.bodyBytes));
        }
      }
    } on FormatException {
      throw Exception('服务器响应异常，请检查服务地址');
    }
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, value['error']?['message'] ?? '请求失败');
    }
    return value['data'];
  }

  Future<void> uploadRecipe(String recipeId, XFile file, {Rect? crop}) =>
      upload('', file, recipeId: recipeId, crop: crop);

  Future<void> upload(
    String id,
    XFile file, {
    String? recipeId,
    Rect? crop,
  }) async {
    if (mock) {
      await _mockStore!.upload(id, file, recipeId: recipeId, crop: crop);
      _dataRevision++;
      return;
    }
    await _ensureAccess();
    final bytes = await file.readAsBytes();
    Future<http.Response> send() async {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse(
          url(
            id.isEmpty
                ? '/api/v1/recipes/$recipeId/media'
                : '/api/v1/entries/$id/media${recipeId == null ? '' : '?recipe_id=$recipeId'}',
          ),
        ),
      );
      if (!kIsWeb) {
        req.headers['X-FoodDiary-Client'] = 'app';
        if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
      final c = crop ?? const Rect.fromLTWH(0, 0, 1, 1);
      req.fields.addAll({
        'crop_x': '${c.left}',
        'crop_y': '${c.top}',
        'crop_width': '${c.width}',
        'crop_height': '${c.height}',
      });
      return http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 60)),
      );
    }

    final generation = _tokenGeneration;
    var res = await send();
    if (res.statusCode == 401 &&
        (_tokenGeneration != generation || await _refresh())) {
      res = await send();
    }
    if (res.statusCode >= 400) {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      throw ApiError(res.statusCode, data['error']?['message'] ?? '照片上传失败');
    }
    _dataRevision++;
  }

  Future<void> _clearTokens() async {
    token = '';
    refreshToken = '';
    await prefs.remove('session');
    if (!kIsWeb) {
      await secureStorage.delete(key: 'auth_tokens');
    }
  }

  Future<void> logout() async {
    if (mock) {
      await _mockStore!.request('POST', '/auth/logout');
      return;
    }
    if (_refreshing != null) await _refreshing;
    final req = http.Request('POST', Uri.parse(url('/api/v1/auth/logout')));
    if (!kIsWeb) {
      req.headers['X-FoodDiary-Client'] = 'app';
      if (refreshToken.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $refreshToken';
      }
    }
    final res = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, '退出登录失败，请稍后重试');
    }
    await _clearTokens();
  }
}

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  @override
  String toString() => message;
}
