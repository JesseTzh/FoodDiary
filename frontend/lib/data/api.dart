import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client_stub.dart' if (dart.library.js_interop) 'client_web.dart';

class Api {
  static const configuredBase = String.fromEnvironment('API_BASE_URL');
  final http.Client client = makeClient();
  late SharedPreferences prefs;
  String base = '';
  String token = '';
  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    base =
        prefs.getString('server') ??
        (configuredBase.isNotEmpty
            ? configuredBase
            : (kIsWeb ? Uri.base.origin : 'http://10.0.2.2:8080'));
    token = prefs.getString('session') ?? '';
  }

  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (!kIsWeb && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
  String url(String path) => '$base$path';
  Future<dynamic> request(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse(url('/api/v1$path')))
      ..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    final saved = res.headers['x-session-token'];
    if (!kIsWeb && saved != null) {
      token = saved;
      await prefs.setString('session', token);
    }
    dynamic value;
    try {
      value = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw Exception('服务器响应异常，请检查服务地址');
    }
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, value['error']?['message'] ?? '请求失败');
    }
    return value['data'];
  }

  Future<void> upload(String id, XFile file) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse(url('/api/v1/entries/$id/media')),
    );
    if (!kIsWeb && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        await file.readAsBytes(),
        filename: file.name,
      ),
    );
    final res = await client.send(req).timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      final data = jsonDecode(await res.stream.bytesToString());
      throw Exception(data['error']?['message'] ?? '照片上传失败');
    }
  }

  Future<void> setServer(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw Exception('请输入完整的 http 或 https 服务地址');
    }
    base = value.trim().replaceAll(RegExp(r'/+$'), '');
    await prefs.setString('server', base);
    token = '';
    await prefs.remove('session');
  }

  Future<void> logout() async {
    await request('POST', '/auth/logout');
    token = '';
    await prefs.remove('session');
  }
}

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  @override
  String toString() => message;
}
