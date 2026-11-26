import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dashboard_finance.dart' show DashboardOverviewMetricCard, FinanceChartPoint, FinanceInteractiveChart;

// Read-only Defaulters dashboard. All balances are monthly snapshots; payments
// are dated transactions. No changes to the Defaulters register or its tables.
enum _DefaulterMetric { balance, payments, unpaid, partial, completed }
enum _DefaulterTrend { balance, payments, open }

class _DefaulterMetricSpec {
  final _DefaulterMetric key;
  final String label;
  final IconData icon;
  final Color accent;
  const _DefaulterMetricSpec(this.key, this.label, this.icon, this.accent);
  bool get money => key == _DefaulterMetric.balance || key == _DefaulterMetric.payments;
  bool get snapshot => key == _DefaulterMetric.balance || key == _DefaulterMetric.unpaid || key == _DefaulterMetric.partial;
}

class DashboardDefaulters extends StatefulWidget {
  final String siteId;
  final DateTime start;
  final DateTime end;
  final int refreshRevision;
  final int filterRevision;
  final List<Map<String, dynamic>> reports;
  const DashboardDefaulters({
    super.key,
    required this.siteId,
    required this.start,
    required this.end,
    this.refreshRevision = 0,
    required this.filterRevision,
    required this.reports,
  });

  @override
  State<DashboardDefaulters> createState() => _DashboardDefaultersState();
}

class _DashboardDefaultersState extends State<DashboardDefaulters> {
  static const _ink = Color(0xFF151515);
  static const _muted = Color(0xFF6D7178);
  static const _border = Color(0xFFE3E5E8);
  static const _soft = Color(0xFFF5F6F7);
  static const _red = Color(0xFFD92D3A);
  static const _blue = Color(0xFF5097F5);
  static const _teal = Color(0xFF36AD98);
  static const _gold = Color(0xFFD29C49);
  static const _pink = Color(0xFFD66B74);
  static const _green = Color(0xFF238451);
  static const _amber = Color(0xFFB26B00);
  static const _specs = <_DefaulterMetricSpec>[
    _DefaulterMetricSpec(_DefaulterMetric.balance, 'Total Outstanding Amount', Icons.account_balance_wallet_outlined, _pink),
    _DefaulterMetricSpec(_DefaulterMetric.payments, 'Payments Received', Icons.payments_outlined, _teal),
    _DefaulterMetricSpec(_DefaulterMetric.unpaid, 'Outstanding', Icons.receipt_long_outlined, _gold),
    _DefaulterMetricSpec(_DefaulterMetric.partial, 'Partially Paid', Icons.pending_actions_outlined, _gold),
    _DefaulterMetricSpec(_DefaulterMetric.completed, 'Completed', Icons.check_circle_outline, _teal),
  ];

  final SupabaseClient _supabase = Supabase.instance.client;
  Map<String, String> _reports = const {};
  Map<String, List<DateTime>> _balanceDates = const {};
  String? _dateError;
  String? _datasetError;
  // Keyed by report ID, including successfully read empty reports. Never reuse
  // data when the property or authoritative finance dataset changes.
  final Map<String, List<Map<String, dynamic>>> _snapshots = {};
  List<Map<String, dynamic>> _payments = const [];
  Map<String, String> _unitById = const {};
  DateTime? _paymentStart;
  DateTime? _paymentEnd;
  bool _loading = true;
  String? _snapshotError;
  String? _paymentError;
  int _sequence = 0;
  _DefaulterMetric? _expanded;
  _DefaulterTrend _trend = _DefaulterTrend.balance;
  int _topCount = 3;
  final Set<String> _showAll = {};
  String _unitSearch = '';
  String _unitSort = 'balance';

