import 'dart:convert';

import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/screens/settings/diagnostics_section.dart';
import 'package:client_tracker/screens/settings/settings_screen.dart';
import 'package:client_tracker/services/app_diagnostic_log.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/state/cloud_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'app_diagnostics_v1': jsonEncode([
        ['2026-11-25T12:05:00.000Z', 'unhandledError', 'StateError', '1.9.16'],
      ]),
    });
    await AppDiagnosticLog.initialize();
  });

  test(
    'keeps recent events and errors and preserves safe request metadata',
    () async {
      final legacy = AppDiagnosticLog.recent.single;
      expect(legacy.asText, contains('15:05:00.000 EAT'));
      expect(legacy.version, '1.9.16');
      for (var i = 0; i < 1020; i++) {
        AppDiagnosticLog.record(DiagnosticEvent.syncChanged, 'test-$i');
      }
      final trace = AppDiagnosticLog.request('ai_summary_configure')!;
      trace.finish(failure: 'needs_update', serverCode: 'PGRST202');
      final error = AppDiagnosticLog.describeError(
        StateError('This exception contains private input'),
        StackTrace.fromString(
          '#0 open (package:client_tracker/main.dart:21:5)',
        ),
      );
      AppDiagnosticLog.recordError(DiagnosticEvent.unhandledError, error);
      expect(AppDiagnosticLog.recent, hasLength(1000));
      expect(AppDiagnosticLog.recent, contains(legacy));
      expect(AppDiagnosticLog.recent.first.asText, contains('main.dart:21:5'));
      expect(
        AppDiagnosticLog.recent[1].asText,
        contains('ms · needs_update · server code PGRST202'),
      );
      expect(AppDiagnosticLog.recent[1].asText, contains('request #1'));
      expect(AppDiagnosticLog.recent[2].asText, contains('request #1'));
      await AppDiagnosticLog.flush();
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('app_diagnostics_v1')!;
      expect(jsonDecode(stored), hasLength(1000));
      expect(stored, isNot(contains('private input')));
    },
  );

  testWidgets('Settings Diagnostics updates live and copies an export', (
    tester,
  ) async {
    final db = openInMemoryDatabase();
    addTearDown(db.close);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-cat-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic log'), findsOneWidget);

    AppDiagnosticLog.record(
      DiagnosticEvent.localDataChanged,
      'client_count_saved',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('client_count_saved', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('copy-diagnostic-log')));
    await tester.pumpAndSettle();
    expect(copied, contains('S&A Hub diagnostics'));
    expect(copied, contains('client_count_saved'));
    expect(copied, isNot(contains('private input')));
    await AppDiagnosticLog.flush();
  });
  testWidgets('copies server job status and duration', (tester) async {
    final db = openInMemoryDatabase();
    addTearDown(db.close);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          cloudSyncProvider.overrideWith(_DiagnosticsCloud.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DiagnosticsSection(serverAvailable: true)),
        ),
      ),
    );
    await tester.tap(find.text('Server jobs'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-diagnostic-log')));
    await tester.pumpAndSettle();
    expect(copied, contains('AI report · failed'));
    expect(copied, contains('gemini_timeout'));
    expect(copied, contains('1500 ms'));
    expect(copied, isNot(contains('secret report details')));
  });
}

class _DiagnosticsCloud extends CloudSyncController {
  @override
  Future<Object?> callAsUserWhenReady(
    String name, [
    Map<String, Object?>? params,
  ]) async {
    expect(name, 'admin_diagnostics');
    return [
      {
        'at': '2026-11-25T14:05:00Z',
        'operation': 'ai_report',
        'status': 'failed',
        'mode': 'scheduled',
        'code': 'gemini_timeout',
        'elapsed_ms': 1500,
        'body': 'secret report details',
      },
    ];
  }
}
