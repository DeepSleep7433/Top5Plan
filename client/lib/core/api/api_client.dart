import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.statusCode, this.code, this.message, [this.details]);
  final int statusCode;
  final String code;
  final String message;
  final Object? details;

  bool get isUnauthorized => statusCode == 401;
  bool get isConflict => statusCode == 409;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({
    required this.baseUrl,
    this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  }) : _client = client ?? http.Client();

  String baseUrl;
  String? token;
  final http.Client _client;
  final Duration timeout;

  String get _root {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/api/v1')) return base;
    return '$base/api/v1';
  }

  Map<String, String> _headers({bool auth = true}) {
    final h = {'Accept': 'application/json', 'Content-Type': 'application/json'};
    if (auth && token != null && token!.isNotEmpty) {
      h['Authorization'] = 'Bearer ${token!}';
    }
    return h;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Duration? requestTimeout,
  }) async {
    final uri = Uri.parse('$_root$path');
    final req = http.Request(method, uri)..headers.addAll(_headers(auth: auth));
    if (body != null) req.body = jsonEncode(body);
    final response = await _client.send(req).then(http.Response.fromStream).timeout(
          requestTimeout ?? timeout,
          onTimeout: () => throw ApiException(0, 'timeout', '请求超时，请稍后重试'),
        );
    final text = utf8.decode(response.bodyBytes);
    Map<String, dynamic> decoded = {};
    if (text.isNotEmpty) {
      try {
        final v = jsonDecode(text);
        if (v is Map<String, dynamic>) decoded = v;
      } catch (_) {
        throw ApiException(response.statusCode, 'invalid_response', '服务器返回了无法解析的响应');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        decoded['error']?.toString() ?? 'http_${response.statusCode}',
        decoded['message']?.toString() ?? '请求失败 (${response.statusCode})',
        decoded['details'],
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> pair({
    required String pairingToken,
    required String deviceName,
    required String platform,
  }) =>
      _request('POST', '/devices/pair', auth: false, body: {
        'pairing_code': pairingToken,
        'device_name': deviceName,
        'platform': platform,
      });

  Future<Map<String, dynamic>> createPairingCode() =>
      _request('POST', '/devices/pairing-code');

  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> operations) =>
      _request('POST', '/sync/push', body: {'operations': operations});

  Future<Map<String, dynamic>> changes({
    required String generation,
    required int cursor,
    int limit = 500,
  }) =>
      _request(
        'GET',
        '/sync/changes?cursor=$cursor&limit=$limit&generation=${Uri.encodeQueryComponent(generation)}',
      );

  Future<Map<String, dynamic>> bootstrap({String? afterType, String? afterId, int limit = 500}) {
    final q = <String>['limit=$limit'];
    if (afterType != null) q.add('after_type=${Uri.encodeQueryComponent(afterType)}');
    if (afterId != null) q.add('after_id=${Uri.encodeQueryComponent(afterId)}');
    return _request('GET', '/sync/bootstrap?${q.join('&')}');
  }

  Future<Map<String, dynamic>> focusCurrent() => _request('GET', '/focus/current');

  Future<Map<String, dynamic>> focusCommand(Map<String, dynamic> command) =>
      _request('POST', '/focus/commands', body: command);

  Future<Map<String, dynamic>> getSettings() => _request('GET', '/settings');

  Future<Map<String, dynamic>> putSettings(String timezone, Map<String, dynamic> settings) =>
      _request('PUT', '/settings', body: {'timezone': timezone, 'settings': settings});

  Future<Map<String, dynamic>> latestAppUpdate({
    required String platform,
    required String currentVersion,
    String channel = 'stable',
  }) =>
      _request(
        'GET',
        '/app-updates/latest?platform=${Uri.encodeQueryComponent(platform)}'
        '&current_version=${Uri.encodeQueryComponent(currentVersion)}'
        '&channel=${Uri.encodeQueryComponent(channel)}',
        auth: false,
      );

  Future<Map<String, dynamic>> listDevices() => _request('GET', '/devices');

  Future<Map<String, dynamic>> revokeDevice(String id) =>
      _request('DELETE', '/devices/$id');

  Future<Map<String, dynamic>> listAIConfigs() => _request('GET', '/ai/configs');

  Future<Map<String, dynamic>> createAIConfig(Map<String, dynamic> config) =>
      _request('POST', '/ai/configs', body: config);

  Future<Map<String, dynamic>> updateAIConfig(String id, Map<String, dynamic> config) =>
      _request('PATCH', '/ai/configs/$id', body: config);

  Future<Map<String, dynamic>> deleteAIConfig(String id) =>
      _request('DELETE', '/ai/configs/$id');

  Future<Map<String, dynamic>> testAIConfig(String id) =>
      _request('POST', '/ai/configs/$id/test', requestTimeout: const Duration(seconds: 130));

  Future<Map<String, dynamic>> testAIDraft(Map<String, dynamic> config) =>
      _request('POST', '/ai/configs/test', body: config, requestTimeout: const Duration(seconds: 130));

  Future<Map<String, dynamic>> previewAssist(String instruction, List<Map<String, String>> sources) =>
      _request('POST', '/ai/assist/preview', body: {'instruction': instruction, 'sources': sources});

  Future<Map<String, dynamic>> createAIJob({
    String? configId,
    required String instruction,
    required List<Map<String, String>> sources,
  }) =>
      _request('POST', '/ai/jobs', body: {
        if (configId != null && configId.isNotEmpty) 'config_id': configId,
        'instruction': instruction,
        'sources': sources,
      });

  Future<Map<String, dynamic>> listAIJobs({int limit = 30}) =>
      _request('GET', '/ai/jobs?limit=$limit');

  Future<Map<String, dynamic>> getAIJob(String id) => _request('GET', '/ai/jobs/$id');

  Future<Map<String, dynamic>> listReports({String? kind, int limit = 20}) =>
      _request('GET', '/ai/reports?limit=$limit${kind == null ? '' : '&kind=$kind'}');

  Future<Map<String, dynamic>> regenerateReport(String id) =>
      _request('POST', '/ai/reports/$id/regenerate');

  void close() => _client.close();
}
