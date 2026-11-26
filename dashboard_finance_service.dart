import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Pure read-only KPI aggregation. Uses the existing database-calculated
/// monthly dataset; never changes the financial source tables or forecasts.
enum FinanceOverviewMetric { billing, collected, ratio, arrears, utilities }

class FinanceOverviewPeriod {
  final DateTime start;
  final DateTime end;
  FinanceOverviewPeriod(DateTime start, DateTime end)
      : start = DateTime(start.year, start.month),
        end = DateTime(end.year, end.month) {
    if (this.start.isAfter(this.end)) {
      throw ArgumentError('Start month must not follow End month');
    }
  }
  int get monthCount => (end.year - start.year) * 12 + end.month - start.month + 1;
  FinanceOverviewPeriod get preceding => FinanceOverviewPeriod(
      DateTime(start.year, start.month - monthCount),
      DateTime(start.year, start.month - 1));
  Iterable<String> get keys sync* {
    for (var i = 0; i < monthCount; i++) {
      yield FinanceOverviewService.monthKey(DateTime(start.year, start.month + i));
    }
  }
}

class FinanceOverviewValue {
  final double? amount;
  final int available;
  final int expected;
  final Map<String, double?> components;
  final Map<String, String> componentCoverage;
  const FinanceOverviewValue(this.amount, this.available, this.expected,
      {this.components = const {}, this.componentCoverage = const {}});
  bool get complete => amount != null && available == expected;
}

class FinanceOverviewComparison {
  final FinanceOverviewValue current;
  final FinanceOverviewValue previous;
  final double? movement;
  final String movementText;
  final bool? favourable;
  const FinanceOverviewComparison(this.current, this.previous, this.movement,
      this.movementText, this.favourable);
}

class FinanceOverviewService {
  final Map<String, Map<String, dynamic>> _months;
  final Map<String, Map<String, dynamic>> _billingByReport;
  FinanceOverviewService(List<Map<String, dynamic>> history,
      Map<String, Map<String, dynamic>> billingByReport)
      : _months = {
          for (final row in history)
            if (parseMonth(row['report_month']) != null)
              monthKey(parseMonth(row['report_month'])!): row,
        },
        _billingByReport = billingByReport;

  static DateTime? parseMonth(dynamic value) {
    final s = value?.toString();
    if (s == null || s.length < 7) return null;
    return DateTime.tryParse('${s.substring(0, 7)}-01');
  }

  static String monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

  static double? number(dynamic value) {
    final n = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    return n != null && n.isFinite ? n : null;
  }

  static bool isActual(Map<String, dynamic> row) {
    final classification = row['classification']?.toString().toLowerCase();
    return row['has_report'] == true &&
        classification != 'test' && classification != 'missing' &&
        classification != 'future';
  }

  Map<String, dynamic>? _row(String key) {
    final row = _months[key];
    return row != null && isActual(row) ? row : null;
  }

  static double? _sum(Iterable<double?> values) {
    final present = values.whereType<double>().toList();
    return present.isEmpty ? null : present.fold<double>(0, (a, b) => a + b);
  }

  static double? _billingValue(Map<String, dynamic>? row, String field) =>
      row != null && row['has_billing'] == true ? number(row[field]) : null;

  // Source breakdowns are read under existing RLS and keyed by the same report
  // IDs as the monthly dataset. Do not display a misleading breakdown if
  // source rows changed between the RPC and detail read, or are inaccessible.
  Map<String, double?> _billingComponents(List<Map<String, dynamic>> rows,
      bool collection, double? total) {
    final fields = collection
        ? const {'Service Charge': 'collection_service_charge',
            'Sinking Fund': 'collection_sinking_fund',
            'Other Income': 'collection_other', 'Open Credit': 'collection_open_credit'}
        : const {'Service Charge': 'billing_service_charge',
            'Sinking Fund': 'billing_sinking_fund', 'Other Income': 'billing_other'};
    final unavailable = {for (final label in fields.keys) label: null as double?};
    if (total == null || rows.isEmpty) return unavailable;
    final details = <Map<String, dynamic>>[];
    for (final row in rows) {
      final detail = _billingByReport[row['report_id']?.toString()];
      if (detail == null || fields.values.any((key) => number(detail[key]) == null)) {
        return unavailable;
      }
      final subtotal = _sum(fields.values.map((key) => number(detail[key])));
      final expected = number(row[collection ? 'collection_total' : 'billing_total']);
      if (subtotal == null || expected == null || (subtotal - expected).abs() > 0.005) {
        return unavailable;
      }
      details.add(detail);
    }
    final components = {for (final entry in fields.entries)
      entry.key: _sum(details.map((row) => number(row[entry.value])))};
    final sum = _sum(components.values);
    return sum != null && (sum - total).abs() <= 0.005 ? components : unavailable;
  }

