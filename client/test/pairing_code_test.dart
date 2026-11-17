import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:t5_plan/core/api/api_client.dart';

void main() {
  test('requests an on-demand six-digit pairing code', () async {
    final api = ApiClient(
      baseUrl: 'https://t5.test',
      token: 'paired-device-token',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices/pairing-code');
        expect(request.headers['Authorization'], 'Bearer paired-device-token');
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'pairing_code': '042731',
            'expires_at': '2026-11-16T00:00:30Z',
            'expires_in_seconds': 30,
            'code_length': 6,
          })),
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await api.createPairingCode();
    expect(result['pairing_code'], '042731');
    expect(result['expires_in_seconds'], 30);
    expect((result['pairing_code'] as String).length, 6);
  });
}
