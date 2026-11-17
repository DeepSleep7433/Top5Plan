import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:t5_plan/core/api/api_client.dart';
import 'package:t5_plan/core/providers.dart';
import 'package:t5_plan/core/settings/preferences.dart';
import 'package:t5_plan/core/updates/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('update checker parses a server-published release', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AppPreferences.load();
    final api = ApiClient(
      baseUrl: 'https://t5.test',
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/app-updates/latest');
        expect(request.url.queryParameters['platform'], 'windows');
        expect(request.url.queryParameters['current_version'], '1.0.0');
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'update_available': true,
            'platform': 'windows',
            'current_version': '1.0.0',
            'latest': {
              'id': '11111111-1111-4111-8111-111111111111',
              'platform': 'windows',
              'version': '1.0.1',
              'download_url': 'https://t5.test/t5-setup-1.0.1.exe',
              'sha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'release_notes': '修复同步并新增更新入口',
              'mandatory': false,
              'channel': 'stable',
              'published_at': '2026-11-16T00:00:00Z',
            },
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final container = ProviderContainer(overrides: [
      appPreferencesProvider.overrideWithValue(prefs),
      apiClientProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);
    final state = await container.read(updateProvider.notifier).check(force: true);
    expect(state.error, isNull);
    expect(state.updateAvailable, isTrue);
    expect(state.latest?.version, '1.0.1');
    expect(state.latest?.releaseNotes, contains('更新入口'));
    expect(state.lastCheckedAt, isNotNull);
  });
}