  FinanceOverviewValue value(FinanceOverviewMetric metric, FinanceOverviewPeriod period) {
    final rows = period.keys.map(_row).whereType<Map<String, dynamic>>().toList();
    final expected = period.monthCount;
    switch (metric) {
      case FinanceOverviewMetric.billing:
      case FinanceOverviewMetric.collected:
        final collection = metric == FinanceOverviewMetric.collected;
        final field = collection ? 'collection_total' : 'billing_total';
        final eligible = rows.where((row) => _billingValue(row, field) != null).toList();
        final total = _sum(eligible.map((row) => _billingValue(row, field)));
        return FinanceOverviewValue(total, eligible.length, expected,
            components: _billingComponents(eligible, collection, total));
      case FinanceOverviewMetric.ratio:
        // Use only paired billing and collection months; never average monthly ratios.
        final paired = rows.where((row) => _billingValue(row, 'billing_total') != null &&
            _billingValue(row, 'collection_total') != null).toList();
        final billed = _sum(paired.map((row) => _billingValue(row, 'billing_total')));
        final collected = _sum(paired.map((row) => _billingValue(row, 'collection_total')));
        final ratio = billed != null && billed > 0 && collected != null
            ? double.parse((collected / billed * 100).toStringAsFixed(2)) : null;
        return FinanceOverviewValue(ratio, paired.length, expected,
            components: {'Total Billing': billed, 'Total Collected': collected});
      case FinanceOverviewMetric.arrears:
        // A closing balance is an End-month snapshot, never a sum of balances.
        final row = _row(monthKey(period.end));
        final eligible = row != null && row['has_billing'] == true &&
            row['has_arrears_reconciliation'] == true && number(row['closing_arrears']) != null;
        final source = eligible ? row : null;
        final closing = number(source?['closing_arrears']);
        return FinanceOverviewValue(closing, closing == null ? 0 : 1, 1,
            components: {'Opening Arrears': number(source?['opening_arrears']),
              'Total Billing': number(source?['billing_total']),
              'Less: Total Collected': number(source?['collection_total']),
              'Adjustments': number(source?['arrears_adjustments']),
              'Closing Arrears': closing});
      case FinanceOverviewMetric.utilities:
        // Missing water/electricity is not zero. Sum known components, clearly
        // label incomplete coverage and suppress comparisons to partial periods.
        final electricity = rows.map((r) => number(r['electricity_bill_rm'])).whereType<double>().toList();
        final water = rows.map((r) => number(r['water_bill_rm'])).whereType<double>().toList();
        final electricityTotal = _sum(electricity);
        final waterTotal = _sum(water);
        return FinanceOverviewValue(_sum([electricityTotal, waterTotal]),
            electricity.length + water.length, expected * 2,
            components: {'Electricity': electricityTotal, 'Water': waterTotal},
            componentCoverage: {'Electricity': '${electricity.length}/$expected months',
              'Water': '${water.length}/$expected months'});
    }
  }

  FinanceOverviewComparison compare(FinanceOverviewMetric metric, FinanceOverviewPeriod period) {
    final current = value(metric, period);
    final previous = value(metric, period.preceding);
    final a = current.amount;
    final b = previous.amount;
    double? movement;
    var text = 'No comparison available';
    bool? favourable;
    if (a != null && b != null && current.complete && previous.complete) {
      if (metric == FinanceOverviewMetric.ratio) {
        movement = a - b;
      } else if (b != 0) {
        movement = (a - b) / b.abs() * 100;
      } else if (a == 0) {
        movement = 0;
      } else {
        text = 'Previous period was zero';
      }
      if (movement != null && movement.isFinite) {
        if (movement.abs() < 0.005) movement = 0;
        final unit = metric == FinanceOverviewMetric.ratio ? ' pp' : '%';
        text = movement == 0 ? 'Unchanged' :
            '${movement > 0 ? '+' : ''}${movement.toStringAsFixed(2)}$unit';
        if (movement != 0) {
          if (metric == FinanceOverviewMetric.collected || metric == FinanceOverviewMetric.ratio) {
            favourable = movement > 0;
          } else if (metric == FinanceOverviewMetric.arrears ||
              metric == FinanceOverviewMetric.utilities) {
            favourable = movement < 0;
          }
        }
      } else {
        movement = null;
      }
    }
    return FinanceOverviewComparison(current, previous, movement, text, favourable);
  }
}