  static String _key(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
  static String _dateKey(DateTime d) => '${_key(d)}-${d.day.toString().padLeft(2, '0')}';
  static DateTime? _date(dynamic raw) {
    final d = DateTime.tryParse(raw?.toString() ?? '');
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }
  static DateTime get _today {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(now.year, now.month, now.day);
  }
  static DateTime _monthEnd(DateTime d) => DateTime(d.year, d.month + 1, 0);
  static DateTime _cutoff(DateTime d) {
    final end = _monthEnd(d);
    return end.isAfter(_today) ? _today : end;
  }
  static DateTime _monthStart(DateTime d) => DateTime(d.year, d.month);
  static bool _within(DateTime d, DateTime a, DateTime b) => !d.isBefore(a) && !d.isAfter(b);
  static String _label(DateTime d) => _monthLabel(_key(d));
  static String _short(DateTime d) => '${_monthNames[d.month - 1].substring(0, 3)} ${d.year}';
  static String _rangeLabel(DateTime a, DateTime b) => _key(a) == _key(b) ? _label(b) : '${_short(a)} – ${_short(b)}';
  static const _monthNames = <String>[
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

  static DateTime? _parseMonth(dynamic raw) {
    final value = raw?.toString();
    if (value == null || value.length < 7) return null;
    return DateTime.tryParse('${value.substring(0, 7)}-01');
  }

  static String _monthLabel(String value) {
    final date = _parseMonth(value);
    return date == null ? value : '${_monthNames[date.month - 1]} ${date.year}';
  }

  static List<Map<String, dynamic>> _maps(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static double? _number(dynamic value) {
    if (value is num) {
      return value.toDouble().isFinite ? value.toDouble() : null;
    }
    final n = double.tryParse(value?.toString() ?? '');
    return n != null && n.isFinite ? n : null;
  }

  static String _money(dynamic value) {
    final number = _number(value);
    if (number == null) return '--';
    final fixed = number.abs().toStringAsFixed(2).split('.');
    final whole = fixed.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return '${number < 0 ? '-' : ''}RM $whole.${fixed.last}';
  }

  static String _unit(Map<String, dynamic> r) {
    final unit = r['unit_no']?.toString().trim() ?? '';
    return unit.isEmpty ? 'Unit unavailable' : unit;
  }
  static String _id(Map<String, dynamic> r) => r['defaulter_id']?.toString() ?? '';
  static String _unitKey(Map<String, dynamic> r) {
    final name = r['unit_no']?.toString().trim().toLowerCase() ?? '';
    return name.isEmpty ? 'id:${_id(r)}' : 'unit:$name';
  }
  static double? _unitCount(Iterable<Map<String, dynamic>>? rows) =>
      rows?.map(_unitKey).toSet().length.toDouble();
  static String _dayLabel(DateTime day) =>
      '${day.day} ${_monthNames[day.month - 1].substring(0, 3)} ${day.year}';
  // Match the existing monthly view's month-end cutoff; label current reports
  // as in progress, not as a final month-end figure or a real-time balance.
  static String _snapshotLabel(DateTime month) =>
      _monthEnd(month).isAfter(_today)
          ? '${_short(month)} (in progress)'
          : _dayLabel(_monthEnd(month));
  DateTime? _balanceDate(Map<String, dynamic> row, DateTime month) {
    final dates = _balanceDates[_id(row)];
    if (dates == null) return null;
    final cutoff = _monthEnd(month);
    for (final date in dates.reversed) {
      if (!date.isAfter(cutoff)) return date;
    }
    return null;
  }
  String _datesLabel(List<Map<String, dynamic>> rows, DateTime month) {
    final dates = rows.map((r) => _balanceDate(r, month)).toList();
    if (dates.any((d) => d == null)) return 'Date unavailable';
    final unique = dates.whereType<DateTime>().toSet().toList()..sort();
    if (unique.isEmpty) return 'Date unavailable';
    return unique.length == 1 ? _dayLabel(unique.first)
        : '${_dayLabel(unique.first)} – ${_dayLabel(unique.last)}';
  }

  DateTime? _latestBalanceDate(Iterable<Map<String, dynamic>> rows, DateTime month) {
    DateTime? latest;
    for (final row in rows) {
      final date = _balanceDate(row, month);
      if (date != null && (latest == null || date.isAfter(latest))) {
        latest = date;
      }
    }
    return latest;
  }

  String _snapshotHeadline(DateTime month, Iterable<Map<String, dynamic>> rows) {
    final latest = _latestBalanceDate(rows, month);
    if (latest != null && latest.isBefore(_monthEnd(month))) {
      return 'Latest balance update: ${_dayLabel(latest)}';
    }
    return _snapshotLabel(month);
  }

  static double? _sum(Iterable<Map<String, dynamic>> rows, String field) {
    var result = 0.0;
    for (final r in rows) {
      final n = _number(r[field]);
      if (n == null || n < 0) return null;
      result += n;
    }
    return result;
  }
  DateTime get _start => _monthStart(widget.start);
  DateTime get _end => _monthStart(widget.end);
  bool get _partialEndMonth => _cutoff(_end).isBefore(_monthEnd(_end));
  int get _months => (_end.year - _start.year) * 12 + _end.month - _start.month + 1;
  DateTime get _previousStart => DateTime(_start.year, _start.month - _months);
  DateTime get _previousEnd => DateTime(_start.year, _start.month - 1);

  // Snapshot metrics compare closing positions month-on-month even when
  // Start/End spans multiple months. Flow metrics retain equal-period comparison.
  DateTime get _snapshotPreviousEnd => DateTime(_end.year, _end.month - 1);

  List<DateTime> get _annualMonths => _reports.keys
      .map((m) => _date('$m-01')).whereType<DateTime>()
      .where((d) => d.year == _end.year).toList()
    ..sort((a, b) => a.compareTo(b));
  List<Map<String, dynamic>>? _monthRows(DateTime month) {
    final id = _reports[_key(month)];
    return id == null ? null : _snapshots[id];
  }
  List<Map<String, dynamic>>? _openRows(DateTime month) => _monthRows(month)
      ?.where((r) => r['record_section'] == 'This Month').toList();
  List<Map<String, dynamic>>? _completedRows(DateTime start, DateTime end) {
    final rows = _monthRows(end);
    if (rows == null) return null;
    final history = rows.where((r) => r['record_section'] == 'History');
    final result = <Map<String, dynamic>>[];
    for (final r in history) {
      final date = _date(r['completed_date']);
      // Do not silently count undated completions as zero.
      if (date == null) return null;
      if (_within(date, _monthStart(start), _cutoff(end))) result.add(r);
    }
    return result;
  }
  List<Map<String, dynamic>>? _paymentsFor(DateTime start, DateTime end) {
    final from = _monthStart(start);
    final through = _cutoff(end);
    if (_paymentError != null || _paymentStart == null || _paymentEnd == null ||
        from.isBefore(_paymentStart!) || through.isAfter(_paymentEnd!) || through.isBefore(from)) {
      return null;
    }
    return _payments.where((r) {
      final date = _date(r['payment_date']);
      return date != null && _within(date, from, through);
    }).toList();
  }
  double? _value(_DefaulterMetric key, DateTime start, DateTime end) {
    switch (key) {
      case _DefaulterMetric.balance:
        final rows = _openRows(end);
        return rows == null ? null : _sum(rows, 'total_due');
      case _DefaulterMetric.payments:
        final payments = _paymentsFor(start, end);
        return payments == null ? null : _sum(payments, 'amount');
      case _DefaulterMetric.unpaid:
        return _unitCount(_openRows(end)?.where((r) => r['status'] == 'Outstanding'));
      case _DefaulterMetric.partial:
        return _unitCount(_openRows(end)?.where((r) => r['status'] == 'Partially Paid'));
      case _DefaulterMetric.completed:
        return _unitCount(_completedRows(start, end));
    }
  }
  String _format(_DefaulterMetricSpec spec, double? value) => value == null ? '—' : spec.money ? _money(value) : value.toStringAsFixed(0);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }
  @override
  void didUpdateWidget(covariant DashboardDefaulters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteId != widget.siteId ||
        oldWidget.start != widget.start || oldWidget.end != widget.end ||
        oldWidget.refreshRevision != widget.refreshRevision ||
        oldWidget.filterRevision != widget.filterRevision ||
        oldWidget.reports != widget.reports) {
      _expanded = null;
      _showAll.clear();
      _unitSearch = '';
      _unitSort = 'balance';
      unawaited(_load());
    }
  }
  @override
  void dispose() {
    _sequence++;
    super.dispose();
  }
  bool _valid(int request) => mounted && request == _sequence;

  // Page until an empty response. Increment by the actual returned count so
  // a server-side maximum smaller than the requested page cannot truncate data.
  Future<List<Map<String, dynamic>>> _readPages(
    Future<dynamic> Function(int from, int to) fetch,
    int request,
  ) async {
    const size = 500;
    final result = <Map<String, dynamic>>[];
    var offset = 0;
    while (_valid(request)) {
      final page = _maps(await fetch(offset, offset + size - 1));
      if (!_valid(request)) return const [];
      if (page.isEmpty) break;
      result.addAll(page);
      offset += page.length;
    }
    return result;
  }

  Future<void> _load() async {
    final request = ++_sequence;
    final site = widget.siteId;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _datasetError = null;
      _snapshotError = null;
      _paymentError = null;
      _reports = const {};
      _balanceDates = const {};
      _dateError = null;
      _snapshots.clear();
      _paymentStart = null;
      _paymentEnd = null;
      _payments = const [];
      _unitById = const {};
    });
    try {
      if (_supabase.auth.currentSession == null) {
        throw StateError('Your session has expired. Sign in again.');
      }
      // Use the same authorised monthly reports as the parent filter. Do not
      // depend on billing, arrears, forecasting, analytics test classifications
      // or a closed reporting month. Future months remain excluded.
      final currentMonth = _monthStart(_today);
      final reports = <String, String>{};
      for (final row in widget.reports) {
        if (row['site_id']?.toString() != site) continue;
        final id = row['id']?.toString();
        final month = _parseMonth(row['report_month']);
        if (id == null || id.isEmpty || month == null ||
            month.isAfter(currentMonth)) {
          continue;
        }
        final key = _key(month);
        if (reports.containsKey(key) && reports[key] != id) {
          throw StateError('Multiple eligible reports for $key.');
        }
        reports[key] = id;
      }
      if (!_valid(request)) return;
      setState(() => _reports = reports);
    } catch (_) {
      if (!_valid(request)) return;
      setState(() {
        _datasetError = 'Unable to read reporting periods for this property.';
        _loading = false;
      });
      return;
    }
    final reports = _reports;
    final months = <DateTime>{_end, _snapshotPreviousEnd, _previousEnd, ..._annualMonths};
    final ids = months.map((d) => reports[_key(d)]).whereType<String>().toSet();
    final missing = ids.where((id) => !_snapshots.containsKey(id)).toList()..sort();
    final annual = _annualMonths;
    final starts = [_previousStart, _start, if (annual.isNotEmpty) annual.first]..sort();
    final ends = [_end, _previousEnd, if (annual.isNotEmpty) annual.last]..sort();
    final from = starts.first;
    final through = _cutoff(ends.last);
    final readPayments = _paymentStart == null || _paymentEnd == null ||
        from.isBefore(_paymentStart!) || through.isAfter(_paymentEnd!) || _paymentError != null;
    if (!mounted) return;
    setState(() {
      _loading = missing.isNotEmpty || readPayments;
      _snapshotError = null;
      _paymentError = null;
    });
    if (!_loading) return;
    // Independent failure paths: a payment read must not hide saved balances.
    try {
      final byReport = <String, List<Map<String, dynamic>>>{for (final id in missing) id: []};
      for (var i = 0; i < missing.length; i += 60) {
        final batch = missing.skip(i).take(60).toList();
        final rows = await _readPages((a, b) async => await _supabase
            .from('finance_defaulters_monthly')
            .select('report_id,defaulter_id,unit_no,total_due,status,record_section,completed_date')
            .eq('site_id', site)
            .inFilter('report_id', batch)
            .order('report_id')
            .order('defaulter_id')
            .range(a, b), request);
        if (!_valid(request)) return;
        for (final row in rows) {
          byReport[row['report_id']?.toString()]?.add(row);
        }
      }
      for (final rows in byReport.values) {
        final seen = <String>{};
        for (final row in rows) {
          if (_id(row).isEmpty || !seen.add(_id(row))) {
            throw StateError('Duplicate or missing defaulter ID in a monthly report.');
          }
        }
      }
      if (!_valid(request)) return;
      setState(() => _snapshots.addAll(byReport));
    } catch (error) {
      if (!_valid(request)) return;
      setState(() => _snapshotError = 'Unable to read monthly defaulter records.');
    }
    if (_valid(request) && _snapshotError == null) {
      try {
        final caseIds = _snapshots.values.expand((rows) => rows).map(_id)
            .where((id) => id.isNotEmpty).toSet().toList()..sort();
        final dates = <String, List<DateTime>>{};
        // Use month-end, exactly as finance_defaulters_monthly does. Actual
        // snapshot dates, not the original due date, are shown in comparisons.
        for (var i = 0; i < caseIds.length; i += 60) {
          final batch = caseIds.skip(i).take(60).toList();
          final rows = await _readPages((a, b) async => await _supabase
              .from('finance_defaulter_balance_snapshots')
              .select('id,defaulter_id,balance_date')
              .inFilter('defaulter_id', batch)
              .lte('balance_date', _dateKey(_monthEnd(ends.last)))
              .order('defaulter_id')
              .order('balance_date')
              .order('id')
              .range(a, b), request);
          if (!_valid(request)) return;
          for (final row in rows) {
            final date = _date(row['balance_date']);
            if (date != null) (dates[_id(row)] ??= <DateTime>[]).add(date);
          }
        }
        for (final entries in dates.values) { entries.sort(); }
        if (!_valid(request)) return;
        setState(() => _balanceDates = dates);
      } catch (_) {
        if (!_valid(request)) return;
        setState(() => _dateError = 'Balance update dates are unavailable. Saved balances are still shown.');
      }
    }
    if (readPayments && _valid(request)) {
      try {
        // Read property-scoped parent IDs first. Do not query unrelated payment
        // records or change authorization; the signed-in client's RLS applies.
        final parents = await _readPages((a, b) async => await _supabase
            .from('finance_defaulters')
            .select('id,unit_no')
            .eq('site_id', site)
            .order('id')
            .range(a, b), request);
        if (!_valid(request)) return;
        final units = <String, String>{};
        for (final row in parents) {
          final id = row['id']?.toString();
          if (id != null && id.isNotEmpty) units[id] = _unit(row);
        }
        final knownIds = _snapshots.values.expand((rows) => rows).map(_id).toSet();
        if (!knownIds.every(units.containsKey)) {
          throw StateError('Payment access does not cover all visible defaulter cases.');
        }
        final parentIds = units.keys.toList()..sort();
        final transactions = <Map<String, dynamic>>[];
        final seen = <String>{};
        for (var i = 0; i < parentIds.length; i += 60) {
          final batch = parentIds.skip(i).take(60).toList();
          final rows = await _readPages((a, b) async => await _supabase
              .from('finance_defaulter_payments')
              .select('id,defaulter_id,payment_date,amount')
              .inFilter('defaulter_id', batch)
              .gte('payment_date', _dateKey(from))
              .lte('payment_date', _dateKey(through))
              .order('payment_date')
              .order('id')
              .range(a, b), request);
          if (!_valid(request)) return;
          for (final row in rows) {
            final id = row['id']?.toString();
            final amount = _number(row['amount']);
            if (id == null || id.isEmpty || !seen.add(id) || amount == null || amount < 0 || _date(row['payment_date']) == null || !units.containsKey(_id(row))) {
              throw StateError('Invalid or duplicate payment record.');
            }
            transactions.add(row);
          }
        }
        if (!_valid(request)) return;
        setState(() {
          _payments = transactions;
          _unitById = units;
          _paymentStart = from;
          _paymentEnd = through;
        });
      } catch (error) {
        if (!_valid(request)) return;
        setState(() {
          _payments = const [];
          _paymentStart = null;
          _paymentEnd = null;
          _paymentError = 'Unable to read dated defaulter payments.';
        });
      }
    }
    if (_valid(request)) setState(() => _loading = false);
  }

  Widget _panel(Widget child, {EdgeInsets? padding, bool shadow = true}) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: _border), boxShadow: shadow ? const [BoxShadow(color: Color(0x0F000000), blurRadius: 24, offset: Offset(0, 8))] : null),
    child: child,
  );
  Widget _heading(String label, {Widget? trailing}) => Row(children: [
    Container(width: 4, height: 16, decoration: BoxDecoration(color: _blue, borderRadius: BorderRadius.circular(3))),
    const SizedBox(width: 9),
    Expanded(child: Text(label, style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w600))),
    ?trailing,
  ]);
  Widget _note(String text) => Text(text, style: const TextStyle(color: _muted, fontSize: 11, height: 1.4));
  Widget _empty(String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Center(child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 12, height: 1.4))));
  Widget _line(String title, String value, {String? subtitle}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w700)),
        if (subtitle != null) ...[const SizedBox(height: 3), _note(subtitle)],
      ])),
      const SizedBox(width: 12),
      Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w800))),
    ]),
  );
  Widget _bar(double? value, double max, Color color) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: Container(height: 12, color: _soft, child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: value == null || max <= 0 ? 0 : (value / max).clamp(0.0, 1.0).toDouble(), heightFactor: 1, child: ColoredBox(color: color)))),
  );
  Widget _limitedRows(String key, List<Widget> rows, {int limit = 10}) {
    final all = _showAll.contains(key);
    final visible = all ? rows : rows.take(limit).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < visible.length; i++) ...[if (i > 0) const Divider(height: 1, color: _border), visible[i]],
      if (rows.length > limit)
        TextButton(
          onPressed: () => setState(() {
            if (all) {
              _showAll.remove(key);
            } else {
              _showAll.add(key);
            }
          }),
          child: Text(
            all ? 'Show less' : 'Show all ${rows.length} records',
            style: const TextStyle(fontSize: 12, color: _red),
          ),
        ),
    ]);
  }

  String _amountDeltaText(double? now, double? before) {
    if (now == null || before == null) {
      return '—';
    }
    final delta = now - before;
    if (delta == 0) {
      return 'RM 0.00';
    }
    return '${delta > 0 ? '+' : '−'}${_money(delta.abs())}';
  }
  double? _previousValue(_DefaulterMetricSpec spec) {
    // Do not imply a prior zero before the property's available reporting history.
    if (spec.key == _DefaulterMetric.payments && !_reports.keys.any((m) => m.compareTo(_key(_previousStart)) >= 0 && m.compareTo(_key(_previousEnd)) <= 0)) return null;
    return spec.snapshot
        ? _value(spec.key, _snapshotPreviousEnd, _snapshotPreviousEnd)
        : _value(spec.key, _previousStart, _previousEnd);
  }
  String _comparisonLabel(_DefaulterMetricSpec spec) {
    if (spec.snapshot) return 'vs ${_short(_snapshotPreviousEnd)}';
    if (_months == 1) return 'vs ${_short(_previousEnd)}';
    if (_previousStart.year == _previousEnd.year) {
      final from = _monthNames[_previousStart.month - 1].substring(0, 3);
      final to = _monthNames[_previousEnd.month - 1].substring(0, 3);
      return 'vs $from–$to ${_previousEnd.year}';
    }
    return 'vs ${_rangeLabel(_previousStart, _previousEnd)}';
  }
  String _coverage(_DefaulterMetricSpec spec, double? amount) {
    if (amount == null) return 'No saved figure';
    if (spec.snapshot) return _partialEndMonth ? 'Current-month snapshot' : 'End-month snapshot';
    if (_partialEndMonth) return 'Through ${_dateKey(_cutoff(_end))}';
    return spec.key == _DefaulterMetric.payments ? 'Recorded payments in period' : 'Units completed in period';
  }
  double? _movement(_DefaulterMetricSpec spec, double? now, double? before) {
    if (now == null || before == null) return null;
    // Do not rate an incomplete flow period against a full preceding period.
    if (_partialEndMonth && !spec.snapshot) return null;
    if (!spec.money) return now - before;
    if (before == 0) return now == 0 ? 0.0 : null;
    return (now - before) / before * 100;
  }
  // Only the balance and actual payment movement receive favourable colours.
  // Status counts can shift for several reasons, so avoid false judgements.
  bool? _favourable(_DefaulterMetricSpec spec, double? movement) {
    if (movement == null || movement == 0) return null;
    if (spec.key == _DefaulterMetric.balance) return movement < 0;
    if (spec.key == _DefaulterMetric.payments) return movement > 0;
    return null;
  }
  String _movementText(_DefaulterMetricSpec spec, double? movement) {
    if (movement == null) return '—';
    final amount = spec.money ? '${movement.abs().toStringAsFixed(2)}%' : movement.abs().toStringAsFixed(0);
    return movement == 0 ? amount : '${movement > 0 ? '▲ +' : '▼ −'}$amount';
  }
  // Only cards with actual detail records can be expanded. A unit in the
  // preceding snapshot may still be useful even when the current count is zero.
  bool _canExpand(_DefaulterMetricSpec spec) {
    switch (spec.key) {
      case _DefaulterMetric.balance:
        return false;
      case _DefaulterMetric.payments:
        return _paymentsFor(_start, _end)?.isNotEmpty ?? false;
      case _DefaulterMetric.completed:
        return _completedRows(_start, _end)?.isNotEmpty ?? false;
      case _DefaulterMetric.unpaid:
      case _DefaulterMetric.partial:
        final current = _openRows(_end);
        if (current == null) return false;
        final status = spec.key == _DefaulterMetric.unpaid
            ? 'Outstanding' : 'Partially Paid';
        return current.any((r) => r['status'] == status) ||
            (_openRows(_snapshotPreviousEnd)?.any((r) => r['status'] == status) ?? false);
    }
  }

  Widget _metricCard(_DefaulterMetricSpec spec) {
    final current = _value(spec.key, _start, _end);
    final previous = _previousValue(spec);
    final movement = _movement(spec, current, previous);
    final expandable = _canExpand(spec);
    // Snapshots compare closing balances/counts month-on-month. Flows compare
    // equal-length periods, but never rate an unfinished period against a full one.
    final delta = _months <= 2 && current != null && previous != null &&
            (spec.snapshot || !_partialEndMonth)
        ? current - previous : null;
    final change = delta == null || movement == null
        ? null
        : spec.money
            ? _movementText(spec, movement)
            : '${_movementText(spec, movement)} ${delta.abs() == 1 ? 'unit' : 'units'}';
    final amountChange = delta == null || !spec.money
        ? null : _amountDeltaText(current, previous);
    final favourable = delta == null || delta == 0
        ? null
        : spec.key == _DefaulterMetric.balance
            ? delta < 0
            : spec.key == _DefaulterMetric.payments ? delta > 0 : null;
    return DashboardOverviewMetricCard(
      label: spec.label,
      icon: spec.icon,
      accent: spec.accent,
      value: !spec.money && current != null
          ? '${_format(spec, current)} units' : _format(spec, current),
      comparisonLabel: delta == null ? null : _comparisonLabel(spec),
      change: change,
      amountChange: amountChange,
      favourable: favourable,
      dataNote: _coverage(spec, current),
      showDataInfo: current == null || (_partialEndMonth && !spec.snapshot),
      selected: expandable && _expanded == spec.key,
      onTap: expandable ? () {
        setState(() {
          _expanded = _expanded == spec.key ? null : spec.key;
          _showAll.remove('metric');
          _unitSearch = '';
          _unitSort = 'balance';
        });
      } : null,
    );
  }

  Widget _metrics() => LayoutBuilder(builder: (context, bounds) {
    const gap = 10.0;
    const minCardWidth = 210.0;
    final columns = math.min(_specs.length, math.max(1, ((bounds.maxWidth + gap) / (minCardWidth + gap)).floor()));
    final cardWidth = (bounds.maxWidth - (columns - 1) * gap) / columns;
    final selected = _specs.where((m) => m.key == _expanded && _canExpand(m)).firstOrNull;
    // Limit unit-comparison panels to a comfortable reading width without
    // changing their table contents or the existing narrow-screen layout.
    final isUnitPanel = selected?.key == _DefaulterMetric.unpaid ||
        selected?.key == _DefaulterMetric.partial;
    final panelWidth = isUnitPanel
        ? math.min(880.0, bounds.maxWidth)
        : bounds.maxWidth;

    double panelLeft(int first) {
      final cardCenter = (_specs.indexOf(selected!) - first) *
          (cardWidth + gap) + cardWidth / 2;
      return (cardCenter - panelWidth / 2)
          .clamp(0.0, bounds.maxWidth - panelWidth)
          .toDouble();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var first = 0; first < _specs.length; first += columns) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var j = first; j < math.min(first + columns, _specs.length); j++) ...[
            if (j > first) const SizedBox(width: gap),
            SizedBox(width: cardWidth, child: _metricCard(_specs[j])),
          ],
        ]),
        AnimatedSize(duration: const Duration(milliseconds: 230), curve: Curves.easeInOutCubic, alignment: Alignment.topCenter,
          child: selected != null && _specs.indexOf(selected) >= first && _specs.indexOf(selected) < first + columns
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: EdgeInsets.only(left: (_specs.indexOf(selected) - first) * (cardWidth + gap)), child: SizedBox(width: cardWidth, height: 18, child: Center(child: Icon(Icons.arrow_drop_down_rounded, color: selected.accent, size: 26)))),
                  Padding(
                    padding: EdgeInsets.only(left: panelLeft(first)),
                    child: SizedBox(
                      width: panelWidth,
                      child: _breakdown(selected),
                    ),
                  ),
                ])
              : const SizedBox(width: double.infinity, height: 0)),
        if (first + columns < _specs.length) const SizedBox(height: gap),
      ],
    ]);
  });

  Map<String, List<Map<String, dynamic>>> _groupByUnit(List<Map<String, dynamic>>? rows) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows ?? const <Map<String, dynamic>>[]) {
      (grouped[_unitKey(row)] ??= <Map<String, dynamic>>[]).add(row);
    }
    return grouped;
  }

  Widget _unitComparison(String status) {
    final before = _monthRows(_snapshotPreviousEnd);
    final current = _monthRows(_end);
    if (current == null) return _empty('No saved figure for this selection.');
    final oldUnits = _groupByUnit(before);
    final newUnits = _groupByUnit(current);
    final keys = <String>{
      for (final row in current) if (row['record_section'] == 'This Month' && row['status'] == status) _unitKey(row),
      for (final row in before ?? const <Map<String, dynamic>>[]) if (row['record_section'] == 'This Month' && row['status'] == status) _unitKey(row),
    };
    String unit(String key) => _unit((newUnits[key] ?? oldUnits[key]!).first);
    double? amount(List<Map<String, dynamic>>? rows) => rows == null ? null : _sum(rows, 'total_due');
    double? difference(String key) {
      final previous = amount(oldUnits[key]);
      final latest = amount(newUnits[key]);
      return previous == null || latest == null ? null : latest - previous;
    }
    final filtered = keys.where((key) => unit(key).toLowerCase().contains(_unitSearch.trim().toLowerCase())).toList()
      ..sort((a, b) {
        if (_unitSort == 'unit') return unit(a).compareTo(unit(b));
        final av = _unitSort == 'change' ? difference(a) : amount(newUnits[a]);
        final bv = _unitSort == 'change' ? difference(b) : amount(newUnits[b]);
        if (av == null && bv != null) return 1;
        if (av != null && bv == null) return -1;
        final order = (bv ?? 0.0).compareTo(av ?? 0.0);
        return order != 0 ? order : unit(a).compareTo(unit(b));
      });
    const amountStyle = TextStyle(fontSize: 12, color: _ink, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);
    const secondaryStyle = TextStyle(fontSize: 10.5, color: _muted, height: 1.3);
    final previousHeader = _short(_snapshotPreviousEnd);
    final currentHeader = _partialEndMonth ? '${_short(_end)} (in progress)' : _short(_end);

    Widget cell(List<Map<String, dynamic>>? rows, DateTime month, {required bool available}) {
      final value = amount(rows);
      final statuses = rows?.map((r) => r['status']?.toString() ?? 'Unknown').toSet().join(' / ');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(!available ? 'Unavailable' : rows == null ? 'Not listed' : _money(value),
            textAlign: TextAlign.right, style: amountStyle),
        if (rows != null) ...[
          const SizedBox(height: 3),
          Text(_datesLabel(rows, month), textAlign: TextAlign.right, style: secondaryStyle),
          if (statuses != status)
            Text(statuses ?? 'Unknown', textAlign: TextAlign.right, style: secondaryStyle),
        ],
      ]);
    }
    Widget delta(String key, {bool showCurrency = false}) {
      final value = difference(key);
      final formatted = showCurrency ? _money(value) : _money(value).replaceFirst('RM ', '');
      return Text(value == null ? '—' : '${value > 0 ? '+' : ''}$formatted',
          textAlign: TextAlign.right,
          style: amountStyle.copyWith(color: value == null || value == 0 ? _muted : value > 0 ? _red : _green));
    }
    Widget heading(String text, {bool numeric = false}) => Text(text,
        textAlign: numeric ? TextAlign.right : TextAlign.left,
        style: const TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w700, height: 1.3));

    Widget row(String key, bool wide, int index) {
      final oldCell = cell(oldUnits[key], _snapshotPreviousEnd, available: before != null);
      final newCell = cell(newUnits[key], _end, available: true);
      final unitText = Text(unit(key), style: const TextStyle(fontSize: 12, color: _ink, fontWeight: FontWeight.w800));
      return Container(
        key: ValueKey('comparison_$key'),
        color: index.isOdd ? const Color(0xFFF8F9FA) : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 2, child: unitText), const SizedBox(width: 10),
                Expanded(flex: 4, child: oldCell), const SizedBox(width: 10),
                Expanded(flex: 4, child: newCell), const SizedBox(width: 10),
                Expanded(flex: 3, child: delta(key)),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [Expanded(child: unitText), const SizedBox(width: 8), Flexible(child: delta(key, showCurrency: true))]),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(child: heading(previousHeader, numeric: true)),
                  const SizedBox(width: 12),
                  Expanded(child: heading(currentHeader, numeric: true)),
                ]),
                const SizedBox(height: 4),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: oldCell),
                  const SizedBox(width: 12),
                  Expanded(child: newCell),
                ]),
              ]),
      );
    }
    return LayoutBuilder(builder: (context, bounds) {
      final wide = bounds.maxWidth >= 630;
      final sideBySide = bounds.maxWidth >= 340;
      final all = _showAll.contains('metric');
      const limit = 5;
      final visible = all ? filtered : filtered.take(limit).toList();
      final controlHeight = math.max(44.0, MediaQuery.textScalerOf(context).scale(12) + 26);
      final controlRadius = BorderRadius.circular(10);
      final search = SizedBox(
        height: controlHeight,
        child: TextFormField(
          key: ValueKey('unit_search_${widget.siteId}_${_key(_end)}_$status'),
          initialValue: _unitSearch,
          onChanged: (value) => setState(() { _unitSearch = value; _showAll.remove('metric'); }),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search unit',
            prefixIcon: const Icon(Icons.search_rounded, size: 17, color: _muted),
            prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: controlRadius, borderSide: const BorderSide(color: _border)),
            enabledBorder: OutlineInputBorder(borderRadius: controlRadius, borderSide: const BorderSide(color: _border)),
            focusedBorder: OutlineInputBorder(borderRadius: controlRadius, borderSide: const BorderSide(color: _blue, width: 1.3)),
          ),
          style: const TextStyle(fontSize: 12, color: _ink),
        ),
      );
      // The sorting selector is right-aligned and matches the search field's
      // outlined rounded rectangle. On very narrow screens it wraps below.
      final sort = Container(
        height: controlHeight,
        width: math.min(170.0, bounds.maxWidth),
        decoration: BoxDecoration(color: Colors.white, borderRadius: controlRadius, border: Border.all(color: _border)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _unitSort,
            isDense: true,
            isExpanded: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            borderRadius: controlRadius,
            dropdownColor: Colors.white,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _muted, size: 18),
            style: const TextStyle(fontSize: 12, color: _ink, fontWeight: FontWeight.w500),
            items: const [
              DropdownMenuItem(value: 'balance', child: Text('Highest balance', overflow: TextOverflow.ellipsis)),
              DropdownMenuItem(value: 'change', child: Text('Largest increase', overflow: TextOverflow.ellipsis)),
              DropdownMenuItem(value: 'unit', child: Text('Unit number', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (value) { if (value != null) setState(() => _unitSort = value); },
          ),
        ),
      );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (sideBySide)
          Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: search))),
            const SizedBox(width: 12),
            sort,
          ])
        else ...[
          search,
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: sort),
        ],
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          _empty('No matching units.')
        else ...[
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (wide) ...[
                Container(color: _soft, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), child: Row(children: [
                  Expanded(flex: 2, child: heading('Unit')), const SizedBox(width: 10),
                  Expanded(flex: 4, child: heading(previousHeader, numeric: true)), const SizedBox(width: 10),
                  Expanded(flex: 4, child: heading(currentHeader, numeric: true)), const SizedBox(width: 10),
                  Expanded(flex: 3, child: heading('Change (RM)', numeric: true)),
                ])),
                const Divider(height: 1, color: _border),
              ],
              AnimatedSize(
                duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: Color(0xFFF0F1F2)),
                    row(visible[i], wide, i),
                  ],
                ]),
              ),
            ]),
          ),
          if (filtered.length > limit)
            TextButton(
              onPressed: () => setState(() { if (all) { _showAll.remove('metric'); } else { _showAll.add('metric'); } }),
              child: Text(all ? 'Show less' : 'Show all ${filtered.length} records', style: const TextStyle(fontSize: 12, color: _red)),
            ),
        ],
      ]);
    });
  }

  Widget _breakdown(_DefaulterMetricSpec spec) {
    final current = _value(spec.key, _start, _end);
    final previous = _previousValue(spec);
    final movement = _movement(spec, current, previous);
    final favourable = _favourable(spec, movement);
    if (spec.key == _DefaulterMetric.unpaid || spec.key == _DefaulterMetric.partial) {
      final status = spec.key == _DefaulterMetric.unpaid ? 'Outstanding' : 'Partially Paid';
      return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('$status · ${current == null ? 'Unavailable' : '${_format(spec, current)} units'}', style: const TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w800))),
          IconButton(tooltip: 'Close breakdown', visualDensity: VisualDensity.compact, onPressed: () => setState(() => _expanded = null), icon: const Icon(Icons.close_rounded, size: 18)),
        ]),
        const SizedBox(height: 10),
        _unitComparison(status),
      ]), padding: const EdgeInsets.all(16), shadow: false);
    }
    final rows = <Widget>[];
    if (current != null) {
      if (spec.key == _DefaulterMetric.balance) {
        final open = _openRows(_end)!;
        final grouped = <String, List<Map<String, dynamic>>>{};
        for (final r in open) { (grouped[r['status']?.toString() ?? 'Unknown'] ??= []).add(r); }
        for (final entry in grouped.entries) {
          final value = _sum(entry.value, 'total_due');
          rows.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _line(entry.key, _money(value), subtitle: '${entry.value.length} cases'),
            _bar(value, current, entry.key == 'Outstanding' ? _gold : entry.key == 'Partially Paid' ? _gold : _blue),
            const SizedBox(height: 6),
          ]));
        }
      } else if (spec.key == _DefaulterMetric.payments) {
        final byUnit = <String, double>{};
        for (final r in _paymentsFor(_start, _end)!) {
          final unit = _unitById[_id(r)] ?? 'Unit unavailable';
          byUnit[unit] = (byUnit[unit] ?? 0) + _number(r['amount'])!;
        }
        final entries = byUnit.entries.toList()..sort((a,b) => b.value.compareTo(a.value));
        for (final e in entries) { rows.add(_line(e.key, _money(e.value))); }
      } else if (spec.key == _DefaulterMetric.completed) {
        final cases = _completedRows(_start, _end)!..sort((a,b) => (b['completed_date']?.toString() ?? '').compareTo(a['completed_date']?.toString() ?? ''));
        for (final r in cases) { rows.add(_line(_unit(r), 'Completed', subtitle: 'Settled ${r['completed_date']}')); }
      }
    }
    final detail = current == null ? _empty('No saved figure for this selection.') : rows.isEmpty ? _empty('No matching records for this selection.') : _limitedRows('metric', rows);
    final comparison = Container(padding: const EdgeInsets.all(13), decoration: spec.money ? BoxDecoration(color: _soft, borderRadius: BorderRadius.circular(9)) : null, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Previous period', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      _note(spec.snapshot ? _snapshotLabel(_snapshotPreviousEnd) : _rangeLabel(_previousStart, _previousEnd)),
      const SizedBox(height: 7),
      Text(_format(spec, previous), style: const TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w800)),
      const SizedBox(height: 7),
      Text(_movementText(spec, movement), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: favourable == null ? _muted : favourable ? _green : _red)),
      const Divider(height: 18, color: _border),
      _note(_coverage(spec, current)),
      if (_partialEndMonth && !spec.snapshot) ...[const SizedBox(height: 6), _note('Current period is incomplete; movement is not rated against a full prior period.')],
    ]));
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text('${spec.label} · ${_format(spec, current)}', style: const TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w800))), IconButton(tooltip: 'Close breakdown', visualDensity: VisualDensity.compact, onPressed: () => setState(() => _expanded = null), icon: const Icon(Icons.close_rounded, size: 18))]),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, bounds) => bounds.maxWidth >= 690 ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: detail), const SizedBox(width: 20), Expanded(child: comparison)]) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [detail, const SizedBox(height: 12), comparison])),
    ]), padding: const EdgeInsets.all(16), shadow: false);
  }

  Widget _segment(String label, bool selected, VoidCallback onTap, {double fontSize = 11}) => Material(
    color: selected ? const Color(0xFF111111) : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8), child: Text(label, style: TextStyle(color: selected ? Colors.white : _muted, fontSize: fontSize, fontWeight: FontWeight.w800)))),
  );
  Widget _segments(List<Widget> items) => Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(color: _soft, borderRadius: BorderRadius.circular(12)), child: Wrap(spacing: 3, runSpacing: 3, children: items));
  // The trend chart retains the annual scope and interactive saved values.
  Widget _trends() {
    final annual = _annualMonths;
    final points = <FinanceChartPoint>[];
    final currency = _trend != _DefaulterTrend.open;
    final color = _trend == _DefaulterTrend.balance
        ? _gold : _trend == _DefaulterTrend.payments ? _teal : _blue;
    for (final month in annual) {
      final value = switch (_trend) {
        _DefaulterTrend.balance => _value(_DefaulterMetric.balance, month, month),
        _DefaulterTrend.payments => _value(_DefaulterMetric.payments, month, month),
        _DefaulterTrend.open => _openRows(month)?.length.toDouble(),
      };
      if (value != null) points.add(FinanceChartPoint(month, value));
    }
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('DEFAULTERS TRENDS'),
      const SizedBox(height: 8),
      _note(annual.isEmpty ? 'No available reporting months'
          : _rangeLabel(DateTime(annual.last.year, 1), annual.last)),
      const SizedBox(height: 10),
      _segments([
        _segment('Outstanding', _trend == _DefaulterTrend.balance,
            () => setState(() => _trend = _DefaulterTrend.balance), fontSize: 13),
        _segment('Payments', _trend == _DefaulterTrend.payments,
            () => setState(() => _trend = _DefaulterTrend.payments), fontSize: 13),
        _segment('Open Cases', _trend == _DefaulterTrend.open,
            () => setState(() => _trend = _DefaulterTrend.open), fontSize: 13),
      ]),
      const SizedBox(height: 14),
      if (points.isEmpty)
        _empty('No saved figures available for this trend.')
      else ...[
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: FinanceInteractiveChart(
            key: ValueKey('defaulters_${widget.siteId}_${_end.year}_${_key(annual.last)}_$_trend'),
            actual: points, future: const [], color: color, mode: 'bars',
            currency: currency, compact: true,
            showAllMonths: true,
            axisStart: DateTime(annual.last.year, 1),
            axisEnd: annual.last,
            axisLabelFontSize: 12,
            moneyFormatter: (value) => currency
                ? _money(value) : '${_number(value)?.toStringAsFixed(0) ?? '—'} cases',
            monthFormatter: _label,
          ),
        ),
      ],
      if (annual.isNotEmpty && points.length != annual.length) ...[
        const SizedBox(height: 8),
        _note('${points.length}/${annual.length} reporting months available'),
      ],
      if (annual.isNotEmpty && _cutoff(annual.last).isBefore(_monthEnd(annual.last)) &&
          (points.isEmpty || _key(points.last.month) != _key(annual.last))) ...[
        const SizedBox(height: 6),
        _note('${_short(annual.last)} is in progress.'),
      ],
    ]));
  }

  Widget _concentration() {
    final open = _openRows(_end);
    final total = open == null ? null : _sum(open, 'total_due');
    final units = <String, double>{};
    if (total != null && open != null) {
      for (final r in open) {
        final amount = _number(r['total_due'])!;
        if (amount <= 0) continue;
        final unit = _unit(r) == 'Unit unavailable' ? 'Unit unavailable (${_id(r)})' : _unit(r);
        units[unit] = (units[unit] ?? 0) + amount;
      }
    }
    final ranked = units.entries.toList()
      ..sort((a, b) {
        final byAmount = b.value.compareTo(a.value);
        return byAmount == 0 ? a.key.compareTo(b.key) : byAmount;
      });
    final top = ranked.take(_topCount).toList();
    final topTotal = top.fold<double>(0, (sum, entry) => sum + entry.value);
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('DEBT CONCENTRATION'),
      const SizedBox(height: 8),
      _note(open == null ? _snapshotLabel(_end) : _snapshotHeadline(_end, open)),
      const SizedBox(height: 10),
      _segments([
        _segment('Top 3', _topCount == 3, () => setState(() => _topCount = 3)),
        _segment('Top 5', _topCount == 5, () => setState(() => _topCount = 5)),
      ]),
      const SizedBox(height: 14),
      if (total == null) _empty('No outstanding snapshot available for this month.')
      else if (total <= 0 || top.isEmpty) _empty('No positive outstanding balances.')
      else ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${(topTotal / total * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: _ink, fontSize: 22, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  _note('Share of outstanding debt'),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(_money(topTotal), style: const TextStyle(color: _ink, fontSize: 20, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(height: 4),
                  _note('${top.length} highest-balance units'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Divider(height: 1, color: _border),
        const SizedBox(height: 10),
        Row(children: const [
          Expanded(child: Text('Unit', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w700))),
          SizedBox(width: 12),
          Text('Amount', textAlign: TextAlign.right, style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        for (final r in top) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(
                child: Text(
                  r.key.startsWith('Unit unavailable (') ? 'Unit unavailable' : r.key,
                  style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              Text(_money(r.value), textAlign: TextAlign.right,
                style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w800)),
            ]),
          ),
          _bar(r.value, top.first.value, _gold),
          if (r != top.last) const SizedBox(height: 8),
        ],
      ],
    ]));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Defaulters Overview', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _ink)),
    const SizedBox(height: 4),
    Text(_rangeLabel(_start, _end), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _muted)),
    const SizedBox(height: 10),
    if (_loading) _panel(const Padding(padding: EdgeInsets.symmetric(vertical: 28), child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: _red)), SizedBox(height: 10), Text('Loading defaulters overview...', style: TextStyle(color: _muted, fontSize: 12))])))) else if (_datasetError != null)
      _panel(Row(children: [
        const Icon(Icons.error_outline, color: _red, size: 20),
        const SizedBox(width: 9),
        Expanded(child: _note(_datasetError!)),
        TextButton(onPressed: () => unawaited(_load()), child: const Text('Retry')),
      ]))
    else ...[
      if (_snapshotError != null || _paymentError != null || _dateError != null) ...[
        _panel(Row(children: [const Icon(Icons.info_outline_rounded, color: _amber, size: 20), const SizedBox(width: 9), Expanded(child: _note([?_snapshotError, ?_paymentError, ?_dateError].join(' '))), TextButton(onPressed: () => unawaited(_load()), child: const Text('Retry'))])),
        const SizedBox(height: 10),
      ],
      _metrics(),
      const SizedBox(height: 14),
      LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          final width = math.min(880.0, (constraints.maxWidth - 14) * 0.62);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: width, child: _trends()), const SizedBox(width: 14), Expanded(child: _concentration())]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_trends(), const SizedBox(height: 14), _concentration()]);
      }),
    ],
  ]);
}
