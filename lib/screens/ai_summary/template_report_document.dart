import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../../design/app_theme.dart';
import '../../widgets/clarity.dart';

/// A responsive report with a persistent index when the viewport has room.
class TemplateReportDocument extends StatefulWidget {
  const TemplateReportDocument({
    super.key,
    required this.template,
    required this.detailed,
    required this.header,
  });

  final Map template;
  final bool detailed;
  final Widget header;

  @override
  State<TemplateReportDocument> createState() => _TemplateReportDocumentState();
}

class _TemplateReportDocumentState extends State<TemplateReportDocument> {
  final _scroll = ScrollController();
  final _anchors = <String, GlobalKey>{};
  String? _active;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateIndex);
  }

  @override
  void didUpdateWidget(TemplateReportDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detailed != widget.detailed ||
        oldWidget.template['meta'] != widget.template['meta']) {
      _active = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double? _offset(String title) {
    final render = _anchors[title]?.currentContext?.findRenderObject();
    if (render == null || !render.attached) return null;
    return RenderAbstractViewport.maybeOf(render)
        ?.getOffsetToReveal(render, 0)
        .offset;
  }

  void _updateIndex() {
    if (!_scroll.hasClients || !widget.detailed) return;
    String? next;
    final position = _scroll.position;
    for (final title in _anchors.keys) {
      final offset = _offset(title);
      if (offset == null) continue;
      if (next == null || offset <= position.pixels + 24) next = title;
      if (position.maxScrollExtent > 0 && position.extentAfter < 2) {
        next = title;
      }
    }
    if (next != _active && mounted) setState(() => _active = next);
  }

  void _jump(String title) {
    final offset = _offset(title);
    if (offset == null || !_scroll.hasClients) return;
    final target = (offset - 10).clamp(0.0, _scroll.position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 270),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final quick = _blocks(widget.template['quick']);
    final sections = widget.detailed
        ? _sections(widget.template)
        : <String, List<Map>>{};
    _anchors.removeWhere((title, _) => !sections.containsKey(title));
    for (final title in sections.keys) {
      _anchors.putIfAbsent(title, GlobalKey.new);
    }
    final active = sections.containsKey(_active)
        ? _active
        : sections.keys.firstOrNull;

    return LayoutBuilder(
      builder: (context, viewport) {
        final pad = viewport.maxWidth >= 1080 ? 36.0 : clarityHPad(context);
        final wide =
            widget.detailed &&
            viewport.maxWidth >= MediaQuery.textScalerOf(context).scale(760) &&
            viewport.maxHeight >= 460;
        final colors = context.clarity;
        final header = Padding(
          padding: EdgeInsets.fromLTRB(
            pad,
            viewport.maxHeight < 460 ? 14 : 24,
            pad,
            16,
          ),
          child: widget.header,
        );
        final cards = [
          for (final entry in sections.entries)
            Padding(
              key: _anchors[entry.key],
              padding: const EdgeInsets.only(bottom: 18),
              child: _SectionCard(title: entry.key, blocks: entry.value),
            ),
        ];
        if (wide) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1320),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: pad),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 222,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: ClarityCard(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        10,
                                        5,
                                        10,
                                        8,
                                      ),
                                      child: _SectionLabel('On this page'),
                                    ),
                                    for (final title in sections.keys)
                                      TextButton(
                                        key: ValueKey('report-jump-$title'),
                                        style: TextButton.styleFrom(
                                          alignment:
                                              AlignmentDirectional.centerStart,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 9,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          foregroundColor: title == active
                                              ? colors.accent
                                              : colors.textSecondary,
                                          backgroundColor: title == active
                                              ? colors.accentSoft
                                              : null,
                                        ),
                                        onPressed: () => _jump(title),
                                        child: Semantics(
                                          selected: title == active,
                                          child: Text(
                                            title,
                                            style: TextStyle(
                                              fontWeight: title == active
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 22),
                          Expanded(
                            child: SingleChildScrollView(
                              key: const ValueKey('report-reading-column'),
                              controller: _scroll,
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: cards,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        Widget centered(Widget child) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: child,
          ),
        );
        if (active != null) {
          return CustomScrollView(
            key: const ValueKey('report-reading-column'),
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(child: centered(header)),
              PinnedHeaderSliver(
                child: ColoredBox(
                  color: colors.bg,
                  child: centered(
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
                      child: DropdownButton<String>(
                        key: const ValueKey('report-section-index'),
                        isExpanded: true,
                        value: active,
                        menuMaxHeight: 360,
                        selectedItemBuilder: (context) => [
                          for (final title in sections.keys)
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                'On this page · $title',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        items: [
                          for (final title in sections.keys)
                            DropdownMenuItem(value: title, child: Text(title)),
                        ],
                        onChanged: (title) {
                          if (title != null) _jump(title);
                        },
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: centered(
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 5, pad, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: cards,
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          key: const ValueKey('report-reading-column'),
          controller: _scroll,
          child: centered(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Padding(
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
                  child: ClarityCard(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final block in quick)
                          _ReportBlock(
                            block: _quickBlock(block),
                            compact: true,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

List<Map> _blocks(Object? value) =>
    value is List ? value.whereType<Map>().toList() : [];

String _title(Map block) =>
    '${block['text'] ?? ''}'.replaceFirst(RegExp(r'^\d+\.\s*'), '');

/// Older saved templates use the same blocks but group several sections together.
Map<String, List<Map>> _sections(Map template) {
  const order = [
    'Summary',
    'Needs attention',
    'Pipeline overview',
    'Staff activity',
    'Status changes today',
    'Milestones and dates',
    'Data notes',
  ];
  final sections = <String, List<Map>>{};
  String? section;
  for (final block in _blocks(template['detailed'])) {
    if (block['kind'] == 'heading') {
      section = switch (_title(block).toLowerCase()) {
        'summary' => 'Summary',
        'needs attention' => 'Needs attention',
        'pipeline overview' => 'Pipeline overview',
        'staff activity' => 'Staff activity',
        'status changes today' ||
        'application activity today' => 'Status changes today',
        'milestones and dates' => 'Milestones and dates',
        'data notes' => 'Data notes',
        _ => null,
      };
      if (section != null) sections.putIfAbsent(section, () => []);
      continue;
    }
    if (section == 'Status changes today' &&
        _title(block) == 'Milestones and dates') {
      section = 'Milestones and dates';
      sections.putIfAbsent(section, () => []);
      continue;
    }
    if (section == null) continue;
    if (section == 'Summary' && block['kind'] == 'text') continue;
    if (section == 'Staff activity' &&
        block['kind'] == 'text' &&
        '${block['text']}'.contains('daily report activity')) {
      sections[section]!.add({
        ...block,
        'text': 'Activity is based on recorded client counts and work updates.',
      });
    } else {
      sections[section]!.add(block);
    }
  }
  return {
    for (final title in order)
      if (sections.containsKey(title)) title: sections[title]!,
  };
}

bool _keepAlert(String line) =>
    !line.contains('overdue ·') && !line.startsWith('0 daily reports');

Map _quickBlock(Map block) {
  if (block['kind'] == 'text' &&
      '${block['text']}'.contains('daily reports submitted')) {
    return {...block, 'text': '${block['text']}'.split(' · ').first};
  }
  if (block['kind'] != 'bullets') return block;
  final items = (block['items'] as List? ?? [])
      .whereType<String>()
      .where(_keepAlert)
      .toList();
  if (items.isEmpty) {
    return {'kind': 'text', 'text': 'Nothing needs attention.'};
  }
  return {
    ...block,
    'items': items
        .map((line) => line.replaceAll('to-do or follow-up', 'follow-up'))
        .toList(),
  };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: context.clarity.accent,
      letterSpacing: 1.1,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.blocks});
  final String title;
  final List<Map> blocks;

  @override
  Widget build(BuildContext context) => ClarityCard(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: _SectionLabel(title)),
        const SizedBox(height: 10),
        for (final block in blocks) _block(block),
      ],
    ),
  );

  Widget _block(Map block) {
    final headers = (block['columns'] as List? ?? [])
        .whereType<String>()
        .toList();
    final rows = (block['rows'] as List? ?? []).whereType<List>().toList();
    if (headers.firstOrNull == 'Status' && title == 'Pipeline overview') {
      return _Pipeline(rows: rows);
    }
    if (headers.firstOrNull == 'Time (EAT)') {
      return _StatusTimeline(headers: headers, rows: rows);
    }
    if (title == 'Summary' && headers.firstOrNull == 'Measure') {
      final attention = rows
          .where((r) => r.length > 1 && r[0] == 'Revenue details')
          .firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetricTiles(
            items: [
              for (final row in rows)
                if (row.length > 1 &&
                    !const {
                      'Daily reports submitted',
                      'Team to-do items completed',
                      'Revenue details',
                    }.contains(row[0]))
                  ('${row[0]}', '${row[1]}'),
            ],
          ),
          if (attention != null)
            _ReportBlock(
              block: {'kind': 'text', 'text': attention[1]},
              compact: false,
            ),
        ],
      );
    }
    if (title == 'Milestones and dates' && headers.length == 2) {
      return _MetricTiles(
        items: [
          for (final row in rows)
            if (row.length > 1)
              (
                '${row[0]}'.replaceFirst('To-do or follow-up', 'Follow-up'),
                '${row[1]}',
              ),
        ],
      );
    }
    if (title == 'Needs attention' && block['kind'] == 'bullets') {
      final items = [
        for (final item in (block['items'] as List? ?? []).whereType<String>())
          for (final line in item.split('\n'))
            if (_keepAlert(line))
              line.replaceAll('to-do or follow-up', 'follow-up'),
      ];
      final numeric = RegExp(r'^(\d[\d,]*) (.+)$');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetricTiles(
            warning: true,
            items: [
              for (final item in items)
                if (numeric.firstMatch(item) case final match?)
                  if (!item.contains('follow-up updates'))
                    (match[2]!, match[1]!),
            ],
          ),
          _ReportBlock(
            block: {
              'kind': items.isEmpty ? 'text' : 'bullets',
              'text': 'Nothing needs attention.',
              'items': items
                  .where(
                    (item) =>
                        !numeric.hasMatch(item) ||
                        item.contains('follow-up updates'),
                  )
                  .toList(),
            },
            compact: false,
          ),
        ],
      );
    }
    if (headers.firstOrNull == 'Staff member') {
      final shown = [
        for (final (i, header) in headers.indexed)
          if (header != 'Reports submitted') i,
      ];
      return _ReportTable(
        block: {
          ...block,
          'columns': [for (final i in shown) headers[i]],
          'rows': [
            for (final row in rows)
              [
                for (final i in shown)
                  if (i < row.length) row[i],
              ],
          ],
        },
        compact: false,
      );
    }
    return _ReportBlock(block: block, compact: false);
  }
}

class _MetricTiles extends StatelessWidget {
  const _MetricTiles({required this.items, this.warning = false});
  final List<(String, String)> items;
  final bool warning;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final ideal = MediaQuery.textScalerOf(context).scale(148);
      final cols = ((box.maxWidth + 10) / (ideal + 10)).floor().clamp(1, 3);
      final width = (box.maxWidth - (cols - 1) * 10) / cols;
      final theme = Theme.of(context);
      final colors = context.clarity;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final (label, value) in items)
            SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: warning
                              ? colors.negativeFg
                              : label == 'Net revenue'
                              ? colors.accent
                              : colors.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _StatusTimeline extends StatelessWidget {
  const _StatusTimeline({required this.headers, required this.rows});
  final List<String> headers;
  final List<List> rows;

  @override
  Widget build(BuildContext context) {
    final from = headers.indexOf('From');
    final to = headers.indexOf('To');
    final changes = [
      for (final row in rows)
        if (from >= 0 &&
            to >= 0 &&
            row.length >= headers.length &&
            row.any((cell) => cell != '—'))
          ('${row[0]}', '${row[1]}', '${row[from]} → ${row[to]}'),
    ];
    if (changes.isEmpty) return const Text('No status changes recorded.');
    final theme = Theme.of(context);
    final colors = context.clarity;
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= MediaQuery.textScalerOf(context).scale(540)) {
          return _ReportTable(
            block: {
              'columns': ['Time (EAT)', 'Client', 'From → To'],
              'rows': [
                for (final (time, client, change) in changes)
                  [time, client, change],
              ],
            },
            compact: false,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (time, client, change) in changes)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: colors.borderSubtle),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          time,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.accent,
                          ),
                        ),
                        Text(client, style: theme.textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      change,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

enum _PipelineStage {
  completed('COE, CAS or visa granted'),
  onHold('On hold or IELTS redo'),
  closed('Withdrawn'),
  inProgress('In progress');

  const _PipelineStage(this.label);
  final String label;

  static _PipelineStage of(String status) {
    final value = status.toLowerCase().trim();
    if (value.startsWith('coe issued') ||
        value.startsWith('cas issued') ||
        value == 'visa granted') {
      return completed;
    }
    if (value == 'on hold' || value == 'to redo ielts') return onHold;
    if (value == 'withdrawn') return closed;
    return inProgress;
  }

  Color color(BuildContext context) => switch (this) {
    completed => context.clarity.positiveFg,
    onHold => context.clarity.negativeFg,
    closed => context.clarity.textMuted,
    inProgress => context.clarity.accent,
  };
}

class _Pipeline extends StatelessWidget {
  const _Pipeline({required this.rows});
  final List<List> rows;

  @override
  Widget build(BuildContext context) {
    final counts = <(String, int)>[
      for (final row in rows)
        if (row.length >= 2)
          if (int.tryParse('${row[1]}'.replaceAll(',', '')) case final count?
              when count > 0)
            ('${row[0]}', count),
    ];
    if (counts.isEmpty) return const Text('No applications in the tracker.');
    final total = counts.fold(0, (sum, row) => sum + row.$2);
    final colors = context.clarity;
    final theme = Theme.of(context);
    final segments = [
      for (final stage in _PipelineStage.values)
        (
          stage.color(context),
          counts
                  .where((row) => _PipelineStage.of(row.$1) == stage)
                  .fold(0, (sum, row) => sum + row.$2) /
              total,
        ),
    ];
    final chart = Center(
      child: SizedBox.square(
        dimension: 190,
        child: CustomPaint(
          painter: _PipelineRing(segments),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$total',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'applications',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Widget dot(Color color) => Icon(Icons.circle, size: 9, color: color);
    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (status, count) in counts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                dot(_PipelineStage.of(status).color(context)),
                const SizedBox(width: 8),
                Expanded(child: Text(status, style: theme.textTheme.bodySmall)),
                const SizedBox(width: 8),
                Text('$count', style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final stage in _PipelineStage.values)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  dot(stage.color(context)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(stage.label, style: theme.textTheme.labelSmall),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: LayoutBuilder(
        builder: (context, box) =>
            box.maxWidth < MediaQuery.textScalerOf(context).scale(515)
            ? Column(children: [chart, const SizedBox(height: 16), legend])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  chart,
                  const SizedBox(width: 22),
                  Expanded(child: legend),
                ],
              ),
      ),
    );
  }
}

class _PipelineRing extends CustomPainter {
  const _PipelineRing(this.segments);
  final List<(Color, double)> segments;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 24.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke;
    var start = -math.pi / 2;
    for (final (color, fraction) in segments) {
      if (fraction <= 0) continue;
      final sweep = fraction * 2 * math.pi;
      canvas.drawArc(rect, start, sweep, false, paint..color = color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_PipelineRing oldDelegate) =>
      !listEquals(segments, oldDelegate.segments);
}

class _ReportBlock extends StatelessWidget {
  const _ReportBlock({required this.block, required this.compact});

  final Map block;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final styles = Theme.of(context).textTheme;
    final colors = context.clarity;
    final text = '${block['text'] ?? ''}';
    final kind = block['kind'];
    final child = switch (kind) {
      'heading' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: colors.borderSubtle),
          const SizedBox(height: 8),
          Text(
            text,
            style: styles.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      'label' => Text(text, style: styles.titleSmall),
      'text' => Text(text, style: styles.bodyMedium),
      'table' => _ReportTable(block: block, compact: compact),
      'bullets' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item
              in (block['items'] as List? ?? []).whereType<String>())
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•',
                    style: styles.bodyMedium?.copyWith(color: colors.accent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item, style: styles.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: EdgeInsets.only(
        top: kind == 'heading' ? (compact ? 12 : 20) : 6,
      ),
      child: child,
    );
  }
}

class _ReportTable extends StatelessWidget {
  const _ReportTable({required this.block, required this.compact});

  final Map block;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final headers = (block['columns'] as List? ?? [])
        .whereType<String>()
        .toList();
    final rows = (block['rows'] as List? ?? []).whereType<List>().toList();
    if (headers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = context.clarity;
    final lastIsTotal = block['total'] == true;
    final quickFigures = compact && headers.first == 'Clients';
    final statusChanges = const {'From', 'Time (EAT)'}.contains(headers.first);
    final staff = headers.first == 'Staff member';
    final timeline = headers.first == 'Time (EAT)';
    final scale = MediaQuery.textScalerOf(context);

    TableRow row(
      List values, {
      bool header = false,
      bool bold = false,
      bool headline = false,
    }) {
      return TableRow(
        decoration: header ? BoxDecoration(color: colors.accentSoft) : null,
        children: [
          for (var i = 0; i < headers.length; i++)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 6,
                vertical: compact ? 4 : 7,
              ),
              child: Text(
                i < values.length ? '${values[i]}' : '—',
                textAlign: quickFigures
                    ? TextAlign.center
                    : (i == 0 || statusChanges
                          ? TextAlign.start
                          : TextAlign.end),
                style:
                    Dt.tab(
                      (headline
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.bodySmall)!,
                    ).copyWith(
                      color: !header && timeline && i == 0
                          ? colors.accent
                          : staff &&
                                !header &&
                                i > 0 &&
                                i < values.length &&
                                values[i] == '0'
                          ? colors.textMuted
                          : null,
                      fontWeight:
                          header || bold || headline || (timeline && i == 1)
                          ? FontWeight.w700
                          : null,
                    ),
              ),
            ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        // At large accessibility sizes, three numeric columns can become
        // narrower than a single currency amount. Keep each metric together.
        if (quickFigures &&
            rows.isNotEmpty &&
            box.maxWidth < scale.scale(260)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, header) in headers.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(header, style: theme.textTheme.labelMedium),
                      for (final (index, cells) in rows.indexed)
                        if (i < cells.length)
                          Text(
                            '${cells[i]}',
                            style: index == 0
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.bodySmall,
                          ),
                    ],
                  ),
                ),
            ],
          );
        }
        final minWidth = headers.length < 3
            ? 0.0
            : scale.scale(76) * headers.length;
        final table = SizedBox(
          width: math.max(box.maxWidth, minWidth),
          child: Table(
            columnWidths: {
              0: FlexColumnWidth(quickFigures || statusChanges ? 1 : 1.65),
              if (timeline) 1: const FlexColumnWidth(1.25),
              if (timeline) 2: const FlexColumnWidth(2.3),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(
              horizontalInside: BorderSide(color: colors.borderSubtle),
            ),
            children: [
              row(headers, header: true),
              for (final (index, cells) in rows.indexed)
                row(
                  cells,
                  bold: lastIsTotal && index == rows.length - 1,
                  headline: quickFigures && index == 0,
                ),
            ],
          ),
        );
        return minWidth > box.maxWidth
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: table,
              )
            : table;
      },
    );
  }
}