/// The automatically selected periods for one property's analytics.
/// The overview's applied Start/End months are deliberately not inputs.
class FinancePropertyPeriods {
  final FinanceOverviewPeriod? forecast;
  final FinanceOverviewPeriod? annualTrends;
  final FinanceOverviewPeriod? annualAttention;

  const FinancePropertyPeriods({this.forecast, this.annualTrends,
    this.annualAttention});

  static DateTime malaysiaCurrentMonth() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(now.year, now.month);
  }

  static bool hasFinancialObservation(Map<String, dynamic> row) {
    if (!FinanceOverviewService.isActual(row)) return false;
    bool hasAmount(String field) => FinanceOverviewService.number(row[field]) != null;
    return (row['has_billing'] == true &&
            (hasAmount('billing_total') || hasAmount('collection_total'))) ||
        (row['has_billing'] == true &&
            row['has_arrears_reconciliation'] == true && hasAmount('closing_arrears')) ||
        (row['has_utilities'] == true &&
            (hasAmount('electricity_bill_rm') || hasAmount('water_bill_rm')));
  }

  factory FinancePropertyPeriods.fromHistory(
    List<Map<String, dynamic>> history, {required DateTime throughMonth}) {
    final cutoff = DateTime(throughMonth.year, throughMonth.month);
    final reportMonths = <DateTime>{};
    final financialMonths = <DateTime>{};
    for (final row in history) {
      final date = FinanceOverviewService.parseMonth(row['report_month']);
      if (date == null || date.isAfter(cutoff)) continue;
      if (row['has_report'] == true && row['classification'] != 'future') {
        reportMonths.add(date);
      }
      if (hasFinancialObservation(row)) financialMonths.add(date);
    }
    final financial = financialMonths.toList()..sort();
    final reports = reportMonths.toList()..sort();
    if (financial.isEmpty && reports.isEmpty) return const FinancePropertyPeriods();
    final year = (financial.isNotEmpty ? financial.last : reports.last).year;
    final annualFinancial = financial.where((date) => date.year == year).toList();
    final annualReports = reports.where((date) => date.year == year).toList();
    // Include trailing saved reports in Attention Required, even if they are
    // test-only or incomplete. Do not extend the actual/forecast period for them.
    return FinancePropertyPeriods(
      forecast: financial.isEmpty ? null :
          FinanceOverviewPeriod(financial.first, financial.last),
      annualTrends: annualFinancial.isEmpty ? null :
          FinanceOverviewPeriod(annualFinancial.first, annualFinancial.last),
      annualAttention: annualReports.isEmpty ? null :
          FinanceOverviewPeriod(annualReports.first, annualReports.last),
    );
  }

  static bool contains(FinanceOverviewPeriod? period, dynamic rawMonth) {
    final date = FinanceOverviewService.parseMonth(rawMonth);
    return period != null && date != null &&
        !date.isBefore(period.start) && !date.isAfter(period.end);
  }
}

/// A range-specific response from the statistical Edge Function, never Gemini.
class FinanceForecastResult {
  final Map<String, dynamic> analysis;
  final bool cached;
  final bool preview;
  final DateTime? savedAt;

  const FinanceForecastResult({
    required this.analysis,
    required this.cached,
    required this.preview,
    this.savedAt,
  });
}

class FinanceForecastException implements Exception {
  final String code;
  final String message;
  const FinanceForecastException(this.code, this.message);
  @override
  String toString() => message;
}

/// A lightweight, property-scoped change token, not financial data.
typedef FinanceForecastChangeState = ({
  String revision,
  String settingsHash,
  String localMonth,
});

class FinanceForecastService {
  final SupabaseClient _supabase;
  FinanceForecastService(this._supabase);

  static const _metrics = [
    'billing_total',
    'collection_total',
    'closing_arrears',
  ];

