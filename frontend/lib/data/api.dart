import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client_stub.dart' if (dart.library.js_interop) 'client_web.dart';

class Api {
  static const configuredBase = String.fromEnvironment('API_BASE_URL');
  final http.Client client;
  Api({http.Client? client}) : client = client ?? makeClient();
  late SharedPreferences prefs;
  String base = '';
  String token = '';
  String refreshToken = '';
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();
  Future<bool>? _refreshing;
  int _tokenGeneration = 0;
  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    base = configuredBase.isNotEmpty
        ? configuredBase
        : (kIsWeb ? Uri.base.origin : 'http://10.0.2.2:8080');
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

  Future<void> upload(String id, XFile file) async {
    await _ensureAccess();
    final bytes = await file.readAsBytes();
    Future<http.Response> send() async {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse(url('/api/v1/entries/$id/media')),
      );
      if (!kIsWeb) {
        req.headers['X-FoodDiary-Client'] = 'app';
        if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
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
