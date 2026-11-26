import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dashboard_finance_service.dart';
import 'dashboard_financial_trends.dart';

// Finance presentation and on-demand statistical forecasts.
// Official finance records are read-only here. Only the authenticated server
// may save the derived forecast cache; this widget never invokes Gemini.
class FinanceDashboardSection extends StatefulWidget {
  final List<Map<String, dynamic>> sites;
  final List<Map<String, dynamic>> reports;
  final String? initialSiteId;
  final DateTime? initialMonth;
  final DateTime? initialFromMonth;
  final bool showSelectors;
  final bool allowAdminForecastPreview;
  final int refreshRevision;
  final int filterRevision;

  const FinanceDashboardSection({
    super.key,
    required this.sites,
    required this.reports,
    this.initialSiteId,
    this.initialMonth,
    this.initialFromMonth,
    this.showSelectors = true,
    this.allowAdminForecastPreview = false,
    this.refreshRevision = 0,
    this.filterRevision = 0,
  });

  @override
  State<FinanceDashboardSection> createState() =>
      _FinanceDashboardSectionState();
}

class _FinanceDashboardSectionState extends State<FinanceDashboardSection> {
  // Finance visual system; overview accents match the Lifts dashboard.
  static const _ink = Color(0xFF151515);
  static const _muted = Color(0xFF6D7178);
  static const _border = Color(0xFFE3E5E8);
  static const _soft = Color(0xFFF5F6F7);
  static const _black = Color(0xFF111111);
  static const _red = Color(0xFFD92D3A);
  static const _darkRed = Color(0xFFA91F2B);
  static const _amber = Color(0xFFB26B00);
  static const _overviewBlue = Color(0xFF5097F5);
  static const _overviewTeal = Color(0xFF36AD98);
  static const _overviewRed = Color(0xFFD66B74);
  static const _overviewAmber = Color(0xFFD29C49);
  static const _overviewGrey = Color(0xFF9CA3AF);

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

  final SupabaseClient _supabase = Supabase.instance.client;
  late final FinanceForecastService _forecastService = FinanceForecastService(
    _supabase,
  );
  String? _siteId;
  String? _fromMonth;
  String? _month;
  String _chartMetric = 'collection_total';
  // Null selects the highest available priority automatically. Explicit
  // selections (including empty categories) survive financial data refreshes.
  String? _attentionPriority;
  bool _attentionCollapsed = false;
  final Set<String> _expandedAttentionMetrics = <String>{};

  bool _loading = true;
  FinanceOverviewMetric? _overviewExpanded;
  Map<String, Map<String, dynamic>> _billingBreakdown = const {};
  bool _breakdownReadFailed = false;
  String? _error;

