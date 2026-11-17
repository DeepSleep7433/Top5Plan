import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

class ApkUpdateException implements Exception {
  ApkUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ApkInstallResult {
  const ApkInstallResult({required this.status, this.message});
  final String status;
  final String? message;

  bool get launched => status == 'launched';
  bool get permissionRequired => status == 'permission_required';
}

class AndroidApkInstaller {
  AndroidApkInstaller({http.Client? client, MethodChannel? channel})
      : _client = client ?? http.Client(),
        _channel = channel ?? const MethodChannel('com.t5plan.app/installer');

  final http.Client _client;
  final MethodChannel _channel;

  Future<File> downloadAndVerify(
    UpdateRelease release, {
    Directory? cacheDirectory,
    void Function(double progress)? onProgress,
  }) async {
    final digest = release.sha256.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw ApkUpdateException('更新公告未提供有效的 SHA-256，拒绝安装');
    }
    final uri = Uri.tryParse(release.downloadUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw ApkUpdateException('APK 下载地址必须是 HTTPS URL');
    }
    final root = cacheDirectory ?? await getTemporaryDirectory();
    final dir = Directory(p.join(root.path, 'updates'));
    await dir.create(recursive: true);
    final safeVersion = release.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final target = File(p.join(dir.path, 't5-plan-$safeVersion.apk'));
    final part = File('${target.path}.part');
    if (await part.exists()) await part.delete();

    final request = http.Request('GET', uri);
    final response = await _client.send(request).timeout(const Duration(seconds: 120));
    if (response.statusCode != HttpStatus.ok) {
      throw ApkUpdateException('APK 下载失败：HTTP ${response.statusCode}');
    }

    final sink = part.openWrite();
    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hashSink.add(chunk);
        received += chunk.length;
        if (response.contentLength != null && response.contentLength! > 0) {
          onProgress?.call((received / response.contentLength!).clamp(0, 1));
        }
      }
      await sink.flush();
      await sink.close();
      hashSink.close();
    } catch (e) {
      await sink.close();
      if (await part.exists()) await part.delete();
      throw ApkUpdateException('APK 下载中断：$e');
    }

    final actual = digestSink.value?.toString().toLowerCase();
    if (actual != digest) {
      if (await part.exists()) await part.delete();
      throw ApkUpdateException('APK SHA-256 校验失败，已删除下载文件');
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    onProgress?.call(1);
    return target;
  }

  Future<ApkInstallResult> downloadAndInstall(
    UpdateRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw ApkUpdateException('仅 Android 支持安装 APK');
    }
    final file = await downloadAndVerify(release, onProgress: onProgress);
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'installApk',
      {'path': file.path},
    );
    final status = result?['status']?.toString() ?? 'unknown';
    return ApkInstallResult(status: status, message: result?['message']?.toString());
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
