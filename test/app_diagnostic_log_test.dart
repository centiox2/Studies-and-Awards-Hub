import 'dart:convert';

import 'package:client_tracker/services/app_diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'diagnostics keep a bounded history and omit raw exception details',
    () async {
      SharedPreferences.setMockInitialValues({});
      await AppDiagnosticLog.initialize();
      for (var i = 0; i < 180; i++) {
        AppDiagnosticLog.record(DiagnosticEvent.syncChanged, 'test-$i');
      }
      final error = AppDiagnosticLog.describeError(
        StateError('This exception contains private input'),
        StackTrace.fromString(
          '#0 open (package:client_tracker/main.dart:21:5)',
        ),
      );
      AppDiagnosticLog.recordError(DiagnosticEvent.unhandledError, error);
      expect(AppDiagnosticLog.recent, hasLength(160));
      expect(AppDiagnosticLog.recent.first.asText, contains('main.dart:21:5'));
      expect(
        AppDiagnosticLog.recent.first.asText,
        isNot(contains('private input')),
      );
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('app_diagnostics_v1')!;
      expect(jsonDecode(stored), hasLength(160));
      expect(stored, isNot(contains('private input')));
    },
  );
}