  Map<String, dynamic>? _analysis;
  List<Map<String, dynamic>> _history = const [];
  // The full property dataset is shared, but the three views have separate
  // periods. Only Financial Overview consumes its applied Start/End filters.
  FinancePropertyPeriods _propertyPeriods = const FinancePropertyPeriods();
  bool _forecastLoading = false;
  bool _forecastPreview = false;
  String? _forecastError;
  FinanceForecastChangeState? _loadedChangeState;
  RealtimeChannel? _revisionChannel;
  String? _watchedSite;
  Timer? _revisionDebounce;
  Timer? _revisionPoll;
  bool _checkingRevision = false;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant FinanceDashboardSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    String? keyOf(DateTime? value) =>
        value == null ? null : _yearMonth(value.toIso8601String());
    final propertyChanged =
        oldWidget.initialSiteId != widget.initialSiteId ||
        oldWidget.allowAdminForecastPreview != widget.allowAdminForecastPreview;
    final selectedSiteMissing =
        _siteId == null ||
        !widget.sites.any((site) => site['id']?.toString() == _siteId);
    if (propertyChanged || selectedSiteMissing) {
      unawaited(_initialize());
      return;
    }
    final overviewChanged =
        keyOf(oldWidget.initialMonth) != keyOf(widget.initialMonth) ||
        keyOf(oldWidget.initialFromMonth) != keyOf(widget.initialFromMonth);
    if (overviewChanged) {
      // didUpdateWidget is followed by build; the property data is already
      // loaded through its latest month. No forecast request or reset here.
      _month = keyOf(widget.initialMonth) ?? _month;
      _fromMonth = keyOf(widget.initialFromMonth) ?? _month;
      _overviewExpanded = null;
    }
    if (oldWidget.refreshRevision != widget.refreshRevision) {
      unawaited(_load());
    } else if (overviewChanged ||
        oldWidget.filterRevision != widget.filterRevision) {
      // Applying the same dates can retry an earlier failure. Ordinary date
      // changes just re-evaluate KPIs and check the tiny property token.
      if (!overviewChanged &&
          !_loading &&
          !_forecastLoading &&
          (_error != null || _forecastError != null)) {
        unawaited(_load());
      } else {
        _scheduleRevisionCheck();
      }
    }
  }

  @override
  void dispose() {
    _sequence++;
    _stopWatching();
    super.dispose();
  }

  static String? _yearMonth(dynamic raw) {
    if (raw == null) return null;
    final date = DateTime.tryParse(raw.toString());
    if (date == null) return null;
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}';
  }

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

  static Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static double? _number(dynamic value) {
    if (value is num) {
      return value.toDouble().isFinite ? value.toDouble() : null;
    }
    final n = double.tryParse(value?.toString() ?? '');
    return n != null && n.isFinite ? n : null;
  }

  static bool _yes(dynamic value) => value == true;

  // A saved financial figure can be displayed even when it is not eligible
  // for forecast training. Do not treat a missing report or test data as actuals.
  static bool _displayableMonth(Map<String, dynamic> row) {
    final classification = row['classification']?.toString().toLowerCase();
    return _yes(row['has_report']) &&
        classification != 'test' &&
        classification != 'missing' &&
        classification != 'future';
  }

  static bool _unverifiedMonth(Map<String, dynamic> row) =>
      row['classification']?.toString().toLowerCase() == 'unverified';

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

  static String _percent(dynamic value) {
    final number = _number(value);
    return number == null ? '--' : '${number.toStringAsFixed(2)}%';
  }

  List<Map<String, dynamic>> get _sites {
    final sites = widget.sites
        .where((item) => (item['id']?.toString() ?? '').isNotEmpty)
        .toList();
    sites.sort(
      (a, b) => (a['site_name']?.toString() ?? '').compareTo(
        b['site_name']?.toString() ?? '',
      ),
    );
    return sites;
  }

  List<String> _monthsFor(String siteId) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final maxMonth = DateTime(now.year, now.month);
    final values = <String>{};
    for (final report in widget.reports) {
      if (report['site_id']?.toString() != siteId) continue;
      final date = _parseMonth(report['report_month']);
      if (date != null && !date.isAfter(maxMonth)) {
        values.add(_yearMonth(report['report_month'])!);
      }
    }
    return values.toList()..sort((a, b) => b.compareTo(a));
  }

  Future<void> _initialize() async {
    _sequence++;
    _stopWatching();
    if (!mounted) return;
    final availableSites = _sites;
    if (_supabase.auth.currentSession == null || availableSites.isEmpty) {
      setState(() {
        _siteId = null;
        _fromMonth = null;
        _month = null;
        _analysis = null;
        _history = const [];
        _propertyPeriods = const FinancePropertyPeriods();
        _loading = false;
        _forecastLoading = false;
        _error = _supabase.auth.currentSession == null
            ? 'Your session has expired. Sign in again.'
            : 'No properties are available.';
      });
      return;
    }
    final known = availableSites.map((s) => s['id']?.toString()).toSet();
    final preferred = widget.initialSiteId;
    final selectedSite = preferred != null && known.contains(preferred)
        ? preferred
        : availableSites.first['id'].toString();
    final months = _monthsFor(selectedSite);
    final preferredMonth = widget.initialMonth == null
        ? null
        : _yearMonth(widget.initialMonth!.toIso8601String());
    final selectedMonth =
        preferredMonth != null && months.contains(preferredMonth)
        ? preferredMonth
        : months.firstOrNull;
    final preferredFromMonth = widget.initialFromMonth == null
        ? null
        : _yearMonth(widget.initialFromMonth!.toIso8601String());
    final selectedFromMonth = selectedMonth == null
        ? null
        : (preferredFromMonth != null &&
                  months.contains(preferredFromMonth) &&
                  preferredFromMonth.compareTo(selectedMonth) <= 0
              ? preferredFromMonth
              : selectedMonth);
    setState(() {
      _siteId = selectedSite;
      _fromMonth = selectedFromMonth;
      _month = selectedMonth;
      _analysis = null;
      _forecastError = null;
      _forecastLoading = selectedMonth != null;
      _loading = selectedMonth != null;
      _attentionPriority = null;
      _attentionCollapsed = false;
      _expandedAttentionMetrics.clear();
      _error = selectedMonth == null
          ? 'No reporting periods are available for this property.'
          : null;
    });
    if (selectedMonth != null) await _load();
  }

  void _selectSite(String siteId) {
    _sequence++;
    _stopWatching();
    final months = _monthsFor(siteId);
    final month = months.firstOrNull;
    setState(() {
      _siteId = siteId;
      _fromMonth = month;
      _month = month;
      _analysis = null;
      _forecastError = null;
      _forecastLoading = month != null;
      _history = const [];
      _propertyPeriods = const FinancePropertyPeriods();
      _billingBreakdown = const {};
      _breakdownReadFailed = false;
      _overviewExpanded = null;
      _loading = month != null;
      _error = month == null ? 'No reporting periods for this property.' : null;
      _attentionPriority = null;
      _attentionCollapsed = false;
      _expandedAttentionMetrics.clear();
    });
    if (month != null) unawaited(_load());
  }

  void _stopWatching() {
    _revisionDebounce?.cancel();
    _revisionDebounce = null;
    _revisionPoll?.cancel();
    _revisionPoll = null;
    final channel = _revisionChannel;
    _revisionChannel = null;
    _watchedSite = null;
    _loadedChangeState = null;
    if (channel != null) unawaited(_removeRevisionChannel(channel));
  }

  Future<void> _removeRevisionChannel(RealtimeChannel channel) async {
    try {
      await _supabase.removeChannel(channel);
    } catch (_) {
      // The channel is already detached from this widget.
    }
  }

  void _watchSite(String site) {
    if (_watchedSite == site) return;
    _stopWatching();
    _watchedSite = site;
    // Only the revision marker is published. RLS and this filter both scope
    // the subscription to the selected property, never financial amounts.
    try {
      _revisionChannel = _supabase
          .channel('finance-revision-$site-${identityHashCode(this)}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'finance_forecast_private',
            table: 'source_revisions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'site_id',
              value: site,
            ),
            callback: (_) {
              if (mounted && _watchedSite == site) _scheduleRevisionCheck();
            },
          )
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed &&
                mounted &&
                _watchedSite == site) {
              _scheduleRevisionCheck();
            }
          });
    } catch (_) {
      // The lightweight check below also recovers missed/unsupported events.
    }
    // Only while this dashboard is open. This reads a tiny change token, not
    // the forecasting engine. It also catches reconnects and month rollovers.
    _revisionPoll = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _watchedSite == site) _scheduleRevisionCheck();
    });
  }

  void _scheduleRevisionCheck() {
    _revisionDebounce?.cancel();
    _revisionDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_checkForChanges());
    });
  }

  Future<void> _checkForChanges() async {
    final site = _siteId;
    final request = _sequence;
    if (!mounted ||
        site == null ||
        _month == null ||
        _watchedSite != site ||
        _loading ||
        _forecastLoading ||
        _checkingRevision ||
        _error != null) {
      return;
    }
    _checkingRevision = true;
    try {
      final next = await _forecastService.changeState(site);
      if (!mounted || request != _sequence || _watchedSite != site) return;
      if (_loadedChangeState != next) {
        // A source change could affect carried balances or annual trends.
        // Refresh the whole current range, but never switch filters.
        unawaited(_load());
      }
    } on PostgrestException catch (error) {
      if (!mounted || request != _sequence) return;
      if (error.code == '42501' || error.code == 'PGRST301') {
        _stopWatching();
        setState(() {
          _analysis = null;
          _history = const [];
          _propertyPeriods = const FinancePropertyPeriods();
          _error = 'Your access to this property is no longer available.';
        });
      }
    } catch (_) {
      // Keep the existing view on transient network failure. Retry on the
      // next notification/check or when Apply Filters is used.
    } finally {
      _checkingRevision = false;
    }
  }

  Future<void> _load() async {
    final site = _siteId;
    if (!mounted || site == null || _month == null) return;
    final currentMonth = FinancePropertyPeriods.malaysiaCurrentMonth();
    final throughMonth = FinanceOverviewService.monthKey(currentMonth);
    final request = ++_sequence;
    _watchSite(site);
    setState(() {
      _loading = true;
      _error = null;
      _analysis = null;
      _forecastLoading = true;
      _forecastError = null;
      _forecastPreview = false;
      _history = const [];
      _propertyPeriods = const FinancePropertyPeriods();
      _billingBreakdown = const {};
      _breakdownReadFailed = false;
      _overviewExpanded = null;
    });
    try {
      // Capture the source token before reading actuals. Any intervening
      // change triggers a fresh load after the forecast finishes.
      FinanceForecastChangeState? before;
      try {
        before = await _forecastService.changeState(site);
      } catch (_) {
        // A notification check must not block the authoritative financial KPIs.
      }
      if (!mounted || request != _sequence) return;
      _loadedChangeState = before;
      final history = await _supabase.rpc(
        'finance_dashboard_monthly_dataset',
        params: <String, dynamic>{
          'p_site_id': site,
          'p_through_month': '$throughMonth-01',
        },
      );
      if (!mounted || request != _sequence) return;
      final historyRows = _maps(history);
      // The server returns full historical data through the latest existing
      // report (not future months). Resolve automatic scopes from actual data,
      // rather than using the overview dates or a stale report list.
      final periods = FinancePropertyPeriods.fromHistory(
        historyRows,
        throughMonth: currentMonth,
      );
      final ids = historyRows
          .where(
            (row) =>
                FinanceOverviewService.isActual(row) &&
                row['has_billing'] == true &&
                row['report_id'] != null,
          )
          .map((row) => row['report_id'].toString())
          .toSet()
          .toList();
      final breakdown = <String, Map<String, dynamic>>{};
      var breakdownFailed = false;
      try {
        for (var i = 0; i < ids.length; i += 80) {
          final rows = _maps(
            await _supabase
                .from('finance_billing_collection')
                .select(
                  'report_id,billing_service_charge,billing_sinking_fund,'
                  'billing_other,collection_service_charge,collection_sinking_fund,'
                  'collection_other,collection_open_credit',
                )
                .inFilter('report_id', ids.skip(i).take(80).toList()),
          );
          if (!mounted || request != _sequence) return;
          for (final row in rows) {
            final id = row['report_id']?.toString();
            if (id != null && ids.contains(id)) breakdown[id] = row;
          }
        }
      } catch (_) {
        // A detail read must not prevent the authoritative KPIs from displaying.
        breakdown.clear();
        breakdownFailed = true;
      }
      if (!mounted || request != _sequence) return;
      setState(() {
        _history = historyRows;
        _propertyPeriods = periods;
        _billingBreakdown = breakdown;
        _breakdownReadFailed = breakdownFailed;
        _loading = false;
        _error = null;
      });
      // Historical charts and KPIs are now visible, regardless of forecast
      // latency or whether a particular metric has enough training history.
      final forecastPeriod = periods.forecast;
      if (forecastPeriod == null) {
        setState(() {
          _forecastLoading = false;
          _forecastError = null;
        });
      } else {
        await _loadForecast(
          site,
          FinanceOverviewService.monthKey(forecastPeriod.start),
          FinanceOverviewService.monthKey(forecastPeriod.end),
          request,
        );
      }
    } catch (error) {
      if (!mounted || request != _sequence) return;
      setState(() {
        _loading = false;
        _forecastLoading = false;
        _error = 'Unable to read Finance analytics: $error';
      });
    } finally {
      if (mounted && request == _sequence && _error == null) {
        _scheduleRevisionCheck();
      }
    }
  }

  Future<void> _loadForecast(
    String site,
    String from,
    String month,
    int request,
  ) async {
    try {
      final result = await _forecastService.forecast(
        siteId: site,
        startMonth: from,
        endMonth: month,
        allowAdminPreview: widget.allowAdminForecastPreview,
      );
      if (!mounted || request != _sequence) return;
      setState(() {
        _analysis = result.analysis;
        _forecastPreview = result.preview;
        _forecastLoading = false;
        _forecastError = null;
      });
    } on FinanceForecastException catch (error) {
      if (!mounted || request != _sequence) return;
      setState(() {
        _analysis = null;
        _forecastLoading = false;
        _forecastError = error.message;
        if (error.code == 'property_access_denied' ||
            error.code == 'authentication_required') {
          _history = const [];
          _propertyPeriods = const FinancePropertyPeriods();
          _error = error.message;
        }
      });
    } catch (_) {
      if (!mounted || request != _sequence) return;
      setState(() {
        _analysis = null;
        _forecastLoading = false;
        _forecastError = 'Unable to load the financial forecast. Please retry.';
      });
    }
  }

  List<Map<String, dynamic>> get _forecastHistory =>
      _history
          .where(
            (row) => FinancePropertyPeriods.contains(
              _propertyPeriods.forecast,
              row['report_month'],
            ),
          )
          .toList()
        ..sort(
          (a, b) => (a['report_month']?.toString() ?? '').compareTo(
            b['report_month']?.toString() ?? '',
          ),
        );

  List<Map<String, dynamic>> get _annualAttentionHistory => _history
      .where(
        (row) => FinancePropertyPeriods.contains(
          _propertyPeriods.annualAttention,
          row['report_month'],
        ),
      )
      .toList();

  List<Map<String, dynamic>> get _rangeAnomalies =>
      _maps(_analysis?['financial_anomalies'])
          .where(
            (row) => FinancePropertyPeriods.contains(
              _propertyPeriods.annualAttention,
              row['month'],
            ),
          )
          .toList();

  List<Map<String, dynamic>> get _rangeQualityIssues {
    final saved = _maps(_analysis?['data_quality_issues'])
        .where(
          (row) => FinancePropertyPeriods.contains(
            _propertyPeriods.annualAttention,
            row['month'],
          ),
        )
        .toList();
    final savedMonths = saved.map((row) => row['month']?.toString()).toSet();
    // Keep authoritative dataset flags visible while forecasting is loading
    // or unavailable. The same month is displayed only once.
    const visibleFlags = <String>{
      'missing_monthly_report',
      'missing_billing',
      'missing_arrears_reconciliation',
      'missing_utilities',
      'non_positive_billing',
      'missing_electricity_bill',
      'missing_water_bill',
      'test_data',
      'unverified_data',
      'derived_arrears_without_reconciliation',
      'not_closed_month',
    };
    final fallback = <Map<String, dynamic>>[];
    for (final row in _annualAttentionHistory) {
      final month = _yearMonth(row['report_month']);
      if (month == null || savedMonths.contains(month)) continue;
      final rawFlags = row['quality_flags'];
      final flags = rawFlags is List
          ? rawFlags
                .map((value) => value.toString())
                .where(visibleFlags.contains)
                .toSet()
          : <String>{};
      if (_unverifiedMonth(row)) flags.add('unverified_data');
      if (flags.isNotEmpty) {
        fallback.add({'month': month, 'flags': flags.toList()});
      }
    }
    return [...fallback, ...saved]..sort(
      (a, b) => (b['month']?.toString() ?? '').compareTo(
        a['month']?.toString() ?? '',
      ),
    );
  }

  Map<String, dynamic>? _forecastFor(String metric) {
    return _asMap(_asMap(_analysis?['forecasts'])?[metric]);
  }

  List<FinanceChartPoint> _actualSeries(String metric) {
    final points = <FinanceChartPoint>[];
    for (final row in _forecastHistory) {
      if (!_displayableMonth(row)) continue;
      // Keep the forecast-training booleans untouched; for chart display use
      // the existence of actual saved Finance module rows instead.
      if ((metric == 'billing_total' || metric == 'collection_total') &&
          !_yes(row['has_billing'])) {
        continue;
      }
      if (metric == 'closing_arrears' &&
          (!_yes(row['has_billing']) ||
              !_yes(row['has_arrears_reconciliation']))) {
        continue;
      }
      final date = _parseMonth(row['report_month']);
      final amount = _number(row[metric]);
      if (date != null && amount != null) {
        points.add(
          FinanceChartPoint(date, amount, unverified: _unverifiedMonth(row)),
        );
      }
    }
    return points;
  }

  List<FinanceChartPrediction> _forecastSeries(String metric) {
    final forecast = _forecastFor(metric);
    final points = <FinanceChartPrediction>[];
    for (final item in _maps(forecast?['forecast'])) {
      final date = _parseMonth(item['month']);
      final value = _number(item['predicted']);
      final low = _number(item['planning_range_low']);
      final high = _number(item['planning_range_high']);
      if (date != null && value != null && low != null && high != null) {
        final end = _propertyPeriods.forecast?.end;
        if (end != null &&
            date.isAfter(end) &&
            low >= 0 &&
            low <= value &&
            value <= high) {
          points.add(FinanceChartPrediction(date, value, low, high));
        }
      }
    }
    points.sort((a, b) => a.month.compareTo(b.month));
    return points;
  }

  Widget _panel({
    required Widget child,
    EdgeInsets? padding,
    Color color = Colors.white,
    bool shadow = true,
  }) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _border),
      boxShadow: shadow
          ? const [
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ]
          : null,
    ),
    child: child,
  );

  InputDecoration _selectorDecoration(String label, IconData icon) =>
      InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 19, color: _red),
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _red, width: 1.4),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  Widget _selectorsPanel() {
    final options = _sites;
    final site = _siteId;
    final months = site == null ? <String>[] : _monthsFor(site);
    final to = months.contains(_month) ? _month : null;
    final validFromMonths = to == null
        ? months
        : months.where((item) => item.compareTo(to) <= 0).toList();
    final from = validFromMonths.contains(_fromMonth) ? _fromMonth : to;

    Widget propertyPicker() => DropdownButtonFormField<String>(
      key: ValueKey('finance_site_${site ?? 'none'}'),
      initialValue: options.any((item) => item['id']?.toString() == site)
          ? site
          : null,
      isExpanded: true,
      decoration: _selectorDecoration('Property', Icons.apartment_outlined),
      items: [
        for (final option in options)
          DropdownMenuItem<String>(
            value: option['id'].toString(),
            child: Text(
              option['site_name']?.toString() ?? 'Unnamed property',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null && value != site) _selectSite(value);
      },
    );

    Widget fromPicker() => DropdownButtonFormField<String>(
      key: ValueKey('finance_from_${site}_${from ?? 'none'}'),
      initialValue: from,
      isExpanded: true,
      decoration: _selectorDecoration(
        'Overview Start',
        Icons.calendar_view_month_outlined,
      ),
      items: [
        for (final value in validFromMonths)
          DropdownMenuItem<String>(
            value: value,
            child: Text(_monthLabel(value)),
          ),
      ],
      onChanged: validFromMonths.isEmpty
          ? null
          : (value) {
              if (value == null || value == _fromMonth) return;
              setState(() {
                _fromMonth = value;
                _overviewExpanded = null;
              });
              _scheduleRevisionCheck();
            },
    );

    Widget toPicker() => DropdownButtonFormField<String>(
      key: ValueKey('finance_to_${site}_${to ?? 'none'}'),
      initialValue: to,
      isExpanded: true,
      decoration: _selectorDecoration(
        'Overview End',
        Icons.event_available_outlined,
      ),
      items: [
        for (final value in months)
          DropdownMenuItem<String>(
            value: value,
            child: Text(_monthLabel(value)),
          ),
      ],
      onChanged: months.isEmpty
          ? null
          : (value) {
              if (value == null || value == _month) return;
              setState(() {
                _month = value;
                if (_fromMonth == null || _fromMonth!.compareTo(value) > 0) {
                  _fromMonth = value;
                }
                _overviewExpanded = null;
              });
              _scheduleRevisionCheck();
            },
    );

    return _panel(
      shadow: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 850) {
            return Row(
              children: [
                Expanded(flex: 2, child: propertyPicker()),
                const SizedBox(width: 12),
                Expanded(child: fromPicker()),
                const SizedBox(width: 12),
                Expanded(child: toPicker()),
              ],
            );
          }
          return Column(
            children: [
              propertyPicker(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: fromPicker()),
                  const SizedBox(width: 12),
                  Expanded(child: toPicker()),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  String _overviewPeriodLabel(FinanceOverviewPeriod period) {
    final from = _monthLabel(FinanceOverviewService.monthKey(period.start));
    final to = _monthLabel(FinanceOverviewService.monthKey(period.end));
    return from == to ? to : '$from – $to';
  }

  String _overviewShortPeriod(FinanceOverviewPeriod period) {
    String short(DateTime date) =>
        '${_monthNames[date.month - 1].substring(0, 3)} ${date.year}';
    if (period.monthCount == 1) return short(period.end);
    final from = _monthNames[period.start.month - 1].substring(0, 3);
    final to = _monthNames[period.end.month - 1].substring(0, 3);
    if (period.start.year == period.end.year) {
      return '$from–$to ${period.end.year}';
    }
    return '${short(period.start)} – ${short(period.end)}';
  }

  String _overviewCoverage(
    FinanceOverviewMetric metric,
    FinanceOverviewValue value,
  ) {
    if (value.amount == null) return 'No saved figure';
    if (metric == FinanceOverviewMetric.utilities && !value.complete) {
      return 'Partial · ${value.available}/${value.expected} bills';
    }
    if (!value.complete) {
      return 'Partial · ${value.available}/${value.expected} months';
    }
    if (metric == FinanceOverviewMetric.arrears) return 'End-month balance';
    final count = metric == FinanceOverviewMetric.utilities
        ? value.expected ~/ 2
        : value.expected;
    return '$count ${count == 1 ? 'month' : 'months'}';
  }

  void _selectOverviewMetric(FinanceOverviewMetric? metric) {
    setState(() {
      _overviewExpanded = _overviewExpanded == metric ? null : metric;
    });
  }

  Widget _financialTrends() {
    final period = _propertyPeriods.annualTrends;
    final site = _sites
        .where((row) => row['id']?.toString() == _siteId)
        .firstOrNull;
    final yearHistory = _history
        .where(
          (row) => FinancePropertyPeriods.contains(period, row['report_month']),
        )
        .toList();
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: period == null
            ? _panel(
                shadow: false,
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Financial Trends',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'No actual financial history is available for this property.',
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              )
            : FinancialTrendsPanel(
                key: ValueKey('financial_trends_${_siteId}_${period.end.year}'),
                propertyName:
                    site?['site_name']?.toString() ?? 'Selected property',
                period: period,
                history: yearHistory,
              ),
      ),
    );
  }

  Widget _metrics() {
    final end = _parseMonth(_month);
    if (end == null) return const SizedBox.shrink();
    final requestedStart = _parseMonth(_fromMonth) ?? end;
    final start = requestedStart.isAfter(end) ? end : requestedStart;
    // The applied Finance filters are the only source of the KPI period.
    final period = FinanceOverviewPeriod(start, end);
    final service = FinanceOverviewService(_history, _billingBreakdown);
    final items = <_FinanceMetricCardData>[
      _FinanceMetricCardData(
        FinanceOverviewMetric.billing,
        'Total Billing',
        Icons.description_outlined,
        _overviewBlue,
      ),
      _FinanceMetricCardData(
        FinanceOverviewMetric.collected,
        'Total Collected',
        Icons.account_balance_wallet_outlined,
        _overviewTeal,
      ),
      _FinanceMetricCardData(
        FinanceOverviewMetric.ratio,
        'Collection-to-Billing',
        Icons.percent_rounded,
        _overviewTeal,
      ),
      _FinanceMetricCardData(
        FinanceOverviewMetric.arrears,
        'Closing Arrears',
        Icons.receipt_long_outlined,
        _overviewRed,
      ),
      _FinanceMetricCardData(
        FinanceOverviewMetric.utilities,
        'Total Utilities',
        Icons.bolt_outlined,
        _overviewAmber,
      ),
    ];
    final comparisons = {
      for (final item in items)
        item.metric: service.compare(item.metric, period),
    };
    final selected = items
        .where((item) => item.metric == _overviewExpanded)
        .firstOrNull;
    final previous = period.preceding;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Financial Overview',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _overviewPeriodLabel(period),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: _muted,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, bounds) {
            const gap = 10.0;
            const minCardWidth = 210.0;
            final columns = math.min(
              items.length,
              math.max(
                1,
                ((bounds.maxWidth + gap) / (minCardWidth + gap)).floor(),
              ),
            );
            final cardWidth = (bounds.maxWidth - (columns - 1) * gap) / columns;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var first = 0; first < items.length; first += columns) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var j = first;
                        j < math.min(first + columns, items.length);
                        j++
                      ) ...[
                        if (j > first) const SizedBox(width: gap),
                        SizedBox(
                          width: cardWidth,
                          child: _FinanceMetricCard(
                            data: items[j],
                            comparison: comparisons[items[j].metric]!,
                            comparisonLabel:
                                'vs ${items[j].metric == FinanceOverviewMetric.arrears ? _overviewShortPeriod(FinanceOverviewPeriod(previous.end, previous.end)) : _overviewShortPeriod(previous)}',
                            coverage: _overviewCoverage(
                              items[j].metric,
                              comparisons[items[j].metric]!.current,
                            ),
                            showComparison: period.monthCount <= 2,
                            selected: _overviewExpanded == items[j].metric,
                            onTap: () => _selectOverviewMetric(items[j].metric),
                          ),
                        ),
                      ],
                    ],
                  ),
                  // A single panel expands immediately below the selected card's row.
                  // The pointer uses the selected card's accent at every breakpoint.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 230),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child:
                        selected != null &&
                            items.indexOf(selected) >= first &&
                            items.indexOf(selected) < first + columns
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: EdgeInsets.only(
                                  left:
                                      (items.indexOf(selected) - first) *
                                      (cardWidth + gap),
                                ),
                                child: SizedBox(
                                  width: cardWidth,
                                  height: 18,
                                  child: Center(
                                    child: Icon(
                                      Icons.arrow_drop_down_rounded,
                                      color: selected.accent,
                                      size: 26,
                                    ),
                                  ),
                                ),
                              ),
                              _overviewBreakdown(
                                selected,
                                comparisons[selected.metric]!,
                                period,
                              ),
                            ],
                          )
                        : const SizedBox(width: double.infinity, height: 0),
                  ),
                  if (first + columns < items.length)
                    const SizedBox(height: gap),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  static const _overviewComponentColors = <Color>[
    _overviewBlue,
    _overviewTeal,
    _overviewAmber,
    _overviewGrey,
  ];

  static Color _overviewBarColor(
    String label,
    int index, {
    required bool utilities,
  }) {
    if (utilities) {
      final key = label.toLowerCase();
      if (key.contains('electricity')) return _overviewAmber;
      if (key.contains('water')) return _overviewBlue;
    } else {
      if (label == 'Total Billing') return _overviewBlue;
      if (label == 'Total Collected') return _overviewTeal;
    }
    return _overviewComponentColors[index % _overviewComponentColors.length];
  }

  static Color _overviewArrearsColor(String label) {
    switch (label) {
      case 'Opening Arrears':
        return _overviewGrey;
      case 'Total Billing':
        return _overviewBlue;
      case 'Less: Total Collected':
        return _overviewTeal;
      case 'Adjustments':
        return _overviewAmber;
      case 'Closing Arrears':
        return _overviewRed;
      default:
        return _overviewGrey;
    }
  }

  Widget _overviewLegendRow({
    required String label,
    required double? amount,
    required Color color,
    String? amountText,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: _ink,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              amountText ?? _money(amount),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // A composition is meaningful only when all parts are available,
  // non-negative, and add up to the authoritative positive total.
  bool _overviewCanShare(FinanceOverviewValue value) {
    final total = value.amount;
    if (total == null ||
        total <= 0 ||
        value.components.isEmpty ||
        value.components.values.any((v) => v == null || v < 0)) {
      return false;
    }
    final sum = value.components.values.whereType<double>().fold<double>(
      0,
      (a, b) => a + b,
    );
    return (sum - total).abs() <= 0.01;
  }

  Widget _overviewComposition(FinanceOverviewValue value) {
    final entries = value.components.entries.toList();
    final canShare = _overviewCanShare(value);
    final total = value.amount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canShare) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 30,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < entries.length; i++)
                    if (entries[i].value! > 0)
                      Expanded(
                        flex: math.max(
                          1,
                          (entries[i].value! / total! * 1000000).round(),
                        ),
                        child: ColoredBox(
                          color:
                              _overviewComponentColors[i %
                                  _overviewComponentColors.length],
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: _border),
          _overviewLegendRow(
            label: entries[i].key,
            amount: entries[i].value,
            color:
                _overviewComponentColors[i % _overviewComponentColors.length],
          ),
        ],
        if (!canShare && entries.any((entry) => entry.value != null))
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Signed amounts are shown without a composition bar when shares are not meaningful.',
              style: TextStyle(fontSize: 11, color: _muted),
            ),
          ),
      ],
    );
  }

  // Utilities and the collection ratio use separate bars on one shared RM
  // scale, never a stacked utility chart or a ratio capped at 100 percent.
  Widget _overviewSeparateBars(
    FinanceOverviewValue value, {
    required bool utilities,
  }) {
    final entries = value.components.entries.toList();
    final amounts = entries.map((e) => e.value).whereType<double>().toList();
    final nonnegative = amounts.every((v) => v >= 0);
    final maxAmount = amounts.fold<double>(0, (a, b) => math.max(a, b));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(height: 9),
          _overviewLegendRow(
            label: entries[i].key,
            amount: entries[i].value,
            color: _overviewBarColor(entries[i].key, i, utilities: utilities),
          ),
          if (nonnegative && maxAmount > 0 && entries[i].value != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 12,
                color: _soft,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: (entries[i].value! / maxAmount)
                        .clamp(0.0, 1.0)
                        .toDouble(),
                    heightFactor: 1,
                    child: ColoredBox(
                      color: _overviewBarColor(
                        entries[i].key,
                        i,
                        utilities: utilities,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
        if (!nonnegative)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Signed values shown without proportional bars.',
              style: TextStyle(fontSize: 10, color: _muted),
            ),
          ),
      ],
    );
  }

  Widget _overviewWaterfall(FinanceOverviewValue value) {
    final opening = value.components['Opening Arrears'];
    final billed = value.components['Total Billing'];
    final collected = value.components['Less: Total Collected'];
    final adjustments = value.components['Adjustments'];
    final closing = value.amount;
    if (opening == null ||
        billed == null ||
        collected == null ||
        adjustments == null ||
        closing == null ||
        (opening + billed - collected + adjustments - closing).abs() > 0.01) {
      return const SizedBox.shrink();
    }
    final starts = <double>[
      0,
      opening,
      opening + billed,
      opening + billed - collected,
      0,
    ];
    final ends = <double>[
      opening,
      opening + billed,
      opening + billed - collected,
      opening + billed - collected + adjustments,
      closing,
    ];
    const keys = [
      'Opening Arrears',
      'Total Billing',
      'Less: Total Collected',
      'Adjustments',
      'Closing Arrears',
    ];
    const labels = [
      'Opening',
      'Billing',
      'Collected',
      'Adjustments',
      'Closing',
    ];
    final colors = keys.map(_overviewArrearsColor).toList();
    final low = [...starts, ...ends, 0.0].reduce(math.min);
    final high = [...starts, ...ends, 0.0].reduce(math.max);
    if (high == low) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, bounds) {
        const plotHeight = 124.0;
        const inset = 4.0;
        final slot = bounds.maxWidth / 5;
        final width = math.min(slot * 0.52, 75.0);
        double x(int i) => slot * i + (slot - width) / 2;
        double y(double v) =>
            inset + (high - v) / (high - low) * (plotHeight - inset * 2);
        return Column(
          children: [
            SizedBox(
              height: plotHeight,
              width: double.infinity,
              child: Stack(
                children: [
                  Positioned(
                    top: y(0),
                    left: 0,
                    right: 0,
                    child: const Divider(height: 1, color: _border),
                  ),
                  for (var i = 0; i < 4; i++)
                    Positioned(
                      left: x(i) + width,
                      top: y(ends[i]),
                      width: slot - width,
                      height: 1,
                      child: const ColoredBox(color: Color(0xFFB6B0AA)),
                    ),
                  for (var i = 0; i < 5; i++)
                    Positioned(
                      left: x(i),
                      top: math.min(y(starts[i]), y(ends[i])),
                      width: width,
                      height: math.max(1.0, (y(starts[i]) - y(ends[i])).abs()),
                      child: ColoredBox(color: colors[i]),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final label in labels)
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        );
      },
    );
  }

  Widget _overviewArrears(FinanceOverviewValue value) {
    final entries = value.components.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _overviewWaterfall(value),
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: _border),
          _overviewLegendRow(
            label: entries[i].key,
            amount: entries[i].value,
            color: _overviewArrearsColor(entries[i].key),
            amountText:
                entries[i].key == 'Less: Total Collected' &&
                    entries[i].value != null
                ? _money(-entries[i].value!)
                : null,
          ),
        ],
      ],
    );
  }

  Widget _overviewBreakdown(
    _FinanceMetricCardData item,
    FinanceOverviewComparison comparison,
    FinanceOverviewPeriod period,
  ) {
    final value = comparison.current;
    final isRatio = item.metric == FinanceOverviewMetric.ratio;
    final isBalance = item.metric == FinanceOverviewMetric.arrears;
    final isUtilities = item.metric == FinanceOverviewMetric.utilities;
    final isBilling =
        item.metric == FinanceOverviewMetric.billing ||
        item.metric == FinanceOverviewMetric.collected;
    final noDetails =
        isBilling &&
        value.amount != null &&
        value.components.values.every((v) => v == null);
    final previous = period.preceding;
    final previousLabel = isBalance
        ? 'As at ${_monthLabel(FinanceOverviewService.monthKey(previous.end))}'
        : _overviewPeriodLabel(previous);
    final currentText = isRatio ? _percent(value.amount) : _money(value.amount);
    final currentLabel = value.complete || value.amount == null
        ? item.label
        : '${item.label} (available)';
    final previousText = comparison.previous.complete
        ? (isRatio
              ? _percent(comparison.previous.amount)
              : _money(comparison.previous.amount))
        : '—';
    final chart = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (noDetails)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _breakdownReadFailed
                  ? 'Source breakdown could not be loaded. The total above is from the monthly dataset.'
                  : 'Source breakdown is unavailable or no longer matches the displayed total. Reload the dashboard before comparing components.',
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ),
        if (isBalance)
          _overviewArrears(value)
        else if (isRatio || isUtilities)
          _overviewSeparateBars(value, utilities: isUtilities)
        else
          _overviewComposition(value),
        if (isUtilities && !value.complete && value.amount != null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Partial total of available bills; missing bills are not zero.',
              style: TextStyle(fontSize: 11, color: _muted),
            ),
          ),
      ],
    );
    final comparisonPanel = Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: _soft,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Previous period',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: _muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            previousLabel,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          const SizedBox(height: 7),
          Text(
            previousText,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
        ],
      ),
    );
    return _panel(
      shadow: false,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$currentLabel · $currentText',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close breakdown',
                visualDensity: VisualDensity.compact,
                onPressed: () => _selectOverviewMetric(item.metric),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, bounds) {
              if (bounds.maxWidth >= 690) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: chart),
                    const SizedBox(width: 20),
                    Expanded(child: comparisonPanel),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [chart, const SizedBox(height: 12), comparisonPanel],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _segmentedOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) => Material(
    color: selected ? _black : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: selected ? Colors.white : _muted),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : _muted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _forecastPanel() {
    final name = _metricName(_chartMetric);
    final color = switch (_chartMetric) {
      'billing_total' => _overviewBlue,
      'closing_arrears' => _overviewRed,
      _ => _overviewTeal,
    };
    final actual = _actualSeries(_chartMetric);
    final predictions = _forecastSeries(_chartMetric);
    final forecast = _forecastFor(_chartMetric);
    final warnings = forecast?['warnings'] is List
        ? (forecast!['warnings'] as List)
              .map((value) => value.toString())
              .toList()
        : <String>[];
    final recentAnomalyWarning = warnings
        .where((value) => value.toLowerCase().contains('recent high-severity'))
        .firstOrNull;
    final unavailableReason = forecast?['reason']?.toString();
    final period = _propertyPeriods.forecast;
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 4,
                        height: 16,
                        decoration: BoxDecoration(
                          color: _overviewBlue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 9),
                      const Text(
                        'FINANCIAL FORECAST',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (recentAnomalyWarning != null) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: recentAnomalyWarning,
                          child: const Icon(
                            Icons.warning_amber_rounded,
                            color: _amber,
                            size: 16,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: _ink,
                    ),
                  ),
                ],
              );
              final controls = Wrap(
                spacing: 5,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: _soft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Wrap(
                      spacing: 3,
                      runSpacing: 3,
                      children: [
                        _segmentedOption(
                          label: 'Billing',
                          selected: _chartMetric == 'billing_total',
                          onTap: () =>
                              setState(() => _chartMetric = 'billing_total'),
                        ),
                        _segmentedOption(
                          label: 'Collection',
                          selected: _chartMetric == 'collection_total',
                          onTap: () =>
                              setState(() => _chartMetric = 'collection_total'),
                        ),
                        _segmentedOption(
                          label: 'Closing Arrears',
                          selected: _chartMetric == 'closing_arrears',
                          onTap: () =>
                              setState(() => _chartMetric = 'closing_arrears'),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh forecast',
                    visualDensity: VisualDensity.compact,
                    onPressed: _forecastLoading
                        ? null
                        : () => unawaited(_load()),
                    icon: const Icon(
                      Icons.refresh_rounded,
                      size: 19,
                      color: _muted,
                    ),
                  ),
                ],
              );
              if (constraints.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [heading, const SizedBox(height: 14), controls],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 14),
                  controls,
                ],
              );
            },
          ),
          if (_forecastPreview) ...[
            const SizedBox(height: 8),
            const Text(
              'Administrator validation preview — not saved.',
              style: TextStyle(
                color: _amber,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (_forecastLoading)
            const SizedBox(
              height: 110,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Calculating financial forecast…',
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else if (_forecastError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _forecastError!,
                    style: const TextStyle(color: _amber, fontSize: 12),
                  ),
                  TextButton.icon(
                    onPressed: () => unawaited(_load()),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Retry forecast'),
                  ),
                ],
              ),
            )
          else if (predictions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                unavailableReason ??
                    (period == null
                        ? 'No saved financial observations are available to forecast.'
                        : 'Not enough eligible historical data to generate this forecast.'),
                style: const TextStyle(
                  color: _muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            )
          else ...[
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: FinanceInteractiveChart(
                key: ValueKey(
                  'property_forecast_${_siteId}_${period?.start}_${period?.end}_$_chartMetric',
                ),
                actual: actual,
                future: predictions,
                color: color,
                mode: 'trend',
                moneyFormatter: _money,
                monthFormatter: (month) =>
                    _monthLabel(_yearMonth(month.toIso8601String())!),
              ),
            ),
            const SizedBox(height: 6),
            _forecastLegend(color),
            const SizedBox(height: 16),
            const Divider(height: 1, color: _border),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final columns = math.min(
                  predictions.length,
                  constraints.maxWidth >= 690
                      ? 3
                      : constraints.maxWidth >= 450
                      ? 2
                      : 1,
                );
                final cardWidth =
                    (constraints.maxWidth - (columns - 1) * gap) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final point in predictions)
                      SizedBox(
                        width: cardWidth,
                        child: _forecastMonthCard(point, color),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _forecastLegend(Color color) {
    Widget item(String label, Widget symbol, String tooltip) => Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          symbol,
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    Widget line({required bool dashed}) => SizedBox(
      width: 30,
      height: 12,
      child: CustomPaint(
        painter: _FinanceLegendPainter(color: color, dashed: dashed),
      ),
    );
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 22,
        runSpacing: 8,
        children: [
          item(
            'Actual',
            line(dashed: false),
            'Saved historical financial figures. Amber points are unverified.',
          ),
          item(
            'Forecast',
            line(dashed: true),
            'Preliminary statistical projection; metrics are fitted independently.',
          ),
          item(
            'Planning Range',
            Container(
              width: 30,
              height: 12,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                border: Border.all(color: color.withValues(alpha: 0.25)),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            'Heuristic planning range, not a calibrated confidence interval.',
          ),
        ],
      ),
    );
  }

  Widget _forecastMonthCard(FinanceChartPrediction point, Color accent) {
    final valueColor = Color.lerp(accent, _ink, 0.36)!;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.055), Colors.white),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 3, color: accent),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 14,
                      color: valueColor,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _monthLabel(_yearMonth(point.month)!),
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _money(point.value),
                    style: TextStyle(
                      color: valueColor,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Divider(height: 20, color: accent.withValues(alpha: 0.18)),
                const Text(
                  'Planning Range',
                  style: TextStyle(
                    color: _muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_money(point.low)} – ${_money(point.high)}',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _metricName(String metric) {
    switch (metric) {
      case 'collection_rate_pct':
        return 'Collection-to-Billing Ratio';
      case 'collection_total':
        return 'Monthly Collection';
      case 'closing_arrears':
        return 'Closing Arrears';
      case 'electricity_bill_rm':
        return 'Electricity Bill';
      case 'water_bill_rm':
        return 'Water Bill';
      case 'billing_total':
        return 'Monthly Billing';
      default:
        return metric.replaceAll('_', ' ');
    }
  }

  List<Map<String, dynamic>> _rankedAnomalies() {
    final rows = [..._rangeAnomalies];
    rows.sort((a, b) {
      int score(Map<String, dynamic> item) => switch (item['severity']) {
        'high' => 0,
        'medium' => 1,
        _ => 2,
      };
      final bySeverity = score(a).compareTo(score(b));
      return bySeverity != 0
          ? bySeverity
          : (b['month']?.toString() ?? '').compareTo(
              a['month']?.toString() ?? '',
            );
    });
    return rows;
  }

  // Severity is supplied by the existing anomaly engine. Retain its values;
  // an unfamiliar severity is shown separately rather than relabelled low.
  static String _attentionSeverity(Map<String, dynamic> item) =>
      item['severity']?.toString().trim().toLowerCase() ?? '';

  static String _attentionMonth(dynamic value) {
    final month = _parseMonth(value);
    if (month == null) return value?.toString() ?? 'Unknown month';
    return '${_monthNames[month.month - 1].substring(0, 3)} ${month.year}';
  }

  static String _attentionAmount(Map<String, dynamic> item) =>
      item['unit']?.toString() == 'percentage_points'
      ? _percent(item['observed'])
      : _money(item['observed']);

  // Ratio changes are percentage-point differences; monetary metrics use
  // relative percentage change. Use the same units in all attention views.
  static String? _attentionDeviation(Map<String, dynamic> item) {
    final isRatio = item['unit']?.toString() == 'percentage_points';
    final difference = _number(item[isRatio ? 'difference' : 'difference_pct']);
    if (difference == null) return null;
    final suffix = isRatio ? ' pp' : '%';
    final rounded = double.parse(difference.toStringAsFixed(1));
    final sign = rounded > 0 ? '+' : '';
    return '$sign${(rounded == 0 ? 0.0 : rounded).toStringAsFixed(1)}$suffix';
  }

  String _attentionDeviationTooltip(Map<String, dynamic> item) =>
      item['unit']?.toString() == 'percentage_points'
      ? 'Percentage-point difference from the rolling historical median.'
      : 'Relative percentage change from the rolling historical median.';

  Duration get _attentionAnimationDuration =>
      MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 220);

  Widget _attentionPriorityCard({
    required String label,
    required String priority,
    required String count,
    required Color accent,
    required IconData icon,
    required bool selected,
    required double width,
  }) {
    return SizedBox(
      width: width,
      height: 78,
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label, $count',
        child: Material(
          color: Color.alphaBlend(
            accent.withValues(alpha: selected ? 0.13 : 0.045),
            Colors.white,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: BorderSide(
              color: selected ? accent : accent.withValues(alpha: 0.18),
              width: selected ? 1.6 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() {
              _attentionCollapsed = selected;
              _attentionPriority = priority;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: accent, size: 16),
                      const SizedBox(width: 5),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            count,
                            style: TextStyle(
                              color: accent,
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _attentionEvidenceRow(
    Map<String, dynamic> item, {
    required bool quality,
    required Color accent,
  }) {
    final value = quality ? _qualityDescription(item) : _attentionAmount(item);
    final deviation = quality ? null : _attentionDeviation(item);
    return Padding(
          padding: const EdgeInsets.fromLTRB(11, 9, 9, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  _attentionMonth(item['month']),
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      value,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                    if (!quality && deviation != null) ...[
                      const SizedBox(height: 3),
                      Tooltip(
                        message: _attentionDeviationTooltip(item),
                        child: Text(
                          deviation,
                          textAlign: TextAlign.end,
                          style: TextStyle(color: accent, fontSize: 10),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
    );
  }

  IconData _attentionMetricIcon(String metric, IconData fallback) =>
      switch (metric) {
        'billing_total' => Icons.description_outlined,
        'collection_total' => Icons.account_balance_wallet_outlined,
        'collection_rate_pct' => Icons.percent_rounded,
        'closing_arrears' => Icons.account_balance_wallet_outlined,
        'electricity_bill_rm' => Icons.bolt_rounded,
        'water_bill_rm' => Icons.water_drop_outlined,
        _ => fallback,
      };

  Widget _attentionMetricGroup({
    required String groupKey,
    required String title,
    required List<Map<String, dynamic>> items,
    required Color accent,
    required IconData icon,
    required bool quality,
  }) {
    final records = [...items]
      ..sort(
        (a, b) => (b['month']?.toString() ?? '').compareTo(
          a['month']?.toString() ?? '',
        ),
      );
    final latest = records.first;
    final months =
        records
            .map((item) => _parseMonth(item['month']))
            .whereType<DateTime>()
            .toSet()
            .toList()
          ..sort();
    final monthCount = months.length;
    final expanded = _expandedAttentionMetrics.contains(groupKey);
    final latestValue = quality
        ? _qualityDescription(latest)
        : _attentionAmount(latest);
    final metric = latest['metric']?.toString() ?? '';
    final deviationText = quality ? null : _attentionDeviation(latest);
    return AnimatedContainer(
      key: ValueKey('attention_group_$groupKey'),
      duration: _attentionAnimationDuration,
      curve: Curves.easeInOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: expanded ? accent.withValues(alpha: 0.32) : _border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            hint: expanded
                ? 'Collapse affected months'
                : 'Expand affected months',
            child: Material(
              color: expanded
                  ? Color.alphaBlend(
                      accent.withValues(alpha: 0.035),
                      Colors.white,
                    )
                  : Colors.white,
              child: InkWell(
                onTap: () => setState(() {
                  if (expanded) {
                    _expandedAttentionMetrics.remove(groupKey);
                  } else {
                    _expandedAttentionMetrics.add(groupKey);
                  }
                }),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: accent, width: 3)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 11, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Icon(
                                quality
                                    ? icon
                                    : _attentionMetricIcon(metric, icon),
                                color: accent,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '$monthCount affected ${monthCount == 1 ? 'month' : 'months'}',
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            AnimatedRotation(
                              turns: expanded ? 0.5 : 0.0,
                              duration: _attentionAnimationDuration,
                              curve: Curves.easeInOutCubic,
                              child: const Icon(
                                Icons.expand_more_rounded,
                                color: _muted,
                                size: 19,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Latest  ·  ${_attentionMonth(latest['month'])}',
                          style: const TextStyle(color: _muted, fontSize: 10.5),
                        ),
                        const SizedBox(height: 4),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final amount = Text(
                              latestValue,
                              style: TextStyle(
                                color: _ink,
                                fontSize: quality ? 12 : 18,
                                fontWeight: FontWeight.w800,
                                height: 1.25,
                              ),
                            );
                            final comparison = deviationText == null
                                ? null
                                : Tooltip(
                                    message: _attentionDeviationTooltip(latest),
                                    child: Text(
                                      deviationText,
                                      style: TextStyle(
                                        color: accent,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  );
                            if (comparison == null) return amount;
                            if (constraints.maxWidth < 255) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  amount,
                                  const SizedBox(height: 6),
                                  comparison,
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(child: amount),
                                const SizedBox(width: 10),
                                comparison,
                              ],
                            );
                          },
                        ),
                        if (months.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 5,
                            runSpacing: 5,
                            children: [
                              for (final month in months)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _soft,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    _attentionMonth(month.toIso8601String()),
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Fade and resize each metric independently. The parent dashboard
          // scrolls, so opening a second metric does not close the first.
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final record in records) ...[
                  const Divider(height: 1, color: _border),
                  _attentionEvidenceRow(
                    record,
                    quality: quality,
                    accent: accent,
                  ),
                ],
              ],
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: _attentionAnimationDuration,
            reverseDuration: _attentionAnimationDuration,
            sizeCurve: Curves.easeInOutCubic,
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeIn,
            alignment: Alignment.topCenter,
          ),
        ],
      ),
    );
  }

  Widget _attentionPanel() {
    final anomalies = _rankedAnomalies();
    final quality = _rangeQualityIssues;
    final high = anomalies
        .where((item) => _attentionSeverity(item) == 'high')
        .toList();
    final medium = anomalies
        .where((item) => _attentionSeverity(item) == 'medium')
        .toList();
    final low = anomalies
        .where((item) => _attentionSeverity(item) == 'low')
        .toList();
    // Future unexpected severity labels remain inspectable, without assigning
    // an invented priority or silently dropping the original alert.
    final unclassified = anomalies
        .where(
          (item) => !(const {
            'high',
            'medium',
            'low',
          }).contains(_attentionSeverity(item)),
        )
        .toList();
    final issueCount = quality.length + unclassified.length;
    final selected =
        _attentionPriority ??
        (high.isNotEmpty
            ? 'high'
            : medium.isNotEmpty
            ? 'medium'
            : low.isNotEmpty
            ? 'low'
            : issueCount > 0
            ? 'quality'
            : 'high');
    final showingQuality = selected == 'quality';
    final rows = switch (selected) {
      'high' => high,
      'medium' => medium,
      'low' => low,
      _ => quality,
    };
    final accent = switch (selected) {
      'high' => _red,
      'medium' => _amber,
      'low' => const Color(0xFF238451),
      _ => _overviewBlue,
    };
    final icon = switch (selected) {
      'high' => Icons.error_outline_rounded,
      'medium' => Icons.warning_amber_rounded,
      'low' => Icons.info_outline_rounded,
      _ => Icons.fact_check_outlined,
    };
    final label = switch (selected) {
      'high' => 'High Priority',
      'medium' => 'Medium Priority',
      'low' => 'Low Priority',
      _ => 'Data Issues',
    };
    final anomalyAvailable =
        _analysis != null && !_forecastLoading && _forecastError == null;
    String count(List<Map<String, dynamic>> records) =>
        anomalyAvailable ? '${records.length}' : '—';
    final grouped = <String, List<Map<String, dynamic>>>{};
    if (!showingQuality) {
      for (final item in rows) {
        final metric = item['metric']?.toString().trim() ?? '';
        (grouped[metric] ??= <Map<String, dynamic>>[]).add(item);
      }
    }
    final groups = <Widget>[
      if (showingQuality) ...[
        if (quality.isNotEmpty)
          _attentionMetricGroup(
            groupKey: 'quality:financial_data',
            title: 'Financial Data Quality',
            items: quality,
            accent: accent,
            icon: icon,
            quality: true,
          ),
        if (unclassified.isNotEmpty)
          _attentionMetricGroup(
            groupKey: 'quality:severity',
            title: 'Unclassified Financial Alerts',
            items: unclassified,
            accent: accent,
            icon: icon,
            quality: false,
          ),
      ] else
        for (final entry in grouped.entries)
          _attentionMetricGroup(
            groupKey: '$selected:${entry.key}',
            title: entry.key.isEmpty
                ? 'Financial Metric'
                : _metricName(entry.key),
            items: entry.value,
            accent: accent,
            icon: icon,
            quality: false,
          ),
    ];
    final selectedCount = showingQuality ? issueCount : rows.length;
    final emptyMessage = !showingQuality && _forecastLoading
        ? 'Checking financial records…'
        : !showingQuality && !anomalyAvailable
        ? 'Financial anomaly check unavailable.'
        : showingQuality
        ? 'No data issues for this period.'
        : 'No ${label.toLowerCase()} issues for this period.';
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Match the Financial Forecast section title and blue accent.
          Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: _overviewBlue,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'ATTENTION REQUIRED',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_forecastPreview)
                const Tooltip(
                  message: 'Administrator validation preview — not saved.',
                  child: Icon(
                    Icons.info_outline_rounded,
                    color: _amber,
                    size: 16,
                  ),
                )
              else if (_forecastError != null)
                const Tooltip(
                  message:
                      'Anomaly check unavailable; source data issues are still shown.',
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: _amber,
                    size: 16,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              // Fit narrow finance columns without shrinking labels excessively.
              final columns = constraints.maxWidth >= 360
                  ? 4
                  : constraints.maxWidth >= 168
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  _attentionPriorityCard(
                    label: 'High Priority',
                    priority: 'high',
                    count: count(high),
                    accent: _red,
                    icon: Icons.error_outline_rounded,
                    selected: !_attentionCollapsed && selected == 'high',
                    width: width,
                  ),
                  _attentionPriorityCard(
                    label: 'Medium Priority',
                    priority: 'medium',
                    count: count(medium),
                    accent: _amber,
                    icon: Icons.warning_amber_rounded,
                    selected: !_attentionCollapsed && selected == 'medium',
                    width: width,
                  ),
                  _attentionPriorityCard(
                    label: 'Low Priority',
                    priority: 'low',
                    count: count(low),
                    accent: const Color(0xFF238451),
                    icon: Icons.info_outline_rounded,
                    selected: !_attentionCollapsed && selected == 'low',
                    width: width,
                  ),
                  _attentionPriorityCard(
                    label: 'Data Issues',
                    priority: 'quality',
                    count: '$issueCount',
                    accent: _overviewBlue,
                    icon: Icons.fact_check_outlined,
                    selected: !_attentionCollapsed && showingQuality,
                    width: width,
                  ),
                ],
              );
            },
          ),
          AnimatedSize(
            duration: _attentionAnimationDuration,
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _attentionCollapsed
                ? const SizedBox(width: double.infinity, height: 0)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            !showingQuality && !anomalyAvailable
                                ? (_forecastLoading
                                      ? 'Checking…'
                                      : 'Unavailable')
                                : '$selectedCount ${selectedCount == 1 ? 'record' : 'records'}',
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      // The dashboard itself scrolls. All groups and expanded evidence
                      // grow naturally downwards; no nested scroll area or fixed height.
                      if (groups.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!showingQuality && _forecastLoading)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  Icon(
                                    !showingQuality && !anomalyAvailable
                                        ? Icons.info_outline_rounded
                                        : Icons.check_circle_outline_rounded,
                                    color: _muted,
                                    size: 24,
                                  ),
                                const SizedBox(height: 9),
                                Text(
                                  emptyMessage,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 11.5,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        for (var index = 0; index < groups.length; index++) ...[
                          if (index > 0) const SizedBox(height: 8),
                          groups[index],
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  static String _qualityDescription(Map<String, dynamic> issue) {
    final flags = issue['flags'] is List
        ? (issue['flags'] as List).map((value) => value.toString()).toSet()
        : <String>{};
    if (flags.contains('unverified_data')) {
      final other = flags.where((flag) => flag != 'unverified_data').toList();
      final details = other.isEmpty
          ? ''
          : ' Other flags: ${other.map((flag) => flag.replaceAll('_', ' ')).join(', ')}.';
      return 'Financial records are saved but not yet verified for forecasting.$details';
    }
    if (flags.contains('test_data')) {
      return 'Test data excluded from historical forecasts and KPIs.';
    }
    if (flags.contains('missing_billing')) {
      return 'Billing is missing and is not interpreted as zero performance.';
    }
    if (flags.contains('missing_monthly_report')) {
      return 'The monthly report is missing.';
    }
    if (flags.isEmpty) return 'Review the source data for this month.';
    return flags.map((value) => value.replaceAll('_', ' ')).join(', ');
  }

  Widget _financialOverviewContent() {
    final isSynthetic = _analysis?['synthetic_example'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isSynthetic) ...[
          _panel(
            color: const Color(0xFFFFF3F4),
            shadow: false,
            child: const Row(
              children: [
                Icon(Icons.science_outlined, color: _red),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'This analysis is marked synthetic or sample data and must not be used for real decisions.',
                    style: TextStyle(
                      color: _darkRed,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        _metrics(),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 900) {
              final trendsWidth = math.min(
                880.0,
                (constraints.maxWidth - 14) * 0.62,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: trendsWidth, child: _financialTrends()),
                  const SizedBox(width: 14),
                  Expanded(child: _attentionPanel()),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _financialTrends(),
                const SizedBox(height: 14),
                _attentionPanel(),
              ],
            );
          },
        ),
        // Always display the independent forecast card, including explicit
        // loading, insufficient-history, preview and failure states.
        const SizedBox(height: 14),
        _forecastPanel(),
        const SizedBox(height: 12),
        const Text(
          'Official financial records are read-only here. Forecasts and anomaly flags support review and do not replace bank reconciliation, accounting evidence, or management approval.',
          style: TextStyle(color: _muted, fontSize: 10.5, height: 1.45),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showSelectors) ...[
          _selectorsPanel(),
          const SizedBox(height: 14),
        ],
        if (_loading)
          const _FinanceLoading()
        else if (_error != null)
          _panel(
            color: const Color(0xFFFFF5F5),
            shadow: false,
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, color: _red),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: _darkRed, fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          _financialOverviewContent(),
      ],
    );
  }

}

class _FinanceMetricCardData {
  final FinanceOverviewMetric metric;
  final String label;
  final IconData icon;
  final Color accent;
  const _FinanceMetricCardData(this.metric, this.label, this.icon, this.accent);
}

class _FinanceMetricCard extends StatelessWidget {
  final _FinanceMetricCardData data;
  final FinanceOverviewComparison comparison;
  final String comparisonLabel;
  final String coverage;
  final bool showComparison;
  final bool selected;
  final VoidCallback onTap;

  const _FinanceMetricCard({
    required this.data,
    required this.comparison,
    required this.comparisonLabel,
    required this.coverage,
    required this.showComparison,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isRatio = data.metric == FinanceOverviewMetric.ratio;
    final current = comparison.current.amount;
    final previous = comparison.previous.amount;
    final movement = comparison.movement;
    // Never compare a partial total to a complete period. If a complete
    // previous figure is zero, the monetary difference is still meaningful,
    // even though a relative percentage cannot be calculated.
    final delta = showComparison &&
            comparison.current.complete &&
            comparison.previous.complete &&
            current != null && previous != null &&
            (movement != null || (!isRatio && previous == 0))
        ? current - previous
        : null;
    final change = delta == null || movement == null
        ? null
        : movement == 0
            ? (isRatio ? '0.00 pp' : '0.00%')
            : '${movement > 0 ? '▲' : '▼'} ${comparison.movementText}';
    final amountChange = delta == null || isRatio
        ? null
        : '${delta > 0 ? '+' : delta < 0 ? '−' : ''}'
            '${_FinanceDashboardSectionState._money(delta.abs())}';
    return DashboardOverviewMetricCard(
      label: data.label,
      icon: data.icon,
      accent: data.accent,
      value: isRatio
          ? _FinanceDashboardSectionState._percent(current)
          : _FinanceDashboardSectionState._money(current),
      comparisonLabel: delta == null ? null : comparisonLabel,
      change: change,
      amountChange: amountChange,
      favourable: delta == null || delta == 0 ? null : comparison.favourable,
      dataNote: coverage,
      showDataInfo: !comparison.current.complete || current == null,
      selected: selected,
      onTap: onTap,
    );
  }
}

// Compact overview layout shared by Finance and Defaulters. A fixed set of
// vertical slots aligns every card, independently of its comparison or arrow.
// Larger text scales increase the slots rather than overflowing the card.
class DashboardOverviewMetricCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color accent;
  final String value;
  final String? comparisonLabel;
  final String? change;
  final String? amountChange;
  final bool? favourable;
  final String? dataNote;
  final bool showDataInfo;
  final bool selected;
  final VoidCallback? onTap;

  const DashboardOverviewMetricCard({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    required this.value,
    this.comparisonLabel,
    this.change,
    this.amountChange,
    this.favourable,
    this.dataNote,
    this.showDataInfo = false,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final headerHeight = math.max(32.0, scaler.scale(14) * 2.3);
    final valueHeight = math.max(36.0, scaler.scale(30) * 1.2);
    final footerHeight = math.max(36.0, scaler.scale(12) * 2.4 + 7);
    final movementColor = favourable == null
        ? const Color(0xFF626262)
        : favourable == true
            ? const Color(0xFF087443)
            : const Color(0xFFBC222A);
    final badgeColor = favourable == null
        ? const Color(0xFFF0F0F0)
        : favourable == true
            ? const Color(0xFFE0F2E7)
            : const Color(0xFFFCE5E5);
    final radius = BorderRadius.circular(14);
    final hasMovement = change != null || amountChange != null;
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: headerHeight,
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: accent, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: label,
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF6D7178),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
                if (showDataInfo && dataNote != null) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: dataNote!,
                    child: const Icon(Icons.info_outline_rounded,
                        size: 15, color: Color(0xFF6D7178)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: valueHeight,
            width: double.infinity,
            child: Tooltip(
              message: dataNote ?? value,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Color(0xFF151515),
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: footerHeight,
            child: LayoutBuilder(builder: (context, bounds) {
              final arrowWidth = onTap == null ? 0.0 : 21.0;
              final badgeWidth = math.min(112.0,
                  math.max(0.0, (bounds.maxWidth - arrowWidth) * 0.52));
              return Row(
                children: [
                  Expanded(
                    child: comparisonLabel == null
                        ? const SizedBox.shrink()
                        : Tooltip(
                            message: comparisonLabel!,
                            child: Text(
                              comparisonLabel!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF6D7178),
                                fontSize: 10,
                                height: 1.15,
                              ),
                            ),
                          ),
                  ),
                  if (hasMovement) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: badgeWidth,
                      height: footerHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                      decoration: BoxDecoration(
                        color: badgeColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (change != null)
                              Text(change!, style: TextStyle(
                                color: movementColor, fontSize: 12,
                                fontWeight: FontWeight.w800, height: 1.1)),
                            if (amountChange != null)
                              Text(amountChange!, style: TextStyle(
                                color: movementColor,
                                fontSize: change == null ? 12 : 10,
                                fontWeight: FontWeight.w700, height: 1.1)),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (onTap != null) ...[
                    const SizedBox(width: 3),
                    Icon(selected ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                        size: 18, color: accent),
                  ],
                ],
              );
            }),
          ),
        ],
      ),
    );
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected ? accent : const Color(0xFFE3E5E8),
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: content,
      ),
    );
  }
}

// Legacy presentation retained for compatibility with existing callers.
class FinanceMetricCardPresentation extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color accent;
  final String value;
  final String comparisonLabel;
  final String coverage;
  final bool showCoverage;
  final String change;
  final String status;
  final bool? favourable;
  final bool selected;
  final VoidCallback? onTap;
  final bool showMovementBadge;
  final String? plainComparisonLine;
  final bool showComparisonLabel;
  final bool showStatus;
  final double? fixedHeight;

  const FinanceMetricCardPresentation({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    required this.value,
    required this.comparisonLabel,
    required this.coverage,
    required this.showCoverage,
    required this.change,
    required this.status,
    required this.favourable,
    required this.selected,
    required this.onTap,
    this.showMovementBadge = true,
    this.plainComparisonLine,
    this.showComparisonLabel = true,
    this.showStatus = true,
    this.fixedHeight,
  });

  @override
  Widget build(BuildContext context) {
    final movementColor = favourable == null
        ? const Color(0xFF626262)
        : favourable == true
        ? const Color(0xFF087443)
        : const Color(0xFFBC222A);
    final badgeColor = favourable == null
        ? const Color(0xFFF0F0F0)
        : favourable == true
        ? const Color(0xFFE0F2E7)
        : const Color(0xFFFCE5E5);
    final radius = BorderRadius.circular(14);
    final content = Container(
      height: fixedHeight,
      constraints: fixedHeight == null
          ? const BoxConstraints(minHeight: 142)
          : null,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: fixedHeight == null
            ? MainAxisSize.min
            : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 27,
                height: 27,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, color: accent, size: 16),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: SizedBox(
                  height: fixedHeight == null
                      ? 30
                      : math.max(
                          30.0,
                          MediaQuery.textScalerOf(context).scale(11) * 2.4,
                        ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF6D7178),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          value,
                          maxLines: 1,
                          style: const TextStyle(
                            color: Color(0xFF151515),
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    if (showComparisonLabel) ...[
                      const SizedBox(height: 5),
                      Text(
                        comparisonLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF6D7178),
                          fontSize: 10,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showMovementBadge) const SizedBox(width: 8),
              if (showMovementBadge) Container(
                width: 64,
                height: showStatus ? 64 : 30,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        change,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: movementColor,
                        ),
                      ),
                    ),
                    if (showStatus) ...[
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          status,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: movementColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (!showMovementBadge && plainComparisonLine != null) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: Color(0xFFE3E5E8)),
            const SizedBox(height: 7),
            Text(
              plainComparisonLine!,
              maxLines: fixedHeight == null ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF6D7178),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ],
          if (showCoverage || onTap != null) ...[
            if (fixedHeight != null) const Spacer(),
            const SizedBox(height: 7),
            Row(
              children: [
                if (showCoverage)
                  Expanded(
                    child: Text(
                      coverage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF6D7178),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (onTap != null)
                  Icon(
                    selected
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: accent,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected ? accent : _FinanceDashboardSectionState._border,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: content,
            ),
    );
  }
}

class _FinanceLoading extends StatelessWidget {
  const _FinanceLoading();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 78),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE3E5E8)),
    ),
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Color(0xFFD92D3A),
          ),
        ),
        SizedBox(height: 12),
        Text(
          'Loading financial overview...',
          style: TextStyle(color: Color(0xFF6D7178), fontSize: 12),
        ),
      ],
    ),
  );
}

