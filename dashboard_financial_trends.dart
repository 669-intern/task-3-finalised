import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dashboard_finance_service.dart';

// Actuals-only annual charts. No additional requests or data writes here.
// Forecasts continue to be handled by FinanceDashboardSection separately.
enum _TrendCategory { billing, ratio, arrears, utilities }

class _TrendSeries {
  final String label;
  final Color color;
  const _TrendSeries(this.label, this.color);
}

class _TrendMonth {
  final DateTime month;
  final List<double?> values;
  const _TrendMonth(this.month, this.values);
}

class FinancialTrendsPanel extends StatefulWidget {
  final String propertyName;
  final FinanceOverviewPeriod period;
  final List<Map<String, dynamic>> history;

  const FinancialTrendsPanel({
    super.key,
    required this.propertyName,
    required this.period,
    required this.history,
  });

  @override
  State<FinancialTrendsPanel> createState() => _FinancialTrendsPanelState();
}

class _FinancialTrendsPanelState extends State<FinancialTrendsPanel> {
  static const _ink = Color(0xFF151515);
  static const _muted = Color(0xFF6D7178);
  static const _border = Color(0xFFE3E5E8);
  static const _soft = Color(0xFFF5F6F7);
  static const _blue = Color(0xFF5097F5);
  static const _teal = Color(0xFF36AD98);
  static const _red = Color(0xFFD66B74);
  static const _amber = Color(0xFFD29C49);

  _TrendCategory _category = _TrendCategory.billing;
  int? _activeMonth;

