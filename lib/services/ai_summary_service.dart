import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'app_diagnostic_log.dart';

final aiSummaryServiceProvider = Provider(
  (ref) => AiSummaryService(
    ref.read(cloudSyncProvider.notifier).callAsUserWhenReady,
  ),
);

class AiSummaryService {
  AiSummaryService(this.call);
  final Future<Object?> Function(String, [Map<String, Object?>?]) call;
  Future<bool> access() async => await call('ai_summary_access') == true;
  Future<Map<String, dynamic>> read() async =>
      Map<String, dynamic>.from(await call('ai_summary_read') as Map);
  Future<Map<String, dynamic>> settings() async =>
      Map<String, dynamic>.from(await call('ai_summary_settings') as Map);
  Future<Map<String, dynamic>> generate() async {
    AppDiagnosticLog.record(DiagnosticEvent.reportRequested);
    try {
      final result = Map<String, dynamic>.from(
        await call('ai_summary_generate') as Map,
      );
      AppDiagnosticLog.record(DiagnosticEvent.reportQueued);
      return result;
    } catch (_) {
      AppDiagnosticLog.record(DiagnosticEvent.reportRequestFailed);
      rethrow;
    }
  }

  Future<void> save({
    required bool enabled,
    required String model,
    required List<int> users,
    String? key,
  }) async {
    final replacement = key?.trim();
    await call('ai_summary_configure', {
      'p_enabled': enabled,
      'p_model': model,
      'p_user_ids': users,
      if (replacement != null && replacement.isNotEmpty) 'p_key': replacement,
    });
  }
}

void _refresh(Ref ref, [Duration interval = const Duration(minutes: 1)]) {
  final timer = Timer(interval, () => ref.invalidateSelf());
  ref.onDispose(timer.cancel);
}

final aiSummaryAccessProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (!ref.watch(accountsEnabledProvider) ||
      ref.watch(currentUserProvider.select((user) => user?.id)) == null) {
    return false;
  }
  var failed = false;
  ref.listen(cloudSyncProvider.select((state) => state.phase), (
    previous,
    next,
  ) {
    if (previous != next && next == SyncPhase.live && failed) {
      ref.invalidateSelf();
    }
  });
  try {
    final granted = await ref.watch(aiSummaryServiceProvider).access();
    if (ref.mounted) _refresh(ref);
    return granted;
  } catch (_) {
    failed = true;
    rethrow;
  }
});
final aiSummariesProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  ref.watch(currentUserProvider.select((user) => user?.id));
  final service = ref.watch(aiSummaryServiceProvider);
  // Rechecking access may replace the Future without changing the grant.
  // Only a change to the effective grant should invalidate a loaded report.
  if (!ref.watch(aiSummaryAccessProvider.select(summaryAccessGranted))) {
    throw StateError('Access has not been assigned.');
  }
  final result = await service.read();
  if (ref.mounted && const {'queued', 'running'}.contains(result['status'])) {
    _refresh(ref, const Duration(seconds: 3));
  }
  return result;
});
final aiSummarySettingsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      ref.watch(currentUserProvider);
      return ref.watch(aiSummaryServiceProvider).settings();
    });

String summaryStatus(Map<String, dynamic> data) {
  if (data['status'] == 'queued' || data['status'] == 'running') {
    return 'A new report is being prepared. The last successful report remains available.';
  }
  if (data['status'] == 'failed') {
    final reason = data['error_message'] as String?;
    return reason == null || reason.isEmpty
        ? 'The latest report could not be generated. Earlier reports remain available.'
        : '$reason Earlier successful reports remain available.';
  }
  if (data['status'] == 'ready') {
    return data['enabled'] == true
        ? 'Today’s summary is ready.'
        : 'Your report is ready. The daily schedule is off.';
  }
  if (data['configured'] != true) {
    return 'Waiting for Admin to configure Gemini in Settings.';
  }
  if (data['enabled'] != true) {
    return 'The daily schedule is off. Admin can generate a report at any time.';
  }
  return 'The next summary will be prepared after 5 pm (Nairobi), at 5:05 pm.';
}

bool summaryAccessGranted(AsyncValue<bool> access) =>
    !access.hasError && !access.isReloading && access.value == true;