class FinanceChartPoint {
  final DateTime month;
  final double value;
  final bool unverified;
  const FinanceChartPoint(this.month, this.value, {this.unverified = false});
}

class FinanceChartPrediction extends FinanceChartPoint {
  final double low;
  final double high;
  const FinanceChartPrediction(super.month, super.value, this.low, this.high);
}

class _FinanceChartItem {
  final DateTime month;
  final double value;
  final double? low;
  final double? high;
  final bool forecast;
  final bool unverified;

  const _FinanceChartItem({
    required this.month,
    required this.value,
    required this.forecast,
    this.low,
    this.high,
    this.unverified = false,
  });
}

class _FinanceChartGeometry {
  final double left;
  final double right;
  final double top;
  final double bottom;
  final int minMonth;
  final int maxMonth;
  final double minY;
  final double maxY;
  final double stepY;
  final int gridSteps;
  final bool currency;
  final bool centerMonthSlots;

  const _FinanceChartGeometry({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.minMonth,
    required this.maxMonth,
    required this.minY,
    required this.maxY,
    required this.stepY,
    required this.gridSteps,
    this.currency = true,
    this.centerMonthSlots = false,
  });

  static int monthNumber(DateTime value) => value.year * 12 + value.month;

  double x(DateTime month) {
    if (centerMonthSlots) {
      return left + (monthNumber(month) - minMonth + 0.5) /
          (maxMonth - minMonth + 1) * (right - left);
    }
    return minMonth == maxMonth
        ? (left + right) / 2
        : left + (monthNumber(month) - minMonth) /
            (maxMonth - minMonth) * (right - left);
  }