  @override
  void didUpdateWidget(covariant FinancialTrendsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period.start != widget.period.start ||
        oldWidget.period.end != widget.period.end ||
        oldWidget.propertyName != widget.propertyName ||
        !identical(oldWidget.history, widget.history)) {
      _activeMonth = null;
    }
  }

  static String _label(_TrendCategory category) => switch (category) {
    _TrendCategory.billing => 'Billing & Collection',
    _TrendCategory.ratio => 'Collection-to-Billing',
    _TrendCategory.arrears => 'Closing Arrears',
    _TrendCategory.utilities => 'Utilities',
  };

  static Color _accent(_TrendCategory category) => switch (category) {
    _TrendCategory.billing => _blue,
    _TrendCategory.ratio => _teal,
    _TrendCategory.arrears => _red,
    _TrendCategory.utilities => _amber,
  };

  List<_TrendSeries> get _series => switch (_category) {
    _TrendCategory.billing => const [
      _TrendSeries('Total Billing', _blue),
      _TrendSeries('Total Collected', _teal),
    ],
    _TrendCategory.ratio => const [
      _TrendSeries('Collection-to-Billing', _teal),
    ],
    _TrendCategory.arrears => const [_TrendSeries('Closing Arrears', _red)],
    _TrendCategory.utilities => const [
      _TrendSeries('Electricity', _amber),
      _TrendSeries('Water', _blue),
    ],
  };

  List<_TrendMonth> _months() {
    // Match the Financial Overview's authoritative per-month eligibility and
    // totals, including paired collection/billing, end-month arrears, and
    // individual nullable utility bills. Missing, test and future months
    // remain calendar slots with null amounts; actual zero is a valid value.
    final service = FinanceOverviewService(widget.history, const {});
    return [
      for (final key in widget.period.keys)
        _month(service, FinanceOverviewService.parseMonth(key)!),
    ];
  }

  _TrendMonth _month(FinanceOverviewService service, DateTime month) {
    final period = FinanceOverviewPeriod(month, month);
    double? value(FinanceOverviewMetric metric) =>
        service.value(metric, period).amount;
    final List<double?> amounts;
    switch (_category) {
      case _TrendCategory.billing:
        amounts = [
          value(FinanceOverviewMetric.billing),
          value(FinanceOverviewMetric.collected),
        ];
        break;
      case _TrendCategory.ratio:
        amounts = [value(FinanceOverviewMetric.ratio)];
        break;
      case _TrendCategory.arrears:
        amounts = [value(FinanceOverviewMetric.arrears)];
        break;
      case _TrendCategory.utilities:
        final parts = service
            .value(FinanceOverviewMetric.utilities, period)
            .components;
        amounts = [parts['Electricity'], parts['Water']];
        break;
    }
    return _TrendMonth(month, amounts);
  }

  bool get _percent => _category == _TrendCategory.ratio;
  // Collection-to-Billing is always a line chart, even for one observation.
  // Billing/collection, arrears and utilities always use zero-based columns.
  bool get _bars => _category != _TrendCategory.ratio;

  static String _amount(double? value, bool percent) {
    if (value == null) return 'No saved figure';
    if (percent) return '${value.toStringAsFixed(2)}%';
    final fixed = value.abs().toStringAsFixed(2).split('.');
    final whole = fixed.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return '${value < 0 ? '-' : ''}RM $whole.${fixed.last}';
  }

  String get _periodLabel {
    final start = _fullMonth(widget.period.start);
    final end = _fullMonth(widget.period.end);
    return start == end ? end : '$start – $end';
  }

  void _select(_TrendCategory category) {
    if (_category == category) return;
    setState(() {
      _category = category;
      _activeMonth = null;
    });
  }

  void _highlight(int? index) {
    if (index != _activeMonth) setState(() => _activeMonth = index);
  }

  Widget _categoryButton(_TrendCategory category) {
    final selected = category == _category;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? const Color(0xFF191919) : _soft,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _select(category),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Text(
              _label(category),
              style: TextStyle(
                color: selected ? Colors.white : _muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _legend(List<_TrendSeries> series) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 18,
    runSpacing: 7,
    children: [
      for (final item in series)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: item.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              item.label,
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ],
        ),
    ],
  );

  Widget _chart(List<_TrendMonth> months, List<_TrendSeries> series) {
    if (!months.any((m) => m.values.any((v) => v != null))) {
      return const SizedBox(
        height: 145,
        child: Center(
          child: Text(
            'No saved financial figures for this period.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        // A year fits the compact parent panel; only very narrow layouts scroll.
        final width = math.max(bounds.maxWidth, 240.0);
        final height = months.length == 1 ? 190.0 : 260.0;
        final size = Size(width, height);
        final geometry = _TrendGeometry.from(size, months, percent: _percent);
        final active = _activeMonth != null && _activeMonth! < months.length
            ? _activeMonth
            : null;
        void update(Offset position) => _highlight(geometry.hitTest(position));
        final tooltipWidth = math.min(235.0, width - 16);
        final focusX = active == null ? 0.0 : geometry.x(active);
        final tooltipLeft =
            (focusX + tooltipWidth + 12 <= width
                    ? focusX + 12
                    : focusX - tooltipWidth - 12)
                .clamp(8.0, width - tooltipWidth - 8)
                .toDouble();
        final chart = SizedBox(
          width: width,
          height: height,
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onHover: (event) => update(event.localPosition),
            onExit: (_) => _highlight(null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) => update(event.localPosition),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _TrendPainter(
                        months: months,
                        series: series,
                        percent: _percent,
                        bars: _bars,
                        highlighted: active,
                      ),
                    ),
                  ),
                  if (active != null)
                    Positioned(
                      left: tooltipLeft,
                      top: 4,
                      width: tooltipWidth,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: const Color(0xFF191919),
                            borderRadius: BorderRadius.circular(9),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x22000000),
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _fullMonth(months[active].month),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              for (var i = 0; i < series.length; i++) ...[
                                const SizedBox(height: 7),
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: series[i].color,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        series[i].label,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFFD7D7D7),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _amount(months[active].values[i], _percent),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        final accessibleValues = months
            .map((month) {
              final amounts = List.generate(
                series.length,
                (i) =>
                    '${series[i].label} ${_amount(month.values[i], _percent)}',
              );
              return '${_fullMonth(month.month)}: ${amounts.join(', ')}';
            })
            .join('; ');
        return Semantics(
          label:
              '${_label(_category)} for ${widget.propertyName}, $_periodLabel. '
              'Saved financial figures only. $accessibleValues',
          child: width > bounds.maxWidth
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: chart,
                )
              : chart,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final series = _series;
    final months = _months();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: _accent(_category),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'FINANCIAL TRENDS',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${widget.propertyName} · $_periodLabel',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 5,
            runSpacing: 6,
            children: [
              for (final category in _TrendCategory.values)
                _categoryButton(category),
            ],
          ),
          const SizedBox(height: 10),
          _chart(months, series),
          if (series.length > 1) ...[
            const SizedBox(height: 8),
            Center(child: _legend(series)),
          ],
        ],
      ),
    );
  }
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
String _fullMonth(DateTime month) =>
    '${_monthNames[month.month - 1]} ${month.year}';
String _shortMonth(DateTime month) =>
    _monthNames[month.month - 1].substring(0, 3);

class _TrendGeometry {
  final Rect plot;
  final double minY;
  final double maxY;
  final double step;
  final int count;
  const _TrendGeometry(this.plot, this.minY, this.maxY, this.step, this.count);

