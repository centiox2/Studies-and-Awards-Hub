import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/ai_summary_service.dart';
import '../../services/app_diagnostic_log.dart';
import '../../services/cloud/cloud_api.dart';
import '../../state/app_state.dart';
import '../../widgets/panels.dart';
import 'report_document.dart';
import 'template_report_document.dart';

String _reportDate(Object? raw) {
  final value = raw?.toString() ?? '';
  final date = DateTime.tryParse(value);
  return date == null ? value : DateFormat('d MMM y').format(date);
}

String? _stamp(Object? raw) {
  final date = DateTime.tryParse('$raw');
  if (date == null) return null;
  final nairobi = date.toUtc().add(const Duration(hours: 3));
  return "${DateFormat('d MMM y, HH:mm').format(nairobi)} EAT";
}

Map<String, Map> _reports(Object? value) {
  if (value is! List) return {};
  final rows = <String, Map>{};
  for (final row in value.whereType<Map>()) {
    final date = row['summary_date'];
    if (date is String &&
        DateTime.tryParse(date) != null &&
        row['content'] is Map) {
      rows.putIfAbsent(date, () => row);
    }
  }
  return rows;
}

class AiSummaryPreview extends ConsumerWidget {
  const AiSummaryPreview({super.key, this.bottomPadding = 24});
  final double bottomPadding;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiSummaryAccessProvider.select(summaryAccessGranted))) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(aiSummariesProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: AppPanel(
        title: 'AI daily summary',
        compactHeader: true,
        trailingWidget: IconButton(
          onPressed: () =>
              ref.read(appActionsProvider).selectTab(AppTab.aiSummary),
          tooltip: 'Read full summary',
          icon: const Icon(Icons.arrow_forward, size: 18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: state.when(
            loading: () => const Text('Loading AI summary…'),
            error: (_, _) => const Text(
              'Unable to load the summary. Open the summary page to retry.',
            ),
            data: (data) {
              final latest = _reports(data['summaries']).values.firstOrNull;
              final brief = (latest?['content'] as Map?)?['brief'];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summaryStatus(data)),
                  if (data['can_generate'] == true) ...[
                    const SizedBox(height: 12),
                    AiGenerateReportButton(data: data),
                  ],
                  if (latest != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Latest · ${_reportDate(latest['summary_date'])}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    if (brief is String && brief.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(brief),
                    ],
                    if (_stamp(latest['cutoff_at']) case final cutoff?) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Data as of $cutoff',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class AiSummaryScreen extends ConsumerStatefulWidget {
  const AiSummaryScreen({super.key});
  @override
  ConsumerState<AiSummaryScreen> createState() => _AiSummaryScreenState();
}

class _AiSummaryScreenState extends ConsumerState<AiSummaryScreen> {
  String? _selectedDate;
  bool _detailed = false;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(aiSummaryAccessProvider.select(summaryAccessGranted))) {
      final access = ref.watch(aiSummaryAccessProvider);
      return ReportReader(
        template: null,
        reportDate: null,
        detailed: false,
        header: const _ReportHeader(),
        fallback: access.isLoading
            ? const Text('Checking access…')
            : access.hasError
            ? _ReportNotice(
                message: 'Unable to check report access.',
                onRetry: () => ref.invalidate(aiSummaryAccessProvider),
              )
            : const Text(
                'Admin must assign AI summary access to your account.',
              ),
      );
    }
    ref.listen(aiSummariesProvider, (before, after) {
      final previous = before?.value?['status'];
      final current = after.value?['status'];
      if (!const {'queued', 'running'}.contains(previous)) return;
      if (current == 'ready') {
        AppDiagnosticLog.record(DiagnosticEvent.reportReady);
      } else if (current == 'failed') {
        AppDiagnosticLog.record(DiagnosticEvent.reportFailed);
      }
    });
    final state = ref.watch(aiSummariesProvider);
    final data = state.when(
      data: (data) => data,
      loading: () => null,
      error: (_, _) => null,
    );
    final rows = _reports(data?['summaries']);
    final date = rows.containsKey(_selectedDate)
        ? _selectedDate
        : rows.keys.firstOrNull;
    final row = rows[date];
    final content = row?['content'] as Map?;
    final savedTemplate = content?['template'];
    final template = savedTemplate is Map && savedTemplate['version'] == 1
        ? savedTemplate
        : null;
    final cutoff = _stamp(row?['cutoff_at']);
    final fallback = switch ((data, row, template)) {
      (null, _, _) =>
        state.isLoading
            ? const Align(
                alignment: AlignmentDirectional.topStart,
                child: CircularProgressIndicator(),
              )
            : _ReportNotice(
                message: 'Unable to load AI summaries.',
                onRetry: () => ref.invalidate(aiSummariesProvider),
              ),
      (_, null, _) => const Text('No reports yet.'),
      (_, final saved?, null) => ReportDocument(
        row: saved,
        detailed: _detailed,
      ),
      _ => null,
    };
    return ReportReader(
      template: template,
      reportDate: date,
      detailed: _detailed,
      header: _ReportHeader(
        data: data,
        dates: rows.keys,
        date: date,
        cutoff: cutoff,
        detailed: _detailed,
        onView: (value) => setState(() => _detailed = value),
        onDate: (value) => setState(() => _selectedDate = value),
        onRefresh: data == null
            ? null
            : () => ref.invalidate(aiSummariesProvider),
        refreshing: state.isLoading,
      ),
      fallback: fallback,
    );
  }
}

class _ReportNotice extends StatelessWidget {
  const _ReportNotice({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(message),
      TextButton(onPressed: onRetry, child: const Text('Retry')),
    ],
  );
}

class _ReportHeader extends StatelessWidget {
  const _ReportHeader({
    this.data,
    this.dates = const [],
    this.date,
    this.cutoff,
    this.detailed = false,
    this.onView,
    this.onDate,
    this.onRefresh,
    this.refreshing = false,
  });

  final Map<String, dynamic>? data;
  final Iterable<String> dates;
  final String? date;
  final String? cutoff;
  final bool detailed;
  final ValueChanged<bool>? onView;
  final ValueChanged<String?>? onDate;
  final VoidCallback? onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.clarity;
    final reportState = data;
    final canGenerate = reportState?['can_generate'] == true;
    final status = switch (reportState?['status']) {
      'ready' when reportState?['enabled'] == true =>
        'Scheduled daily at 5:05 pm EAT.',
      'ready' => 'Daily schedule is off.',
      _ when reportState != null => summaryStatus(reportState),
      _ => null,
    };
    final factsStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.textMuted,
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                'AI summary',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontSize: MediaQuery.sizeOf(context).width < 480 ? 24 : 28,
                ),
              ),
            ),
            if (onRefresh != null)
              IconButton(
                key: const ValueKey('refresh-ai-reports'),
                tooltip: 'Refresh reports',
                visualDensity: VisualDensity.compact,
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
              ),
          ],
        ),
        if (cutoff != null) ...[
          const SizedBox(height: 5),
          Text('Data as of $cutoff', style: factsStyle),
        ],
        if (status != null) ...[
          const SizedBox(height: 4),
          Semantics(liveRegion: true, child: Text(status, style: factsStyle)),
        ],
      ],
    );

    ChoiceChip viewChip(String label, bool isDetailed) {
      final selected = detailed == isDetailed;
      return ChoiceChip(
        key: ValueKey(
          isDetailed ? 'report-detailed-view' : 'report-summary-view',
        ),
        label: Text(label),
        selected: selected,
        selectedColor: colors.accentSoft,
        side: BorderSide(color: selected ? colors.accent : colors.border),
        showCheckmark: false,
        onSelected: (_) => onView?.call(isDetailed),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final wide = box.maxWidth >= scaler.scale(1000);
        final controls = Wrap(
          alignment: wide ? WrapAlignment.end : WrapAlignment.start,
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (dates.isNotEmpty) ...[
              SizedBox(
                width: scaler.scale(162).clamp(0.0, box.maxWidth),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Report date',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('report-date-picker'),
                      value: date,
                      isExpanded: true,
                      isDense: true,
                      menuMaxHeight: 420,
                      items: [
                        for (final date in dates)
                          DropdownMenuItem(
                            value: date,
                            child: Text(
                              _reportDate(date),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: onDate,
                    ),
                  ),
                ),
              ),
              viewChip('Quick View', false),
              viewChip('Detailed report', true),
            ],
            if (canGenerate) AiGenerateReportButton(data: reportState!),
          ],
        );
        final hasControls = dates.isNotEmpty || canGenerate;
        if (hasControls && wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: title),
              const SizedBox(width: 24),
              Flexible(
                flex: 2,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: controls,
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            if (hasControls) ...[const SizedBox(height: 12), controls],
          ],
        );
      },
    );
  }
}

