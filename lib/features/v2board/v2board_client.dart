import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'brand_config.dart';

const _sessionKey = 'v2board.session.v1';

final _secureStorage = Platform.isMacOS
    ? const FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      )
    : const FlutterSecureStorage();

class V2BoardException implements Exception {
  const V2BoardException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

class V2BoardSession {
  const V2BoardSession({
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.token,
    required this.subscribeUrl,
    required this.updatedAt,
  });

  final String baseUrl;
  final String email;
  final String authData;
  final String token;
  final String subscribeUrl;
  final DateTime updatedAt;

  V2BoardSession copyWith({
    String? subscribeUrl,
    DateTime? updatedAt,
  }) {
    return V2BoardSession(
      baseUrl: baseUrl,
      email: email,
      authData: authData,
      token: token,
      subscribeUrl: subscribeUrl ?? this.subscribeUrl,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'baseUrl': baseUrl,
        'email': email,
        'authData': authData,
        'token': token,
        'subscribeUrl': subscribeUrl,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory V2BoardSession.fromJson(Map<String, Object?> json) {
    final baseUrl = json['baseUrl'] as String? ?? '';
    final email = json['email'] as String? ?? '';
    final authData = json['authData'] as String? ?? '';
    final token = json['token'] as String? ?? '';
    final subscribeUrl = json['subscribeUrl'] as String? ?? '';
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (baseUrl.isEmpty ||
        email.isEmpty ||
        authData.isEmpty ||
        subscribeUrl.isEmpty) {
      throw const FormatException('invalid v2board session');
    }
    return V2BoardSession(
      baseUrl: baseUrl,
      email: email,
      authData: authData,
      token: token,
      subscribeUrl: subscribeUrl,
      updatedAt: updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class V2BoardClient {
  V2BoardClient({String? baseUrl})
      : baseUrl = _normalizeBaseUrl(
          baseUrl ?? BrandConfig.normalizedApiBaseUrl,
        ),
        _dio = Dio(
          BaseOptions(
            connectTimeout: Duration(
              seconds: BrandConfig.requestTimeoutSeconds,
            ),
            sendTimeout: Duration(seconds: BrandConfig.requestTimeoutSeconds),
            receiveTimeout: Duration(
              seconds: BrandConfig.requestTimeoutSeconds,
            ),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'User-Agent': BrandConfig.appName + '-FlClash',
            },
            responseType: ResponseType.json,
          ),
        );

  final String baseUrl;
  final Dio _dio;

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Future<V2BoardSession> login({
    required String email,
    required String password,
  }) async {
    final response = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '$baseUrl/api/v1/auth/login',
        data: {'email': email.trim(), 'password': password},
      ),
    );
    final data = _data(response);
    final authData = _stringValue(data['auth_data']);
    final token = _stringValue(data['token']);
    if (authData.isEmpty || token.isEmpty) {
      throw const V2BoardException('站点返回的登录数据不完整');
    }
    final subscribeUrl = await _getSubscribeUrl(authData);
    final session = V2BoardSession(
      baseUrl: baseUrl,
      email: email.trim(),
      authData: authData,
      token: token,
      subscribeUrl: subscribeUrl,
      updatedAt: DateTime.now(),
    );
    await saveSession(session);
    return session;
  }

  Future<String> refreshSubscribeUrl(V2BoardSession session) async {
    final subscribeUrl = await _getSubscribeUrl(session.authData);
    final updated = session.copyWith(
      subscribeUrl: subscribeUrl,
      updatedAt: DateTime.now(),
    );
    await saveSession(updated);
    return subscribeUrl;
  }

  Future<String> _getSubscribeUrl(String authData) async {
    final response = await _request(
      () => _dio.get<Map<String, dynamic>>(
        '$baseUrl/api/v1/user/getSubscribe',
        options: Options(headers: {'Authorization': authData}),
      ),
    );
    final data = _data(response);
    final subscribeUrl = _stringValue(data['subscribe_url']);
    if (subscribeUrl.isEmpty) {
      throw const V2BoardException('站点没有返回可用的订阅地址');
    }
    return _resolveUrl(subscribeUrl);
  }

  String _resolveUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) {
      return '$baseUrl/${value.trim().replaceFirst(RegExp(r'^/+'), '')}';
    }
    return uri.toString();
  }

  Future<Response<Map<String, dynamic>>> _request(
    Future<Response<Map<String, dynamic>>> Function() request,
  ) async {
    try {
      final response = await request();
      if (response.statusCode != null && response.statusCode! >= 400) {
        throw V2BoardException(
          _messageFromBody(response.data) ?? '站点请求失败',
          statusCode: response.statusCode,
        );
      }
      return response;
    } on V2BoardException {
      rethrow;
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final message = _messageFromBody(error.response?.data) ??
          switch (error.type) {
            DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout => '连接站点超时，请检查网络后重试',
            DioExceptionType.badResponse => '站点请求失败（HTTP ${statusCode ?? '-'}）',
            _ => '无法连接站点，请检查网络或域名配置',
          };
      throw V2BoardException(message, statusCode: statusCode);
    } catch (error) {
      throw V2BoardException('站点请求失败：$error');
    }
  }

  static Map<String, dynamic> _data(Response<Map<String, dynamic>> response) {
    final body = response.data;
    if (body == null) throw const V2BoardException('站点返回为空');
    final data = body['data'];
    if (data is! Map) {
      throw V2BoardException(_messageFromBody(body) ?? '站点返回格式错误');
    }
    return Map<String, dynamic>.from(data);
  }

  static String _stringValue(Object? value) => value?.toString().trim() ?? '';

  static String? _messageFromBody(Object? body) {
    if (body is Map) {
      final message = body['message'] ?? body['msg'] ?? body['error'];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString().trim();
      }
    }
    return null;
  }

  static Future<V2BoardSession?> loadSession() async {
    final raw = await _secureStorage.read(key: _sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) {
        await _secureStorage.delete(key: _sessionKey);
        return null;
      }
      final session = V2BoardSession.fromJson(Map<String, Object?>.from(json));
      if (session.baseUrl != BrandConfig.normalizedApiBaseUrl) {
        await _secureStorage.delete(key: _sessionKey);
        return null;
      }
      return session;
    } catch (_) {
      await _secureStorage.delete(key: _sessionKey);
      return null;
    }
  }

  static Future<void> saveSession(V2BoardSession session) async {
    await _secureStorage.write(
      key: _sessionKey,
      value: jsonEncode(session.toJson()),
    );
  }

  static Future<void> clearSession() async {
    await _secureStorage.delete(key: _sessionKey);
  }
}
