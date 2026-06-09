import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// In-app full-APK self-updater (local/dev). On startup it asks the dashboard's
/// `/latest` manifest for the newest build; if its `version_code` is higher than
/// the installed one it downloads the APK and fires Android's install prompt
/// (the user taps Install — app-driven installs require consent on Android).
///
/// `_baseUrl` is injected at build time (e.g. a cloudflared URL). Fully
/// best-effort: every failure is swallowed and it never blocks startup.
class InhouseApkUpdater {
  // TODO: set to your dashboard's public URL (ngrok / cloudflared / domain).
  // Left as the placeholder, the guard in _run() keeps this updater disabled.
  static const String _baseUrl = '__BASE_URL__';
  static const String _tag = '[inhouse-apk-updater]';

  /// Call once, early in main(), without awaiting.
  static void check() => unawaited(_run());

  static Future<void> _run() async {
    if (_baseUrl.startsWith('__')) return; // not configured
    HttpClient? client;
    try {
      final info = await PackageInfo.fromPlatform();
      final installed = int.tryParse(info.buildNumber) ?? 0;

      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await client.getUrl(Uri.parse('$_baseUrl/latest'));
      req.headers.set('ngrok-skip-browser-warning', '1');
      final resp = await req.close();
      if (resp.statusCode != HttpStatus.ok) return;
      final body = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      if (body['available'] != true) return;

      final latest = (body['version_code'] as num).toInt();
      if (latest <= installed) {
        debugPrint('$_tag up to date (installed=$installed)');
        return;
      }
      final apkPath = body['apk_path'] as String;
      debugPrint('$_tag update $installed -> $latest, downloading $apkPath');

      final dir = await getApplicationSupportDirectory();
      final apk = File('${dir.path}/update-$latest.apk');
      final tmp = File('${apk.path}.tmp');
      final dreq = await client.getUrl(Uri.parse('$_baseUrl$apkPath'));
      dreq.headers.set('ngrok-skip-browser-warning', '1');
      final dresp = await dreq.close();
      if (dresp.statusCode != HttpStatus.ok) return;
      final sink = tmp.openWrite();
      await dresp.pipe(sink);
      await tmp.rename(apk.path);

      debugPrint('$_tag downloaded -> ${apk.path}; opening installer');
      await OpenFilex.open(
        apk.path,
        type: 'application/vnd.android.package-archive',
      );
    } catch (e) {
      debugPrint('$_tag skipped: $e');
    } finally {
      client?.close();
    }
  }
}