  static Map<String, dynamic>? _map(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // Non-JSON error messages are deliberately not exposed to the UI.
      }
    }
    return null;
  }

  static FinanceForecastException _failure(dynamic payload, int? status) {
    final data = _map(payload);
    final code = data?['code']?.toString() ?? '';
    switch (code) {
      case 'model_pending_validation':
        return const FinanceForecastException(
          'model_pending_validation',
          'Financial forecasting is pending production activation.',
        );
      case 'source_changed':
        return const FinanceForecastException(
          'source_changed',
          'Financial records changed during forecasting. Please retry.',
        );
      case 'preview_admin_only':
      case 'property_access_denied':
        return const FinanceForecastException(
          'property_access_denied',
          'You do not have access to this forecast.',
        );
      case 'authentication_required':
        return const FinanceForecastException(
          'authentication_required', 'Your session has expired. Sign in again.',
        );
      case 'invalid_range':
        return const FinanceForecastException(
          'invalid_range', 'Select a valid property and reporting period.',
        );
      case 'property_not_found':
        return const FinanceForecastException(
          'property_not_found', 'This property is no longer available.',
        );
    }
    if (status == 401) {
      return const FinanceForecastException(
        'authentication_required', 'Your session has expired. Sign in again.',
      );
    }
    if (status == 403) {
      return const FinanceForecastException(
        'property_access_denied', 'You do not have access to this forecast.',
      );
    }
    if (status == 409) {
      return const FinanceForecastException(
        'source_changed', 'Financial records changed. Please retry.',
      );
    }
    return const FinanceForecastException(
      'forecast_unavailable',
      'Unable to generate the financial forecast. Please retry.',
    );
  }

  Future<FinanceForecastResult> _request({
    required String siteId,
    required String startMonth,
    required String endMonth,
    required bool preview,
  }) async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw const FinanceForecastException(
        'authentication_required', 'Your session has expired. Sign in again.',
      );
    }
    try {
      final response = await _supabase.functions.invoke(
        'finance-forecast',
        body: <String, dynamic>{
          'site_id': siteId,
          'start_month': startMonth,
          'end_month': endMonth,
          if (preview) 'preview': true,
        },
        headers: <String, String>{
          'Authorization': 'Bearer ${session.accessToken}',
        },
      ).timeout(const Duration(seconds: 50));
      final payload = _map(response.data);
      if (response.status < 200 || response.status >= 300 ||
          payload?['status'] == 'error') {
        throw _failure(response.data, response.status);
      }
      final analysis = _map(payload?['analysis']);
      final forecasts = _map(analysis?['forecasts']);
      if (payload?['status'] != (preview ? 'preview' : 'available') ||
          analysis == null ||
          analysis['site_id']?.toString() != siteId ||
          analysis['selected_start_month'] != startMonth ||
          analysis['selected_report_month'] != endMonth ||
          analysis['source'] != 'supabase_rpc' ||
          analysis['synthetic_example'] != false ||
          analysis['financial_anomalies'] is! List ||
          analysis['data_quality_issues'] is! List ||
          forecasts == null ||
          _metrics.any((metric) => _map(forecasts[metric]) == null)) {
        throw const FinanceForecastException(
          'invalid_forecast', 'The forecast did not match the property and automatic historical period.',
        );
      }
      return FinanceForecastResult(
        analysis: analysis,
        cached: payload?['cached'] == true,
        preview: preview,
        savedAt: DateTime.tryParse(payload?['saved_at']?.toString() ?? ''),
      );
    } on FunctionException catch (error) {
      throw _failure(error.details, error.status);
    } on TimeoutException {
      throw const FinanceForecastException(
        'forecast_timeout', 'The forecast took too long. Please retry.',
      );
    } on FinanceForecastException {
      rethrow;
    } catch (_) {
      throw const FinanceForecastException(
        'forecast_unavailable',
        'Unable to connect to the financial forecast service. Please retry.',
      );
    }
  }

  /// Try the production path first. During validation only an administrator
  /// may use the read-only, clearly labelled preview path. The server, not
  /// this client hint, checks the administrator's actual permissions.
  Future<FinanceForecastResult> forecast({
    required String siteId,
    required String startMonth,
    required String endMonth,
    bool allowAdminPreview = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _request(siteId: siteId, startMonth: startMonth,
            endMonth: endMonth, preview: false);
      } on FinanceForecastException catch (error) {
        if (error.code == 'model_pending_validation' && allowAdminPreview) {
          return _request(siteId: siteId, startMonth: startMonth,
              endMonth: endMonth, preview: true);
        }
        if (error.code != 'source_changed' || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw const FinanceForecastException(
      'source_changed', 'Financial records changed. Please retry.',
    );
  }

  Future<FinanceForecastChangeState> changeState(String siteId) async {
    final raw = await _supabase.rpc('finance_forecast_change_state',
        params: {'p_site_id': siteId}).timeout(const Duration(seconds: 12));
    final data = _map(raw);
    final revision = data?['revision']?.toString();
    final hash = data?['settings_hash']?.toString();
    final month = data?['local_month']?.toString();
    if (revision == null || !RegExp(r'^\d+$').hasMatch(revision) ||
        hash == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        month == null || !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) {
      throw const FinanceForecastException(
        'invalid_change_state', 'Unable to check financial source changes.',
      );
    }
    return (revision: revision, settingsHash: hash, localMonth: month);
  }
}
