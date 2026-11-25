import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_info.dart';

enum DiagnosticArea {
  app('App'),
  storage('Storage'),
  cloud('Cloud'),
  crash('Crash');

  const DiagnosticArea(this.label);
  final String label;
}

enum DiagnosticEvent {
  startup('App started'),
  lifecycle('App lifecycle'),
  memoryPressure('Memory pressure', error: true),
  pageOpened('Page opened'),
  settingsOpened('Settings section opened'),
  sessionChanged('Session changed'),
  storageReady('Local database opened', area: DiagnosticArea.storage),
  localDataChanged('Local data changed', area: DiagnosticArea.storage),
  backupStarted('Automatic backup started', area: DiagnosticArea.storage),
  backupSaved('Automatic backup saved', area: DiagnosticArea.storage),
  backupFailed(
    'Automatic backup failed',
    area: DiagnosticArea.storage,
    error: true,
  ),
  syncChanged('Cloud sync', area: DiagnosticArea.cloud),
  syncFailed('Cloud sync failed', area: DiagnosticArea.cloud, error: true),
  syncCompleted('Cloud sync finished', area: DiagnosticArea.cloud),
  realtime('Live connection', area: DiagnosticArea.cloud),
  rpcStarted('Cloud request started', area: DiagnosticArea.cloud),
  rpcSucceeded('Cloud request completed', area: DiagnosticArea.cloud),
  rpcFailed('Cloud request failed', area: DiagnosticArea.cloud, error: true),
  reportRequested('AI report requested'),
  reportQueued('AI report accepted', area: DiagnosticArea.cloud),
  reportRequestFailed(
    'AI report request failed',
    area: DiagnosticArea.cloud,
    error: true,
  ),
  reportReady('AI report ready', area: DiagnosticArea.cloud),
  reportFailed('AI report failed', area: DiagnosticArea.cloud, error: true),
  flutterError('Flutter error', area: DiagnosticArea.crash, error: true),
  unhandledError('Unhandled error', area: DiagnosticArea.crash, error: true),
  startupError('Startup error', area: DiagnosticArea.crash, error: true);

  const DiagnosticEvent(
    this.label, {
    this.area = DiagnosticArea.app,
    this.error = false,
  });
  final String label;
  final DiagnosticArea area;
  final bool error;
}

class DiagnosticEntry {
  const DiagnosticEntry(this.at, this.event, this.detail, this.version);

  final DateTime at;
  final DiagnosticEvent event;
  final String detail;
  final String version;

  static String timestamp(DateTime at) {
    final local = at.toUtc().add(const Duration(hours: 3)).toIso8601String();
    return '${local.substring(0, 23).replaceFirst('T', ' ')} EAT';
  }

  String get asText => [
    '${timestamp(at)} · v$version · ${event.area.label} · ${event.label}',
    if (detail.isNotEmpty) detail,
  ].join('\n');

  List<Object> get _json => [at.toIso8601String(), event.name, detail, version];
}

class DiagnosticRequest {
  DiagnosticRequest._(this._operation, this._id);
  final String _operation;
  final int _id;
  final _elapsed = Stopwatch()..start();

  String get _label => '$_operation · request #$_id';

  void finish({String? failure, String? serverCode}) {
    _elapsed.stop();
    AppDiagnosticLog._append(
      failure == null
          ? DiagnosticEvent.rpcSucceeded
          : DiagnosticEvent.rpcFailed,
      [
        _label,
        '${_elapsed.elapsedMilliseconds} ms',
        if (failure != null) AppDiagnosticLog._identifier(failure),
        if (serverCode != null)
          'server code ${AppDiagnosticLog._identifier(serverCode)}',
      ].join(' · '),
    );
  }
}

/// A bounded local timeline. Routine entries accept technical labels and
/// aggregate counts only. Errors contain types and app frames.
abstract final class AppDiagnosticLog {
  static const _key = 'app_diagnostics_v1';
  static const _limit = 1000;
  static const _keepErrors = 100;
  static final _revision = ValueNotifier(0);
  static final _entries = <DiagnosticEntry>[];
  static final _token = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');
  static SharedPreferences? _prefs;
  static Future<void>? _initialization;
  static Future<void>? _saveInFlight;
  static Timer? _writeTimer;
  static bool _enabled = false;
  static bool _dirty = false;
  static bool _notificationPending = false;
  static int _requestNumber = 0;

  static ValueListenable<int> get revision => _revision;

  static List<DiagnosticEntry> get recent =>
      List.unmodifiable(_entries.reversed);

