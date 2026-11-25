import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/app_diagnostic_log.dart';
import '../../services/app_info.dart';
import '../../services/cloud/cloud_api.dart';
import '../../state/app_state.dart' show currentUserProvider;
import '../../state/cloud_sync.dart';
import '../../widgets/panels.dart';

enum _LogFilter {
  all('All events'),
  app('App'),
  storage('Storage'),
  cloud('Cloud'),
  errors('Errors');

  const _LogFilter(this.label);
  final String label;

  bool includes(DiagnosticEntry entry) => switch (this) {
    all => true,
    app => entry.event.area == DiagnosticArea.app,
    storage => entry.event.area == DiagnosticArea.storage,
    cloud => entry.event.area == DiagnosticArea.cloud,
    errors => entry.event.error,
  };
}

class _ServerEvent {
  const _ServerEvent(this.text, this.error);

  final String text;
  final bool error;

  static _ServerEvent? read(Map row) {
    final timestamp = DateTime.tryParse('${row['at']}');
    if (timestamp == null) return null;
    final operation = switch (row['operation']) {
      'ai_report' => 'AI report',
      'airtable_sync' => 'Airtable sync',
      'schedule' => 'Scheduler invocation',
      _ => 'Server job',
    };
    final status = _identifier(row['status']) ?? 'unknown';
    final mode = _identifier(row['mode']);
    final code = _identifier(row['code']);
    final started = DateTime.tryParse('${row['started_at']}');
    final duration = row['elapsed_ms'];
    final counts = row['counts'];
    return _ServerEvent(
      [
        '${DiagnosticEntry.timestamp(timestamp)} · $operation · $status',
        [
          ?mode,
          if (started != null)
            'Worker started ${DiagnosticEntry.timestamp(started)}',
          if (duration is int && duration >= 0) '$duration ms',
          if (code != null) 'code $code',
          if (counts is Map)
            for (final name in [
              'added',
              'changed',
              'removed',
              'total',
              'pages',
            ])
              if (counts[name] is int) '${counts[name]} $name',
        ].join(' · '),
      ].where((line) => line.isNotEmpty).join('\n'),
      status == 'failed' || status == 'expired',
    );
  }

  static String? _identifier(Object? value) =>
      value is String && RegExp(r'^[a-z0-9_-]{1,63}$').hasMatch(value)
      ? value
      : null;
}

final _serverDiagnosticsProvider =
    FutureProvider.autoDispose<List<_ServerEvent>>((ref) async {
      ref.watch(currentUserProvider.select((user) => user?.id));
      final controller = ref.read(cloudSyncProvider.notifier);
      final result = await controller.callAsUserWhenReady('admin_diagnostics');
      return [
        for (final row in (result as List).whereType<Map>())
          ?_ServerEvent.read(row),
      ];
    }, retry: (_, _) => null);

class DiagnosticsSection extends ConsumerStatefulWidget {
  const DiagnosticsSection({super.key, required this.serverAvailable});
  final bool serverAvailable;

  @override
  ConsumerState<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends ConsumerState<DiagnosticsSection> {
  _LogFilter _filter = _LogFilter.all;
  bool _server = false;

  Future<void> _copy(String text) async {
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      message = 'Diagnostic log copied';
    } catch (_) {
      message = 'Could not copy the diagnostic log';
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final showServer = widget.serverAvailable && _server;
    return AppPanel(
      title: 'Diagnostic log',
      subtitle: showServer
          ? 'Recent AI reports, Airtable sync and scheduler runs. Times are in Nairobi.'
          : 'App activity, cloud requests and errors on this device. Times are in Nairobi.',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (widget.serverAvailable)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('Device log'),
                    selected: !showServer,
                    onSelected: (_) => setState(() => _server = false),
                  ),
                  ChoiceChip(
                    label: const Text('Server jobs'),
                    selected: showServer,
                    onSelected: (_) => setState(() => _server = true),
                  ),
                ],
              ),
            if (showServer)
              _serverLog(ref.watch(_serverDiagnosticsProvider))
            else
              ValueListenableBuilder(
                valueListenable: AppDiagnosticLog.revision,
                builder: (context, _, child) {
                  final entries = AppDiagnosticLog.recent
                      .where(_filter.includes)
                      .toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: MediaQuery.textScalerOf(context).scale(144),
                            child: DropdownButton<_LogFilter>(
                              isExpanded: true,
                              value: _filter,
                              items: [
                                for (final filter in _LogFilter.values)
                                  DropdownMenuItem(
                                    value: filter,
                                    child: Text(
                                      filter.label,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (filter) =>
                                  setState(() => _filter = filter!),
                            ),
                          ),
                          _copyButton(
                            entries.isEmpty
                                ? null
                                : () =>
                                      _copy(AppDiagnosticLog.copyText(entries)),
                          ),
                        ],
                      ),
                      _eventList([
                        for (final entry in entries)
                          (entry.asText, entry.event.error),
                      ], empty: 'No matching events have been recorded.'),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _serverLog(AsyncValue<List<_ServerEvent>> state) {
    final entries = state.value ?? const [];
    final error = state.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _copyButton(
              entries.isEmpty
                  ? null
                  : () => _copy(
                      [
                        'S&A Hub server diagnostics · v${AppInfo.version}',
                        'Copied ${DiagnosticEntry.timestamp(DateTime.now())}',
                        for (final entry in entries) entry.text,
                      ].join('\n\n'),
                    ),
            ),
            OutlinedButton.icon(
              onPressed: state.isLoading
                  ? null
                  : () => ref.invalidate(_serverDiagnosticsProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        if (state.isLoading) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error is CloudException && error.code == 'needs_update'
                ? 'Server job history requires the diagnostics update on the online database.'
                : 'Unable to load server jobs. Check your connection and refresh.',
          ),
        if (entries.isNotEmpty || (!state.isLoading && error == null))
          _eventList([
            for (final entry in entries) (entry.text, entry.error),
          ], empty: 'No recent server jobs.'),
      ],
    );
  }

  Widget _copyButton(VoidCallback? onPressed) => FilledButton.icon(
    key: const ValueKey('copy-diagnostic-log'),
    onPressed: onPressed,
    icon: const Icon(Icons.copy_outlined),
    label: const Text('Copy log'),
  );

  Widget _eventList(List<(String, bool)> rows, {required String empty}) {
    if (rows.isEmpty) return Text(empty);
    final palette = context.clarity;
    final style = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .52,
      child: ListView.separated(
        primary: false,
        itemCount: rows.length,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          final (text, error) = rows[index];
          return SelectableText(
            text,
            style: style?.copyWith(
              color: error ? palette.negativeFg : palette.text,
            ),
          );
        },
      ),
    );
  }
}