  double y(double value) =>
      bottom - (value - minY) / (maxY - minY) * (bottom - top);

  // Use human-readable 1, 2, 2.5, 5, 10 x powers of ten, choosing
  // a step large enough to avoid crowded labels on the chart.
  static double _niceStep(double raw) {
    final safe = math.max(raw, 0.01);
    final power = math.pow(10, (math.log(safe) / math.ln10).floor()).toDouble();
    final fraction = safe / power;
    for (final multiplier in const <double>[1, 2, 2.5, 5, 10]) {
      if (fraction <= multiplier + 1e-10) return multiplier * power;
    }
    return 10 * power;
  }

  static String _axisLabel(double value, double step, double magnitude, {bool currency = true}) {
    if (!currency) return value.toStringAsFixed(0);
    // Keep the same unit on every tick, and retain enough decimal places
    // to distinguish adjacent ticks even when balances are nearly constant.
    final divisor = magnitude >= 1000000 && step >= 1000
        ? 1000000.0
        : magnitude >= 1000 && step >= 100
        ? 1000.0
        : 1.0;
    final suffix = divisor == 1000000
        ? 'm'
        : divisor == 1000
        ? 'k'
        : '';
    final scaledStep = step / divisor;
    var decimals = 0;
    var scaled = scaledStep;
    while (decimals < 8 && (scaled - scaled.roundToDouble()).abs() > 1e-7) {
      scaled *= 10;
      decimals++;
    }
    final normalized = value.abs() < step * 1e-7 ? 0.0 : value;
    final parts = (normalized / divisor).toStringAsFixed(decimals).split('.');
    final whole = parts.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final number = parts.length == 2 ? '$whole.${parts.last}' : whole;
    return 'RM $number$suffix';
  }

