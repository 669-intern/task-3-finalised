import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../property_sites_service.dart';
import 'dashboard_finance.dart';
import 'dashboard_defaulters.dart';
import 'dashboard_ai_insights.dart';
import '../widgets/dashboard_filters.dart';
import '../widgets/dashboard_metric_card.dart';
import '../widgets/styles.dart';
import '../widgets/app_shell.dart';
import '../widgets/app_common_app_bar.dart';

// ============================================================
// ADMIN DASHBOARD
// Uses the same records and monthly-effective rules as the report modules.
// The PDF is a visual reference only; it is never used as a data source.
// ============================================================

class AdminPortalPage extends StatefulWidget {
  final Map<String, dynamic> profile;
  final VoidCallback onRefresh;
  final VoidCallback onManageProperties;
  final VoidCallback onOpenStaffPortal;
  final VoidCallback onManageStaff;
  final AppShellController? shellController;

  const AdminPortalPage({
    super.key,
    required this.profile,
    required this.onRefresh,
    required this.onManageProperties,
    required this.onOpenStaffPortal,
    required this.onManageStaff,
    this.shellController,
  });

  @override
  State<AdminPortalPage> createState() => _AdminPortalPageState();
}

enum _FinanceDashboardTab { financialOverview, defaulters }

typedef _FinanceSelection = ({String siteId, String? from, String? to});

