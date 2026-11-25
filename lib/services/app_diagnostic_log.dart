import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_info.dart';

enum DiagnosticEvent {
  startup('App started'),
  storageReady('Local database opened'),
  pageOpened('Page opened'),
  syncChanged('Cloud sync'),
  syncFailed('Cloud sync failed', error: true),
  reportRequested('AI report requested'),
  reportQueued('AI report accepted'),
  reportRequestFailed('AI report request failed', error: true),
  reportReady('AI report ready'),
  reportFailed('AI report failed', error: true),
  flutterError('Flutter error', error: true),
  unhandledError('Unhandled error', error: true),
  startupError('Startup error', error: true);

  const DiagnosticEvent(this.label, {this.error = false});
  final String label;
  final bool error;
}

class DiagnosticEntry {
  const DiagnosticEntry(this.at, this.event, this.detail, this.version);

  final DateTime at;
  final DiagnosticEvent event;
  final String detail;
  final String version;

  String get asText => [
    '${at.toLocal().toIso8601String().split('.').first.replaceFirst('T', ' ')} · v$version · ${event.label}',
    if (detail.isNotEmpty) detail,
  ].join('\n');

  List<Object> get _json => [at.toIso8601String(), event.name, detail, version];
}

/// Recent diagnostics stored on this device with bounded retention.
/// Event metadata uses internal labels. Error details use types and app frames.
abstract final class AppDiagnosticLog {
  static const _key = 'app_diagnostics_v1';
  static const _limit = 160;
  static final _entries = <DiagnosticEntry>[];
  static SharedPreferences? _prefs;
  static bool _enabled = false;
  static bool _dirty = false;
  static bool _writing = false;

  static List<DiagnosticEntry> get recent =>
      List.unmodifiable(_entries.reversed);

  static Future<void> initialize() async {
    if (_enabled) return;
    _enabled = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as List;
      for (final row in decoded.take(_limit).whereType<List>()) {
        if (row.length != 4) continue;
        final at = DateTime.tryParse('${row[0]}');
        final event = DiagnosticEvent.values
            .where((event) => event.name == row[1])
            .firstOrNull;
        if (at != null && event != null) {
          _entries.add(DiagnosticEntry(at, event, '${row[2]}', '${row[3]}'));
        }
      }
    } catch (_) {
      // Diagnostics must never prevent the app from opening.
    }
  }

  static void record(DiagnosticEvent event, [String detail = '']) {
    // Refuse free-form strings at routine call sites.
    if (!RegExp(r'^[a-zA-Z0-9_-]{0,48}$').hasMatch(detail)) return;
    _append(event, detail);
  }

  static ({String message, String stack}) describeError(
    Object error,
    StackTrace? stack,
  ) {
    final type = error.runtimeType.toString();
    final message = error.toString().startsWith('A RenderFlex overflowed')
        ? 'Layout overflow'
        : type;
    final frames = RegExp(
      r'(?:package:client_tracker/[a-zA-Z0-9_./]+\.dart|main\.dart\.js):\d+(?::\d+)?',
    ).allMatches(stack?.toString() ?? '').map((frame) => frame[0]!).take(12);
    return (message: message, stack: frames.join('\n'));
  }

  static void recordError(
    DiagnosticEvent event,
    ({String message, String stack}) error,
  ) {
    _append(
      event,
      [error.message, if (error.stack.isNotEmpty) error.stack].join('\n'),
    );
  }

  static void _append(DiagnosticEvent event, String detail) {
    if (!_enabled) return;
    final now = DateTime.now();
    final last = _entries.lastOrNull;
    if (last?.event == event &&
        last?.detail == detail &&
        now.difference(last!.at) < const Duration(seconds: 5)) {
      return;
    }
    _entries.add(DiagnosticEntry(now, event, detail, AppInfo.version));
    if (_entries.length > _limit) _entries.removeAt(0);
    _dirty = true;
    unawaited(_save());
  }

  static Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null || _writing) return;
    _writing = true;
    try {
      while (_dirty) {
        _dirty = false;
        await prefs.setString(
          _key,
          jsonEncode(_entries.map((entry) => entry._json).toList()),
        );
      }
    } catch (_) {
      // The in-memory log remains readable when persistence fails.
    } finally {
      _writing = false;
    }
  }
}