  String label(double value) =>
      _axisLabel(value, stepY, math.max(minY.abs(), maxY.abs()), currency: currency);

  static _FinanceChartGeometry from(
    Size size,
    List<_FinanceChartItem> items, {
    required bool bars,
    bool currency = true,
    DateTime? axisStart,
    DateTime? axisEnd,
    double axisLabelFontSize = 9.5,
    bool centerMonthSlots = false,
  }) {
    const top = 16.0;
    final bottom = math.max(top + 20, size.height - 36);
    final months = <int>[
      ...items.map((item) => monthNumber(item.month)),
      if (axisStart != null) monthNumber(axisStart),
      if (axisEnd != null) monthNumber(axisEnd),
    ];
    final minMonth = months.reduce(math.min);
    final maxMonth = months.reduce(math.max);
    final values = <double>[
      for (final item in items) ...[
        item.value,
        if (item.low != null) item.low!,
        if (item.high != null) item.high!,
      ],
      if (bars) 0.0,
    ];
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final spread = maximum - minimum;
    // Use tight bounds for line charts. Only flat or almost-flat data
    // needs a small fallback spread to avoid a zero-height scale.
    final range = spread > 0
        ? spread
        : math.max(1.0, math.max(minimum.abs(), maximum.abs()) * 0.01);
    final paddedMin = bars && minimum >= 0
        ? 0.0
        : minimum >= 0
        ? math.max(0.0, minimum - range * 0.04)
        : minimum - range * 0.04;
    final paddedMax = bars && maximum <= 0 ? 0.0 : maximum + range * 0.04;
    final targetIntervals = math.max(
      4,
      math.min(7, ((bottom - top) / 37).floor()),
    );
    final rawStep = _niceStep(
      math.max(paddedMax - paddedMin, 0.01) / targetIntervals,
    );
    final step = currency ? rawStep : math.max(1.0, rawStep.ceilToDouble());
    final minY = (paddedMin / step).floorToDouble() * step;
    final gridSteps = math.max(
      1,
      (paddedMax / step).ceil() - (paddedMin / step).floor(),
    );
    final maxY = minY + step * gridSteps;
    final magnitude = math.max(minY.abs(), maxY.abs());
    // Measure labels rather than clipping long currency values.
    var labelWidth = 0.0;
    for (var i = 0; i <= gridSteps; i++) {
      final painter = TextPainter(
        text: TextSpan(
          text: _axisLabel(minY + i * step, step, magnitude, currency: currency),
          style: TextStyle(fontSize: axisLabelFontSize, fontWeight: FontWeight.w500),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      labelWidth = math.max(labelWidth, painter.width);
      painter.dispose();
    }
    final left = math.max(64.0, labelWidth + 12);
    final right = math.max(left + 20, size.width - 27);
    return _FinanceChartGeometry(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      minMonth: minMonth,
      maxMonth: maxMonth,
      minY: minY,
      maxY: maxY,
      stepY: step,
      gridSteps: gridSteps,
      currency: currency,
      centerMonthSlots: centerMonthSlots,
    );
  }
}

class _FinanceLegendPainter extends CustomPainter {
  final Color color;
  final bool dashed;

  const _FinanceLegendPainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final start = Offset(1, size.height / 2);
    final end = Offset(size.width - 1, size.height / 2);
    if (dashed) {
      _FinanceChartPainter._dashed(canvas, start, end, paint);
    } else {
      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FinanceLegendPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}

class FinanceInteractiveChart extends StatefulWidget {
  final List<FinanceChartPoint> actual;
  final List<FinanceChartPrediction> future;
  final Color color;
  final String mode;
  final bool currency;
  final bool compact;
  final bool showAllMonths;
  final DateTime? axisStart;
  final DateTime? axisEnd;
  final double axisLabelFontSize;
  final String Function(dynamic value) moneyFormatter;
  final String Function(DateTime month) monthFormatter;

  const FinanceInteractiveChart({
    super.key,
    required this.actual,
    required this.future,
    required this.color,
    required this.mode,
    this.currency = true,
    this.compact = false,
    this.showAllMonths = false,
    this.axisStart,
    this.axisEnd,
    this.axisLabelFontSize = 9.5,
    required this.moneyFormatter,
    required this.monthFormatter,
  });

  @override
  State<FinanceInteractiveChart> createState() =>
      _FinanceInteractiveChartState();
}

class _FinanceInteractiveChartState extends State<FinanceInteractiveChart> {
  int? _hovered;

  List<_FinanceChartItem> get _items {
    final values = <_FinanceChartItem>[
      for (final item in widget.actual)
        _FinanceChartItem(
          month: item.month,
          value: item.value,
          forecast: false,
          unverified: item.unverified,
        ),
      for (final item in widget.future)
        _FinanceChartItem(
          month: item.month,
          value: item.value,
          low: item.low,
          high: item.high,
          forecast: true,
        ),
    ];
    values.sort((a, b) => a.month.compareTo(b.month));
    return values;
  }

  int? _hitTest(Offset position, Size size, List<_FinanceChartItem> items) {
    if (items.isEmpty) return null;
    final geometry = _FinanceChartGeometry.from(
      size,
      items,
      bars: widget.mode == 'bars',
      currency: widget.currency,
      axisStart: widget.axisStart,
      axisEnd: widget.axisEnd,
      axisLabelFontSize: widget.axisLabelFontSize,
      centerMonthSlots: widget.showAllMonths && widget.mode == 'bars',
    );
    if (position.dx < geometry.left - 18 ||
        position.dx > geometry.right + 18 ||
        position.dy < geometry.top - 20 ||
        position.dy > geometry.bottom + 18) {
      return null;
    }
    var nearest = 0;
    var distance = double.infinity;
    for (var index = 0; index < items.length; index++) {
      final next = (geometry.x(items[index].month) - position.dx).abs();
      if (next < distance) {
        distance = next;
        nearest = index;
      }
    }
    if (widget.showAllMonths) {
      final slot = (geometry.right - geometry.left) /
          (geometry.maxMonth - geometry.minMonth + 1);
      if (distance > slot / 2) return null;
    }
    return nearest;
  }

  void _update(Offset position, Size size, List<_FinanceChartItem> items) {
    final next = _hitTest(position, size, items);
    if (next != _hovered) setState(() => _hovered = next);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (items.isEmpty) return const SizedBox.shrink();
        final months = <int>[
          ...items.map((item) => _FinanceChartGeometry.monthNumber(item.month)),
          if (widget.axisStart != null)
            _FinanceChartGeometry.monthNumber(widget.axisStart!),
          if (widget.axisEnd != null)
            _FinanceChartGeometry.monthNumber(widget.axisEnd!),
        ];
        final monthCount = months.reduce(math.max) - months.reduce(math.min) + 1;
        // A narrow viewport can scroll horizontally rather than skip months.
        final width = widget.showAllMonths
            ? math.max(constraints.maxWidth, monthCount * 46.0 + 118)
            : widget.compact
                ? math.max(constraints.maxWidth, 300.0)
                : math.max(constraints.maxWidth, items.length * 72.0 + 82);
        final height = widget.compact ? 230.0 : 300.0;
        final size = Size(width, height);
        final geometry = _FinanceChartGeometry.from(
          size,
          items,
          bars: widget.mode == 'bars',
          currency: widget.currency,
          axisStart: widget.axisStart,
          axisEnd: widget.axisEnd,
          axisLabelFontSize: widget.axisLabelFontSize,
          centerMonthSlots: widget.showAllMonths && widget.mode == 'bars',
        );
        final active = _hovered != null && _hovered! < items.length
            ? items[_hovered!]
            : null;
        final activeX = active == null ? 0.0 : geometry.x(active.month);
        final activeY = active == null ? 0.0 : geometry.y(active.value);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: height,
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              onHover: (event) => _update(event.localPosition, size, items),
              onExit: (_) {
                if (_hovered != null) setState(() => _hovered = null);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _update(details.localPosition, size, items),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _FinanceChartPainter(
                          items: items,
                          color: widget.color,
                          mode: widget.mode,
                          currency: widget.currency,
                          highlighted: _hovered,
                          showAllMonths: widget.showAllMonths,
                          axisStart: widget.axisStart,
                          axisEnd: widget.axisEnd,
                          axisLabelFontSize: widget.axisLabelFontSize,
                        ),
                      ),
                    ),
                    if (active != null)
                      Positioned(
                        left: (activeX - 105)
                            .clamp(0.0, math.max(0.0, width - 216))
                            .toDouble(),
                        top: (activeY - 96)
                            .clamp(2.0, math.max(2.0, height - 112))
                            .toDouble(),
                        child: IgnorePointer(
                          child: Container(
                            width: 210,
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: const Color(0xFF111111),
                              borderRadius: BorderRadius.circular(11),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 14,
                                  offset: Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.monthFormatter(active.month),
                                  style: const TextStyle(
                                    color: Color(0xFFC7C7C7),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.moneyFormatter(active.value),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  active.forecast
                                      ? 'Preliminary forecast'
                                      : active.unverified
                                      ? 'Historical actual • unverified'
                                      : 'Historical actual',
                                  style: TextStyle(
                                    color: active.forecast
                                        ? Color.lerp(
                                            widget.color,
                                            Colors.white,
                                            0.35,
                                          )
                                        : active.unverified
                                        ? const Color(0xFFFFC06B)
                                        : const Color(0xFFC7C7C7),
                                    fontSize: 10,
                                  ),
                                ),
                                if (active.forecast &&
                                    active.low != null &&
                                    active.high != null) ...[
                                  const Divider(
                                    height: 14,
                                    color: Color(0xFF3E3E3E),
                                  ),
                                  Text(
                                    'Planning range: ${widget.moneyFormatter(active.low)} – ${widget.moneyFormatter(active.high)}',
                                    style: const TextStyle(
                                      color: Color(0xFFD4D4D4),
                                      fontSize: 9.5,
                                      height: 1.35,
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
          ),
        );
      },
    );
  }
}

class _FinanceChartPainter extends CustomPainter {
  final List<_FinanceChartItem> items;
  final Color color;
  final String mode;
  final bool currency;
  final int? highlighted;
  final bool showAllMonths;
  final DateTime? axisStart;
  final DateTime? axisEnd;
  final double axisLabelFontSize;

  const _FinanceChartPainter({
    required this.items,
    required this.color,
    required this.mode,
    this.currency = true,
    required this.highlighted,
    this.showAllMonths = false,
    this.axisStart,
    this.axisEnd,
    this.axisLabelFontSize = 9.5,
  });

  static String _shortMonth(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];

  static void _text(
    Canvas canvas,
    String value,
    Offset offset, {
    required double size,
    required Color color,
    FontWeight weight = FontWeight.w500,
    double? maxWidth,
    TextAlign align = TextAlign.left,
    bool fillWidth = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: color, fontSize: size, fontWeight: weight),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(
      minWidth: fillWidth ? (maxWidth ?? 0.0) : 0.0,
      maxWidth: maxWidth ?? double.infinity,
    );
    painter.paint(canvas, offset);
    painter.dispose();
  }

  static void _dashed(Canvas canvas, Offset start, Offset end, Paint paint) {
    final length = (end - start).distance;
    if (length <= 0.001) return;
    final direction = (end - start) / length;
    for (var at = 0.0; at < length; at += 11) {
      final until = math.min(at + 6, length);
      canvas.drawLine(start + direction * at, start + direction * until, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;
    final bars = mode == 'bars';
    final geometry = _FinanceChartGeometry.from(
      size, items, bars: bars, currency: currency,
      axisStart: axisStart, axisEnd: axisEnd,
      axisLabelFontSize: axisLabelFontSize,
      centerMonthSlots: showAllMonths && bars,
    );
    final plotWidth = geometry.right - geometry.left;
    final grid = Paint()
      ..color = const Color(0xFFE9EAEC)
      ..strokeWidth = 1;
    for (var index = 0; index <= geometry.gridSteps; index++) {
      final value = geometry.minY + geometry.stepY * index;
      final y = geometry.y(value);
      canvas.drawLine(
        Offset(geometry.left, y),
        Offset(geometry.right, y),
        grid,
      );
      _text(
        canvas,
        geometry.label(value),
        Offset(0, y - (showAllMonths ? axisLabelFontSize * 0.63 : 6)),
        size: axisLabelFontSize,
        color: const Color(0xFF7B7F85),
        maxWidth: geometry.left - 8,
        align: TextAlign.right,
        fillWidth: showAllMonths,
      );
    }

    final monthSpan = math.max(1, geometry.maxMonth - geometry.minMonth);
    final maxLabels = math.max(2, (plotWidth / 72).floor());
    final labelStep = showAllMonths ? 1 : math.max(1, (monthSpan / (maxLabels - 1)).ceil());
    for (
      var month = geometry.minMonth;
      month <= geometry.maxMonth;
      month += labelStep
    ) {
      final year = (month - 1) ~/ 12;
      final monthNumber = month - year * 12;
      final date = DateTime(year, monthNumber);
      final x = geometry.x(date);
      _text(
        canvas,
        showAllMonths ? _shortMonth(date.month) : '${_shortMonth(date.month)} ${date.year % 100}',
        Offset(x - 24, geometry.bottom + 12),
        size: axisLabelFontSize,
        color: const Color(0xFF7B7F85),
        maxWidth: 48,
        align: TextAlign.center,
        fillWidth: showAllMonths,
      );
    }

    final future = items.where((item) => item.forecast).toList();
    if (!bars && future.isNotEmpty) {
      final firstX = geometry.x(future.first.month);
      // Subtle separation of the future area from the historical series.
      canvas.drawRect(
        Rect.fromLTRB(firstX, geometry.top, geometry.right, geometry.bottom),
        Paint()..color = color.withValues(alpha: 0.035),
      );
    }
    if (!bars && future.length >= 2) {
      final band = Path()
        ..moveTo(
          geometry.x(future.first.month),
          geometry.y(future.first.high ?? future.first.value),
        );
      for (final item in future.skip(1)) {
        band.lineTo(
          geometry.x(item.month),
          geometry.y(item.high ?? item.value),
        );
      }
      for (final item in future.reversed) {
        band.lineTo(geometry.x(item.month), geometry.y(item.low ?? item.value));
      }
      band.close();
      canvas.drawPath(band, Paint()..color = color.withValues(alpha: 0.16));
    } else if (!bars && future.length == 1) {
      final point = future.first;
      final x = geometry.x(point.month);
      canvas.drawLine(
        Offset(x, geometry.y(point.low ?? point.value)),
        Offset(x, geometry.y(point.high ?? point.value)),
        Paint()
          ..color = color.withValues(alpha: 0.16)
          ..strokeWidth = 10,
      );
    }

    if (bars) {
      final barWidth = math.min(
        32.0,
        plotWidth / (showAllMonths
            ? geometry.maxMonth - geometry.minMonth + 1
            : math.max(items.length, 1)) * 0.52,
      );
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final x = geometry.x(item.month);
        final top = geometry.y(item.value);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTRB(
            x - barWidth / 2,
            math.min(top, geometry.y(0)),
            x + barWidth / 2,
            math.max(top, geometry.y(0)),
          ),
          const Radius.circular(5),
        );
        canvas.drawRRect(
          rect,
          Paint()
            ..color = item.forecast
                ? color.withValues(alpha: 0.34)
                : item.unverified
                ? color.withValues(alpha: 0.65)
                : color,
        );
        if (item.forecast || item.unverified) {
          final outline = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2;
          outline.color = item.unverified ? const Color(0xFFB26B00) : color;
          canvas.drawRRect(rect, outline);
        }
      }
    } else {
      final actual = items.where((item) => !item.forecast).toList();
      final actualPaint = Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var index = 1; index < actual.length; index++) {
        if (_FinanceChartGeometry.monthNumber(actual[index].month) -
                _FinanceChartGeometry.monthNumber(actual[index - 1].month) ==
            1) {
          canvas.drawLine(
            Offset(
              geometry.x(actual[index - 1].month),
              geometry.y(actual[index - 1].value),
            ),
            Offset(
              geometry.x(actual[index].month),
              geometry.y(actual[index].value),
            ),
            actualPaint,
          );
        }
      }
      final forecastPaint = Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      if (actual.isNotEmpty &&
          future.isNotEmpty &&
          _FinanceChartGeometry.monthNumber(future.first.month) -
                  _FinanceChartGeometry.monthNumber(actual.last.month) ==
              1) {
        _dashed(
          canvas,
          Offset(geometry.x(actual.last.month), geometry.y(actual.last.value)),
          Offset(
            geometry.x(future.first.month),
            geometry.y(future.first.value),
          ),
          forecastPaint..color = color.withValues(alpha: 0.48),
        );
        forecastPaint.color = color;
      }
      for (var index = 1; index < future.length; index++) {
        _dashed(
          canvas,
          Offset(
            geometry.x(future[index - 1].month),
            geometry.y(future[index - 1].value),
          ),
          Offset(
            geometry.x(future[index].month),
            geometry.y(future[index].value),
          ),
          forecastPaint,
        );
      }
    }

    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final point = Offset(geometry.x(item.month), geometry.y(item.value));
      if (!bars) {
        canvas.drawCircle(
          point,
          highlighted == index ? 5.2 : 3.7,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          point,
          highlighted == index ? 3.8 : 2.8,
          Paint()
            ..color = item.unverified
                ? const Color(0xFFB26B00)
                : item.forecast
                ? color.withValues(alpha: 0.78)
                : color,
        );
      }
      if (highlighted == index) {
        canvas.drawLine(
          Offset(point.dx, geometry.top),
          Offset(point.dx, geometry.bottom),
          Paint()
            ..color = color.withValues(alpha: 0.18)
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FinanceChartPainter oldDelegate) =>
      oldDelegate.items != items ||
      oldDelegate.color != color ||
      oldDelegate.mode != mode ||
      oldDelegate.currency != currency ||
      oldDelegate.showAllMonths != showAllMonths ||
      oldDelegate.axisStart != axisStart ||
      oldDelegate.axisEnd != axisEnd ||
      oldDelegate.axisLabelFontSize != axisLabelFontSize ||
      oldDelegate.highlighted != highlighted;
}
