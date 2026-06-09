import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// In-house code-push updater (local/dev). Host-agnostic: it tries each base
/// URL in order and uses the first that responds — `localhost` works on a USB
/// device via `adb reverse tcp:8080 tcp:8080`, and `10.0.2.2` is the Android
/// emulator's alias for the host. The patch is downloaded from that SAME base
/// (using only the path from the check response), so one build works on both
/// the phone and the emulator regardless of how each reaches the host.
///
/// Fire-and-forget at startup; fully best-effort (never blocks the first frame
/// or crashes); writes atomically so the hook never loads a half-written file.
class InhouseUpdater {
  // TODO: configure for your deployment. The updater tries each base in order
  // and uses the first that responds, so you can keep several:
  //   - your public URL (ngrok / cloudflared / your domain) for real devices
  //   - localhost  -> a USB device via `adb reverse tcp:8080 tcp:8080`
  //   - 10.0.2.2   -> the Android emulator's alias for the host machine
  static const List<String> _bases = <String>[
    // 'https://your-tunnel.example.com',
    'http://localhost:8080',
    'http://10.0.2.2:8080',
  ];
  // TODO: set to YOUR app's package id and the release version it ships as.
  // _releaseVersion MUST equal the installed app's version — a patch only loads
  // on the exact release it was built against (see docs/ARCHITECTURE.md).
  static const String _appId = 'com.example.app';
  static const String _releaseVersion = '1.0.0';
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