class _AdminPortalPageState extends State<AdminPortalPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _sites = [];
  List<Map<String, dynamic>> _availableReports = [];
  Set<String> _selectedProperties = <String>{};
  DateTime? _selectedStartPeriod;
  DateTime? _selectedEndPeriod;

  int? _propertyCount;
  int? _staffAccountCount;
  String? _managementWarning;
  String? _reportWarning;
  _DashboardReportData? _reportData;

  bool _filtersInitialized = false;
  bool _filtersDirty = false;
  // Hourly staffing chart shows the latest occurrence of this weekday in the
  // latest selected reporting month (not an estimated daily average).
  int _staffHourlyWeekday = DateTime.monday;
  // Always open on the staffing charts; other categories are selected on demand.
  String _selectedDashboardCategory = 'staff';
  // The Finance category owns navigation and independent tab filters.
  // Financial Overview is the default every time the category is entered.
  _FinanceDashboardTab _selectedFinanceTab = _FinanceDashboardTab.financialOverview;
  bool _defaultersVisited = false;
  _FinanceSelection? _defaultersApplied;
  _FinanceSelection? _defaultersDraft;
  int _defaultersFilterRevision = 0;
  // Overview and Defaulters keep independent applied and draft filters.
  _FinanceSelection? _financeApplied;
  _FinanceSelection? _financeDraft;
  int _financeRefreshRevision = 0;
  int _financeFilterRevision = 0;
  Map<String, String> _financeClassifications = const {};
  bool get _canViewFinance =>
      widget.profile['account_status'] == 'active' &&
      (widget.profile['role'] == 'admin' || widget.profile['role'] == 'staff');
  bool get _canViewAi =>
      _canViewFinance && widget.profile['role'] == 'admin';
  bool _loading = true;
  int _requestSequence = 0;

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  @override
  void dispose() {
    _requestSequence++;
    super.dispose();
  }

  static DateTime? _calendarDate(dynamic raw) {
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})',
    ).firstMatch(raw?.toString().trim() ?? '');
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  static DateTime _monthStart(DateTime value) =>
      DateTime(value.year, value.month);

  static DateTime _monthCutoff(DateTime month) {
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return monthEnd.isAfter(today) ? today : monthEnd;
  }

  static List<Map<String, dynamic>> _rows(dynamic data) {
    if (data is! List) return [];
    return data
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static int _intValue(dynamic value) =>
      (num.tryParse(value?.toString() ?? '') ?? 0).toInt();

  static const List<String> _monthNames = <String>[
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

  static const List<String> _shortMonthNames = <String>[
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
  ];

  static String _monthLabel(DateTime month) =>
      '${_monthNames[month.month - 1]} ${month.year}';

  Future<List<Map<String, dynamic>>> _loadAvailableReports(
    List<Map<String, dynamic>> sites,
  ) async {
    final ids = sites
        .map((site) => site['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return [];
    final output = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += 80) {
      final batch = ids.skip(i).take(80).toList();
      var offset = 0;
      while (true) {
        final page = _rows(
          await _supabase
              .from('monthly_reports')
              .select('id, site_id, report_month')
              .inFilter('site_id', batch)
              .order('report_month', ascending: false)
              .range(offset, offset + 999),
        );
        output.addAll(page);
        if (page.length < 1000) break;
        offset += 1000;
      }
    }
    output.removeWhere((row) => _calendarDate(row['report_month']) == null);
    output.sort(
      (a, b) => (b['report_month']?.toString() ?? '').compareTo(
        a['report_month']?.toString() ?? '',
      ),
    );
    return output;
  }

  void _restoreDefaultFilters() {
    // Defaults come from Dashboard reports only, never the Monthly Reports sidebar.
    final fallbackSite = _availableReports.isNotEmpty
        ? _availableReports.first['site_id']?.toString()
        : (_sites.isEmpty ? null : _sites.first['id']?.toString());
    _selectedProperties = fallbackSite == null
        ? <String>{}
        : <String>{fallbackSite};
    final siteReports = _availableReports
        .where((report) => report['site_id']?.toString() == fallbackSite)
        .toList();
    // Default to January of the active reporting year, not the first saved row.
    final currentMonth = _monthStart(DateTime.now());
    final latestExisting = siteReports
        .map((r) => _calendarDate(r['report_month']))
        .whereType<DateTime>()
        .where((date) => !date.isAfter(currentMonth))
        .firstOrNull;
    final endDate = latestExisting == null
        ? currentMonth
        : _monthStart(latestExisting);
    _selectedStartPeriod = DateTime(endDate.year, 1);
    _selectedEndPeriod = endDate;
    _filtersInitialized = true;
    _filtersDirty = false;
  }

  Future<void> _loadDashboard({
    bool reloadManagement = true,
    bool resetFilters = false,
  }) async {
    final request = ++_requestSequence;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _reportWarning = null;
    });

    var sites = _sites;
    var propertyCount = _propertyCount;
    var staffCount = _staffAccountCount;
    var managementWarning = _managementWarning;

    if (reloadManagement || sites.isEmpty) {
      final warnings = <String>[];
      try {
        // This is the same authenticated source as the Properties page.
        final response = await PropertySitesService.listSitesAuthenticated();
        sites = List<Map<String, dynamic>>.from(response.sites);
        if (widget.profile['role'] == 'staff') {
          final userId = _supabase.auth.currentUser?.id;
          if (userId == null) throw StateError('Session expired');
          final assignments = _rows(await _supabase.from('staff_site_assignments')
              .select('site_id').eq('user_id', userId));
          final allowed = assignments.map((row) => row['site_id']?.toString()).toSet();
          sites = sites.where((site) => allowed.contains(site['id']?.toString())).toList();
        }
        propertyCount = sites.length;
      } catch (error) {
        if (widget.profile['role'] == 'staff') {
          sites = [];
          propertyCount = 0;
        }
        warnings.add('Properties: $error');
      }
      if (widget.profile['role'] == 'admin') {
        try {
          // Staff accounts, not the on-site staffing/pax shown in the chart.
          final session = _supabase.auth.currentSession;
          if (session == null) throw StateError('Session expired');
          final response = await _supabase.functions.invoke(
            'staff-management',
            body: <String, dynamic>{'action': 'list_staff'},
            headers: <String, String>{
              'Authorization': 'Bearer ${session.accessToken}',
            },
          );
          if (response.data is! Map) {
            throw StateError('Unexpected staff response');
          }
          final payload = Map<String, dynamic>.from(response.data as Map);
          if (payload['error'] != null) {
            throw StateError(payload['error'].toString());
          }
          if (payload['staff'] is! List) {
            throw StateError('No staff list returned');
          }
          staffCount = (payload['staff'] as List).length;
        } catch (error) {
          warnings.add('Staff accounts: $error');
        }
      }
      managementWarning = warnings.isEmpty ? null : warnings.join('  |  ');
    }

    if (!mounted || request != _requestSequence) return;
    List<Map<String, dynamic>> availableReports;
    try {
      availableReports = await _loadAvailableReports(sites);
    } catch (error) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _sites = sites;
        _propertyCount = propertyCount;
        _staffAccountCount = staffCount;
        _managementWarning = managementWarning;
        _reportWarning = 'Could not load available reporting periods: $error';
        _reportData = null;
        _loading = false;
      });
      return;
    }

    // Only test markers are needed; verification is no longer required.
    final classifications = <String, String>{};
    if (_canViewFinance) {
      try {
        final rows = _rows(await _supabase.rpc('finance_dashboard_test_reports'));
        for (final row in rows) {
          final id = row['report_id']?.toString();
          if (id != null) classifications[id] = 'test';
        }
      } catch (_) {
        // Overview's finance dataset enforces test exclusion independently.
        // Defaulters use authorised monthly reports independently of these markers.
      }
    }
    if (!mounted || request != _requestSequence) return;
    setState(() {
      _sites = sites;
      _propertyCount = propertyCount;
      _staffAccountCount = staffCount;
      _managementWarning = managementWarning;
      _availableReports = availableReports;
      _financeClassifications = classifications;
      if (reloadManagement) _financeRefreshRevision++;
      if (!_filtersInitialized || resetFilters) _restoreDefaultFilters();
    });
    await _applyFiltersForRequest(request);
  }

  Future<void> _applyFilters() async {
    final request = ++_requestSequence;
    setState(() {
      _loading = true;
      _reportWarning = null;
    });
    await _applyFiltersForRequest(request);
  }

  Future<void> _applyFiltersForRequest(int request) async {
    if (_selectedProperties.isEmpty ||
        _selectedStartPeriod == null ||
        _selectedEndPeriod == null) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _reportData = null;
        _reportWarning = 'Select a property, Start month and End month.';
        _loading = false;
      });
      return;
    }

    final start = _monthStart(_selectedStartPeriod!);
    final end = _monthStart(_selectedEndPeriod!);
    if (start.isAfter(end)) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _reportWarning = 'End month must be the same as or after Start month.';
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('End month must be the same as or after Start month.'),
        ),
      );
      return;
    }

    final selectedReports = _availableReports.where((report) {
      final date = _calendarDate(report['report_month']);
      if (date == null ||
          !_selectedProperties.contains(report['site_id']?.toString())) {
        return false;
      }
      final period = _monthStart(date);
      return !period.isBefore(start) && !period.isAfter(end);
    }).toList();

    if (selectedReports.isEmpty) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _reportData = null;
        _reportWarning = 'No monthly reports match the selected filters.';
        _loading = false;
        _filtersDirty = false;
      });
      return;
    }

    try {
      final reportData = await _loadFilteredReportData(selectedReports);
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _reportData = reportData;
        _reportWarning = null;
        _filtersDirty = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _reportData = null;
        _reportWarning = 'Could not load Dashboard chart data: $error';
        _loading = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _readReportRows(
    String table,
    List<String> reportIds,
  ) async {
    if (reportIds.isEmpty) return [];
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < reportIds.length; i += 80) {
      final ids = reportIds.skip(i).take(80).toList();
      var offset = 0;
      while (true) {
        final page = _rows(
          await _supabase
              .from(table)
              .select()
              .inFilter('report_id', ids)
              .range(offset, offset + 999),
        );
        rows.addAll(page);
        if (page.length < 1000) break;
        offset += 1000;
      }
    }
    return rows;
  }

  Future<_DashboardSiteSource> _loadSiteSource(
    String siteId,
    List<Map<String, dynamic>> siteReports,
  ) async {
    final reportMonths = <String, DateTime>{};
    for (final report in siteReports) {
      final id = report['id']?.toString();
      final date = _calendarDate(report['report_month']);
      if (id != null && date != null) reportMonths[id] = _monthStart(date);
    }
    final ids = reportMonths.keys.toList();
    final data = await Future.wait<List<Map<String, dynamic>>>([
      _readReportRows('maintenance_works', ids),
      _readReportRows('maintenance_progress_updates', ids),
      _readReportRows('complaints_resolution', ids),
      _readReportRows('complaint_progress_updates', ids),
      _readReportRows('lift_incidents', ids),
      _readReportRows('occupancy_records', ids),
      _readReportRows('service_providers', ids),
      _readReportRows('staff_effective', ids),
    ]);

    // Direct rows distinguish explicit opt-in for non-default staff services
    // from the effective view's default include_in_staff=true.
    final directStaff = <Map<String, dynamic>>[];
    final providerIds = data[6]
        .map((provider) => provider['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    for (var i = 0; i < providerIds.length; i += 80) {
      final ids = providerIds.skip(i).take(80).toList();
      directStaff.addAll(
        _rows(
          await _supabase
              .from('staff')
              .select('service_provider_id,include_in_staff')
              .inFilter('service_provider_id', ids),
        ),
      );
    }
    final property = await _supabase
        .from('property_sites')
        .select('total_units')
        .eq('id', siteId)
        .maybeSingle();

    return _DashboardSiteSource(
      reportMonths: reportMonths,
      maintenance: data[0],
      maintenanceUpdates: _indexProgress(data[1], 'maintenance_id'),
      complaints: data[2],
      complaintUpdates: _indexProgress(data[3], 'complaint_id'),
      lifts: data[4],
      occupancy: data[5],
      providers: data[6],
      effectiveStaff: data[7],
      directStaff: directStaff,
      totalUnits: _intValue(property?['total_units']),
    );
  }

  static Map<String, List<Map<String, dynamic>>> _indexProgress(
    List<Map<String, dynamic>> rows,
    String foreignKey,
  ) {
    final index = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final id = row[foreignKey]?.toString();
      if (id != null && id.isNotEmpty) {
        (index[id] ??= <Map<String, dynamic>>[]).add(row);
      }
    }
    for (final updates in index.values) {
      updates.sort((a, b) {
        final aDate = _calendarDate(a['progress_date']) ?? DateTime(1900);
        final bDate = _calendarDate(b['progress_date']) ?? DateTime(1900);
        final dateOrder = aDate.compareTo(bDate);
        if (dateOrder != 0) return dateOrder;
        final createdOrder = (a['created_at']?.toString() ?? '').compareTo(
          b['created_at']?.toString() ?? '',
        );
        if (createdOrder != 0) return createdOrder;
        return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });
    }
    return index;
  }

  // This reproduces the date-effective 'This Month' record that Maintenance
  // and Complaints display. Original rows are never modified or duplicated.
  static String? _effectiveStatusForMonth({
    required Map<String, dynamic> source,
    required DateTime month,
    required Map<String, DateTime> reportMonths,
    required List<Map<String, dynamic>> updates,
    required bool complaint,
  }) {
    final original = reportMonths[source['report_id']?.toString()];
    if (original == null || original.isAfter(month)) return null;
    final startDate = _calendarDate(source['entry_date']) ?? original;
    final startMonth = _monthStart(startDate);
    if (startMonth.isAfter(month)) return null;
    final cutoff = _monthCutoff(month);
    if (cutoff.isBefore(month)) return null;

    Map<String, dynamic>? beforeMonth;
    Map<String, dynamic>? latest;
    var changedThisMonth = false;
    for (final update in updates) {
      final date = _calendarDate(update['progress_date']);
      if (date == null || (complaint && date.isBefore(startDate))) continue;
      if (date.isBefore(month)) beforeMonth = update;
      if (!date.isAfter(cutoff)) latest = update;
      if (!date.isBefore(month) && !date.isAfter(cutoff)) {
        changedThisMonth = true;
      }
    }
    if (startMonth.isBefore(month) &&
        beforeMonth?['status']?.toString() == 'Completed' &&
        !changedThisMonth) {
      return null;
    }

    final rawStatus = (latest?['status'] ?? source['status'] ?? 'Pending')
        .toString();
    // A base-row Completed status is not a dated completion event.
    final hasDatedCompletion = latest != null && rawStatus == 'Completed';
    if (complaint) {
      // Match Complaints & Resolution: no Completed Date means In Progress.
      // This also treats all legacy Overdue statuses as In Progress.
      return hasDatedCompletion ? 'Completed' : 'In Progress';
    }
    final savedStatus = rawStatus == 'Completed' && !hasDatedCompletion
        ? 'In Progress'
        : rawStatus;
    if (savedStatus == 'Completed') return savedStatus;
    final deadline = _calendarDate(
      latest == null ? source['deadline'] : latest['deadline'],
    );
    if (deadline != null && _monthStart(deadline).isBefore(month)) {
      return 'Overdue';
    }
    return savedStatus;
  }

  static Map<String, int> _statusBuckets(Iterable<String> statuses) {
    final result = <String, int>{
      'Completed': 0,
      'In Progress': 0,
      'KIV': 0,
      'Cancelled': 0,
      'Overdue': 0,
    };
    for (final status in statuses) {
      final key = switch (status.trim().toLowerCase()) {
        'completed' => 'Completed',
        'in progress' => 'In Progress',
        'pending' || 'on hold' => 'KIV',
        'cancelled' => 'Cancelled',
        'overdue' => 'Overdue',
        _ => 'KIV',
      };
      result[key] = (result[key] ?? 0) + 1;
    }
    return result;
  }

  static Map<String, int> _complaintStatusBuckets(
    Iterable<String> statuses,
  ) {
    final buckets = <String, int>{'Completed': 0, 'In Progress': 0};
    for (final status in statuses) {
      final key = status == 'Completed' ? 'Completed' : 'In Progress';
      buckets[key] = buckets[key]! + 1;
    }
    return buckets;
  }

  Future<_DashboardReportData> _loadFilteredReportData(
    List<Map<String, dynamic>> selectedReports,
  ) async {
    final bySite = <String, List<Map<String, dynamic>>>{};
    final selectedPeriods = <int, DateTime>{};
    for (final report in selectedReports) {
      final siteId = report['site_id']?.toString();
      final date = _calendarDate(report['report_month']);
      if (siteId == null || date == null) continue;
      (bySite[siteId] ??= <Map<String, dynamic>>[]).add(report);
      selectedPeriods[date.year * 100 + date.month] = _monthStart(date);
    }

    final maintenanceStatuses = <String, String>{};
    final complaintStatuses = <String, String>{};
    final byMonth = <int, int>{
      for (final period in selectedPeriods.keys) period: 0,
    };
    final byLift = <String, int>{};
    final mantrapCounts = <String, int>{'Yes': 0, 'No': 0, 'Not recorded': 0};
    final seenLiftIds = <String>{};
    final maintenanceByMonth = <int, int>{
      for (final period in selectedPeriods.keys) period: 0,
    };
    final complaintReceivedByMonth = <int, int>{
      for (final period in selectedPeriods.keys) period: 0,
    };
    final complaintCompletedByMonth = <int, int>{
      for (final period in selectedPeriods.keys) period: 0,
    };
    final occupancyOccupiedByMonth = <int, int>{};
    final occupancyUnitsByMonth = <int, int>{};
    final occupancySitesByMonth = <int, int>{};
    final occupancyTotals = <String, int>{
      'Owner-occupied': 0,
      'Tenanted': 0,
      'Vacant': 0,
      'Commercial': 0,
    };
    var totalUnits = 0;
    final staffTotals = <String, int>{};
    final dayNightTotals = <String, int>{};
    final hourlyByWeekday = List<List<int>>.generate(
      7,
      (_) => List<int>.filled(24, 0),
    );
    final hourlyByCategory = <String, List<List<int>>>{
      for (final category in _dashboardStaffCategories)
        category: List<List<int>>.generate(
          7,
          (_) => List<int>.filled(24, 0),
        ),
    };
    final monthlyHeadcountByCategory = <String, Map<int, int>>{
      for (final category in _dashboardStaffCategories) category: <int, int>{},
    };
    final monthlyShiftsByCategory = <String, Map<int, int>>{
      for (final category in _dashboardStaffCategories) category: <int, int>{},
    };
    final monthlyStaffHeadcounts = <int, int>{};
    final monthlyStaffShifts = <int, int>{};
    final headcountSiteCounts = <int, int>{};
    final shiftSiteCounts = <int, int>{};
    final securityPositions = <String, int>{};
    var securityPositionsEntered = false;
    var securityPositionsIncomplete = false;
    final latestRequestedMonth = selectedPeriods.values.reduce(
      (a, b) => a.isAfter(b) ? a : b,
    );
    final staffTrendKeys = <int>[
      for (var month = 1; month <= latestRequestedMonth.month; month++)
        latestRequestedMonth.year * 100 + month,
    ];
    final staffWarnings = <String>[];
    var staffEntered = false;
    var shiftsEntered = false;
    var hourlyEntered = false;
    var staffingIncomplete = false;

    for (final entry in bySite.entries) {
      final siteId = entry.key;
      final selectedForSite = entry.value.toList()
        ..sort(
          (a, b) => (a['report_month']?.toString() ?? '').compareTo(
            b['report_month']?.toString() ?? '',
          ),
        );
      final allSiteReports = _availableReports
          .where((report) => report['site_id']?.toString() == siteId)
          .toList();
      final siteData = await _loadSiteSource(siteId, allSiteReports);

      // For multiple selected months, a carried-forward record is counted
      // ONCE per property, using the latest selected month in which it appears.
      for (final report in selectedForSite) {
        final period = _calendarDate(report['report_month']);
        if (period == null) continue;
        final month = _monthStart(period);
        for (final source in siteData.maintenance) {
          final id = source['id']?.toString();
          if (id == null || id.isEmpty) continue;
          final status = _effectiveStatusForMonth(
            source: source,
            month: month,
            reportMonths: siteData.reportMonths,
            updates: siteData.maintenanceUpdates[id] ?? const [],
            complaint: false,
          );
          if (status == null) {
            maintenanceStatuses.remove('$siteId:$id');
          } else {
            maintenanceStatuses['$siteId:$id'] = status;
          }
        }
        for (final source in siteData.complaints) {
          final id = source['id']?.toString();
          if (id == null || id.isEmpty) continue;
          final status = _effectiveStatusForMonth(
            source: source,
            month: month,
            reportMonths: siteData.reportMonths,
            updates: siteData.complaintUpdates[id] ?? const [],
            complaint: true,
          );
          if (status != null) {
            // Keep completed complaints counted once within the selected
            // range, even after they leave later months' This Month list.
            complaintStatuses['$siteId:$id'] = status;
          }
        }
      }

      // Maintenance/complaint trends use original entry dates, rather than
      // counting a carried-forward status as a new event each month.
      final reportMonthKeys = selectedForSite
          .map((report) => _calendarDate(report['report_month']))
          .whereType<DateTime>()
          .map((date) => date.year * 100 + date.month)
          .toSet();
      for (final work in siteData.maintenance) {
        final date =
            _calendarDate(work['entry_date']) ??
            siteData.reportMonths[work['report_id']?.toString()];
        if (date == null) continue;
        final key = date.year * 100 + date.month;
        if (reportMonthKeys.contains(key)) {
          maintenanceByMonth[key] = (maintenanceByMonth[key] ?? 0) + 1;
        }
      }
      for (final complaint in siteData.complaints) {
        final date =
            _calendarDate(complaint['entry_date']) ??
            siteData.reportMonths[complaint['report_id']?.toString()];
        if (date == null) continue;
        final key = date.year * 100 + date.month;
        if (reportMonthKeys.contains(key)) {
          complaintReceivedByMonth[key] =
              (complaintReceivedByMonth[key] ?? 0) + 1;
        }
      }
      // Count each complaint's first valid dated completion once, in its
      // month, using the same date validity as Complaints & Resolution.
      for (final complaint in siteData.complaints) {
        final original =
            siteData.reportMonths[complaint['report_id']?.toString()];
        if (original == null) continue;
        final startDate = _calendarDate(complaint['entry_date']) ?? original;
        final updates =
            siteData.complaintUpdates[complaint['id']?.toString()] ?? const [];
        for (final update in updates) {
          if (update['status']?.toString().trim().toLowerCase() !=
              'completed') {
            continue;
          }
          final date = _calendarDate(update['progress_date']);
          if (date == null || date.isBefore(startDate)) continue;
          if (date.isAfter(_monthCutoff(_monthStart(date)))) continue;
          final key = date.year * 100 + date.month;
          if (reportMonthKeys.contains(key)) {
            complaintCompletedByMonth[key] =
                (complaintCompletedByMonth[key] ?? 0) + 1;
          }
          break;
        }
      }

      // Lift frequency counts each incident in its actual incident month;
      // carried-forward progress is not another lift breakdown.
      for (final incident in siteData.lifts) {
        final id = incident['id']?.toString();
        if (id == null || !seenLiftIds.add('$siteId:$id')) continue;
        final date =
            _calendarDate(incident['incident_date']) ??
            siteData.reportMonths[incident['report_id']?.toString()];
        if (date == null) continue;
        final key = date.year * 100 + date.month;
        if (!selectedPeriods.containsKey(key) ||
            !selectedForSite.any((report) {
              final reportDate = _calendarDate(report['report_month']);
              return reportDate != null &&
                  reportDate.year == date.year &&
                  reportDate.month == date.month;
            })) {
          continue;
        }
        byMonth[key] = (byMonth[key] ?? 0) + 1;
        final mantrap = incident['mantrap'];
        final mantrapLabel = mantrap == true
            ? 'Yes'
            : mantrap == false
            ? 'No'
            : 'Not recorded';
        mantrapCounts[mantrapLabel] = (mantrapCounts[mantrapLabel] ?? 0) + 1;
        final tower = incident['tower']?.toString().trim() ?? '';
        final liftNo = incident['lift_no']?.toString().trim() ?? '';
        final singleSite = bySite.length == 1;
        final siteName =
            _sites
                .where((site) => site['id']?.toString() == siteId)
                .map((site) => site['site_name']?.toString() ?? '')
                .firstOrNull ??
            'Property';
        final liftLabel =
            '${tower.isEmpty ? '-' : tower} '
            '(Lift ${liftNo.isEmpty ? '-' : liftNo})';
        final label = singleSite ? liftLabel : '$siteName - $liftLabel';
        byLift[label] = (byLift[label] ?? 0) + 1;
      }

      // Occupancy and on-site staffing are monthly snapshots, not events.
      // Take each property's latest SELECTED report to prevent repeated unit
      // totals / staffing across multiple selected months.
      final latestReport = selectedForSite.last;
      final latestId = latestReport['id']?.toString() ?? '';
      final latestMonth = _calendarDate(latestReport['report_month']);
      final latestOccupancy = siteData.occupancy
          .where((row) => row['report_id']?.toString() == latestId)
          .toList();
      final recordedUnits = latestOccupancy.fold<int>(
        0,
        (sum, row) => sum + _intValue(row['total_units']),
      );
      totalUnits += siteData.totalUnits > 0
          ? siteData.totalUnits
          : recordedUnits;
      // Occupancy is a month-specific snapshot. Missing records are gaps,
      // never silently displayed as 0% occupancy.
      for (final report in selectedForSite) {
        final date = _calendarDate(report['report_month']);
        if (date == null) continue;
        final key = date.year * 100 + date.month;
        final rows = siteData.occupancy
            .where(
              (row) => row['report_id']?.toString() == report['id']?.toString(),
            )
            .toList();
        if (rows.isEmpty) continue;
        final sumUnits = rows.fold<int>(
          0,
          (sum, row) => sum + _intValue(row['total_units']),
        );
        final denominator = siteData.totalUnits > 0
            ? siteData.totalUnits
            : sumUnits;
        if (denominator <= 0) continue;
        final occupied = rows.fold<int>(
          0,
          (sum, row) =>
              sum +
              _intValue(row['owner_occupied']) +
              _intValue(row['tenant_occupied']),
        );
        occupancyOccupiedByMonth[key] =
            (occupancyOccupiedByMonth[key] ?? 0) + occupied;
        occupancyUnitsByMonth[key] =
            (occupancyUnitsByMonth[key] ?? 0) + denominator;
        occupancySitesByMonth[key] = (occupancySitesByMonth[key] ?? 0) + 1;
      }
      for (final row in latestOccupancy) {
        occupancyTotals['Owner-occupied'] =
            occupancyTotals['Owner-occupied']! +
            _intValue(row['owner_occupied']);
        occupancyTotals['Tenanted'] =
            occupancyTotals['Tenanted']! + _intValue(row['tenant_occupied']);
        occupancyTotals['Vacant'] =
            occupancyTotals['Vacant']! + _intValue(row['vacant']);
        occupancyTotals['Commercial'] =
            occupancyTotals['Commercial']! + _intValue(row['commercial_units']);
      }

      if (latestMonth != null) {
        try {
          // Staffing trends cover every calendar month from January to the
          // latest selected month, even if no monthly provider snapshot was
          // saved yet. Contract dates determine which months have staff.
          for (var calendarMonth = 1;
              calendarMonth <= latestRequestedMonth.month;
              calendarMonth++) {
            final trendMonth = DateTime(latestRequestedMonth.year, calendarMonth);
            final key = trendMonth.year * 100 + trendMonth.month;
            final staffing = _loadStaffForReport(
              providers: siteData.providers,
              effectiveStaff: siteData.effectiveStaff,
              directStaff: siteData.directStaff,
              reportMonths: siteData.reportMonths,
              month: trendMonth,
            );
            if (staffing.entered) {
              headcountSiteCounts[key] = (headcountSiteCounts[key] ?? 0) + 1;
              monthlyStaffHeadcounts[key] =
                  (monthlyStaffHeadcounts[key] ?? 0) +
                  staffing.counts.values.fold<int>(
                    0,
                    (sum, value) => sum + value,
                  );
              for (final category in _dashboardStaffCategories) {
                if (!staffing.counts.containsKey(category)) continue;
                final categoryValues = monthlyHeadcountByCategory[category]!;
                categoryValues[key] = (categoryValues[key] ?? 0) +
                    staffing.counts[category]!;
              }
            }
            if (staffing.scheduledStaffShifts != null &&
                staffing.shiftEntered) {
              shiftSiteCounts[key] = (shiftSiteCounts[key] ?? 0) + 1;
              monthlyStaffShifts[key] =
                  (monthlyStaffShifts[key] ?? 0) +
                  staffing.scheduledStaffShifts!;
              for (final category in _dashboardStaffCategories) {
                if (!staffing.shiftsByCategory.containsKey(category)) continue;
                final categoryValues = monthlyShiftsByCategory[category]!;
                categoryValues[key] = (categoryValues[key] ?? 0) +
                    staffing.shiftsByCategory[category]!;
              }
            }
          }

          // Current staffing cards and hourly coverage still use the latest
          // selected report for this property, not the final trend month.
          final staffing = _loadStaffForReport(
            providers: siteData.providers,
            effectiveStaff: siteData.effectiveStaff,
            directStaff: siteData.directStaff,
            reportMonths: siteData.reportMonths,
            month: _monthStart(latestMonth),
            includeHourly: true,
          );
          staffEntered = staffEntered || staffing.entered;
          shiftsEntered = shiftsEntered || staffing.shiftEntered;
          hourlyEntered = hourlyEntered || staffing.hourlyEntered;
          staffingIncomplete = staffingIncomplete || staffing.incomplete;
          for (final item in staffing.counts.entries) {
            staffTotals[item.key] = (staffTotals[item.key] ?? 0) + item.value;
          }
          for (final item in staffing.shifts.entries) {
            dayNightTotals[item.key] =
                (dayNightTotals[item.key] ?? 0) + item.value;
          }
          for (final item in staffing.securityPositions.entries) {
            securityPositions[item.key] =
                (securityPositions[item.key] ?? 0) + item.value;
          }
          securityPositionsEntered =
              securityPositionsEntered || staffing.securityPositionsEntered;
          securityPositionsIncomplete =
              securityPositionsIncomplete || staffing.securityPositionsIncomplete;
          for (var day = 0; day < 7; day++) {
            for (var hour = 0; hour < 24; hour++) {
              hourlyByWeekday[day][hour] += staffing.hourlyByWeekday[day][hour];
              for (final category in _dashboardStaffCategories) {
                hourlyByCategory[category]![day][hour] +=
                    staffing.hourlyByCategory[category]?[day][hour] ?? 0;
              }
            }
          }
        } catch (error) {
          staffWarnings.add('Staff at $siteId: $error');
        }
      }
    }

    final sortedMonths = selectedPeriods.keys.toList()..sort();
    final sortedLifts = byLift.keys.toList()..sort((a, b) => a.compareTo(b));
    final sortedStaff = staffTotals.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    String staffMonthLabel(int key) {
      final date = DateTime(key ~/ 100, key % 100);
      return _shortMonthNames[date.month - 1];
    }

    final periodTitle = sortedMonths.length == 1
        ? _monthLabel(selectedPeriods[sortedMonths.first]!)
        : 'selected periods';
    final siteLabel = bySite.length == 1
        ? (_sites
                  .where((site) => site['id']?.toString() == bySite.keys.first)
                  .map((site) => site['site_name']?.toString() ?? '')
                  .firstOrNull ??
              'Selected property')
        : '${bySite.length} properties';
    return _DashboardReportData(
      description: '$siteLabel  |  ${selectedReports.length} monthly report(s)',
      periodTitle: periodTitle,
      multiplePeriods: sortedMonths.length > 1,
      maintenance: _statusBuckets(maintenanceStatuses.values),
      complaints: _complaintStatusBuckets(complaintStatuses.values),
      liftMonths: [
        for (final key in sortedMonths)
          '${_shortMonthNames[selectedPeriods[key]!.month - 1]} '
              '${selectedPeriods[key]!.year}',
      ],
      liftByMonth: [for (final key in sortedMonths) byMonth[key] ?? 0],
      liftByLift: {for (final key in sortedLifts) key: byLift[key]!},
      mantrap: mantrapCounts,
      maintenanceMonths: [
        for (final key in sortedMonths)
          '${_shortMonthNames[selectedPeriods[key]!.month - 1]} '
              '${selectedPeriods[key]!.year}',
      ],
      maintenanceByMonth: [
        for (final key in sortedMonths) maintenanceByMonth[key] ?? 0,
      ],
      complaintMonths: [
        for (final key in sortedMonths)
          '${_shortMonthNames[selectedPeriods[key]!.month - 1]} '
              '${selectedPeriods[key]!.year}',
],
      complaintReceivedByMonth: [
        for (final key in sortedMonths) complaintReceivedByMonth[key] ?? 0,
      ],
      complaintCompletedByMonth: [
        for (final key in sortedMonths) complaintCompletedByMonth[key] ?? 0,
      ],
      occupancyRateMonths: [
        for (final key in sortedMonths)
          '${_shortMonthNames[selectedPeriods[key]!.month - 1]} '
              '${selectedPeriods[key]!.year}',
      ],
      occupancyRates: [
        for (final key in sortedMonths)
          if ((occupancySitesByMonth[key] ?? 0) != bySite.length ||
              (occupancyUnitsByMonth[key] ?? 0) <= 0)
            null
          else
            100.0 *
                (occupancyOccupiedByMonth[key] ?? 0) /
                occupancyUnitsByMonth[key]!,
      ],
      totalUnits: totalUnits,
      occupancy: occupancyTotals,
      staff: _DashboardStaffData(
        counts: {for (final key in sortedStaff) key: staffTotals[key]!},
        shifts: dayNightTotals,
        hourlyByWeekday: hourlyByWeekday,
        hourlyByCategory: hourlyByCategory,
        shiftEntered: shiftsEntered,
        hourlyEntered: hourlyEntered,
        incomplete: staffingIncomplete,
        monthLabels: staffTrendKeys.map(staffMonthLabel).toList(),
        monthlyHeadcount: [
          for (final key in staffTrendKeys)
            (headcountSiteCounts[key] ?? 0) == bySite.length
                ? monthlyStaffHeadcounts[key]
                : null,
        ],
        monthlyHeadcountByCategory: <String, List<int?>>{
          for (final category in _dashboardStaffCategories)
            category: [
              for (final key in staffTrendKeys)
                (headcountSiteCounts[key] ?? 0) == bySite.length
                    ? monthlyHeadcountByCategory[category]![key]
                    : null,
            ],
        },
        staffShiftMonthLabels: staffTrendKeys.map(staffMonthLabel).toList(),
        monthlyStaffShifts: [
          for (final key in staffTrendKeys)
            (shiftSiteCounts[key] ?? 0) == bySite.length
                ? monthlyStaffShifts[key]
                : null,
        ],
        monthlyShiftsByCategory: <String, List<int?>>{
          for (final category in _dashboardStaffCategories)
            category: [
              for (final key in staffTrendKeys)
                (shiftSiteCounts[key] ?? 0) == bySite.length
                    ? monthlyShiftsByCategory[category]![key]
                    : null,
            ],
        },
        shiftTrendPartial: staffTrendKeys.any(
          (key) => (shiftSiteCounts[key] ?? 0) != bySite.length,
        ),
        securityPositions: securityPositions,
        securityPositionsEntered: securityPositionsEntered,
        securityPositionsIncomplete: securityPositionsIncomplete,
        entered: staffEntered,
        warning: staffWarnings.isEmpty ? null : staffWarnings.join(' | '),
      ),
    );
  }

  // Time values come from PostgreSQL TIME columns. Legacy staffing text is
  // supported for reports created before structured shift times were added.
  static int? _staffMinutes(dynamic raw) {
    final value = raw?.toString().trim().toLowerCase() ?? '';
    final match = RegExp(
      r'^(\d{1,2})(?::(\d{2}))?(?::\d{2})?\s*(am|pm)?$',
    ).firstMatch(value);
    if (match == null) return null;
    var hour = int.parse(match.group(1)!);
    final minute = int.tryParse(match.group(2) ?? '0') ?? -1;
    if (minute < 0 || minute > 59) return null;
    final meridiem = match.group(3);
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      hour = hour % 12 + (meridiem == 'pm' ? 12 : 0);
    } else if (hour > 23) {
      return null;
    }
    return hour * 60 + minute;
  }

  static List<int>? _staffShiftTimes(Map<String, dynamic> staff, String shift) {
    final start = _staffMinutes(staff['${shift}_shift_start_time']);
    final end = _staffMinutes(staff['${shift}_shift_end_time']);
    if (start != null && end != null) return <int>[start, end];
    final legacy = staff['${shift}_shift_timing']?.toString() ?? '';
    final parts = legacy.split(RegExp(r'\s*[-–—]\s*'));
    if (parts.length != 2) return null;
    final legacyStart = _staffMinutes(parts[0]);
    final legacyEnd = _staffMinutes(parts[1]);
    return legacyStart == null || legacyEnd == null
        ? null
        : <int>[legacyStart, legacyEnd];
  }

  // ISO weekdays: 1 = Monday and 7 = Sunday. Only Daily and Weekly
  // schedules can be converted to exact dates from weekdays alone. Monthly
  // and irregular services need actual visit dates, which are not saved here.
  static Set<int>? _staffWorkingDays(Map<String, dynamic> staff, String shift) {
    final frequency = staff['frequency']?.toString().trim().toLowerCase();
    if (frequency != 'daily' &&
        frequency != 'weekly' &&
        frequency != null &&
        frequency.isNotEmpty) {
      return null;
    }
    final raw = staff['${shift}_shift_weekdays'];
    if (raw is List && raw.isNotEmpty) {
      final days = <int>{};
      for (final item in raw) {
        final day = int.tryParse(item.toString());
        if (day == null || day < 1 || day > 7) return null;
        days.add(day);
      }
      return days;
    }
    if (staff['frequency']?.toString().trim().toLowerCase() == 'daily') {
      return <int>{1, 2, 3, 4, 5, 6, 7};
    }
    return null;
  }

  static DateTime _lastWeekdayInMonth(DateTime month, int weekday) {
    final last = DateTime(month.year, month.month + 1, 0);
    return last.subtract(Duration(days: (last.weekday - weekday + 7) % 7));
  }

  // No Upcoming/Archived records are included. Each provider is resolved as
  // of the requested month, and its matching effective row is a read-only
  // reflection of the shared Service Providers staffing data.
  _DashboardStaffData _loadStaffForReport({
    required List<Map<String, dynamic>> providers,
    required List<Map<String, dynamic>> effectiveStaff,
    required List<Map<String, dynamic>> directStaff,
    required Map<String, DateTime> reportMonths,
    required DateTime month,
    bool includeHourly = false,
  }) {
    if (providers.isEmpty) {
      return _DashboardStaffData(
        counts: const <String, int>{},
        entered: false,
        hourlyByWeekday: List<List<int>>.generate(
          7,
          (_) => List<int>.filled(24, 0),
        ),
      );
    }
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final byId = <String, Map<String, dynamic>>{
      for (final provider in providers)
        if (provider['id'] != null) provider['id'].toString(): provider,
    };
    final effectiveById = <String, Map<String, dynamic>>{
      for (final row in effectiveStaff)
        if (row['service_provider_id'] != null)
          row['service_provider_id'].toString(): row,
    };
    final directById = <String, Map<String, dynamic>>{
      for (final row in directStaff)
        if (row['service_provider_id'] != null)
          row['service_provider_id'].toString(): row,
    };

    String rootOf(Map<String, dynamic> provider) {
      var cursor = provider['id']?.toString() ?? '';
      final visited = <String>{};
      while (cursor.isNotEmpty && visited.add(cursor)) {
        final parent = byId[cursor]?['source_provider_id']?.toString() ?? '';
        if (parent.isEmpty || !byId.containsKey(parent)) break;
        cursor = parent;
      }
      return cursor;
    }

    // A null setting means staffing was not selected or excluded on this
    // provider snapshot or an earlier ancestor. Preserve explicit exclusions.
    bool? explicitStaffSetting(Map<String, dynamic> provider) {
      var cursor = provider['id']?.toString() ?? '';
      final visited = <String>{};
      while (cursor.isNotEmpty && visited.add(cursor)) {
        final direct = directById[cursor];
        if (direct != null) return direct['include_in_staff'] == true;
        cursor = byId[cursor]?['source_provider_id']?.toString() ?? '';
      }
      return null;
    }

    DateTime? effectiveExpiry(Map<String, dynamic> provider, DateTime onDate) {
      final expiry = _calendarDate(
        provider['expiry_date'] ?? provider['expiry_renewal_date'],
      );
      final confirmed = _calendarDate(provider['renewal_confirmed_at']);
      final newExpiry = _calendarDate(provider['next_expiry_date']);
      if (expiry != null &&
          confirmed != null &&
          !confirmed.isAfter(onDate) &&
          newExpiry != null &&
          newExpiry.isAfter(expiry)) {
        return newExpiry;
      }
      return expiry;
    }

    bool effectiveInMonth(Map<String, dynamic> provider) {
      if (provider['history_deleted_at'] != null) return false;
      final commencement = _calendarDate(provider['commencement_date']);
      if (commencement != null && _monthStart(commencement).isAfter(month)) {
        return false;
      }
      final expiry = effectiveExpiry(provider, monthEnd);
      if (expiry != null &&
          (_monthStart(expiry).isBefore(month) ||
              (expiry.day == 1 && _monthStart(expiry) == month))) {
        // A contract ending on the first is not active in that new month.
        return false;
      }
      final status = provider['status']?.toString().trim().toLowerCase() ?? '';
      final ended = status == 'terminated' || status == 'no longer used';
      final stoppedAt = _calendarDate(provider['lifecycle_date']);
      if (ended &&
          stoppedAt != null &&
          _monthStart(stoppedAt).isBefore(month)) {
        return false;
      }
      final restored = _calendarDate(provider['restored_month']);
      if (restored != null && _monthStart(restored).isAfter(month)) {
        return false;
      }
      if (provider['is_archived'] == true) {
        final archivedAt = _calendarDate(provider['archived_at']);
        if (archivedAt == null || !_monthStart(archivedAt).isAfter(month)) {
          return false;
        }
      }
      return true;
    }

    bool effectiveOnDay(Map<String, dynamic> provider, DateTime day) {
      if (provider['history_deleted_at'] != null) return false;
      final commencement = _calendarDate(provider['commencement_date']);
      if (commencement != null && commencement.isAfter(day)) return false;
      final expiry = effectiveExpiry(provider, day);
      if (expiry != null &&
          (day.isAfter(expiry) ||
              (expiry.day == 1 && !day.isBefore(expiry)))) {
        return false;
      }
      final status = provider['status']?.toString().trim().toLowerCase() ?? '';
      final ended = status == 'terminated' || status == 'no longer used';
      final stoppedAt = _calendarDate(provider['lifecycle_date']);
      if (ended && (stoppedAt == null || day.isAfter(stoppedAt))) return false;
      final restored = _calendarDate(provider['restored_month']);
      if (restored != null && _monthStart(restored).isAfter(_monthStart(day))) {
        return false;
      }
      if (provider['is_archived'] == true) {
        final archivedAt = _calendarDate(provider['archived_at']);
        if (archivedAt == null || !day.isBefore(archivedAt)) return false;
      }
      return true;
    }

    // Each linked provider has monthly copies. Use the latest copy on or
    // before the month; before its first saved copy, use the earliest one as
    // the original contract baseline (subject to commencement/expiry dates).
    final snapshotsByRoot = <String, List<Map<String, dynamic>>>{};
    for (final provider in providers) {
      if (reportMonths[provider['report_id']?.toString()] == null) continue;
      (snapshotsByRoot[rootOf(provider)] ??= []).add(provider);
    }
    final latestByRoot = <String, Map<String, dynamic>>{};
    final initialStaffByRoot = <String, Map<String, dynamic>>{};
    for (final entry in snapshotsByRoot.entries) {
      final snapshots = entry.value..sort((a, b) {
        final aMonth = reportMonths[a['report_id']?.toString()]!;
        final bMonth = reportMonths[b['report_id']?.toString()]!;
        final byMonth = aMonth.compareTo(bMonth);
        return byMonth != 0
            ? byMonth
            : (a['updated_at']?.toString() ?? '')
                  .compareTo(b['updated_at']?.toString() ?? '');
      });
      Map<String, dynamic>? selected;
      for (final provider in snapshots) {
        final savedMonth = reportMonths[provider['report_id']?.toString()]!;
        if (!savedMonth.isAfter(month)) selected = provider;
        final id = provider['id']?.toString();
        final effective = effectiveById[id];
        // The FIRST explicit staffing setup is the backdated baseline.
        // Later changes must not overwrite months with earlier saved values.
        if (!initialStaffByRoot.containsKey(entry.key) &&
            directById[id]?['include_in_staff'] == true &&
            effective != null &&
            (effective['total_staff'] != null ||
                effective['day_shift_staff'] != null ||
                effective['night_shift_staff'] != null)) {
          initialStaffByRoot[entry.key] = effective;
        }
      }
      latestByRoot[entry.key] = selected ?? snapshots.first;
    }

    const initialCategories = <String>{'Security', 'Cleaning', 'Landscaping'};
    final counts = <String, int>{};
    var dayTotal = 0;
    var nightTotal = 0;
    final securityPositions = <String, int>{};
    var securityPositionsEntered = false;
    var securityPositionsIncomplete = false;
    var entered = false;
    var shiftEntered = false;
    var hourlyEntered = false;
    var incomplete = false;
    var staffShifts = 0;
    var shiftsComplete = true;
    final shiftsByCategory = <String, int>{};
    final hourlyByWeekday = List<List<int>>.generate(
      7,
      (_) => List<int>.filled(24, 0),
    );
    final hourlyByCategory = <String, List<List<int>>>{
      for (final category in _dashboardStaffCategories)
        category: List<List<int>>.generate(
          7,
          (_) => List<int>.filled(24, 0),
        ),
    };

    for (final provider in latestByRoot.values) {
      if (!effectiveInMonth(provider)) continue;
      final id = provider['id']?.toString();
      final category = provider['service']?.toString().trim() ?? '';
      if (id == null || category.isEmpty) continue;
      var row = effectiveById[id];
      final savedSetting = explicitStaffSetting(provider);
      var usedBaseline = false;
      // When staffing was first entered after contract commencement, carry
      // its FIRST entered configuration back to the unrecorded months. Never
      // overwrite a previous setting, especially an explicit exclusion.
      if (savedSetting == null &&
          (row == null ||
              (row['total_staff'] == null &&
                  row['day_shift_staff'] == null &&
                  row['night_shift_staff'] == null))) {
        final baseline = initialStaffByRoot[rootOf(provider)];
        if (baseline != null) {
          row = baseline;
          usedBaseline = true;
        }
      }
      if (savedSetting == false ||
          row == null ||
          row['include_in_staff'] != true ||
          (!initialCategories.contains(category) &&
              savedSetting != true &&
              !usedBaseline)) {
        continue;
      }
      // Total staff represents unique assigned employees, not the sum of
      // simultaneous shift coverage. The two values are independent.
      final number = int.tryParse(row['total_staff']?.toString() ?? '');
      if (number != null && number >= 0) {
        entered = true;
        counts[category] = (counts[category] ?? 0) + number;
      } else {
        incomplete = true;
      }

      final rawDay = row['day_shift_staff'];
      final rawNight = row['night_shift_staff'];
      final day = int.tryParse(rawDay?.toString() ?? '') ?? 0;
      final night = int.tryParse(rawNight?.toString() ?? '') ?? 0;
      final hasShiftData = rawDay != null || rawNight != null;
      if (!hasShiftData || day < 0 || night < 0) {
        // Missing shift data cannot be presented as a complete monthly total.
        if ((number ?? 0) > 0 || number == null) {
          shiftsComplete = false;
          incomplete = true;
        }
        continue;
      }
      dayTotal += day;
      nightTotal += night;
      shiftEntered = true;

      if (category.toLowerCase() == 'security') {
        for (final shift in <String>['day', 'night']) {
          final shiftPax = shift == 'day' ? day : night;
          if (shiftPax <= 0) continue;
          final supervisors = int.tryParse(
            row['${shift}_shift_supervisors']?.toString() ?? '',
          );
          final guards = int.tryParse(
            row['${shift}_shift_guards']?.toString() ?? '',
          );
          if (supervisors == null ||
              guards == null ||
              supervisors < 0 ||
              guards < 0 ||
              supervisors + guards != shiftPax) {
            securityPositionsIncomplete = true;
          } else {
            securityPositionsEntered = true;
            final supervisorKey = '${shift}_shift_supervisors';
            final guardKey = '${shift}_shift_guards';
            securityPositions[supervisorKey] =
                (securityPositions[supervisorKey] ?? 0) + supervisors;
            securityPositions[guardKey] =
                (securityPositions[guardKey] ?? 0) + guards;
          }
        }
      }

      var providerStaffShifts = 0;
      for (final shift in <String>['day', 'night']) {
        final pax = shift == 'day' ? day : night;
        if (pax <= 0) continue;
        final weekdays = _staffWorkingDays(row, shift);
        final times = _staffShiftTimes(row, shift);
        if (weekdays == null) {
          incomplete = true;
          shiftsComplete = false;
          continue;
        }
        // Staff-shifts count each person once per scheduled shift start day,
        // even when a night shift ends on the following calendar day.
        for (
          var date = DateTime(month.year, month.month, 1);
          date.month == month.month && date.year == month.year;
          date = date.add(const Duration(days: 1))
        ) {
          if (weekdays.contains(date.weekday) &&
              effectiveOnDay(provider, date)) {
            staffShifts += pax;
            providerStaffShifts += pax;
          }
        }
        if (times == null) {
          incomplete = true;
          continue;
        }
        if (!includeHourly) continue;
        hourlyEntered = true;
        final startMinute = times[0];
        final endMinute = times[1];
        final duration = endMinute > startMinute
            ? endMinute - startMinute
            : 1440 - startMinute + endMinute;
        for (var weekday = 1; weekday <= 7; weekday++) {
          final reference = _lastWeekdayInMonth(month, weekday);
          for (final daysAgo in <int>[1, 0]) {
            final anchor = reference.subtract(Duration(days: daysAgo));
            if (!weekdays.contains(anchor.weekday) ||
                !effectiveOnDay(provider, anchor)) {
              continue;
            }
            final shiftStart = DateTime(
              anchor.year,
              anchor.month,
              anchor.day,
              startMinute ~/ 60,
              startMinute % 60,
            );
            final shiftEnd = shiftStart.add(Duration(minutes: duration));
            for (var hour = 0; hour < 24; hour++) {
              final moment = DateTime(
                reference.year,
                reference.month,
                reference.day,
                hour,
              );
              if (!moment.isBefore(shiftStart) && moment.isBefore(shiftEnd)) {
                hourlyByWeekday[weekday - 1][hour] += pax;
                final categoryHours = hourlyByCategory[category];
                if (categoryHours != null) {
                  categoryHours[weekday - 1][hour] += pax;
                }
              }
            }
          }
        }
      }
      if (_dashboardStaffCategories.contains(category)) {
        shiftsByCategory[category] =
            (shiftsByCategory[category] ?? 0) + providerStaffShifts;
      }
    }

    final shifts = <String, int>{};
    if (dayTotal > 0) shifts['Day shift'] = dayTotal;
    if (nightTotal > 0) shifts['Night shift'] = nightTotal;
    return _DashboardStaffData(
      counts: counts,
      shifts: shifts,
      securityPositions: securityPositions,
      securityPositionsEntered: securityPositionsEntered,
      securityPositionsIncomplete: securityPositionsIncomplete,
      hourlyByWeekday: hourlyByWeekday,
      hourlyByCategory: hourlyByCategory,
      shiftsByCategory: shiftsByCategory,
      scheduledStaffShifts: shiftsComplete ? staffShifts : null,
      entered: entered,
      shiftEntered: shiftEntered,
      hourlyEntered: hourlyEntered,
      incomplete: incomplete,
    );
  }

  List<_DashboardFilterOption<String>> get _propertyOptions {
    final sorted = _sites.toList()
      ..sort(
        (a, b) => (a['site_name']?.toString() ?? '').toLowerCase().compareTo(
          (b['site_name']?.toString() ?? '').toLowerCase(),
        ),
      );
    return <_DashboardFilterOption<String>>[
      for (final site in sorted)
        if (site['id'] != null)
          _DashboardFilterOption<String>(
            site['id'].toString(),
            site['site_name']?.toString() ?? 'Unnamed property',
          ),
    ];
  }

  List<_DashboardFilterOption<int>> get _yearOptions {
    final years = <int>{};
    for (final report in _availableReports) {
      if (_selectedProperties.isNotEmpty &&
          !_selectedProperties.contains(report['site_id']?.toString())) {
        continue;
      }
      final date = _calendarDate(report['report_month']);
      if (date != null) years.add(date.year);
    }
    final ordered = years.toList()..sort((a, b) => b.compareTo(a));
    return <_DashboardFilterOption<int>>[
      for (final year in ordered) _DashboardFilterOption<int>(year, '$year'),
    ];
  }

  Future<void> _editPeriodFilter({
    required String label,
    required DateTime? selected,
    required ValueChanged<DateTime> onSaved,
  }) async {
    final availableYears = _yearOptions.map((option) => option.value).toList();
    final currentYear = DateTime.now().year;
    if (label == 'End' && !availableYears.contains(currentYear)) {
      availableYears.add(currentYear);
      availableYears.sort((a, b) => b.compareTo(a));
    }
    if (availableYears.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No reporting years are available.')),
      );
      return;
    }

    var year = selected != null && availableYears.contains(selected.year)
        ? selected.year
        : availableYears.first;
    var month = selected?.month ?? 1;

    final result = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Select $label'),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: month,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Month'),
                  items: [
                    for (var i = 0; i < _monthNames.length; i++)
                      DropdownMenuItem<int>(
                        value: i + 1,
                        child: Text(_monthNames[i]),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) update(() => month = value);
                  },
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<int>(
                  initialValue: year,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Year'),
                  items: [
                    for (final value in availableYears)
                      DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) update(() => year = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(DateTime(year, month)),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (selected != null &&
        selected.year == result.year &&
        selected.month == result.month) {
      return;
    }
    setState(() {
      onSaved(result);
      _filtersDirty = true;
    });
  }

  Future<void> _editFilter<T>({
    required String title,
    required List<_DashboardFilterOption<T>> options,
    required Set<T> selected,
    required ValueChanged<Set<T>> onSaved,
  }) async {
    final chosen = Set<T>.from(selected);
    final result = await showDialog<Set<T>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Select $title'),
          content: SizedBox(
            width: 390,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => update(() {
                          chosen
                            ..clear()
                            ..addAll(options.map((option) => option.value));
                        }),
                        child: const Text('Select All'),
                      ),
                      TextButton(
                        onPressed: () => update(chosen.clear),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const Divider(),
                  if (options.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No available options.'),
                    ),
                  for (final option in options)
                    CheckboxListTile(
                      key: ValueKey('${title}_${option.value}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: AppColors.red,
                      title: Text(option.label),
                      value: chosen.contains(option.value),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          chosen.add(option.value);
                        } else {
                          chosen.remove(option.value);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(Set<T>.from(chosen)),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.length == selected.length && selected.containsAll(result)) {
      return;
    }
    setState(() {
      onSaved(result);
      _filtersDirty = true;
    });
  }

  String _filterSummary<T>(
    List<_DashboardFilterOption<T>> options,
    Set<T> selected,
  ) {
    if (selected.isEmpty) return 'Choose...';
    if (options.isNotEmpty &&
        selected.length == options.length &&
        options.every((option) => selected.contains(option.value))) {
      return 'All (${options.length})';
    }
    if (selected.length == 1) {
      for (final option in options) {
        if (selected.contains(option.value)) return option.label;
      }
    }
    return '${selected.length} selected';
  }

  Widget _buildDashboardCategorySelector() {
    final options = <String, String>{
      'staff': 'Staff',
      'lifts': 'Lifts',
      'maintenance': 'Maintenance',
      'complaints': 'Complaints',
      'occupancy': 'Occupancy',
      if (_canViewFinance) 'finance': 'Finance',
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DropdownButtonFormField<String>(
            key: ValueKey('dashboard_category_$_selectedDashboardCategory'),
            initialValue: options.containsKey(_selectedDashboardCategory)
                ? _selectedDashboardCategory : 'staff',
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Category',
              prefixIcon: Icon(
                Icons.dashboard_customize_outlined,
                color: Color(0xFF4F87D9),
              ),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final item in options.entries)
                DropdownMenuItem<String>(
                  value: item.key,
                  child: Text(item.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              final enteringFinance = value == 'finance' &&
                  _selectedDashboardCategory != 'finance';
              if (value != _selectedDashboardCategory || value == 'finance') {
                setState(() {
                  _selectedDashboardCategory = value;
                  if (value == 'finance') {
                    _selectedFinanceTab = _FinanceDashboardTab.financialOverview;
                    if (enteringFinance) _defaultersVisited = false;
                  }
                });
              }
            },
          ),
        ),
      ),
    );
  }

  void _selectDashboardTab(_FinanceDashboardTab tab) {
    if (_selectedFinanceTab == tab) return;
    setState(() {
      _selectedFinanceTab = tab;
      if (tab == _FinanceDashboardTab.defaulters) {
        _defaultersVisited = true;
      }
    });
  }

  Widget _dashboardTab({
    required _FinanceDashboardTab tab,
    required String label,
    required IconData icon,
  }) {
    final selected = _selectedFinanceTab == tab;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? const Color(0xFF111111) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _selectDashboardTab(tab),
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17, color: selected ? Colors.white : const Color(0xFF6D7178)),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : const Color(0xFF6D7178),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
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

  Widget _dashboardTabs() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F6F7),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE3E5E8)),
    ),
    child: Row(
      children: [
        Expanded(
          child: _dashboardTab(
            tab: _FinanceDashboardTab.financialOverview,
            label: 'Overview',
            icon: Icons.analytics_outlined,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _dashboardTab(
            tab: _FinanceDashboardTab.defaulters,
            label: 'Defaulters',
            icon: Icons.people_outline,
          ),
        ),
      ],
    ),
  );

  // Offstage sections occupy no dashboard height. Retaining their state
  // preserves chart controls, expanded panels and loaded data between tabs.
  // AnimatedOpacity sits outside Visibility so the selected panel can fade in
  // even while the hidden panel's own tickers are disabled.
  Widget _dashboardPane({required bool visible, required Widget child}) =>
      AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: MediaQuery.of(context).disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Visibility(
          visible: visible,
          maintainState: true,
          child: ExcludeFocus(excluding: !visible, child: child),
        ),
      );

  // Monthly-report eligibility is independent of finance forecast training.
  List<String> _financeMonthsFor(String siteId, {bool excludeTest = false}) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final currentMonth = DateTime(now.year, now.month);
    final months = <String>{};
    for (final report in _availableReports) {
      if (report['site_id']?.toString() != siteId) continue;
      if (excludeTest && _financeClassifications[report['id']?.toString()] == 'test') {
        continue;
      }
      final date = _calendarDate(report['report_month']);
      if (date == null || _monthStart(date).isAfter(currentMonth)) continue;
      months.add('${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}');
    }
    return months.toList()..sort((a, b) => b.compareTo(a));
  }

  // The AI assessment is outside both tabs. It follows the active tab's
  // applied property, not its Start/End selection, and uses the latest
  // eligible reporting month as the anchor for its own range controls.
  Widget _buildOverallFinanceAi() {
    final properties = _propertyOptions;
    if (properties.isEmpty) return const SizedBox.shrink();
    final selected = _selectedFinanceTab == _FinanceDashboardTab.defaulters
        ? _defaultersApplied : _financeApplied;
    final property = properties.where((p) => p.value == selected?.siteId).firstOrNull
        ?? properties.first;
    final siteId = property.value;
    final latest = _financeMonthsFor(siteId, excludeTest: true).firstOrNull;
    if (latest == null) {
      return _messageCard('No eligible reporting months for AI Financial Insights.');
    }
    return AiFinancialInsightsSection(
      key: ValueKey('finance_ai_${siteId}_${latest}_$_financeRefreshRevision'),
      siteId: siteId,
      siteName: property.label,
      reportingMonth: latest,
    );
  }

  Widget _buildFinanceWorkspace() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_canViewAi) ...[
        _buildOverallFinanceAi(),
        const SizedBox(height: 14),
      ],
      _dashboardTabs(),
      const SizedBox(height: 14),
      _dashboardPane(
        visible: _selectedFinanceTab == _FinanceDashboardTab.financialOverview,
        child: _buildFinancePane(defaulters: false),
      ),
      if (_defaultersVisited)
        _dashboardPane(
          visible: _selectedFinanceTab == _FinanceDashboardTab.defaulters,
          child: _buildFinancePane(defaulters: true),
        ),
    ],
  );

  /// Finance remains a single-property view. Only Apply changes the applied
  /// period; draft edits do not trigger analytics reads.
  Widget _buildFinancePane({required bool defaulters}) {
    final properties = _propertyOptions;
    if (properties.isEmpty) return _messageCard('No properties are available.');
    final ids = properties.map((option) => option.value).toSet();
    // Independent from the general Dashboard filters.
    final fallbackSite = properties.first.value;
    // Defaulters are operational records, not finance-analytics training data.
    // Include saved current and past reports even if analytics marks them as test.
    List<String> monthsFor(String siteId) => _financeMonthsFor(siteId);

    String qualityFor(String siteId, String month) {
      final report = _availableReports.where((row) =>
          row['site_id']?.toString() == siteId &&
          (row['report_month']?.toString() ?? '').startsWith(month)).firstOrNull;
      return (_financeClassifications[report?['id']?.toString()] ?? 'assumed_valid')
          .toLowerCase();
    }

    _FinanceSelection defaults(String siteId) {
      final months = monthsFor(siteId);
      // Defaulters default to the latest saved, non-future month, regardless
      // of analytics classification. Overview retains its non-test preference.
      final latest = defaulters
          ? months.firstOrNull
          : (months.where((month) =>
              qualityFor(siteId, month) != 'test').firstOrNull ?? months.firstOrNull);
      return (siteId: siteId, from: latest, to: latest);
    }

    _FinanceSelection normalize(_FinanceSelection? selection) {
      if (selection == null || !ids.contains(selection.siteId)) {
        return defaults(fallbackSite);
      }
      final months = monthsFor(selection.siteId);
      final fallback = defaults(selection.siteId);
      final end = months.contains(selection.to) ? selection.to : fallback.to;
      final start = months.contains(selection.from) && end != null &&
          selection.from!.compareTo(end) <= 0 ? selection.from :
          (fallback.from != null && end != null && fallback.from!.compareTo(end) <= 0
              ? fallback.from : end);
      return (siteId: selection.siteId, from: start, to: end);
    }

    final applied = normalize(defaulters ? _defaultersApplied : _financeApplied);
    final savedDraft = defaulters ? _defaultersDraft : _financeDraft;
    final draft = savedDraft == null ? applied : normalize(savedDraft);
    void saveDraft(_FinanceSelection value) {
      if (defaulters) {
        _defaultersDraft = value;
      } else {
        _financeDraft = value;
      }
    }
    void apply(_FinanceSelection value) {
      if (defaulters) {
        _defaultersApplied = value;
        _defaultersDraft = null;
        _defaultersFilterRevision++;
      } else {
        _financeApplied = value;
        _financeDraft = null;
        _financeFilterRevision++;
      }
    }
    final dirty = draft != applied;
    final draftMonths = monthsFor(draft.siteId);
    final siteId = applied.siteId;
    final from = applied.from;
    final to = applied.to;
    final propertyName = properties.firstWhere((item) => item.value == siteId).label;
    final draftName = properties.firstWhere((item) => item.value == draft.siteId).label;
    String periodLabel(String? month) => month == null ? 'Choose month & year' :
        _monthLabel(DateTime.parse('$month-01'));

    Future<void> pickValue({
      required String title,
      required List<_DashboardFilterOption<String>> options,
      required String? selected,
      required ValueChanged<String> onSaved,
    }) async {
      final result = await showDialog<String>(context: context,
        builder: (dialogContext) => SimpleDialog(
          title: Text('Select $title'),
          children: [for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(option.value),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Icon(selected == option.value ? Icons.radio_button_checked :
                      Icons.radio_button_unchecked,
                      size: 20, color: selected == option.value ? AppColors.red : AppColors.grey),
                  const SizedBox(width: 10),
                  Expanded(child: Text(option.label)),
                ]),
              ),
            ),
          ],
        ),
      );
      if (result == null || !mounted) return;
      setState(() => onSaved(result));
    }

    final monthOptions = [for (final month in draftMonths)
      _DashboardFilterOption<String>(month, periodLabel(month))];
    final reportCount = from == null || to == null ? 0 :
        monthsFor(siteId).where((month) => month.compareTo(from) >= 0 &&
            month.compareTo(to) <= 0).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardFilters(
          fields: [
            DashboardFilterField(label: 'Property', summary: draftName,
              onTap: () => pickValue(title: 'Property', options: properties,
                selected: draft.siteId, onSaved: (value) {
                  if (value != draft.siteId) saveDraft(defaults(value));
                })),
            DashboardFilterField(label: 'Start', summary: periodLabel(draft.from),
              onTap: draftMonths.isEmpty ? null : () => pickValue(
                title: 'Start', options: monthOptions, selected: draft.from,
                onSaved: (value) => saveDraft((siteId: draft.siteId,
                  from: value, to: draft.to == null || value.compareTo(draft.to!) > 0
                    ? value : draft.to)))),
            DashboardFilterField(label: 'End', summary: periodLabel(draft.to),
              onTap: draftMonths.isEmpty ? null : () => pickValue(
                title: 'End', options: monthOptions, selected: draft.to,
                onSaved: (value) => saveDraft((siteId: draft.siteId,
                  from: draft.from == null || draft.from!.compareTo(value) > 0
                    ? value : draft.from, to: value)))),
          ],
          dirty: dirty,
          compact: true,
          showReset: false,
          onApply: dirty ? () => setState(() => apply(draft)) : null,
          onReset: null,
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.apartment_outlined, size: 15, color: AppColors.grey),
          const SizedBox(width: 6),
          Expanded(child: Text('$propertyName | ${defaulters ? 'Defaulters' : 'Overview'}: $reportCount monthly report(s)',
            style: const TextStyle(fontSize: 11, color: AppColors.grey,
              fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 14),
        if (from == null || to == null)
          _messageCard('No reporting months are available for this property.')
        else if (defaulters)
          DashboardDefaulters(
            key: ValueKey('dashboard_defaulters_$siteId'),
            siteId: siteId,
            start: DateTime.parse('$from-01'),
            end: DateTime.parse('$to-01'),
            reports: _availableReports,
            refreshRevision: _financeRefreshRevision,
            filterRevision: _defaultersFilterRevision,
          )
        else ...[
          FinanceDashboardSection(
            // Keep analytics state mounted for the same property. Start/End
            // update Financial Overview only; the child checks change tokens.
            key: ValueKey('finance_dashboard_$siteId'),
            sites: _sites,
            reports: _availableReports,
            initialSiteId: siteId,
            initialMonth: DateTime.parse('$to-01'),
            initialFromMonth: DateTime.parse('$from-01'),
            showSelectors: false,
            allowAdminForecastPreview: _canViewAi,
            refreshRevision: _financeRefreshRevision,
            filterRevision: _financeFilterRevision,
          ),
        ],
      ],
    );
  }

  Widget _buildFilters() {
    final properties = _propertyOptions;
    return DashboardFilters(
      fields: [
        DashboardFilterField(
          label: 'Property', summary: _filterSummary(properties, _selectedProperties),
          onTap: () => _editFilter<String>(title: 'Property', options: properties,
            selected: _selectedProperties, onSaved: (values) => _selectedProperties = values),
        ),
        DashboardFilterField(label: 'Start', summary: _selectedStartPeriod == null
            ? 'Choose month & year' : _monthLabel(_selectedStartPeriod!),
          onTap: () => _editPeriodFilter(label: 'Start', selected: _selectedStartPeriod,
            onSaved: (value) => _selectedStartPeriod = value)),
        DashboardFilterField(label: 'End', summary: _selectedEndPeriod == null
            ? 'Choose month & year' : _monthLabel(_selectedEndPeriod!),
          onTap: () => _editPeriodFilter(label: 'End', selected: _selectedEndPeriod,
            onSaved: (value) => _selectedEndPeriod = value)),
      ],
      dirty: _filtersDirty,
      onApply: _loading ? null : _applyFilters,
      onReset: _loading ? null : () {
        setState(_restoreDefaultFilters);
        _applyFilters();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.profile['full_name']?.toString().trim();
    final isAdmin = widget.profile['role'] == 'admin';
    final isStaff = widget.profile['role'] == 'staff';

    final greetingName = name == null || name.isEmpty
      ? (isStaff ? 'Staff' : 'Admin')
      : name;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppCommonAppBar(
        title: 'Dashboard',
        onRefresh: () {
          widget.onRefresh();
          _loadDashboard();
        },
      ),
      body: LayoutBuilder(
builder: (context, bounds) {
          final narrow = bounds.maxWidth < 650;
          return ListView(
            padding: EdgeInsets.all(narrow ? 14 : 24),
            children: [
            // Welcome banner for Admin and Staff users.
            if (isAdmin || isStaff) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  color: AppColors.black,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            isAdmin
                                ? Icons.admin_panel_settings_outlined
                                : Icons.person_outline,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            isAdmin
                                ? 'ADMINISTRATOR WORKSPACE'
                                : 'STAFF WORKSPACE',
                            style: const TextStyle(
                              color: Color(0xFFE2E2E2),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome, $greetingName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isAdmin
                          ? 'Manage properties, staff accounts and the monthly report workspace.'
                          : 'Manage your assigned properties and monthly reports.',
                      style: const TextStyle(
                        color: Color(0xFFD0D0D0),
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Management summary cards remain Admin only.
            if (isAdmin) ...[
                if (narrow)
                  Column(
                    children: [
                      _summaryCard(
                        title: 'Total Properties',
                        value: _propertyCount?.toString() ?? '-',
                        icon: Icons.apartment_outlined,
                        onTap: widget.onManageProperties,
                      ),
                      const SizedBox(height: 12),
                      _summaryCard(
                        title: 'Total Staff',
                        value: _staffAccountCount?.toString() ?? '-',
                        icon: Icons.people_outline,
                        onTap: widget.onManageStaff,
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: _summaryCard(
                          title: 'Total Properties',
                          value: _propertyCount?.toString() ?? '-',
                          icon: Icons.apartment_outlined,
                          onTap: widget.onManageProperties,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _summaryCard(
                          title: 'Total Staff',
                          value: _staffAccountCount?.toString() ?? '-',
                          icon: Icons.people_outline,
                          onTap: widget.onManageStaff,
                        ),
                      ),
                    ],
                  ),
                if (_managementWarning != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _managementWarning!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.error,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
              ],
              _buildDashboardCategorySelector(),
              const SizedBox(height: 14),
              if (_selectedDashboardCategory == 'finance' && _canViewFinance) ...[
                // AI is outside the Overview/Defaulters tabs and uses its own range.
                // Gemini is intentionally NOT shown for non-finance categories.
                _buildFinanceWorkspace(),
              ] else ...[
                // All existing filters/charts stay exactly as before.
                _buildFilters(),
                const SizedBox(height: 18),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_reportData == null)
                  _messageCard(
                    _reportWarning ?? 'No dashboard data is available.',
                  )
                else ...[
                  _reportContext(_reportData!),
                  const SizedBox(height: 14),
                  _buildReportCharts(_reportData!),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.red, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.grey,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                        color: AppColors.black,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.red),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reportContext(_DashboardReportData data) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.apartment_outlined, size: 16, color: AppColors.grey),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              data.description,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _messageCard(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.grey)),
  );

  Widget _chartCard({
    required String label,
    required Widget child,
    Color accent = const Color(0xFF5097F5),
  }) => Container(
    constraints: const BoxConstraints(minHeight: 302),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(14),
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
                color: accent,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.black,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );

  Widget _noRecordsChart() => const SizedBox(
    height: 176,
    child: Center(
      child: Text(
        'No records available.',
        style: TextStyle(color: AppColors.grey),
      ),
    ),
  );

  Widget _metricCard(String label, String value, IconData icon, Color color) {
    return DashboardMetricSurface(
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 23,
                    color: AppColors.black,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricGrid(List<Widget> widgets) =>
      DashboardMetricGrid(children: widgets);

  Widget _largeAndSmall(Widget large, Widget small) => LayoutBuilder(
    builder: (context, bounds) {
      if (bounds.maxWidth < 760) {
        return Column(children: [large, const SizedBox(height: 14), small]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 7, child: large),
          const SizedBox(width: 14),
          Expanded(flex: 4, child: small),
        ],
      );
    },
  );

  Widget _equalCharts(Widget left, Widget right) => LayoutBuilder(
    builder: (context, bounds) {
      if (bounds.maxWidth < 760) {
        return Column(children: [left, const SizedBox(height: 14), right]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: left),
          const SizedBox(width: 14),
          Expanded(child: right),
        ],
      );
    },
  );

  // Omit Security Positions entirely when Security has no active headcount.
  // Without the card, Hourly Staff Coverage uses the full available width.
  Widget _staffCharts(Widget hourly, Widget? positions) => LayoutBuilder(
    builder: (context, bounds) {
      if (positions == null) return hourly;
      if (bounds.maxWidth < 760) {
        return Column(
          children: [hourly, const SizedBox(height: 14), positions],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 7,
            child: SizedBox(height: 370, child: hourly),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 4,
            child: SizedBox(height: 370, child: positions),
          ),
        ],
      );
    },
  );

  Widget _securityPositionChart(_DashboardStaffData staff) {
    if (!staff.securityPositionsEntered) {
      return const SizedBox(
        height: 176,
        child: Center(
          child: Text(
            'Security positions not entered.',
            style: TextStyle(color: AppColors.grey),
          ),
        ),
      );
    }

    Widget roleRow(String name, String shift) {
      final supervisors = staff.securityPositions['${shift}_shift_supervisors'];
      final guards = staff.securityPositions['${shift}_shift_guards'];
      if (supervisors == null || guards == null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Not entered',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ],
        );
      }
      final total = supervisors + guards;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '$total Pax',
                style: const TextStyle(fontSize: 12, color: AppColors.grey),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                if (total <= 0)
                  Expanded(
                    child: Container(
                      height: 13,
                      color: const Color(0xFFE8ECF1),
                    ),
                  )
                else ...[
                  if (supervisors > 0)
                    Expanded(
                      flex: supervisors,
                      child: Container(
                        height: 13,
                        color: const Color(0xFF4D9DDB),
                      ),
                    ),
                  if (guards > 0)
                    Expanded(
                      flex: guards,
                      child: Container(
                        height: 13,
                        color: const Color(0xFF36B49C),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Supervisors: $supervisors    Guards: $guards',
            style: const TextStyle(fontSize: 11, color: AppColors.grey),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        roleRow('Day Shift', 'day'),
        const SizedBox(height: 20),
        roleRow('Night Shift', 'night'),
        if (staff.securityPositionsIncomplete) ...[
          const SizedBox(height: 15),
          const Text(
            'Some Security positions are not yet entered.',
            style: TextStyle(color: Color(0xFF9C6B19), fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _buildReportCharts(_DashboardReportData data) {
    const blue = Color(0xFF5097F5);
    const teal = Color(0xFF36AD98);
    const amber = Color(0xFFD29C49);
    const purple = Color(0xFF8B7ACF);
    const red = Color(0xFFD66B74);
    Widget section(String title, List<Widget> widgets) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.black,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < widgets.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          widgets[i],
        ],
      ],
    );

    switch (_selectedDashboardCategory) {
      case 'staff':
        final total = data.staff.counts.values.fold<int>(
          0,
          (sum, value) => sum + value,
        );
        final day = data.staff.shifts['Day shift'] ?? 0;
        final night = data.staff.shifts['Night shift'] ?? 0;
        final hasSecurity = (data.staff.counts['Security'] ?? 0) > 0;
        final currentCategories = <String>[
          for (final category in _dashboardStaffCategories)
            if ((data.staff.counts[category] ?? 0) > 0) category,
        ];
        final headcountCategories = <String>[
          for (final category in _dashboardStaffCategories)
            if (data.staff.monthlyHeadcountByCategory[category]?.any(
                  (value) => value != null && value > 0,
                ) ??
                false)
              category,
        ];
        final shiftCategories = <String>[
          for (final category in _dashboardStaffCategories)
            if (data.staff.monthlyShiftsByCategory[category]?.any(
                  (value) => value != null && value > 0,
                ) ??
                false)
              category,
        ];
        final hourlyBreakdown = <String, List<int?>>{
          for (final category in currentCategories)
            category: [
              for (var hour = 0; hour < 24; hour++)
                data.staff.hourlyByCategory[category] == null
                    ? 0
                    : data.staff.hourlyByCategory[category]![
                        _staffHourlyWeekday - 1
                      ][hour],
              // Actual midnight coverage for the following day.
              data.staff.hourlyByCategory[category] == null
                  ? 0
                  : data.staff.hourlyByCategory[category]![
                      _staffHourlyWeekday % 7
                    ][0],
            ],
        };
        return section('Staff', [
          _metricGrid([
            _metricCard(
              'Total Staff',
              data.staff.entered ? '$total' : '--',
              Icons.people_outline,
              blue,
            ),
            _metricCard(
              'Day Shift',
              data.staff.shiftEntered ? '$day' : '--',
              Icons.wb_sunny_outlined,
              teal,
            ),
            _metricCard(
              'Night Shift',
              data.staff.shiftEntered ? '$night' : '--',
              Icons.nights_stay_outlined,
              purple,
            ),
          ]),
          _staffCharts(
            _chartCard(
              label: 'HOURLY STAFF COVERAGE',
              accent: blue,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Day', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 10),
                      DropdownButton<int>(
                        value: _staffHourlyWeekday,
                        isDense: true,
                        items: [
                          for (var day = 1; day <= 7; day++)
                            DropdownMenuItem<int>(
                              value: day,
                              child: Text(
                                const <String>[
                                  'Monday',
                                  'Tuesday',
                                  'Wednesday',
                                  'Thursday',
                                  'Friday',
                                  'Saturday',
                                  'Sunday',
                                ][day - 1],
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _staffHourlyWeekday = value);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  data.staff.hourlyEntered && currentCategories.isNotEmpty
                      ? _DashboardStackedBars(
                          labels: [
                            for (var hour = 0; hour <= 24; hour++)
                              '${(hour % 24).toString().padLeft(2, '0')}:00',
                          ],
                          categories: currentCategories,
                          valuesByCategory: hourlyBreakdown,
                          colors: _dashboardStaffColors,
                          tooltipUnit: 'Pax',
                          hourly: true,
                          yAxisTickInterval: 2,
                          yAxisMinimumMaximum: 14,
                        )
                      : _noRecordsChart(),
                ],
              ),
            ),
            hasSecurity
                ? _chartCard(
                    label: 'SECURITY POSITIONS',
                    accent: teal,
                    child: _securityPositionChart(data.staff),
                  )
                : null,
          ),
          _equalCharts(
            _chartCard(
              label: 'MONTHLY HEADCOUNT',
              accent: blue,
              child: headcountCategories.isNotEmpty &&
                      data.staff.monthlyHeadcount.any((v) => v != null)
                  ? _DashboardStackedBars(
                      labels: data.staff.monthLabels,
                      categories: headcountCategories,
                      valuesByCategory: data.staff.monthlyHeadcountByCategory,
                      colors: _dashboardStaffColors,
                      tooltipUnit: 'Pax',
                    )
                  : _noRecordsChart(),
            ),
            _chartCard(
              label: 'MONTHLY STAFF-SHIFTS',
              accent: teal,
              child: shiftCategories.isNotEmpty &&
                      data.staff.monthlyStaffShifts.any((v) => v != null)
                  ? _DashboardStackedBars(
                      labels: data.staff.staffShiftMonthLabels,
                      categories: shiftCategories,
                      valuesByCategory: data.staff.monthlyShiftsByCategory,
                      colors: _dashboardStaffColors,
                      tooltipUnit: 'Staff-shifts',
                    )
                  : _noRecordsChart(),
            ),
          ),
        ]);
      case 'lifts':
        final incidents = data.liftByMonth.fold<int>(0, (a, b) => a + b);
        return section('Lifts', [
          _metricGrid([
            _metricCard(
              'Incidents',
              '$incidents',
              Icons.report_problem_outlined,
              blue,
            ),
            _metricCard(
              'Mantrap',
              '${data.mantrap['Yes'] ?? 0}',
              Icons.warning_amber_outlined,
              red,
            ),
            _metricCard(
              'Lifts Affected',
              '${data.liftByLift.length}',
              Icons.elevator_outlined,
              amber,
            ),
          ]),
          _largeAndSmall(
            _chartCard(
              label: 'MONTHLY LIFT INCIDENTS',
              accent: blue,
              child: incidents == 0
                  ? _noRecordsChart()
                  : _DashboardLineChart(
                      labels: data.liftMonths,
                      values: data.liftByMonth
                          .map((v) => v.toDouble())
                          .toList(),
                      color: blue,
                    ),
            ),
            _chartCard(
              label: 'MANTRAP BREAKDOWN',
              accent: red,
              child: incidents == 0
                  ? _noRecordsChart()
                  : _DashboardDonut(
                      values: data.mantrap,
                      centerCaption: 'Incidents',
                      colors: const [red, teal, Color(0xFF9CA3AF)],
                    ),
            ),
          ),
          _chartCard(
            label: 'INCIDENTS BY LIFT',
            accent: amber,
            child: data.liftByLift.isEmpty
                ? _noRecordsChart()
                : _DashboardRankingBars(values: data.liftByLift, color: amber),
          ),
        ]);
      case 'maintenance':
        final stats = data.maintenance;
        final works = stats.values.fold<int>(0, (a, b) => a + b);
        return section('Maintenance & Upgrading', [
          _metricGrid([
            _metricCard(
              'Work Records',
              '$works',
              Icons.handyman_outlined,
              blue,
            ),
            _metricCard(
              'Completed',
              '${stats['Completed'] ?? 0}',
              Icons.check_circle_outline,
              teal,
            ),
            _metricCard(
              'In Progress',
              '${stats['In Progress'] ?? 0}',
              Icons.build_outlined,
              amber,
            ),
            _metricCard(
              'Overdue',
              '${stats['Overdue'] ?? 0}',
              Icons.error_outline,
              red,
            ),
          ]),
          _largeAndSmall(
            _chartCard(
              label: 'MONTHLY MAINTENANCE WORKS',
              accent: blue,
              child: data.maintenanceByMonth.every((v) => v == 0)
                  ? _noRecordsChart()
                  : _DashboardLineChart(
                      labels: data.maintenanceMonths,
                      values: data.maintenanceByMonth
                          .map((v) => v.toDouble())
                          .toList(),
                      color: blue,
                      yAxisTickInterval: 2,
                      yAxisMinimumMaximum: 10,
                    ),
            ),
            _chartCard(
              label: 'WORK STATUS',
              accent: teal,
              child: works == 0
                  ? _noRecordsChart()
                  : _DashboardDonut(
                      values: stats,
                      centerCaption: 'Works',
                      colors: const [teal, blue, amber, Color(0xFF9CA3AF), red],
                    ),
            ),
          ),
        ]);
      case 'complaints':
        final stats = data.complaints;
        final total = stats.values.fold<int>(0, (a, b) => a + b);
        return section('Complaints', [
          _metricGrid([
            _metricCard(
              'Complaint Records',
              '$total',
              Icons.feedback_outlined,
              blue,
            ),
            _metricCard(
              'Completed',
              '${stats['Completed'] ?? 0}',
              Icons.task_alt_outlined,
              teal,
            ),
            _metricCard(
              'In Progress',
              '${stats['In Progress'] ?? 0}',
              Icons.autorenew,
              red,
            ),
          ]),
          _largeAndSmall(
            _chartCard(
              label: 'MONTHLY COMPLAINTS RECEIVED',
              accent: blue,
              child: data.complaintReceivedByMonth.every((v) => v == 0)
                  ? _noRecordsChart()
                  : _DashboardLineChart(
                      labels: data.complaintMonths,
                      values: data.complaintReceivedByMonth
                          .map((v) => v.toDouble())
                          .toList(),
                      color: blue,
                    ),
            ),
            _chartCard(
              label: 'COMPLAINT STATUS',
              accent: purple,
              child: total == 0
                  ? _noRecordsChart()
                  : _DashboardDonut(
                      values: stats,
                      centerCaption: 'Complaints',
                      colors: const [teal, red],
                    ),
            ),
          ),
          _chartCard(
            label: 'MONTHLY COMPLAINTS COMPLETED',
            accent: teal,
            child: data.complaintCompletedByMonth.every((v) => v == 0)
                ? _noRecordsChart()
                : _DashboardBars(
                    labels: data.complaintMonths,
                    values: data.complaintCompletedByMonth,
                  ),
          ),
        ]);
      case 'occupancy':
        final owner = data.occupancy['Owner-occupied'] ?? 0;
        final tenant = data.occupancy['Tenanted'] ?? 0;
        final vacant = data.occupancy['Vacant'] ?? 0;
        final base = data.totalUnits;
        final hasOccupancy = data.occupancy.values.any((v) => v > 0);
        String percent(int value) => base > 0 && hasOccupancy
            ? '${(100 * value / base).toStringAsFixed(1)}%'
            : '--';
        return section('Occupancy', [
          _metricGrid([
            _metricCard(
              'Occupied',
              percent(owner + tenant),
              Icons.apartment_outlined,
              teal,
            ),
            _metricCard(
              'Owner-occupied',
              percent(owner),
              Icons.home_outlined,
              blue,
            ),
            _metricCard(
              'Tenanted',
              percent(tenant),
              Icons.key_outlined,
              purple,
            ),
            _metricCard(
              'Vacant',
              percent(vacant),
              Icons.home_work_outlined,
              amber,
            ),
          ]),
          _largeAndSmall(
            _chartCard(
              label: 'MONTHLY OCCUPANCY RATE',
              accent: teal,
              child: data.occupancyRates.any((v) => v != null)
                  ? _DashboardLineChart(
                      labels: data.occupancyRateMonths,
                      values: data.occupancyRates,
                      color: teal,
                      suffix: '%',
                      percentage: true,
                    )
                  : _noRecordsChart(),
            ),
            _chartCard(
              label: 'OCCUPANCY BREAKDOWN (%)',
              accent: purple,
              child: !hasOccupancy || base <= 0
                  ? _noRecordsChart()
                  : _DashboardDonut(
                      values: data.occupancy,
                      centerCaption: 'Units',
                      colors: const [blue, teal, amber, Color(0xFF9CA3AF)],
                      asPercent: true,
                      percentageBase: base,
                    ),
            ),
          ),
        ]);
      default:
        return _messageCard('Select a dashboard category.');
    }
  }
}

class _DashboardFilterOption<T> {
  final T value;
  final String label;

  const _DashboardFilterOption(this.value, this.label);
}

class _DashboardSiteSource {
  final Map<String, DateTime> reportMonths;
  final List<Map<String, dynamic>> maintenance;
  final Map<String, List<Map<String, dynamic>>> maintenanceUpdates;
  final List<Map<String, dynamic>> complaints;
  final Map<String, List<Map<String, dynamic>>> complaintUpdates;
  final List<Map<String, dynamic>> lifts;
  final List<Map<String, dynamic>> occupancy;
  final List<Map<String, dynamic>> providers;
  final List<Map<String, dynamic>> effectiveStaff;
  final List<Map<String, dynamic>> directStaff;
  final int totalUnits;

  const _DashboardSiteSource({
    required this.reportMonths,
    required this.maintenance,
    required this.maintenanceUpdates,
    required this.complaints,
    required this.complaintUpdates,
    required this.lifts,
    required this.occupancy,
    required this.providers,
    required this.effectiveStaff,
    required this.directStaff,
    required this.totalUnits,
  });
}

class _DashboardReportData {
  final String description;
  final String periodTitle;
  final bool multiplePeriods;
  final Map<String, int> maintenance;
  final Map<String, int> complaints;
  final List<String> liftMonths;
  final List<int> liftByMonth;
  final Map<String, int> liftByLift;
  final Map<String, int> mantrap;
  final List<String> maintenanceMonths;
  final List<int> maintenanceByMonth;
  final List<String> complaintMonths;
  final List<int> complaintReceivedByMonth;
  final List<int> complaintCompletedByMonth;
  final List<String> occupancyRateMonths;
  final List<double?> occupancyRates;
  final int totalUnits;
  final Map<String, int> occupancy;
  final _DashboardStaffData staff;

  const _DashboardReportData({
    required this.description,
    required this.periodTitle,
    required this.multiplePeriods,
    required this.maintenance,
    required this.complaints,
    required this.liftMonths,
    required this.liftByMonth,
    required this.liftByLift,
    required this.mantrap,
    required this.maintenanceMonths,
    required this.maintenanceByMonth,
    required this.complaintMonths,
    required this.complaintReceivedByMonth,
    required this.complaintCompletedByMonth,
    required this.occupancyRateMonths,
    required this.occupancyRates,
    required this.totalUnits,
    required this.occupancy,
    required this.staff,
  });
}

class _DashboardStaffData {
  final Map<String, int> counts;
  final Map<String, int> shifts;
  final Map<String, int> shiftsByCategory;
  final Map<String, int> securityPositions;
  final bool securityPositionsEntered;
  final bool securityPositionsIncomplete;
  final List<List<int>> hourlyByWeekday;
  final Map<String, List<List<int>>> hourlyByCategory;
  final int? scheduledStaffShifts;
  final List<String> monthLabels;
  final List<int?> monthlyHeadcount;
  final Map<String, List<int?>> monthlyHeadcountByCategory;
  final List<String> staffShiftMonthLabels;
  final List<int?> monthlyStaffShifts;
  final Map<String, List<int?>> monthlyShiftsByCategory;
  final bool shiftTrendPartial;
  final bool shiftEntered;
  final bool hourlyEntered;
  final bool incomplete;
  final bool entered;
  final String? warning;

  const _DashboardStaffData({
    required this.counts,
    this.shifts = const <String, int>{},
    this.shiftsByCategory = const <String, int>{},
    this.securityPositions = const <String, int>{},
    this.securityPositionsEntered = false,
    this.securityPositionsIncomplete = false,
    this.hourlyByWeekday = const <List<int>>[],
    this.hourlyByCategory = const <String, List<List<int>>>{},
    this.scheduledStaffShifts,
    this.monthLabels = const <String>[],
    this.monthlyHeadcount = const <int?>[],
    this.monthlyHeadcountByCategory = const <String, List<int?>>{},
    this.staffShiftMonthLabels = const <String>[],
    this.monthlyStaffShifts = const <int?>[],
    this.monthlyShiftsByCategory = const <String, List<int?>>{},
    this.shiftTrendPartial = false,
    this.shiftEntered = false,
    this.hourlyEntered = false,
    this.incomplete = false,
    required this.entered,
    this.warning,
  });

  String get totalLabel => warning != null
      ? 'Unavailable'
      : entered
      ? counts.values.fold<int>(0, (sum, value) => sum + value).toString()
      : 'Not entered';
}


// Colours remain consistent across all Staff breakdown charts.
const List<String> _dashboardStaffCategories = <String>[
  'Security',
  'Cleaning',
  'Landscaping',
];
const Map<String, Color> _dashboardStaffColors = <String, Color>{
  'Security': Color(0xFF4D91F1),
  'Cleaning': Color(0xFF36AD98),
  'Landscaping': Color(0xFFEAA652),
};

// One stacked bar per hour/month with the whole service breakdown on hover.
// Null category values mean missing reports, not zero staffing.
class _DashboardStackedBars extends StatefulWidget {
  final List<String> labels;
  final List<String> categories;
  final Map<String, List<int?>> valuesByCategory;
  final Map<String, Color> colors;
  final String tooltipUnit;
  final bool hourly;
  final int? yAxisTickInterval;
  final int? yAxisMinimumMaximum;

  const _DashboardStackedBars({
    required this.labels,
    required this.categories,
    required this.valuesByCategory,
    required this.colors,
    required this.tooltipUnit,
    this.hourly = false,
    this.yAxisTickInterval,
    this.yAxisMinimumMaximum,
  });

  @override
  State<_DashboardStackedBars> createState() => _DashboardStackedBarsState();
}

class _DashboardStackedBarsState extends State<_DashboardStackedBars> {
  int? _hoveredIndex;

  int? _atPosition(Offset position, Size size) {
    if (widget.labels.isEmpty) return null;
    const left = 42.0;
    const right = 12.0;
    const top = 24.0;
    const bottom = 36.0;
    final plotWidth = size.width - left - right;
    if (plotWidth <= 0 ||
        position.dx < left ||
        position.dx > size.width - right ||
        position.dy < top ||
        position.dy > size.height - bottom) {
      return null;
    }
    final step = plotWidth / widget.labels.length;
    return ((position.dx - left) / step)
        .floor()
        .clamp(0, widget.labels.length - 1)
        .toInt();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.labels.isEmpty) {
      return const SizedBox(
        height: 176,
        child: Center(child: Text('No records available.')),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = math.max(
          bounds.maxWidth,
          widget.hourly
              ? widget.labels.length * 24.0 + 54
              : widget.labels.length * 43.0 + 54,
        );
        final size = Size(width, 238);
        final hovered = _hoveredIndex != null &&
                _hoveredIndex! >= 0 &&
                _hoveredIndex! < widget.labels.length
            ? _hoveredIndex
            : null;
        const left = 42.0;
        const right = 12.0;
        final step = (width - left - right) / widget.labels.length;
        // Show only saved values in hover details. Missing is not zero.
        final hoverIndex = hovered ?? -1;
        final hoveredCategories = <String>[
for (final category in widget.categories)
            if (hoverIndex >= 0 &&
                widget.valuesByCategory[category] != null &&
                hoverIndex < widget.valuesByCategory[category]!.length &&
                widget.valuesByCategory[category]![hoverIndex] != null)
              category,
        ];
        final selectedHasData = hoveredCategories.isNotEmpty;
        final selectedTotal = !selectedHasData
            ? null
            : hoveredCategories.fold<int>(
                0,
                (sum, category) =>
                    sum + widget.valuesByCategory[category]![hoverIndex]!,
              );
        String hoverValue(String category) =>
            '${widget.valuesByCategory[category]![hoverIndex]!}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                height: size.height,
                child: MouseRegion(
                  onHover: (event) {
                    final next = _atPosition(event.localPosition, size);
                    if (next != _hoveredIndex) {
                      setState(() => _hoveredIndex = next);
                    }
                  },
                  onExit: (_) {
                    if (_hoveredIndex != null) {
                      setState(() => _hoveredIndex = null);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      setState(() => _hoveredIndex =
                          _atPosition(details.localPosition, size));
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _DashboardStackedBarsPainter(
                              labels: widget.labels,
                              categories: widget.categories,
                              valuesByCategory: widget.valuesByCategory,
                              colors: widget.colors,
                              hourly: widget.hourly,
                              yAxisTickInterval: widget.yAxisTickInterval,
                              yAxisMinimumMaximum: widget.yAxisMinimumMaximum,
                              highlighted: hovered,
                            ),
                          ),
                        ),
                        if (hovered != null && selectedHasData)
                          Positioned(
                            left: (left + step * (hovered + 0.5) - 95)
                                .clamp(0.0, math.max(0.0, width - 192))
                                .toDouble(),
                            top: 0,
                            child: IgnorePointer(
                              child: Container(
                                width: 192,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.charcoal,
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: const [
                                    BoxShadow(
                                      blurRadius: 6,
                                      color: Color(0x22000000),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.hourly &&
                                              hovered == widget.labels.length - 1
                                          ? '00:00 (next day)'
                                          : widget.labels[hovered],
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    for (final category in hoveredCategories)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 3),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 7,
                                              height: 7,
                                              color: widget.colors[category] ??
                                                  AppColors.grey,
                                            ),
                                            const SizedBox(width: 5),
                                            Expanded(
                                              child: Text(
                                                category,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              hoverValue(category),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    const Divider(
                                      height: 12,
                                      color: Color(0x55FFFFFF),
                                    ),
                                    Text(
                                      selectedTotal == null
                                          ? 'Total: No data'
                                          : 'Total: $selectedTotal ${widget.tooltipUnit}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
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
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final category in widget.categories)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: widget.colors[category] ?? AppColors.grey,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(category, style: const TextStyle(fontSize: 10)),
                    ],
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _DashboardStackedBarsPainter extends CustomPainter {
  final List<String> labels;
  final List<String> categories;
  final Map<String, List<int?>> valuesByCategory;
  final Map<String, Color> colors;
  final bool hourly;
  final int? yAxisTickInterval;
  final int? yAxisMinimumMaximum;
  final int? highlighted;

  const _DashboardStackedBarsPainter({
    required this.labels,
    required this.categories,
    required this.valuesByCategory,
    required this.colors,
    required this.hourly,
    required this.yAxisTickInterval,
    required this.yAxisMinimumMaximum,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty) return;
    const left = 42.0;
    const right = 12.0;
    const top = 24.0;
    const bottom = 36.0;
    final plotWidth = math.max(1.0, size.width - left - right);
    final plotHeight = size.height - top - bottom;
    final barStep = plotWidth / labels.length;

    int? valueFor(String category, int index) {
      final rows = valuesByCategory[category];
      if (rows == null || index >= rows.length) return null;
      return rows[index];
    }

    int? totalFor(int index) {
      var hasData = false;
      var total = 0;
      for (final category in categories) {
        final value = valueFor(category, index);
        if (value == null) continue;
        hasData = true;
        total += math.max(0, value);
      }
      return hasData ? total : null;
    }

    final maxData = List<int>.generate(labels.length, (i) => totalFor(i) ?? 0)
        .fold<int>(0, math.max);
    final step = yAxisTickInterval ??
        _dashboardNiceStep(math.max(4, maxData));
    final maximum = math.max(
      yAxisMinimumMaximum ?? step,
      ((math.max(1, maxData) + step - 1) ~/ step) * step,
    );
    final grid = Paint()
      ..color = const Color(0xFFE8ECF1)
      ..strokeWidth = 1;

    void drawLabel(String value, double x, double y,
        {TextAlign align = TextAlign.center, double width = 42}) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: value,
          style: const TextStyle(color: AppColors.grey, fontSize: 10),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: width);
      final dx = align == TextAlign.right
          ? x + width - textPainter.width
          : align == TextAlign.center
              ? x + (width - textPainter.width) / 2
              : x;
      textPainter.paint(canvas, Offset(dx, y));
    }

    for (var tick = 0; tick <= maximum; tick += step) {
      final y = top + plotHeight * (1 - tick / maximum);
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      drawLabel('$tick', 0, y - 6, width: left - 7, align: TextAlign.right);
    }

    final maxLabels = math.max(
      2,
      (plotWidth / (hourly ? 68 : 48)).floor(),
    );
    final labelStep = math.max(
      1,
      ((labels.length - 1) / (maxLabels - 1)).ceil(),
    );
    for (var i = 0; i < labels.length; i++) {
      if (i % labelStep != 0 && i != labels.length - 1) continue;
      final centerX = left + barStep * (i + 0.5);
      drawLabel(
        labels[i],
        centerX - 29,
        size.height - bottom + 10,
        width: 58,
      );
    }

    for (var i = 0; i < labels.length; i++) {
      final total = totalFor(i);
      final centerX = left + barStep * (i + 0.5);
      if (total == null) continue;
      final barWidth = math.min(hourly ? 18.0 : 32.0, barStep * 0.72);
      var accumulated = 0;
      for (final category in categories) {
        final value = math.max(0, valueFor(category, i) ?? 0);
        if (value == 0) continue;
        final lower = accumulated;
        accumulated += value;
        final upperY = top + plotHeight * (1 - accumulated / maximum);
        final lowerY = top + plotHeight * (1 - lower / maximum);
        final rectangle = Rect.fromLTWH(
          centerX - barWidth / 2,
          upperY,
          barWidth,
          lowerY - upperY,
        );
        final paint = Paint()..color = colors[category] ?? AppColors.grey;
        canvas.drawRect(rectangle, paint);
        if (highlighted == i) {
          canvas.drawRect(
            rectangle,
            Paint()
              ..color = const Color(0xFFE8ECF1)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }
      if (!hourly && total > 0) {
        final y = top + plotHeight * (1 - total / maximum);
        drawLabel('$total', centerX - 22, y - 17, width: 44);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardStackedBarsPainter oldDelegate) =>
      oldDelegate.labels != labels ||
      oldDelegate.categories != categories ||
      oldDelegate.valuesByCategory != valuesByCategory ||
      oldDelegate.colors != colors ||
      oldDelegate.highlighted != highlighted;
}

// Charts are drawn with Flutter Canvas. No new chart dependency is needed.
// Legends always show the values; hovering the coloured segment or bar shows
// the same value in a tooltip. Zero-value pie segments are omitted.
class _DashboardPiePart {
  final String name;
  final int value;
  final Color color;

  const _DashboardPiePart(this.name, this.value, this.color);
}

class _DashboardDonut extends StatefulWidget {
  final Map<String, int> values;
  final List<Color> colors;
  final String centerCaption;
  final bool asPercent;
  final int? percentageBase;

  const _DashboardDonut({
    required this.values,
    required this.colors,
    this.centerCaption = 'Records',
    this.asPercent = false,
    this.percentageBase,
  });

  @override
  State<_DashboardDonut> createState() => _DashboardDonutState();
}

class _DashboardDonutState extends State<_DashboardDonut> {
  int? _hoveredIndex;

  List<_DashboardPiePart> get _visibleParts {
    final entries = widget.values.entries.toList();
    final output = <_DashboardPiePart>[];
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].value <= 0) continue;
      output.add(
        _DashboardPiePart(
          entries[i].key,
          entries[i].value,
          widget.colors[i % widget.colors.length],
        ),
      );
    }
    return output;
  }

  int? _hitTest(Offset position, List<_DashboardPiePart> parts) {
    const radius = 88.0;
    final dx = position.dx - radius;
    final dy = position.dy - radius;
    final distance = math.sqrt(dx * dx + dy * dy);
    // Painter uses radius 73 and 29px strokes for a 176px square.
    if (distance < 56 || distance > 90) return null;
    final total = parts.fold<int>(0, (sum, item) => sum + item.value);
    if (total <= 0) return null;
    final angle =
        (math.atan2(dy, dx) + math.pi / 2 + math.pi * 2) % (math.pi * 2);
    var cursor = 0.0;
    for (var i = 0; i < parts.length; i++) {
      cursor += math.pi * 2 * parts[i].value / total;
      if (angle <= cursor) return i;
    }
    return parts.length - 1;
  }

  void _updateHover(Offset local, List<_DashboardPiePart> parts) {
    final next = _hitTest(local, parts);
    if (next != _hoveredIndex) setState(() => _hoveredIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    final parts = _visibleParts;
    final total = parts.fold<int>(0, (sum, part) => sum + part.value);
    final base = widget.percentageBase ?? total;
    if (parts.isEmpty) {
      return const SizedBox(
        height: 176,
        child: Center(
          child: Text(
            'No records available.',
            style: TextStyle(color: AppColors.grey),
          ),
        ),
      );
    }
    final active =
        _hoveredIndex != null &&
            _hoveredIndex! >= 0 &&
            _hoveredIndex! < parts.length
        ? parts[_hoveredIndex!]
        : null;

    String percentOf(int value) =>
        base <= 0 ? '-' : (value * 100 / base).toStringAsFixed(1);

    return Column(
      children: [
        SizedBox(
          height: 186,
          child: Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              onHover: (event) => _updateHover(event.localPosition, parts),
              onExit: (_) {
                if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _updateHover(details.localPosition, parts),
                child: SizedBox(
                  width: 176,
                  height: 176,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _DashboardDonutPainter(
                            parts: parts,
                            highlighted: _hoveredIndex,
                          ),
                        ),
                      ),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.asPercent
                                  ? (base > 0
                                        ? '${(total / base * 100).toStringAsFixed(1)}%'
                                        : '-')
                                  : '$total',
                              style: const TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.w900,
                                color: AppColors.black,
                              ),
                            ),
                            Text(
                              widget.asPercent ? 'Total' : widget.centerCaption,
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (active != null)
                        Positioned(
                          top: 1,
                          left: -18,
                          child: IgnorePointer(
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 210),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.charcoal,
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: const [
                                  BoxShadow(
                                    blurRadius: 7,
                                    color: Color(0x33000000),
                                  ),
                                ],
                              ),
                              child: Text(
                                '${active.name}: ${active.value}'
                                '${widget.asPercent ? ' (${percentOf(active.value)}%)' : ''}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final part in parts)
              Tooltip(
                message:
                    '${part.name}: ${part.value}'
                    '${widget.asPercent ? ' (${percentOf(part.value)}%)' : ''}',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: part.color,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      widget.asPercent
                          ? '${part.name} (${part.value} · ${percentOf(part.value)}%)'
                          : '${part.name} (${part.value})',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.black,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DashboardDonutPainter extends CustomPainter {
  final List<_DashboardPiePart> parts;
  final int? highlighted;

  const _DashboardDonutPainter({
    required this.parts,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: math.min(size.width, size.height) / 2 - 15,
    );
    final paint = Paint()..style = PaintingStyle.stroke;
    final total = parts.fold<int>(0, (sum, part) => sum + part.value);
    if (total <= 0) {
      paint
        ..strokeWidth = 29
        ..color = const Color(0xFFE8ECF1);
      canvas.drawArc(rect, 0, math.pi * 2, false, paint);
      return;
    }
    var start = -math.pi / 2;
    for (var i = 0; i < parts.length; i++) {
      final angle = math.pi * 2 * parts[i].value / total;
      paint
        ..strokeWidth = highlighted == i ? 34 : 29
        ..color = parts[i].color;
      canvas.drawArc(rect, start, angle, false, paint);
      start += angle;
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardDonutPainter oldDelegate) => true;
}

// Choose 1/2/5/10-based ticks so large staff-shift values have a readable Y axis.
int _dashboardNiceStep(int maximum) {
  if (maximum <= 4) return 1;
  final target = maximum / 4.0;
  final magnitude = math
      .pow(10, (math.log(target) / math.ln10).floor())
      .toInt();
  if (target <= magnitude) return magnitude;
  if (target <= magnitude * 2) return magnitude * 2;
  if (target <= magnitude * 5) return magnitude * 5;
  return magnitude * 10;
}

class _DashboardBars extends StatefulWidget {
  final List<String> labels;
  final List<int?> values;

  const _DashboardBars({required this.labels, required this.values});

  @override
  State<_DashboardBars> createState() => _DashboardBarsState();
}

class _DashboardBarsState extends State<_DashboardBars> {
  int? _hoveredIndex;

  int? _barAt(Offset position, Size size) {
    if (widget.labels.isEmpty) return null;
    const left = 32.0;
    const right = 8.0;
    const top = 18.0;
    const bottom = 67.0;
    final chartHeight = size.height - top - bottom;
    final step = (size.width - left - right) / widget.labels.length;
    if (step <= 0) return null;
    final index = ((position.dx - left) / step).floor();
    if (index < 0 || index >= widget.labels.length) return null;
    final value = index < widget.values.length ? widget.values[index] : null;
    if (value == null || value <= 0) return null;
    final maxValue = widget.values.whereType<int>().fold<int>(
      4,
      (a, b) => math.max(a, b),
    );
    final tickStep = _dashboardNiceStep(maxValue);
    final maxTick = ((maxValue + tickStep - 1) ~/ tickStep) * tickStep;
    final centerX = left + step * (index + 0.5);
    final barWidth = math.min(29.0, step * 0.56);
    final barHeight = chartHeight * value / maxTick;
    if (position.dx < centerX - barWidth / 2 ||
        position.dx > centerX + barWidth / 2 ||
        position.dy < top + chartHeight - barHeight ||
        position.dy > top + chartHeight) {
      return null;
    }
    return index;
  }

  void _updateHover(Offset position, Size size) {
    final next = _barAt(position, size);
    if (next != _hoveredIndex) setState(() => _hoveredIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.labels.isEmpty) {
      return const Text('No chart data available.');
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final chartWidth = math.max(
          bounds.maxWidth,
          42.0 * widget.labels.length + 42,
        );
        final chartSize = Size(chartWidth, 238);
        final hovered =
            _hoveredIndex != null &&
                _hoveredIndex! >= 0 &&
                _hoveredIndex! < widget.labels.length &&
                _hoveredIndex! < widget.values.length
            ? _hoveredIndex
            : null;
        const left = 32.0;
        const right = 8.0;
        final step = (chartWidth - left - right) / widget.labels.length;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: chartWidth,
            height: chartSize.height,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              onHover: (event) => _updateHover(event.localPosition, chartSize),
              onExit: (_) {
                if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _updateHover(details.localPosition, chartSize),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DashboardBarPainter(
                          labels: widget.labels,
                          values: widget.values,
                          highlighted: hovered,
                        ),
                      ),
                    ),
                    if (hovered != null)
                      Positioned(
                        left: (left + step * (hovered + 0.5) - 70)
                            .clamp(0.0, math.max(0.0, chartWidth - 145))
                            .toDouble(),
                        top: 0,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.charcoal,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${widget.labels[hovered]}: ${widget.values[hovered]}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
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

class _DashboardBarPainter extends CustomPainter {
  final List<String> labels;
  final List<int?> values;
  final int? highlighted;

  const _DashboardBarPainter({
    required this.labels,
    required this.values,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty) return;
    const left = 32.0;
    const right = 8.0;
    const top = 18.0;
    const bottom = 67.0;
    final chartWidth = size.width - left - right;
    final chartHeight = size.height - top - bottom;
    final maxValue = values.whereType<int>().fold<int>(
      4,
      (a, b) => math.max(a, b),
    );
    final tickStep = _dashboardNiceStep(maxValue);
    final maxTick = ((maxValue + tickStep - 1) ~/ tickStep) * tickStep;
    final gridPaint = Paint()
      ..color = const Color(0xFFE4E7EC)
      ..strokeWidth = 1;
    final step = chartWidth / labels.length;

    void drawText(
      String text,
      Offset position, {
      double maxWidth = 80,
      Color color = AppColors.grey,
      double fontSize = 10,
      TextAlign align = TextAlign.center,
      int? maxLines,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, color: color),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
        maxLines: maxLines,
        ellipsis: maxLines == null ? null : '…',
      )..layout(maxWidth: maxWidth);
      final double textLeft;
      if (align == TextAlign.center) {
        textLeft = position.dx + (maxWidth - painter.width) / 2;
      } else if (align == TextAlign.right) {
        textLeft = position.dx + maxWidth - painter.width;
      } else {
        textLeft = position.dx;
      }
      painter.paint(canvas, Offset(textLeft, position.dy));
    }

    for (var tick = 0; tick <= maxTick; tick += tickStep) {
      final y = top + chartHeight * (1 - tick / maxTick);
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width - right, y),
        gridPaint,
      );
      drawText(
        '$tick',
        Offset(0, y - 7),
        maxWidth: left - 8,
        align: TextAlign.right,
      );
    }

    for (var i = 0; i < labels.length; i++) {
      final centerX = left + step * (i + 0.5);
      final rawValue = i < values.length ? values[i] : null;
      final value = math.max(0, rawValue ?? 0);
      final barHeight = chartHeight * value / maxTick;
      final barWidth = math.min(29.0, step * 0.56);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          centerX - barWidth / 2,
          top + chartHeight - barHeight,
          barWidth,
          barHeight,
        ),
        const Radius.circular(4),
      );
      final paint = Paint()
        ..color = highlighted == i
            ? const Color(0xFF2478E9)
            : const Color(0xFF5097F5);
      canvas.drawRRect(rect, paint);
      if (rawValue == null) {
        drawText(
          '-',
          Offset(centerX - step * 0.42, top + chartHeight - 16),
          maxWidth: step * 0.84,
        );
      } else if (value > 0) {
        drawText(
          '$value',
          Offset(centerX - step * 0.42, top + chartHeight - barHeight - 16),
          maxWidth: step * 0.84,
          color: AppColors.black,
        );
      }
      drawText(
        labels[i],
        Offset(centerX - step * 0.48, top + chartHeight + 10),
        maxWidth: step * 0.96,
        maxLines: 3,
        fontSize: 9.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardBarPainter oldDelegate) => true;
}

// Smooth hourly and monthly line chart. Missing points remain gaps.
class _DashboardLineChart extends StatefulWidget {
  final List<String> labels;
  final List<double?> values;
  final Color color;
  final String suffix;
  final bool percentage;
  final int? yAxisTickInterval;
  final int? yAxisMinimumMaximum;

  const _DashboardLineChart({
    required this.labels,
    required this.values,
    required this.color,
    this.suffix = '',
    this.percentage = false,
    this.yAxisTickInterval,
    this.yAxisMinimumMaximum,
  });

  @override
  State<_DashboardLineChart> createState() => _DashboardLineChartState();
}

class _DashboardLineChartState extends State<_DashboardLineChart> {
  int? _hovered;

  @override
  Widget build(BuildContext context) {
    if (widget.labels.isEmpty || !widget.values.any((value) => value != null)) {
      return const SizedBox(
        height: 176,
        child: Center(
          child: Text(
            'No records available.',
            style: TextStyle(color: AppColors.grey),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        const height = 232.0;
        final width = bounds.maxWidth;
        const left = 42.0;
        const right = 16.0;
        final plotWidth = math.max(1.0, width - left - right);
        final hovered =
            _hovered != null &&
                _hovered! >= 0 &&
                _hovered! < widget.labels.length &&
                _hovered! < widget.values.length
            ? _hovered
            : null;
        final cursorX = hovered == null || widget.labels.length <= 1
            ? left + plotWidth / 2
            : left + plotWidth * hovered / (widget.labels.length - 1);
        final hoveredValue = hovered == null ? null : widget.values[hovered];
        final hoveredLabel = hoveredValue == null
            ? 'No data'
            : '${hoveredValue.toStringAsFixed(widget.percentage ? 1 : (hoveredValue % 1 == 0 ? 0 : 1))}${widget.suffix}';
        final tooltipText = hovered == null
            ? ''
            : '${widget.labels[hovered]}: $hoveredLabel';
        return SizedBox(
          height: height,
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            onHover: (event) {
              final next = widget.labels.length <= 1
                  ? 0
                  : (((event.localPosition.dx - left) / plotWidth) *
                            (widget.labels.length - 1))
                        .round()
                        .clamp(0, widget.labels.length - 1);
              if (next != _hovered) setState(() => _hovered = next.toInt());
            },
            onExit: (_) {
              if (_hovered != null) setState(() => _hovered = null);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                final next = widget.labels.length <= 1
                    ? 0
                    : (((details.localPosition.dx - left) / plotWidth) *
                              (widget.labels.length - 1))
                          .round()
                          .clamp(0, widget.labels.length - 1);
                setState(() => _hovered = next.toInt());
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DashboardLinePainter(
                        labels: widget.labels,
                        values: widget.values,
                        color: widget.color,
                        percentage: widget.percentage,
                        yAxisTickInterval: widget.yAxisTickInterval,
                        yAxisMinimumMaximum: widget.yAxisMinimumMaximum,
                        highlighted: hovered,
                      ),
                    ),
                  ),
                  if (hovered != null)
                    Positioned(
                      left: (cursorX - 80)
                          .clamp(0.0, math.max(0.0, width - 165))
                          .toDouble(),
                      top: 0,
                      child: IgnorePointer(
                        child: Container(
constraints: const BoxConstraints(maxWidth: 164),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.charcoal,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            tooltipText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DashboardLinePainter extends CustomPainter {
  final List<String> labels;
  final List<double?> values;
  final Color color;
  final bool percentage;
  final int? yAxisTickInterval;
  final int? yAxisMinimumMaximum;
  final int? highlighted;

  const _DashboardLinePainter({
    required this.labels,
    required this.values,
    required this.color,
    required this.percentage,
    required this.yAxisTickInterval,
    required this.yAxisMinimumMaximum,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty) return;
    const left = 42.0;
    const right = 16.0;
    const top = 24.0;
    const bottom = 32.0;
    final chartWidth = math.max(1.0, size.width - left - right);
    final chartHeight = size.height - top - bottom;
    final maxData = values.whereType<double>().fold<double>(
      0.0,
      (a, b) => math.max(a, b),
    );
    final double maximum;
    if (percentage) {
      maximum = maxData <= 100
          ? 100.0
          : ((maxData / 25).ceil() * 25).toDouble();
    } else if (yAxisTickInterval != null) {
      final tickStep = yAxisTickInterval!;
      maximum = math.max(
        yAxisMinimumMaximum ?? tickStep,
        (maxData / tickStep).ceil() * tickStep,
      ).toDouble();
    } else {
      final step = _dashboardNiceStep(math.max(4, maxData.ceil()));
      maximum = (((math.max(4, maxData.ceil()) + step - 1) ~/ step) * step)
          .toDouble();
    }
    double xFor(int index) => labels.length == 1
        ? left + chartWidth / 2
        : left + chartWidth * index / (labels.length - 1);
    double yFor(double value) =>
        top + chartHeight * (1 - value.clamp(0.0, maximum) / maximum);

    void text(
      String value,
      Offset position, {
      TextAlign align = TextAlign.center,
      double width = 60,
      Color textColor = AppColors.grey,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(color: textColor, fontSize: 10),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: width);
      final x = align == TextAlign.right
          ? position.dx + width - painter.width
          : align == TextAlign.center
          ? position.dx + (width - painter.width) / 2
          : position.dx;
      painter.paint(canvas, Offset(x, position.dy));
    }

    final grid = Paint()
      ..color = const Color(0xFFE8ECF1)
      ..strokeWidth = 1;
    final tickCount = yAxisTickInterval == null
        ? 4
        : (maximum / yAxisTickInterval!).round();
    for (var tick = 0; tick <= tickCount; tick++) {
      final value = yAxisTickInterval == null
          ? maximum * tick / 4
          : (tick * yAxisTickInterval!).toDouble();
      final y = yFor(value);
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      text(
        '${value.toStringAsFixed(percentage || value % 1 == 0 ? 0 : 1)}'
        '${percentage ? '%' : ''}',
        Offset(0, y - 6),
        width: left - 7,
        align: TextAlign.right,
      );
    }

    // Adapt month/hour labels to the available width so they never crowd.
    final maxLabels = math.max(2, (chartWidth / 70).floor());
    final labelStep = math.max(
      1,
      ((labels.length - 1) / (maxLabels - 1)).ceil(),
    );
    for (var i = 0; i < labels.length; i++) {
      if (i % labelStep != 0 && i != labels.length - 1) continue;
      final x = xFor(i);
      text(labels[i], Offset(x - 29, size.height - bottom + 9), width: 58);
    }

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
    var segment = <Offset>[];
    void drawSegment() {
      if (segment.isEmpty) return;
      final path = Path()..moveTo(segment.first.dx, segment.first.dy);
      for (final point in segment.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      if (segment.length > 1) {
        final fill = Path.from(path)
          ..lineTo(segment.last.dx, yFor(0))
          ..lineTo(segment.first.dx, yFor(0))
          ..close();
        canvas.drawPath(fill, fillPaint);
      }
      canvas.drawPath(path, linePaint);
      for (final point in segment) {
        canvas.drawCircle(point, 3.6, Paint()..color = Colors.white);
        canvas.drawCircle(point, 2.6, Paint()..color = color);
      }
      segment = <Offset>[];
    }

    for (var i = 0; i < labels.length; i++) {
      final value = i < values.length ? values[i] : null;
      if (value == null) {
        drawSegment();
        continue;
      }
      segment.add(Offset(xFor(i), yFor(value)));
    }
    drawSegment();

    if (highlighted != null &&
        highlighted! < values.length &&
        values[highlighted!] != null) {
      final point = Offset(xFor(highlighted!), yFor(values[highlighted!]!));
      canvas.drawLine(
        Offset(point.dx, top),
        Offset(point.dx, yFor(0)),
        Paint()
          ..color = color.withValues(alpha: 0.28)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(point, 5, Paint()..color = Colors.white);
      canvas.drawCircle(point, 3.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardLinePainter oldDelegate) =>
      oldDelegate.labels != labels ||
      oldDelegate.values != values ||
      oldDelegate.color != color ||
      oldDelegate.highlighted != highlighted;
}

class _DashboardRankingBars extends StatelessWidget {
  final Map<String, int> values;
  final Color color;
  const _DashboardRankingBars({required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    final items = values.entries.where((item) => item.value > 0).toList()
      ..sort((a, b) {
        final count = b.value.compareTo(a.value);
        return count == 0 ? a.key.compareTo(b.key) : count;
      });
    if (items.isEmpty) {
      return const SizedBox(
        height: 176,
        child: Center(
          child: Text(
            'No records available.',
            style: TextStyle(color: AppColors.grey),
          ),
        ),
      );
    }
    final maximum = math.max(1, items.first.value);
    return Column(
      children: [
        for (final item in items.take(10)) ...[
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: item.key,
                  child: Text(
                    item.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${item.value}',
                style: const TextStyle(fontSize: 12, color: AppColors.grey),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: item.value / maximum,
              backgroundColor: const Color(0xFFE9EDF2),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (items.length > 10)
          Text(
            '${items.length - 10} more lifts not shown',
            style: const TextStyle(color: AppColors.grey, fontSize: 11),
          ),
      ],
    );
  }
}