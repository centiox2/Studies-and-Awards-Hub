import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/ai_summary_service.dart';
import '../../services/app_diagnostic_log.dart';
import '../../services/cloud/cloud_api.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import 'report_document.dart';
import 'template_report_document.dart';

String _reportDate(Object? raw) {
  final value = raw?.toString() ?? '';
  final date = DateTime.tryParse(value);
  return date == null ? value : DateFormat('d MMM y').format(date);
}

String _stamp(Object? raw) {
  final date = DateTime.tryParse('$raw');
  return date == null
      ? '$raw'
      : '${DateFormat('d MMM y, HH:mm').format(date.toUtc().add(const Duration(hours: 3)))} Nairobi';
}

class AiSummaryPreview extends ConsumerWidget {
  const AiSummaryPreview({super.key, this.bottomPadding = 24});
  final double bottomPadding;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!summaryAccessGranted(ref.watch(aiSummaryAccessProvider))) {
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
              final rows = data['summaries'] as List? ?? [];
              final latest = rows.firstOrNull as Map?;
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
                    const SizedBox(height: 8),
                    Text('${(latest['content'] as Map)['brief']}'),
                    const SizedBox(height: 8),
                    Text(
                      'Data as of ${_stamp(latest['cutoff_at'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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
  String? selected;
  bool detailed = false;
  @override
  Widget build(BuildContext context) {
    final access = ref.watch(aiSummaryAccessProvider);
    if (!summaryAccessGranted(access)) {
      return Center(
        child: Text(
          access.isLoading
              ? 'Checking access…'
              : 'Admin must assign AI summary access to your account.',
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
    return ref
        .watch(aiSummariesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Unable to load AI summaries.'),
                TextButton(
                  onPressed: () => ref.invalidate(aiSummariesProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (data) {
            final rows = (data['summaries'] as List? ?? []).cast<Map>();
            final row =
                rows.where((r) => r['summary_date'] == selected).firstOrNull ??
                rows.firstOrNull;
            final content = row?['content'] as Map?;
            final template = content?['template'];
            final hasTemplate = template is Map && template['version'] == 1;
            final header = _ReportHeader(
              data: data,
              rows: rows,
              date: row?['summary_date']?.toString(),
              meta: hasTemplate
                  ? template['meta']?.toString()
                  : row == null
                  ? null
                  : _stamp(row['cutoff_at']),
              detailed: detailed,
              hasTemplate: hasTemplate,
              onView: (value) => setState(() => detailed = value),
              onDate: (value) => setState(() => selected = value),
              onRequested: () => setState(() => selected = null),
            );
            if (hasTemplate) {
              return TemplateReportDocument(
                template: template,
                detailed: detailed,
                header: header,
              );
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(
                clarityHPad(context),
                20,
                clarityHPad(context),
                24,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: 16),
                        if (row != null && content != null)
                          ReportDocument(
                            row: row,
                            detailed: detailed,
                            cutoffLabel: _stamp(row['cutoff_at']),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('No reports yet.'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
  }
}

class _ReportHeader extends StatelessWidget {
  const _ReportHeader({
    required this.data,
    required this.rows,
    required this.date,
    required this.meta,
    required this.detailed,
    required this.hasTemplate,
    required this.onView,
    required this.onDate,
    required this.onRequested,
  });
  final Map<String, dynamic> data;
  final List<Map> rows;
  final String? date;
  final String? meta;
  final bool detailed;
  final bool hasTemplate;
  final ValueChanged<bool> onView;
  final ValueChanged<String?> onDate;
  final VoidCallback onRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.clarity;
    final ready = data['status'] == 'ready';
    final status = ready && data['enabled'] == true
        ? 'Scheduled daily at 5:05 pm EAT.'
        : summaryStatus(data);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AI summary',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: MediaQuery.sizeOf(context).width < 480 ? 24 : 28,
          ),
        ),
        const SizedBox(height: 5),
        if (meta != null)
          Text(
            meta!,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textMuted),
          ),
        const SizedBox(height: 4),
        Text(
          status,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.textMuted),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        final controls = Wrap(
          spacing: 8,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (rows.isNotEmpty) ...[
              SizedBox(
                width: MediaQuery.textScalerOf(context)
                    .scale(162)
                    .clamp(0.0, box.maxWidth),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(date),
                  initialValue: date,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Report date',
                    isDense: true,
                  ),
                  items: [
                    for (final row in rows)
                      DropdownMenuItem(
                        value: '${row['summary_date']}',
                        child: Text(
                          _reportDate(row['summary_date']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: onDate,
                ),
              ),
              ChoiceChip(
                key: const ValueKey('report-summary-view'),
                label: Text(hasTemplate ? 'Quick View' : 'Summary'),
                selected: !detailed,
                selectedColor: colors.accentSoft,
                onSelected: (_) => onView(false),
              ),
              ChoiceChip(
                key: const ValueKey('report-detailed-view'),
                label: const Text('Detailed report'),
                selected: detailed,
                selectedColor: colors.accentSoft,
                onSelected: (_) => onView(true),
              ),
            ],
            if (data['can_generate'] == true)
              AiGenerateReportButton(data: data, onRequested: onRequested),
          ],
        );
        if (box.maxWidth >= MediaQuery.textScalerOf(context).scale(1000)) {
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
          children: [title, const SizedBox(height: 12), controls],
        );
      },
    );
  }
}

/// Requests a server-side refresh; the key never leaves the server.
class AiGenerateReportButton extends ConsumerStatefulWidget {
  const AiGenerateReportButton({
    super.key,
    required this.data,
    this.onRequested,
  });
  final Map<String, dynamic> data;
  final VoidCallback? onRequested;
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
      widget.onRequested?.call();
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