  bool get showsReference => minY <= 100 && maxY >= 100;
  double get slot => plot.width / count;
  double x(int index) => plot.left + (index + 0.5) * slot;
  double y(double value) =>
      plot.bottom - (value - minY) / (maxY - minY) * plot.height;

  int? hitTest(Offset point) {
    if (point.dx < plot.left ||
        point.dx > plot.right ||
        point.dy < plot.top - 12 ||
        point.dy > plot.bottom + 12) {
      return null;
    }
    return ((point.dx - plot.left) / slot).floor().clamp(0, count - 1).toInt();
  }

  static _TrendGeometry from(
    Size size,
    List<_TrendMonth> months, {
    required bool percent,
  }) {
    final amounts = months.expand((m) => m.values).whereType<double>().toList();
    // Bars need a zero baseline. For the percentage line, use the actual
    // observed range with modest padding so small changes are visible.
    // Do not force 100% into the scale if it is far from the observations.
    final values = <double>[if (!percent || amounts.isEmpty) 0, ...amounts];
    var low = values.reduce(math.min);
    var high = values.reduce(math.max);
    if (percent) {
      final padding = math.max((high - low) * 0.12, 0.15);
      final nonnegative = low >= 0;
      low -= padding;
      high += padding;
      if (nonnegative) low = math.max(0.0, low);
    }
    final rawStep = (high == low ? 1.0 : high - low) / (percent ? 5 : 4);
    final power = math
        .pow(10, (math.log(rawStep) / math.ln10).floor())
        .toDouble();
    final fraction = rawStep / power;
    final niceStep =
        (fraction <= 1
            ? 1.0
            : fraction <= 2
            ? 2.0
            : fraction <= 2.5
            ? 2.5
            : fraction <= 5
            ? 5.0
            : 10.0) *
        power;
    final step = percent ? math.max(0.01, niceStep) : niceStep;
    final minY = ((low / step).floor() * step).toDouble();
    var maxY = ((high / step).ceil() * step).toDouble();
    if (maxY <= minY) maxY = minY + step * 4;
    final left = percent ? 51.0 : 70.0;
    return _TrendGeometry(
      Rect.fromLTRB(
        left,
        25,
        math.max(left + 20, size.width - 12),
        size.height - 33,
      ),
      minY,
      maxY,
      step,
      months.length,
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<_TrendMonth> months;
  final List<_TrendSeries> series;
  final bool percent;
  final bool bars;
  final int? highlighted;
  const _TrendPainter({
    required this.months,
    required this.series,
    required this.percent,
    required this.bars,
    required this.highlighted,
  });

  static const _muted = Color(0xFF7B8088);
  static const _grid = Color(0xFFE6EAF0);

  static String _trim(double value, int decimals) =>
      value.toStringAsFixed(decimals).replaceFirst(RegExp(r'\.?0+$'), '');

  String _compact(double value) {
    final abs = value.abs();
    final sign = value < 0 ? '-' : '';
    if (percent) return '${_trim(value.abs() < 0.0000001 ? 0.0 : value, 2)}%';
    if (abs >= 1000000) return '$sign${_trim(abs / 1000000, 2)}m';
    if (abs >= 1000) return '$sign${_trim(abs / 1000, 2)}k';
    return '$sign${_trim(abs, 2)}';
  }

  static void _text(
    Canvas canvas,
    String text,
    Rect rect, {
    double fontSize = 10,
    Color color = _muted,
    TextAlign align = TextAlign.center,
    FontWeight weight = FontWeight.w500,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, color: color, fontWeight: weight),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(minWidth: rect.width, maxWidth: rect.width);
    painter.paint(canvas, Offset(rect.left, rect.top));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = _TrendGeometry.from(size, months, percent: percent);
    final grid = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    final baseline = Paint()
      ..color = const Color(0xFFBFC6CF)
      ..strokeWidth = 1;
    final zero = g.y(0);
    for (var i = 0; i <= ((g.maxY - g.minY) / g.step).round(); i++) {
      final value = g.minY + i * g.step;
      final y = g.y(value);
      canvas.drawLine(
        Offset(g.plot.left, y),
        Offset(g.plot.right, y),
        value.abs() < g.step * 1e-8 ? baseline : grid,
      );
      _text(
        canvas,
        percent ? _compact(value) : 'RM ${_compact(value)}',
        Rect.fromLTWH(0, y - 7, g.plot.left - 8, 14),
        align: TextAlign.right,
        fontSize: 9.5,
      );
    }
    if (highlighted != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          g.x(highlighted!) - g.slot / 2,
          g.plot.top,
          g.slot,
          g.plot.height,
        ),
        Paint()..color = series.first.color.withValues(alpha: 0.06),
      );
    }
    if (percent && g.showsReference) {
      final y = g.y(100);
      final paint = Paint()
        ..color = const Color(0xFF9CA3AF)
        ..strokeWidth = 1.2;
      for (double x = g.plot.left; x < g.plot.right; x += 9) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 5, g.plot.right), y),
          paint,
        );
      }
    }
    if (bars) {
      final groupWidth = math.min(
        g.slot * 0.66,
        series.length == 1 ? 28.0 : 44.0,
      );
      final gap = 1.3;
      final barWidth = (groupWidth - gap * (series.length - 1)) / series.length;
      for (var i = 0; i < months.length; i++) {
        for (var j = 0; j < series.length; j++) {
          final value = months[i].values[j];
          if (value == null) continue;
          final cx =
              g.x(i) - groupWidth / 2 + barWidth / 2 + j * (barWidth + gap);
          final y = g.y(value);
          final paint = Paint()..color = series[j].color;
          // A recorded zero gets a small baseline marker, not a missing bar.
          if (value == 0) {
            canvas.drawLine(
              Offset(cx - barWidth / 2, zero),
              Offset(cx + barWidth / 2, zero),
              paint..strokeWidth = 2,
            );
          } else {
            final rect = Rect.fromLTRB(
              cx - barWidth / 2,
              math.min(y, zero),
              cx + barWidth / 2,
              math.max(y, zero),
            );
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                rect,
                Radius.circular(math.min(4.0, barWidth / 2)),
              ),
              paint,
            );
          }
        }
      }
    } else {
      // Split the line into consecutive non-null runs; never bridge missing
      // months or infer a zero value. A zoomed percentage axis uses a plain
      // line, not an area fill that would imply a zero baseline.
      for (var j = 0; j < series.length; j++) {
        var run = <int>[];
        void flush() {
          if (run.isEmpty) return;
          final color = series[j].color;
          final line = Path()
            ..moveTo(g.x(run.first), g.y(months[run.first].values[j]!));
          for (final index in run.skip(1)) {
            line.lineTo(g.x(index), g.y(months[index].values[j]!));
          }
          if (run.length > 1) {
            canvas.drawPath(
              line,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2.4
                ..strokeJoin = StrokeJoin.round
                ..strokeCap = StrokeCap.round,
            );
          }
          for (final index in run) {
            final value = months[index].values[j]!;
            final position = Offset(g.x(index), g.y(value));
            canvas.drawCircle(
              position,
              index == highlighted ? 4.5 : 3.6,
              Paint()..color = Colors.white,
            );
            canvas.drawCircle(
              position,
              index == highlighted ? 3.5 : 2.6,
              Paint()..color = color,
            );
            if (months.length <= 6 && g.slot >= 48) {
              _text(
                canvas,
                _compact(value),
                Rect.fromLTWH(
                  position.dx - g.slot / 2,
                  math.max(0.0, position.dy - 16),
                  g.slot,
                  14,
                ),
                color: const Color(0xFF33383D),
                fontSize: 10,
                weight: FontWeight.w700,
              );
            }
          }
          run = <int>[];
        }

        for (var i = 0; i < months.length; i++) {
          if (months[i].values[j] == null) {
            flush();
          } else {
            run.add(i);
          }
        }
        flush();
      }
    }
    // Use calendar slots, including absent months. On narrow screens skip
    // labels rather than forcing ordinary periods to scroll or overlap.
    final labelStep = math.max(1, (30 / g.slot).ceil());
    final labelWidth = math.min(40.0, g.slot * labelStep);
    for (var i = 0; i < months.length; i += labelStep) {
      if (i > 0 &&
          i < months.length - 1 &&
          g.slot * (months.length - 1 - i) < labelWidth) {
        continue;
      }
      _text(
        canvas,
        _shortMonth(months[i].month),
        Rect.fromLTWH(
          g.x(i) - labelWidth / 2,
          g.plot.bottom + 11,
          labelWidth,
          14,
        ),
        fontSize: 9.5,
      );
    }
    if ((months.length - 1) % labelStep != 0) {
      _text(
        canvas,
        _shortMonth(months.last.month),
        Rect.fromLTWH(
          g.x(months.length - 1) - labelWidth / 2,
          g.plot.bottom + 11,
          labelWidth,
          14,
        ),
        fontSize: 9.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.months != months ||
      old.series != series ||
      old.percent != percent ||
      old.bars != bars ||
      old.highlighted != highlighted;
}