  static String copyText(Iterable<DiagnosticEntry> entries) => [
    'S&A Hub diagnostics · v${AppInfo.version} · ${AppInfo.platform}',
    'Copied ${DiagnosticEntry.timestamp(DateTime.now())}',
    for (final entry in entries) entry.asText,
  ].join('\n\n');

  static Future<void> initialize() => _initialization ??= _load();

  static Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as List;
      for (final row in decoded.whereType<List>()) {
        if (row.length != 4 || row.last is! String || row[2] is! String) {
          continue;
        }
        final at = DateTime.tryParse('${row[0]}');
        final event = DiagnosticEvent.values
            .where((e) => e.name == row[1])
            .firstOrNull;
        if (at != null && event != null) {
          _entries.add(
            DiagnosticEntry(at, event, row[2] as String, row.last as String),
          );
        }
      }
      _trim();
    } catch (_) {
      // Diagnostics must never prevent the app from opening.
    } finally {
      _enabled = true;
      _revision.value++;
    }
  }

  static String _identifier(String value) =>
      _token.hasMatch(value) ? value : 'unknown';

  static void record(DiagnosticEvent event, [String detail = '']) {
    if (detail.isNotEmpty && !_token.hasMatch(detail)) return;
    _append(event, detail);
  }

  static DiagnosticRequest? request(String operation) {
    if (!_enabled) return null;
    final request = DiagnosticRequest._(
      _identifier(operation),
      ++_requestNumber,
    );
    _append(DiagnosticEvent.rpcStarted, request._label);
    return request;
  }

  static void syncCompleted({
    required String operation,
    required Duration elapsed,
    required int pending,
    required int held,
    bool? changed,
  }) {
    _append(
      DiagnosticEvent.syncCompleted,
      [
        _identifier(operation),
        '${elapsed.inMilliseconds} ms',
        '$pending pending',
        '$held held back',
        if (changed != null)
          changed ? 'local data updated' : 'no local changes',
      ].join(' · '),
    );
  }

  static ({String message, String stack}) describeError(
    Object error,
    StackTrace? stack,
  ) {
    // Avoid pulling raw messages into the log, even on failed API and DB calls.
    final message =
        error is FlutterError &&
            error.diagnostics.firstOrNull?.toDescription().startsWith(
                  'A RenderFlex overflowed',
                ) ==
                true
        ? 'Layout overflow'
        : _identifier(error.runtimeType.toString());
    final frames = RegExp(
      r'(?:package:client_tracker/[a-zA-Z0-9_./]+\.dart|main\.dart\.js):\d+(?::\d+)?',
    ).allMatches(stack?.toString() ?? '').map((frame) => frame[0]!).take(16);
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

  static void _trim() {
    var errors = _entries.where((entry) => entry.event.error).length;
    while (_entries.length > _limit) {
      final preserveError = _entries.first.event.error && errors <= _keepErrors;
      final index = preserveError
          ? _entries.indexWhere((entry) => !entry.event.error)
          : 0;
      if (_entries.removeAt(index).event.error) errors--;
    }
  }

  static void _append(DiagnosticEvent event, String detail) {
    if (!_enabled) return;
    final now = DateTime.now().toUtc();
    final last = _entries.lastOrNull;
    if (last?.event == event &&
        last?.detail == detail &&
        now.difference(last!.at) < const Duration(seconds: 5)) {
      return;
    }
    _entries.add(DiagnosticEntry(now, event, detail, AppInfo.version));
    if (_entries.length > _limit) _trim();
    _dirty = true;
    if (!_notificationPending) {
      _notificationPending = true;
      scheduleMicrotask(() {
        _notificationPending = false;
        _revision.value++;
      });
    }
    if (event.error || event == DiagnosticEvent.startup) {
      unawaited(flush());
    } else {
      _writeTimer ??= Timer(const Duration(milliseconds: 350), flush);
    }
  }

  static Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    final prefs = _prefs;
    if (prefs == null) return;
    final pending = _saveInFlight ??= _save(prefs);
    await pending;
    if (identical(_saveInFlight, pending)) _saveInFlight = null;
  }

  static Future<void> _save(SharedPreferences prefs) async {
    try {
      while (_dirty) {
        _dirty = false;
        final saved = await prefs.setString(
          _key,
          jsonEncode(_entries.map((entry) => entry._json).toList()),
        );
        if (!saved) {
          _dirty = true;
          return;
        }
      }
    } catch (_) {
      // The in-memory log remains readable when persistence fails.
      _dirty = true;
    }
  }
}
