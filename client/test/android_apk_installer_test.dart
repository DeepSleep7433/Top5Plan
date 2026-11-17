import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:t5_plan/core/updates/android_apk_installer.dart';
import 'package:t5_plan/core/updates/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('downloads APK and accepts matching SHA-256', () async {
    final bytes = utf8.encode('fake apk payload for checksum test');
    final digest = sha256.convert(bytes).toString();
    final dir = await Directory.systemTemp.createTemp('t5_apk_test_');
    addTearDown(() async => dir.delete(recursive: true));
    final installer = AndroidApkInstaller(
      client: MockClient((request) async {
        expect(request.url.scheme, 'https');
        return http.Response.bytes(bytes, 200, headers: {'content-length': '${bytes.length}'});
      }),
    );
    final file = await installer.downloadAndVerify(
      UpdateRelease(
        version: '1.0.1',
        downloadUrl: 'https://example.com/t5.apk',
        sha256: digest,
        releaseNotes: '',
        mandatory: false,
        publishedAt: null,
      ),
      cacheDirectory: dir,
    );
    expect(await file.readAsBytes(), bytes);
    expect(await file.exists(), isTrue);
  });

  test('rejects mismatched SHA-256 and removes partial file', () async {
    final bytes = utf8.encode('tampered apk payload');
    final dir = await Directory.systemTemp.createTemp('t5_apk_test_');
    addTearDown(() async => dir.delete(recursive: true));
    final installer = AndroidApkInstaller(
      client: MockClient((request) async => http.Response.bytes(bytes, 200)),
    );
    expect(
      () => installer.downloadAndVerify(
        UpdateRelease(
          version: '1.0.1',
          downloadUrl: 'https://example.com/t5.apk',
          sha256: 'a'.padRight(64, 'a'),
          releaseNotes: '',
          mandatory: false,
          publishedAt: null,
        ),
        cacheDirectory: dir,
      ),
      throwsA(isA<ApkUpdateException>()),
    );
  });

  test('rejects missing SHA-256 before network access', () async {
    final installer = AndroidApkInstaller(
      client: MockClient((request) async {
        fail('network must not be called without a checksum');
      }),
    );
    expect(
      () => installer.downloadAndVerify(
        const UpdateRelease(
          version: '1.0.1',
          downloadUrl: 'https://example.com/t5.apk',
          sha256: '',
          releaseNotes: '',
          mandatory: false,
          publishedAt: null,
        ),
      ),
      throwsA(isA<ApkUpdateException>()),
    );
  });
}
