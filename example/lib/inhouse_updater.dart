import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// In-house code-push updater, configured for this demo app. It tries each base
/// URL in order and uses the first that responds; the patch is downloaded from
/// that same base. Fire-and-forget at startup, fully best-effort.
class InhouseUpdater {
  static const List<String> _bases = <String>[
    'http://10.0.2.2:8080', // Android emulator -> host loopback
    'http://localhost:8080', // USB device via `adb reverse tcp:8080 tcp:8080`
  ];
  static const String _appId = 'com.example.codepush_demo';
  static const String _releaseVersion = '1.0.0'; // must match installed app
  static const String _platform = 'android';
  static const String _arch = 'arm64';
  static const String _channel = 'stable';
  static const String _tag = '[inhouse-updater]';

  /// Call once, early in main(), without awaiting.
  static void check() => unawaited(_run());

  static Future<void> _run() async {
    final supportDir = await getApplicationSupportDirectory();
    final patchDir = Directory('${supportDir.path}/inhouse_patches');
    final numberFile = File('${patchDir.path}/applied_number');
    int? current;
    if (numberFile.existsSync()) {
      current = int.tryParse((await numberFile.readAsString()).trim());
    }
    for (final base in _bases) {
      try {
        if (await _tryBase(base, current, patchDir, numberFile)) return;
      } catch (e) {
        debugPrint('$_tag $base unreachable: $e');
      }
    }
  }

  /// Returns true if this base reached the dashboard (whether or not a patch
  /// was downloaded), so the caller stops trying other bases.
  static Future<bool> _tryBase(
    String base,
    int? current,
    Directory patchDir,
    File numberFile,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final checkReq =
          await client.postUrl(Uri.parse('$base/api/v1/patches/check'));
      checkReq.headers.contentType = ContentType.json;
      checkReq.headers.set('ngrok-skip-browser-warning', '1');
      checkReq.add(utf8.encode(jsonEncode({
        'app_id': _appId,
        'release_version': _releaseVersion,
        'platform': _platform,
        'arch': _arch,
        'channel': _channel,
        'client_id': 'device',
        'current_patch_number': current,
      })));
      final checkResp = await checkReq.close();
      if (checkResp.statusCode != HttpStatus.ok) return false; // try next base
      final body = jsonDecode(await checkResp.transform(utf8.decoder).join())
          as Map<String, dynamic>;

      if (body['patch_available'] != true) {
        debugPrint('$_tag up to date via $base (current=$current)');
        return true;
      }
      final patch = body['patch'] as Map<String, dynamic>;
      final number = (patch['number'] as num).toInt();
      if (current != null && number <= current) return true;

      // Download from THIS base + the path (ignore the host in download_url).
      final path = Uri.parse(patch['download_url'] as String).path;
      final url = '$base$path';
      debugPrint('$_tag downloading patch #$number from $url');
      await patchDir.create(recursive: true);
      final tmp = File('${patchDir.path}/libapp.so.tmp');
      final dlReq = await client.getUrl(Uri.parse(url));
      dlReq.headers.set('ngrok-skip-browser-warning', '1');
      final dlResp = await dlReq.close();
      if (dlResp.statusCode != HttpStatus.ok) return true;
      final sink = tmp.openWrite();
      await dlResp.pipe(sink); // pipe flushes + closes the sink
      await tmp.rename('${patchDir.path}/libapp.so'); // atomic swap
      await numberFile.writeAsString('$number');
      debugPrint('$_tag installed patch #$number via $base -> next launch');
      return true;
    } finally {
      client.close();
    }
  }
}