/// Requests a server-side refresh; the key never leaves the server.
class AiGenerateReportButton extends ConsumerStatefulWidget {
  const AiGenerateReportButton({super.key, required this.data});
  final Map<String, dynamic> data;
  @override
  ConsumerState<AiGenerateReportButton> createState() =>
      _AiGenerateReportButtonState();
}

class _AiGenerateReportButtonState
    extends ConsumerState<AiGenerateReportButton> {
  bool _busy = false;
  Future<void> _generate() async {
    setState(() => _busy = true);
    var requested = false;
    try {
      await ref.read(aiSummaryServiceProvider).generate();
      requested = true;
      if (!mounted) return;
      ref.invalidate(aiSummariesProvider);
      await ref.read(aiSummariesProvider.future);
    } catch (error) {
      if (mounted) {
        final needsKey =
            error is CloudException && error.code == 'gemini_key_required';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              requested
                  ? 'Report requested. Refresh the page to check its progress.'
                  : needsKey
                  ? 'Add your Gemini API key in Settings → Team → AI daily summary.'
                  : 'Could not request the report. Try again shortly.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data['can_generate'] != true) return const SizedBox.shrink();
    final active =
        _busy || const {'queued', 'running'}.contains(widget.data['status']);
    final configured = widget.data['configured'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          key: const ValueKey('generate-ai-report'),
          onPressed: active || !configured ? null : _generate,
          icon: active
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_outlined, size: 18),
          label: Text(active ? 'Generating report…' : 'Generate report now'),
        ),
        if (!configured)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Add your Gemini API key in Settings → Team → AI daily summary first.',
            ),
          ),
      ],
    );
  }
}
