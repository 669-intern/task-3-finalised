import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/styles.dart';

class ServiceProvidersPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const ServiceProvidersPage({super.key, required this.report});

  @override
  State<ServiceProvidersPage> createState() => _ServiceProvidersPageState();
}

const List<String> _manualStatusOptions = ['Active', 'Renewal Due'];

// Keep the original renewal-date calculation for reports before November 2026.
// It is needed for historical statuses while legacy Supabase data is retained.
final DateTime _renewalRuleCutoverMonth = DateTime(2026, 11);

DateTime _oneCalendarMonthBefore(DateTime date) {
  final previous = DateTime(date.year, date.month - 1, 1);
  final lastDay = DateTime(date.year, date.month, 0).day;
  return DateTime(
    previous.year,
    previous.month,
    date.day > lastDay ? lastDay : date.day,
  );
}

class _ServiceProvidersPageState extends State<ServiceProvidersPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _providers = [];
  List<Map<String, dynamic>> _upcomingProviders = [];
  final Map<String, Map<String, dynamic>> _staffByProviderId = {};
  List<Map<String, dynamic>> _archivedProviders = [];
  final Map<String, List<Map<String, dynamic>>> _lifecycleHistoryByMonth = {};
  final Map<String, DateTime> _reportMonths = {};
  final Map<String, String> _reportIdByMonth = {};
  final Set<String> _selectedStatuses = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  static const String _bucket = 'service-provider-attachments';

  static const List<String> _suggestedServices = [
    'Cleaning',
    'Security',
    'Landscaping',
    'Lift Maintenance',
    'Pest Control',
    'Plumbing',
    'Electrical',
    'Fire Protection',
    'Air Conditioning',
    'Waste Management',
    'Pool Maintenance',
    'Other',
  ];

  static const List<String> _statuses = [
    'Active',
    'Renewal Due',
    'Expired',
    'Terminated',
  ];

  String get _reportId => widget.report['id'].toString();

  String get _siteId => widget.report['site_id'].toString();

  DateTime? get _reportMonth {
    final value = DateTime.tryParse(
      widget.report['report_month']?.toString() ?? '',
    );

    return value == null ? null : DateTime(value.year, value.month);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshSearch);
    _loadProviders();
  }

  @override
  void dispose() {
    _searchController.removeListener(_refreshSearch);
    _searchController.dispose();
    super.dispose();
  }

  void _refreshSearch() {
    if (mounted) {
      setState(() {});
    }
  }

  static bool _hasText(dynamic value) =>
      value != null && value.toString().trim().isNotEmpty;

  String _scheduleDescription(Map<String, dynamic> provider) {
    final staff = _staffByProviderId[provider['id']?.toString()];
    if (staff == null) return '';

    final details = <String>[];
    final serviceHours = staff['service_hours']?.toString().trim() ?? '';
    final frequency = staff['frequency']?.toString().trim() ?? '';
    final totalStaff = staff['total_staff'];
    final included = staff['include_in_staff'] != false;
    final security =
        provider['service']?.toString().trim().toLowerCase() == 'security';

    // Service hours and frequency belong to Provider Details, not the staffing
    // toggle. Display them even when this provider is excluded from manpower.
    if (serviceHours.isNotEmpty) {
      details.add('Service hours: $serviceHours');
    }
    if (frequency.isNotEmpty) {
      details.add('Frequency: $frequency');
    }

    if (included) {
      final shifts = <String>[];

      void addShift(
        String label,
        dynamic timingValue,
        dynamic pax,
        dynamic supervisors,
        dynamic guards,
      ) {
        final timing = timingValue?.toString().trim() ?? '';
        if (pax == 0 || (timing.isEmpty && pax == null)) return;

        final timeText = timing.isEmpty ? '' : ' ($timing)';
        final paxText = pax == null ? '' : ': $pax pax';
        final positions = security && supervisors != null && guards != null
            ? ' ($supervisors supervisor(s), $guards guard(s))'
            : '';
        shifts.add('$label$timeText$paxText$positions');
      }

      addShift(
        'Day shift',
        staff['day_shift_timing'],
        staff['day_shift_staff'],
        staff['day_shift_supervisors'],
        staff['day_shift_guards'],
      );
      addShift(
        'Night shift',
        staff['night_shift_timing'],
        staff['night_shift_staff'],
        staff['night_shift_supervisors'],
        staff['night_shift_guards'],
      );

      if (shifts.isNotEmpty) {
        details.add('Working hours:\n${shifts.join('\n')}');
      }
      if (totalStaff != null) {
        details.add('Total staff: $totalStaff');
      }
    }

    return details.join('\n\n');
  }

  String _displayProviderNotes(Map<String, dynamic> provider) {
    // Do not drop or overwrite legacy entries in either existing notes column.
    final scheduleNotes =
        provider['schedule_staffing']?.toString().trim() ?? '';
    final otherNotes = provider['notes']?.toString().trim() ?? '';
    if (scheduleNotes.isEmpty) return otherNotes;
    if (otherNotes.isEmpty || otherNotes == scheduleNotes) return scheduleNotes;
    return '$scheduleNotes\n\n$otherNotes';
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(value.toString());
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  static String _displayDate(dynamic value) {
    final date = _parseDate(value);
    return date == null ? 'Not set' : _formatDate(date);
  }

  static String? _dateForDatabase(DateTime? date) {
    if (date == null) {
      return null;
    }

    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  // Keep expired contracts in their expiry month. From the following month
  // they are historical unless renewed by expiry + one calendar day.
  // expiry_date is the single source of truth for the contract end date.
  DateTime? _expiryDate(Map<String, dynamic> p) => _parseDate(p['expiry_date']);

  // For historical status calculations only (before the cutover month).
  DateTime? _legacyRenewalDate(Map<String, dynamic> p) =>
      _parseDate(p['renewal_date']);

  DateTime _monthEnd(DateTime month) =>
      DateTime(month.year, month.month + 1, 0);

  DateTime _monthStart(DateTime month) => DateTime(month.year, month.month, 1);

  DateTime _nextDay(DateTime date) =>
      DateTime(date.year, date.month, date.day + 1);

  // Do not let a future report month archive a contract before the actual
  // calendar day after expiry. Older reports retain their own month-end view.
  DateTime _archiveReferenceDate(DateTime reportMonth) {
    final today = DateUtils.dateOnly(DateTime.now());
    final reportEnd = _monthEnd(reportMonth);
    return reportEnd.isBefore(today) ? reportEnd : today;
  }

  bool _isAutomaticallyArchivedInMonth(
    Map<String, dynamic> provider,
    DateTime reportMonth,
  ) {
    final reference = _archiveReferenceDate(reportMonth);
    final archiveFrom = _automaticArchiveFrom(provider, reference);
    return archiveFrom != null && !archiveFrom.isAfter(reference);
  }

  // A contract expires at the end of its expiry date, entering Archive the
  // next calendar day; termination retains its existing next-month rule.
  // This is a display rule: never change historical is_archived flags.
  DateTime? _automaticArchiveFrom(
    Map<String, dynamic> provider,
    DateTime asOfDate,
  ) {
    final expiry = _expiryDate(provider);
    final confirmed = _parseDate(provider['renewal_confirmed_at']);
    final nextExpiry = _parseDate(provider['next_expiry_date']);
    final validRenewal =
        expiry != null &&
        confirmed != null &&
        !confirmed.isAfter(asOfDate) &&
        nextExpiry != null &&
        nextExpiry.isAfter(expiry);
    final effectiveExpiry = validRenewal ? nextExpiry : expiry;

    final stop = _parseDate(provider['lifecycle_date']);
    if (provider['status'] == 'Terminated' &&
        stop != null &&
        (effectiveExpiry == null || !stop.isAfter(effectiveExpiry))) {
      // Preserve the existing rule for explicit termination.
      return DateTime(stop.year, stop.month + 1, 1);
    }
    return effectiveExpiry == null ? null : _nextDay(effectiveExpiry);
  }

  String _automaticArchiveCause(
    Map<String, dynamic> provider,
    DateTime asOfDate,
  ) {
    final expiry = _expiryDate(provider);
    final confirmed = _parseDate(provider['renewal_confirmed_at']);
    final nextExpiry = _parseDate(provider['next_expiry_date']);
    final validRenewal =
        expiry != null &&
        confirmed != null &&
        !confirmed.isAfter(asOfDate) &&
        nextExpiry != null &&
        nextExpiry.isAfter(expiry);
    final effectiveExpiry = validRenewal ? nextExpiry : expiry;
    final stop = _parseDate(provider['lifecycle_date']);
    return provider['status'] == 'Terminated' &&
            stop != null &&
            (effectiveExpiry == null || !stop.isAfter(effectiveExpiry))
        ? 'Terminated'
        : 'Expired';
  }

  String _currentStatus(
    Map<String, dynamic> provider, {
    DateTime? reportMonth,
  }) {
    final month = reportMonth ?? _reportMonth;
    final reference = month == null
        ? DateUtils.dateOnly(DateTime.now())
        : _archiveReferenceDate(month);
    final terminated = provider['status']?.toString() == 'Terminated';
    final stopDate = _parseDate(provider['lifecycle_date']);
    if (terminated && (stopDate == null || !stopDate.isAfter(reference))) {
      return 'Terminated';
    }
    final expiry = _expiryDate(provider);
    final historical =
        month != null && _monthStart(month).isBefore(_renewalRuleCutoverMonth);
    final confirmed = _parseDate(provider['renewal_confirmed_at']);
    final nextExpiry = _parseDate(provider['next_expiry_date']);
    // A confirmed renewal is Active in its confirmation month. The renewed
    // start/expiry apply to subsequent monthly copies.
    if (confirmed != null &&
        !confirmed.isAfter(reference) &&
        nextExpiry != null &&
        (expiry == null || !nextExpiry.isBefore(_nextDay(expiry)))) {
      return 'Active';
    }
    // Preserve the legacy expiry-status boundary for historical reports.
    // Newer reports mark a contract Expired from the day after expiry.
    if (expiry != null &&
        (historical
            ? reference.isAfter(_nextDay(expiry))
            : reference.isAfter(expiry))) {
      return 'Expired';
    }
    if (confirmed != null &&
        !confirmed.isAfter(reference) &&
        nextExpiry == null &&
        (historical ||
            (month != null &&
                month.year == confirmed.year &&
                month.month == confirmed.month))) {
      // A previous renewal confirmation must not suppress reminders for the
      // NEXT contract when the new expiry date approaches.
      return 'Active';
    }
    // Before November 2026, retain the existing optional Renewal Date rule.
    // From November 2026 onward, derive Renewal Due from expiry_date only.
    final reminderDate = historical ? _legacyRenewalDate(provider) : expiry;
    if (reminderDate != null) {
      final reminderBegins = _oneCalendarMonthBefore(reminderDate);
      final alreadyRenewed =
          confirmed != null &&
          !confirmed.isBefore(reminderBegins) &&
          !confirmed.isAfter(reference);
      if (!alreadyRenewed && !reference.isBefore(reminderBegins)) {
        return 'Renewal Due';
      }
    }
    return 'Active';
  }

  bool _visibleInMonth(Map<String, dynamic> provider, DateTime month) {
    if (provider['history_deleted_at'] != null ||
        _isAutomaticallyArchivedInMonth(provider, month)) {
      return false;
    }
    final start = _parseDate(provider['commencement_date']);
    final expiry = _expiryDate(provider);
    final stop = _parseDate(provider['lifecycle_date']);
    if (start != null && _monthStart(start).isAfter(_monthStart(month))) {
      return false;
    }
    if (expiry != null && _monthStart(expiry).isBefore(_monthStart(month))) {
      return false;
    }
    if (provider['status'] == 'Terminated' &&
        stop != null &&
        _monthStart(stop).isBefore(_monthStart(month))) {
      return false;
    }
    return true;
  }

  // Upcoming Appointments appear only in the calendar month immediately
  // before commencement; no separate reporting start date is needed.
  bool _isUpcomingInMonth(Map<String, dynamic> provider, DateTime month) {
    if (provider['is_archived'] == true ||
        provider['history_deleted_at'] != null) {
      return false;
    }
    final start = _parseDate(provider['commencement_date']);
    final nextMonth = DateTime(month.year, month.month + 1);
    if (start == null || !_monthStart(start).isAtSameMomentAs(nextMonth)) {
      return false;
    }
    final expiry = _expiryDate(provider);
    if (expiry != null && expiry.isBefore(start)) {
      return false;
    }
    final stop = _parseDate(provider['lifecycle_date']);
    if (provider['status'] == 'Terminated' &&
        (stop == null || stop.isBefore(start))) {
      return false;
    }
    return true;
  }

  String _statusLabel(String status) {
    return status == 'Terminated' ? 'No Longer Used' : status;
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Active':
        return const Color(0xFF22683D);
      case 'Renewal Due':
        return const Color(0xFF966400);
      case 'Expired':
        return AppColors.red;
      case 'Terminated':
        return AppColors.grey;
      default:
        return AppColors.black;
    }
  }

  int get _activeCount =>
      _providers.where((p) => _currentStatus(p) == 'Active').length;

  int get _renewalDueCount =>
      _providers.where((p) => _currentStatus(p) == 'Renewal Due').length;

  int get _expiredCount =>
      _providers.where((p) => _currentStatus(p) == 'Expired').length;

  // Count each logical result once. Archived Records mirrors History and
  // must never increase the No Longer Used summary total.
  int get _noLongerUsedCount {
    final ids = <String>{};
    for (final provider in _providers) {
      if (_currentStatus(provider) == 'Terminated') {
        ids.add(provider['id'].toString());
      }
    }
    for (final group in _lifecycleHistoryByMonth.entries) {
      final month = _parseMonthLabel(group.key);
      for (final provider in group.value) {
        if (_currentStatus(provider, reportMonth: month) == 'Terminated') {
          ids.add(provider['id'].toString());
        }
      }
    }
    return ids.length;
  }

  void _toggleStatus(String status) {
    setState(() {
      if (_selectedStatuses.contains(status)) {
        _selectedStatuses.remove(status);
      } else {
        _selectedStatuses.add(status);
      }
    });
  }

  bool _matchesSearch(Map<String, dynamic> provider) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    final searchable = [
      provider['service'],
      provider['company_pic'],
      provider['contact'],
      provider['schedule_staffing'],
      provider['notes'],
      provider['lifecycle_reason'],
      provider['archive_reason'],
      provider['_archive_reason'],
      _currentStatus(provider),
      _statusLabel(_currentStatus(provider)),
      provider['commencement_date'],
      provider['expiry_date'],
      provider['renewal_date'],
      provider['expiry_renewal_date'],
      if (_reportMonth != null && _isUpcomingInMonth(provider, _reportMonth!))
        'Upcoming',
    ].where((v) => v != null).join(' ').toLowerCase();
    return searchable.contains(query);
  }

  static String _monthLabel(DateTime date) {
    const names = [
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
    return '${names[date.month - 1]} ${date.year}';
  }

  void _message(String message, {bool error = false}) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.redDark : AppColors.charcoal,
      ),
    );
  }

  // Load all snapshots for THIS property only; Historical and Archived
  // references point to the exact same row objects, not duplicate records.
  Future<void> _loadProviders() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_hasText(widget.report['id']) ||
          !_hasText(widget.report['site_id']) ||
          _reportMonth == null) {
        throw StateError('Report id, site_id, and report_month are required.');
      }
      final currentMonth = _reportMonth!;
      final reportsResponse = await _supabase
          .from('monthly_reports')
          .select('id,report_month')
          .eq('site_id', _siteId)
          .lte('report_month', _dateForDatabase(_monthStart(currentMonth))!)
          .order('report_month', ascending: false);
      final months = <String, DateTime>{};
      final idsByMonth = <String, String>{};
      for (final r in List<Map<String, dynamic>>.from(reportsResponse)) {
        final id = r['id']?.toString();
        final month = _parseDate(r['report_month']);
        if (id == null || month == null) {
          continue;
        }
        months[id] = _monthStart(month);
        idsByMonth[_dateForDatabase(_monthStart(month))!] = id;
      }
      months[_reportId] = _monthStart(currentMonth);
      idsByMonth[_dateForDatabase(_monthStart(currentMonth))!] = _reportId;

      // Idempotently reconcile monthly copies even when this report has
      // other providers already; late renewals from the previous month
      // should still appear automatically.
      await _initializeReportProviders();

      final all = <Map<String, dynamic>>[];
      final reportIds = months.keys.toList();
      for (var i = 0; i < reportIds.length; i += 80) {
        final part = reportIds.skip(i).take(80).toList();
        final rows = await _supabase
            .from('service_providers')
            .select()
            .inFilter('report_id', part)
            .order('company_pic');
        all.addAll(List<Map<String, dynamic>>.from(rows));
      }
      final current = all
          .where(
            (p) =>
                p['report_id']?.toString() == _reportId &&
                p['is_archived'] != true &&
                _visibleInMonth(p, currentMonth),
          )
          .toList();

      // Read future snapshots from THIS property's reports only. They can
      // appear as Upcoming exactly one month before commencement; no future
      // rows are copied or edited here.
      final futureReports = await _supabase
          .from('monthly_reports')
          .select('id,report_month')
          .eq('site_id', _siteId)
          .gt('report_month', _dateForDatabase(_monthEnd(currentMonth))!)
          .order('report_month', ascending: true);
      final futureMonths = <String, DateTime>{};
      for (final report in List<Map<String, dynamic>>.from(futureReports)) {
        final id = report['id']?.toString();
        final date = _parseDate(report['report_month']);
        if (id != null && date != null) {
          futureMonths[id] = _monthStart(date);
        }
      }
      final futureProviders = <Map<String, dynamic>>[];
      final futureIds = futureMonths.keys.toList();
      for (var i = 0; i < futureIds.length; i += 80) {
        final part = futureIds.skip(i).take(80).toList();
        final rows = await _supabase
            .from('service_providers')
            .select()
            .inFilter('report_id', part);
        futureProviders.addAll(List<Map<String, dynamic>>.from(rows));
      }

      // Trace source_provider_id across past and future snapshots so one
      // logical provider appears only once in Upcoming Appointments.
      final byId = <String, Map<String, dynamic>>{
        for (final p in [...all, ...futureProviders])
          if (p['id'] != null) p['id'].toString(): p,
      };
      String rootOf(Map<String, dynamic> p) {
        var id = p['id'].toString();
        final visited = <String>{};
        while (visited.add(id)) {
          final parent = byId[id]?['source_provider_id']?.toString();
          if (parent == null || parent.isEmpty || !byId.containsKey(parent)) {
            break;
          }
          id = parent;
        }
        return id;
      }

      // Each monthly copy belongs to the same provider lineage. Future copies
      // are read-only sources for contracts entered retrospectively; they are
      // never written into earlier reporting months.
      final snapshotMonths = <String, DateTime>{...months, ...futureMonths};
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final p in [...all, ...futureProviders]) {
        (groups[rootOf(p)] ??= []).add(p);
      }
      int snapshotOrder(Map<String, dynamic> a, Map<String, dynamic> b) {
        final am = snapshotMonths[a['report_id']?.toString()] ?? DateTime(9999);
        final bm = snapshotMonths[b['report_id']?.toString()] ?? DateTime(9999);
        final cmp = am.compareTo(bm);
        if (cmp != 0) return cmp;
        return (a['updated_at']?.toString() ?? '').compareTo(
          b['updated_at']?.toString() ?? '',
        );
      }

      for (final snapshots in groups.values) {
        snapshots.sort(snapshotOrder);
      }

      // A contract is reportable from its commencement month through its
      // expiry month, unless a termination or manual archive ends visibility.
      bool reportable(Map<String, dynamic> p, DateTime month) {
        if (!_visibleInMonth(p, month)) return false;
        final savedMonth = snapshotMonths[p['report_id']?.toString()];
        final start = _parseDate(p['commencement_date']);
        if (start == null &&
            (savedMonth == null || savedMonth.isAfter(month))) {
          return false; // Never invent a start date.
        }
        final restored = _parseDate(p['restored_month']);
        if (restored != null &&
            _monthStart(restored).isAfter(_monthStart(month))) {
          return false; // A restoration cannot reopen archived earlier months.
        }
        if (p['is_archived'] == true) {
          final archiveDate = _parseDate(p['archived_at']);
          if (archiveDate == null ||
              !_monthStart(archiveDate).isAfter(_monthStart(month))) {
            return false;
          }
        }
        return true;
      }

      // Prefer the record saved for the month, then the latest prior saved
      // state (including termination/archive), to avoid reviving an ended
      // contract from an older copy. Later backdated copies are read-only.
      Map<String, dynamic>? asOfMonth(
        List<Map<String, dynamic>> snapshots,
        DateTime month,
        String reportId,
      ) {
        final exact = snapshots
            .where((p) => p['report_id']?.toString() == reportId)
            .toList();
        if (exact.isNotEmpty) {
          final p = exact.last;
          return reportable(p, month) ? p : null;
        }
        Map<String, dynamic>? latestPrevious;
        Map<String, dynamic>? later;
        for (final p in snapshots) {
          final savedMonth = snapshotMonths[p['report_id']?.toString()];
          if (savedMonth == null) continue;
          if (!savedMonth.isAfter(month)) {
            // A deletion hides its own month, not other contract months.
            if (p['history_deleted_at'] == null) latestPrevious = p;
          } else if (later == null && reportable(p, month)) {
            later = p;
          }
        }
        if (latestPrevious != null && reportable(latestPrevious, month)) {
          return latestPrevious;
        }
        return later;
      }

      // Existing records stay editable in their own month. When a contract is
      // valid but no independent record has been saved for this report month,
      // show a read-only reference rather than changing an older report.
      final currentRoots = all
          .where((p) => p['report_id']?.toString() == _reportId)
          .map(rootOf)
          .toSet();
      for (final entry in groups.entries) {
        if (currentRoots.contains(entry.key)) continue;
        final p = asOfMonth(entry.value, currentMonth, _reportId);
        if (p != null) {
          current.add({...p, '_history_inferred': true});
        }
      }

      // Preserve the original No Longer Used summary behaviour. It is a
      // logical provider count, not a count of historical monthly copies.
      // Archive contains one latest state per provider lineage. Automatic
      // expiry/termination must not mutate the saved monthly snapshots.
      final lifecycleHistory = <String, List<Map<String, dynamic>>>{};
      final archivedItems = <String, Map<String, dynamic>>{};
      final selectedEnd = _monthEnd(currentMonth);
      final asOfDate = _archiveReferenceDate(currentMonth);
      for (final entry in groups.entries) {
        final snapshots = entry.value.where((p) {
          final saved = snapshotMonths[p['report_id']?.toString()];
          return saved != null && !saved.isAfter(currentMonth);
        }).toList();
        if (snapshots.isEmpty) continue;
        final newest = snapshots.last;
        final earlierRestorations = snapshots.where((p) {
          final restored = _parseDate(p['restored_month']);
          return restored != null &&
              _monthStart(restored).isBefore(currentMonth);
        }).toList();
        final last = earlierRestorations.isEmpty
            ? newest
            : earlierRestorations.last;
        if (last['history_deleted_at'] != null) continue;
        final expiry = _expiryDate(last);
        final terminated = last['status'] == 'Terminated';
        final stopDate = _parseDate(last['lifecycle_date']);
        final archiveDate = _parseDate(last['archived_at']);
        final restoreMonth = _parseDate(last['restored_month']);
        final isOldArchive =
            last['is_archived'] == true &&
            (archiveDate == null ||
                _monthStart(archiveDate).isBefore(currentMonth));
        DateTime? historyMonth;
        if (restoreMonth != null &&
            _monthStart(restoreMonth).isBefore(currentMonth)) {
          historyMonth = restoreMonth;
        } else if (isOldArchive) {
          historyMonth =
              archiveDate ?? snapshotMonths[last['report_id']?.toString()];
        } else if (terminated &&
            stopDate != null &&
            _monthStart(stopDate).isBefore(currentMonth)) {
          historyMonth = stopDate;
        } else if (expiry != null &&
            _monthStart(expiry).isBefore(currentMonth) &&
            selectedEnd.isAfter(_nextDay(expiry))) {
          historyMonth = expiry;
        }
        if (historyMonth != null) {
          (lifecycleHistory[_monthLabel(historyMonth)] ??= []).add(last);
        }
        // The newest snapshot determines the present archive state. Keep
        // manually archived contracts and auto-expired contracts distinct.
        if (newest['history_deleted_at'] != null) continue;
        final manualArchiveDate = _parseDate(newest['archived_at']);
        if (newest['is_archived'] == true) {
          if (manualArchiveDate == null ||
              !DateUtils.dateOnly(
                manualArchiveDate.toLocal(),
              ).isAfter(asOfDate)) {
            archivedItems[entry.key] = newest;
          }
          continue;
        }
        final automaticFrom = _automaticArchiveFrom(newest, asOfDate);
        if (automaticFrom != null && !automaticFrom.isAfter(asOfDate)) {
          final cause = _automaticArchiveCause(newest, asOfDate);
          archivedItems[entry.key] = <String, dynamic>{
            ...newest,
            '_auto_archived': true,
            '_auto_archive_cause': cause,
            '_archive_effective_date': _dateForDatabase(automaticFrom),
            '_archive_reason': cause == 'Terminated'
                ? 'Provider stopped being used on '
                      '${_displayDate(newest['lifecycle_date'])}.'
                : 'Contract expired on '
                      '${_displayDate(newest['expiry_date'])}.',
          };
        }
      }
      current.sort(
        (a, b) => (a['company_pic']?.toString() ?? '').compareTo(
          b['company_pic']?.toString() ?? '',
        ),
      );

      final upcomingByRoot = <String, Map<String, dynamic>>{};
      for (final provider in [...all, ...futureProviders]) {
        if (!_isUpcomingInMonth(provider, currentMonth)) continue;
        final key = rootOf(provider);
        final previous = upcomingByRoot[key];
        final providerMonth =
            months[provider['report_id']?.toString()] ??
            futureMonths[provider['report_id']?.toString()] ??
            DateTime(9999);
        final previousMonth = previous == null
            ? DateTime(9999)
            : (months[previous['report_id']?.toString()] ??
                  futureMonths[previous['report_id']?.toString()] ??
                  DateTime(9999));
        if (previous == null || providerMonth.isBefore(previousMonth)) {
          upcomingByRoot[key] = provider;
        }
      }
      final upcoming = upcomingByRoot.values.toList()
        ..sort(
          (a, b) => (a['company_pic']?.toString() ?? '').compareTo(
            b['company_pic']?.toString() ?? '',
          ),
        );

      // Staff details are entered once and inherited from earlier monthly
      // provider copies by the RLS-safe staff_effective view. Each provider
      // still has its own effective month; future overrides never rewrite past.
      final staffByProviderId = <String, Map<String, dynamic>>{};
      final providerIds = <String>{
        for (final p in [...all, ...futureProviders])
          if (p['id'] != null) p['id'].toString(),
      }.toList();

      for (var i = 0; i < providerIds.length; i += 80) {
        final batch = providerIds.skip(i).take(80).toList();
        final rows = await _supabase
            .from('staff_effective')
            .select(
              'service_provider_id,total_staff,service_hours,frequency,'
              'day_shift_timing,day_shift_staff,'
              'night_shift_timing,night_shift_staff,include_in_staff,'
              'day_shift_start_time,day_shift_end_time,'
              'night_shift_start_time,night_shift_end_time,'
              'day_shift_weekdays,night_shift_weekdays,'
              'day_shift_supervisors,day_shift_guards,'
              'night_shift_supervisors,night_shift_guards',
            )
            .inFilter('service_provider_id', batch);

        for (final row in List<Map<String, dynamic>>.from(rows)) {
          staffByProviderId[row['service_provider_id'].toString()] = row;
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _providers = current;
        _upcomingProviders = upcoming;
        _staffByProviderId
          ..clear()
          ..addAll(staffByProviderId);
        _archivedProviders = archivedItems.values.toList();
        _reportMonths
          ..clear()
          ..addAll(months)
          ..addAll(futureMonths);
        _reportIdByMonth
          ..clear()
          ..addAll(idsByMonth);
        _lifecycleHistoryByMonth
          ..clear()
          ..addAll(lifecycleHistory);
        _loading = false;
      });
    } catch (e, trace) {
      debugPrint('Service Providers load error: $e');
      debugPrintStack(stackTrace: trace);
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _initializeReportProviders() async {
    final month = _reportMonth!;

    final monthStart =
        '${month.year.toString().padLeft(4, '0')}-'
        '${month.month.toString().padLeft(2, '0')}-01';

    final previousReport = await _supabase
        .from('monthly_reports')
        .select('id, report_month')
        .eq('site_id', _siteId)
        .lt('report_month', monthStart)
        .order('report_month', ascending: false)
        .limit(1)
        .maybeSingle();

    if (previousReport != null) {
      final rows = await _supabase
          .from('service_providers')
          .select()
          .eq('report_id', previousReport['id'].toString())
          .eq('is_archived', false)
          .order('service')
          .order('company_pic');

      final sourceProviders = List<Map<String, dynamic>>.from(rows);

      if (sourceProviders.isNotEmpty) {
        await _inheritProviders(sourceProviders);
      }
      // The preceding month can legitimately have zero providers after an
      // archive. Never fall through to old unassigned rows in that case.
      return;
    }

    // Initial setup: assign existing unlinked records to this report.
    // Do not overwrite records already associated with another report.
    final unassignedRows = await _supabase
        .from('service_providers')
        .select()
        .filter('report_id', 'is', 'null')
        .eq('is_archived', false)
        .order('service')
        .order('company_pic');

    for (final provider in List<Map<String, dynamic>>.from(unassignedRows)) {
      await _supabase
          .from('service_providers')
          .update({
            'report_id': _reportId,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', provider['id'])
          .filter('report_id', 'is', 'null');
    }
  }

  /// Creates independent provider records for the current month.
  ///
  /// Attachments are associated with each new provider record while keeping
  /// their existing storage paths, so the underlying files do not need to
  /// be uploaded a second time.
  Future<void> _inheritProviders(
    List<Map<String, dynamic>> sourceProviders,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final month = _reportMonth!;
    for (final source in sourceProviders) {
      if (source['is_archived'] == true ||
          source['history_deleted_at'] != null) {
        continue;
      }
      final oldExpiry = _expiryDate(source);
      final nextExpiry = _parseDate(source['next_expiry_date']);
      final confirmed = _parseDate(source['renewal_confirmed_at']);
      DateTime? newStart = _parseDate(source['commencement_date']);
      DateTime? newExpiry = oldExpiry;
      DateTime? upcomingExpiry = nextExpiry;
      if (oldExpiry != null && _monthStart(oldExpiry).isBefore(month)) {
        if (confirmed == null ||
            nextExpiry == null ||
            nextExpiry.isBefore(_monthStart(month))) {
          continue;
        }
        newStart = _nextDay(oldExpiry);
        newExpiry = nextExpiry;
        upcomingExpiry = null;
      }
      if (newStart != null && _monthStart(newStart).isAfter(month)) {
        continue;
      }
      if (newExpiry != null && _monthStart(newExpiry).isBefore(month)) {
        continue;
      }
      final ended = _parseDate(source['lifecycle_date']);
      if (source['status'] == 'Terminated' &&
          ended != null &&
          _monthStart(ended).isBefore(month)) {
        continue;
      }
      final sourceId = source['id'].toString();
      final existing = await _supabase
          .from('service_providers')
          .select('id')
          .eq('report_id', _reportId)
          .eq('source_provider_id', sourceId)
          .limit(1);
      if (existing.isNotEmpty) {
        continue;
      }
      final copy = await _supabase
          .from('service_providers')
          .insert({
            'report_id': _reportId,
            'source_provider_id': sourceId,
            'service': source['service'],
            'company_pic': source['company_pic'],
            'contact': source['contact'],
            'schedule_staffing': source['schedule_staffing'],
            'commencement_date': _dateForDatabase(newStart),
            'expiry_renewal_date': _dateForDatabase(
              newExpiry,
            ), // PDF compatibility until its migration
            'expiry_date': _dateForDatabase(newExpiry),
            'renewal_date': source['renewal_date'],
            'renewal_confirmed_at': source['renewal_confirmed_at'],
            'next_expiry_date': _dateForDatabase(upcomingExpiry),
            'notes': source['notes'],
            'status': source['status'] ?? 'Active',
            'is_archived': false,
            'created_at': now,
            'updated_at': now,
            'lifecycle_date': source['lifecycle_date'],
            'lifecycle_reason': source['lifecycle_reason'],
          })
          .select()
          .single();
      await _copyAttachments(sourceId, copy['id'].toString());
    }
  }

  Future<void> _copyAttachments(String sourceId, String destId) async {
    final items = await _supabase
        .from('service_provider_attachments')
        .select()
        .eq('service_provider_id', sourceId);
    for (final a in List<Map<String, dynamic>>.from(items)) {
      await _supabase.from('service_provider_attachments').insert({
        'service_provider_id': destId,
        'file_name': a['file_name'],
        'storage_path': a['storage_path'],
        'google_drive_file_id': a['google_drive_file_id'],
        'content_type': a['content_type'],
        'file_size_bytes': a['file_size_bytes'],
        'uploaded_by': a['uploaded_by'],
      });
    }
  }

  Future<void> _openForm({
    Map<String, dynamic>? existing,
    DateTime? recordMonth,
  }) async {
    if (_saving) {
      return;
    }

    // Contract-derived cards have no saved row for their displayed month.
    // Save an independent monthly record instead of editing the source month.
    final inferred = existing?['_history_inferred'] == true;
    final editMonth = inferred ? (recordMonth ?? _reportMonth) : null;
    final targetReportId = editMonth == null
        ? null
        : _reportIdByMonth[_dateForDatabase(_monthStart(editMonth))!];
    if (inferred && targetReportId == null) {
      _message('The selected month has no monthly report.', error: true);
      return;
    }

    final result = await showDialog<_ProviderFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProviderFormDialog(
        existing: existing == null ? null : {...existing, 'is_archived': false},
        staff: existing == null
            ? null
            : _staffByProviderId[existing['id']?.toString()],
        suggestedServices: _suggestedServices,
        reportMonth: inferred
            ? editMonth
            : _reportMonths[existing?['report_id']?.toString()] ?? _reportMonth,
        effectiveStatus: existing == null
            ? null
            : _currentStatus(
                existing,
                reportMonth: inferred
                    ? editMonth
                    : _reportMonths[existing['report_id']?.toString()],
              ),
        allowArchive:
            !inferred &&
            (existing == null ||
                existing['report_id']?.toString() == _reportId),
      ),
    );

    if (result == null || !mounted) {
      return;
    }

    if (result.archive) {
      if (existing == null || result.archiveDate == null) {
        return;
      }
      final confirmed = await _confirmProviderAction(
        'Archive Service Provider?',
        'Archive "${existing['company_pic']}" effective '
            '${_formatDate(result.archiveDate!)}? Previous monthly reports '
            'will remain unchanged; future copies will be excluded.',
        'Archive',
      );
      if (confirmed && mounted) {
        await _setProviderArchived(
          existing,
          archive: true,
          date: result.archiveDate!,
          reason: result.archiveReason ?? '',
        );
      }
      return;
    }
    if (result.restore) {
      if (existing == null) {
        return;
      }
      final confirmed = await _confirmProviderAction(
        'Restore Service Provider?',
        'Restore "${existing['company_pic']}" to the main provider list '
            'for this report and re-enable matching future copies?',
        'Restore',
      );
      if (confirmed && mounted) {
        await _setProviderArchived(existing, archive: false);
      }
      return;
    }

    setState(() => _saving = true);

    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final Map<String, dynamic> saved;

      if (existing == null || inferred) {
        saved = await _supabase
            .from('service_providers')
            .insert({
              ...result.fields,
              'report_id': inferred ? targetReportId : _reportId,
              if (inferred) 'source_provider_id': existing!['id'],
              if (inferred) 'is_archived': false,
              if (inferred) 'restored_month': existing!['restored_month'],
              'created_at': now,
              'updated_at': now,
            })
            .select()
            .single();
        if (inferred) {
          await _copyAttachments(
            existing!['id'].toString(),
            saved['id'].toString(),
          );
        }
      } else {
        saved = await _supabase
            .from('service_providers')
            .update({...result.fields, 'updated_at': now})
            .eq('id', existing['id'])
            .eq('report_id', existing['report_id'])
            .select()
            .single();
      }

      // Only create a month-specific staff override when the user actually
      // changes a staffing control. Editing provider contact/contract details
      // must not freeze inherited staffing or overwrite another month's data.
      if (result.staffing != null) {
        final staffSaved = await _supabase
            .from('staff')
            .upsert({
              'service_provider_id': saved['id'],
              ...result.staffing!,
              'updated_at': now,
            }, onConflict: 'service_provider_id')
            .select('service_provider_id');
        if (staffSaved.isEmpty) {
          throw StateError(
            'Staffing could not be saved. Check report permissions.',
          );
        }
      }

      if (existing != null &&
          !inferred &&
          result.fields['status'] == 'Terminated' &&
          result.fields['lifecycle_date'] != null) {
        await _terminateFutureSnapshots(
          saved['id'].toString(),
          result.fields['lifecycle_date'].toString(),
          result.fields['lifecycle_reason']?.toString(),
        );
      }

      // Upload new files through the authenticated Supabase Edge Function.
      // The backend creates the Service Providers Google Drive folder and
      // inserts service_provider_attachments metadata using the user's RLS.
      for (final file in result.files) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
          throw Exception('${file.name} must be between 1 byte and 10 MB.');
        }

        final extension = file.name.contains('.')
            ? file.name.split('.').last.toLowerCase()
            : null;
        final contentType = switch (extension) {
          'pdf' => 'application/pdf',
          'png' => 'image/png',
          'jpg' || 'jpeg' => 'image/jpeg',
          'doc' => 'application/msword',
          'docx' =>
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          _ => 'application/octet-stream',
        };

        final response = await _supabase.functions.invoke(
          'upload-to-google-drive',
          body: {
            'serviceProviderId': saved['id'].toString(),
            'reportId': saved['report_id']?.toString() ?? _reportId,
            'fileName': file.name,
            'mimeType': contentType,
            'fileBase64': base64Encode(bytes),
          },
        );
        final result = response.data;
        if (response.status != 200 ||
            result is! Map ||
            result['success'] != true) {
          final reason = result is Map
              ? (result['error']?.toString() ?? 'Upload not confirmed')
              : 'Upload not confirmed';
          throw Exception('${file.name}: $reason');
        }
      }

      if (!mounted) {
        return;
      }

      await _loadProviders();

      if (!mounted) {
        return;
      }

      _message(
        result.files.isEmpty
            ? 'Service provider saved.'
            : 'Service provider saved with attachments.',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      _message('Unable to save service provider: $e', error: true);
      await _loadProviders();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  // Update only linked snapshots from later months in this property.
  // Earlier monthly reports remain intact after a termination.
  Future<void> _terminateFutureSnapshots(
    String sourceId,
    String endDate,
    String? reason,
  ) async {
    final stop = _parseDate(endDate);
    if (stop == null) {
      return;
    }
    final laterReports = await _supabase
        .from('monthly_reports')
        .select('id')
        .eq('site_id', _siteId)
        .gt('report_month', _dateForDatabase(_monthStart(stop))!);
    final laterIds = List<Map<String, dynamic>>.from(
      laterReports,
    ).map((row) => row['id'].toString()).toSet();
    if (laterIds.isEmpty) {
      return;
    }
    final queue = <String>[sourceId];
    final seen = <String>{sourceId};
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      final children = await _supabase
          .from('service_providers')
          .select('id,report_id')
          .eq('source_provider_id', parent);
      for (final child in List<Map<String, dynamic>>.from(children)) {
        final id = child['id']?.toString();
        if (id == null || !seen.add(id)) {
          continue;
        }
        queue.add(id);
        if (!laterIds.contains(child['report_id']?.toString())) {
          continue;
        }
        final updated = await _supabase
            .from('service_providers')
            .update({
              'status': 'Terminated',
              'lifecycle_date': endDate,
              'lifecycle_reason': reason,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', id)
            .eq('report_id', child['report_id'])
            .select('id');
        if (updated.isEmpty) {
          throw StateError(
            'Failed to update a future provider snapshot. '
            'Check UPDATE and SELECT RLS policies.',
          );
        }
      }
    }
  }

  // Delete one logical company across every report month for this property.
  // Match linked provider IDs, never company/PIC text, so a similarly named
  // provider at this or another property is not accidentally removed.
  Future<void> _deleteCompany(Map<String, dynamic> provider) async {
    if (_saving) return;
    final selectedId = provider['id']?.toString();
    if (selectedId == null || selectedId.isEmpty) {
      _message('Unable to identify the selected company.', error: true);
      return;
    }

    final confirmed = await _confirmProviderAction(
      'Delete Company?',
      'Permanently delete "${provider['company_pic']}" from this property? '
          'All linked records in every Service Providers and Staff Management '
          'report month, including History, Upcoming Appointments and manually '
          'archived records, will be deleted. This cannot be undone.',
      'Delete Company',
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      // Include past, present and FUTURE reports. Using only the selected
      // month would leave linked copies that can later reappear in History.
      const pageSize = 500;
      final reportIds = <String>{};
      var offset = 0;
      while (true) {
        final result = await _supabase
            .from('monthly_reports')
            .select('id')
            .eq('site_id', _siteId)
            .order('id')
            .range(offset, offset + pageSize - 1);
        final rows = List<Map<String, dynamic>>.from(result);
        for (final row in rows) {
          final id = row['id']?.toString();
          if (id != null && id.isNotEmpty) reportIds.add(id);
        }
        if (rows.length < pageSize) break;
        offset += pageSize;
      }
      if (!reportIds.contains(_reportId)) {
        throw StateError(
          'The selected report does not belong to this property.',
        );
      }

      // Read the entire provider lineage for this property, even snapshots
      // already hidden from a particular month or manually archived.
      final byId = <String, Map<String, dynamic>>{};
      final siteReportIds = reportIds.toList()..sort();
      for (var i = 0; i < siteReportIds.length; i += 80) {
        final batch = siteReportIds.skip(i).take(80).toList();
        var rowOffset = 0;
        while (true) {
          final result = await _supabase
              .from('service_providers')
              .select('id,report_id,source_provider_id')
              .inFilter('report_id', batch)
              .order('id')
              .range(rowOffset, rowOffset + pageSize - 1);
          final rows = List<Map<String, dynamic>>.from(result);
          for (final row in rows) {
            final id = row['id']?.toString();
            if (id != null && id.isNotEmpty) byId[id] = row;
          }
          if (rows.length < pageSize) break;
          rowOffset += pageSize;
        }
      }
      if (!byId.containsKey(selectedId)) {
        throw StateError(
          'The selected company was not found at this property.',
        );
      }

      // Each monthly copy has source_provider_id pointing to its parent.
      // Traverse both directions, including siblings of an older missing
      // parent. Only IDs belonging to THIS property's reports are deleted.
      final linked = <String, Set<String>>{};
      for (final row in byId.values) {
        final id = row['id']?.toString() ?? '';
        final parent = row['source_provider_id']?.toString() ?? '';
        if (id.isEmpty || parent.isEmpty) continue;
        (linked[id] ??= <String>{}).add(parent);
        (linked[parent] ??= <String>{}).add(id);
      }
      final seen = <String>{};
      final pending = <String>[selectedId];
      for (var i = 0; i < pending.length; i++) {
        final id = pending[i];
        if (!seen.add(id)) continue;
        for (final neighbor in linked[id] ?? const <String>{}) {
          if (!seen.contains(neighbor)) pending.add(neighbor);
        }
      }
      final companyIds = seen.where(byId.containsKey).toList()..sort();
      if (companyIds.isEmpty) {
        throw StateError('No linked company records could be found.');
      }

      // Remove dependent records first. A staff row may be shared by all
      // reporting months; it is deleted only because the whole company is
      // being deleted. Do not delete the underlying files: attachment paths
      // may also be used by other records or hosted in Google Drive.
      for (var i = 0; i < companyIds.length; i += 80) {
        final batch = companyIds.skip(i).take(80).toList();
        await _supabase
            .from('staff')
            .delete()
            .inFilter('service_provider_id', batch);
        await _supabase
            .from('service_provider_attachments')
            .delete()
            .inFilter('service_provider_id', batch);

        // If RLS silently blocks either delete, do not remove the company
        // record while its dependent rows remain accessible.
        final remainingStaff = await _supabase
            .from('staff')
            .select('service_provider_id')
            .inFilter('service_provider_id', batch)
            .limit(1);
        final remainingAttachments = await _supabase
            .from('service_provider_attachments')
            .select('service_provider_id')
            .inFilter('service_provider_id', batch)
            .limit(1);
        if (remainingStaff.isNotEmpty || remainingAttachments.isNotEmpty) {
          throw StateError(
            'Linked staff or attachments could not be deleted. '
            'Check DELETE and SELECT permissions for this property.',
          );
        }
      }

      // Delete descendants before their parents to respect the existing
      // source_provider_id foreign key, without changing the DB schema.
      final companySet = companyIds.toSet();
      int depthOf(String id) {
        var depth = 0;
        var cursor = id;
        final visited = <String>{id};
        while (true) {
          final parent = byId[cursor]?['source_provider_id']?.toString();
          if (parent == null ||
              !companySet.contains(parent) ||
              !visited.add(parent)) {
            break;
          }
          depth++;
          cursor = parent;
        }
        return depth;
      }

      final depths = <String, int>{
        for (final id in companyIds) id: depthOf(id),
      };
      companyIds.sort((a, b) {
        final byDepth = depths[b]!.compareTo(depths[a]!);
        return byDepth != 0 ? byDepth : a.compareTo(b);
      });

      var index = 0;
      while (index < companyIds.length) {
        final level = depths[companyIds[index]]!;
        final batch = <String>[];
        while (index < companyIds.length &&
            depths[companyIds[index]] == level &&
            batch.length < 80) {
          batch.add(companyIds[index]);
          index++;
        }
        final removed = await _supabase
            .from('service_providers')
            .delete()
            .inFilter('id', batch)
            .select('id');
        if (removed.length != batch.length) {
          throw StateError(
            'Some company records could not be deleted. '
            'Check DELETE and SELECT permissions.',
          );
        }
      }

      await _loadProviders();
      if (mounted) {
        _message(
          'Company deleted from all Service Providers and Staff months.',
        );
      }
    } catch (e) {
      if (mounted) {
        _message('Unable to complete company deletion: $e', error: true);
        await _loadProviders();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Archived Records references an existing provider snapshot. Restoration
  // may target a prior monthly report without recreating a History UI section.
  Future<void> _restoreProvider(Map<String, dynamic> provider) async {
    if (_saving || _reportMonth == null) {
      return;
    }
    final automatic = provider['_auto_archived'] == true;
    final automaticFrom = _parseDate(provider['_archive_effective_date']);
    final keys = _reportIdByMonth.keys.where((key) {
      final month = _parseDate(key);
      return month != null &&
          (!automatic ||
              automaticFrom == null ||
              !_monthStart(month).isBefore(_monthStart(automaticFrom)));
    }).toList()..sort((a, b) => b.compareTo(a));
    final defaultKey = _dateForDatabase(_monthStart(_reportMonth!))!;
    if (!keys.contains(defaultKey)) {
      _message(
        'Select a report month when this contract is archived.',
        error: true,
      );
      return;
    }
    String selectedKey = defaultKey;
    DateTime? newExpiry;
    final oldExpiry = _expiryDate(provider);
    final stopDate = _parseDate(provider['lifecycle_date']);
    final wasTerminated = provider['status'] == 'Terminated';
    bool existingContractValid() {
      final month = _parseDate(selectedKey)!;
      return !wasTerminated &&
          oldExpiry != null &&
          !_monthStart(oldExpiry).isBefore(month);
    }

    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          backgroundColor: AppColors.white,
          title: Text(
            automatic
                ? (wasTerminated
                      ? 'Reactivate Service Provider'
                      : 'Renew Service Provider')
                : 'Restore Service Provider',
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Choose the report month for this provider.'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedKey,
                  isExpanded: true,
                  items: [
                    for (final value in keys)
                      DropdownMenuItem(
                        value: value,
                        child: Text(_monthLabel(_parseDate(value)!)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      updateDialog(() {
                        selectedKey = v;
                        newExpiry = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  existingContractValid()
                      ? 'The existing Expiry Date is still valid for this month. '
                            'You may keep it or enter a new expiry for a new contract.'
                      : 'Enter a valid new Expiry Date to start a new contract '
                            'period. Earlier monthly reports remain unchanged.',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final month = _parseDate(selectedKey)!;
                    final previousEnd = wasTerminated ? stopDate : oldExpiry;
                    final first = previousEnd == null
                        ? month
                        : _nextDay(previousEnd);
                    final initial =
                        newExpiry ??
                        DateTime(first.year + 1, first.month, first.day);
                    final selected = await showDatePicker(
                      context: dialogContext,
                      initialDate: initial,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2200),
                    );
                    if (selected != null) {
                      updateDialog(() => newExpiry = selected);
                    }
                  },
                  icon: const Icon(Icons.event),
                  label: Text(
                    newExpiry == null
                        ? 'Keep expiry / Choose new date'
                        : _formatDate(newExpiry!),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: existingContractValid() || newExpiry != null
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(
                automatic
                    ? (wasTerminated ? 'Reactivate' : 'Renew')
                    : 'Restore',
              ),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) {
      return;
    }
    final targetReport = _reportIdByMonth[selectedKey];
    if (targetReport == null) {
      _message('The selected month has no monthly report.', error: true);
      return;
    }
    final targetMonth = _parseDate(selectedKey)!;
    // Only start a new period when the previous period has expired;
    // restoring an archived but still-valid period keeps its original start.
    final newContract = !existingContractValid();
    final previousEnd = wasTerminated ? stopDate : oldExpiry;
    final start = newContract && previousEnd != null
        ? _nextDay(previousEnd)
        : (_parseDate(provider['commencement_date']) ?? targetMonth);
    final finalExpiry = newExpiry ?? oldExpiry;
    if (finalExpiry == null ||
        _monthStart(start).isAfter(targetMonth) ||
        _monthStart(finalExpiry).isBefore(targetMonth) ||
        finalExpiry.isBefore(start)) {
      _message(
        'Start and Expiry Dates must cover the restored month.',
        error: true,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final sourceId = provider['id'].toString();
      final fields = <String, dynamic>{
        'service': provider['service'],
        'company_pic': provider['company_pic'],
        'contact': provider['contact'],
        'schedule_staffing': provider['schedule_staffing'],
        'notes': provider['notes'],
        'commencement_date': _dateForDatabase(start),
        'expiry_date': _dateForDatabase(finalExpiry),
        'expiry_renewal_date': _dateForDatabase(finalExpiry),
        'renewal_date': provider['renewal_date'],
        'renewal_confirmed_at': selectedKey,
        'next_expiry_date': null,
        'status': 'Active',
        'is_archived': false,
        'archived_at': null,
        'archive_reason': null,
        'restored_month': selectedKey,
        'lifecycle_date': null,
        'lifecycle_reason': null,
        'history_deleted_at': null,
        'updated_at': now,
      };
      // In-place restore of the SAME monthly row: do not duplicate the provider.
      if (provider['report_id']?.toString() == targetReport &&
          provider['is_archived'] == true &&
          !newContract) {
        await _supabase
            .from('service_providers')
            .update(fields)
            .eq('id', sourceId)
            .eq('report_id', targetReport)
            .select('id')
            .single();
        // Undo the old archive on future snapshots created by the same action.
        final archiveTimestamp = provider['archived_at']?.toString() ?? '';
        if (archiveTimestamp.isNotEmpty) {
          await _updateFutureProviderCopies(
            sourceId,
            archive: false,
            archiveTimestamp: archiveTimestamp,
          );
        }
      } else {
        final matches = await _supabase
            .from('service_providers')
            .select('id')
            .eq('report_id', targetReport)
            .eq('source_provider_id', sourceId)
            .limit(1);
        if (matches.isNotEmpty) {
          await _supabase
              .from('service_providers')
              .update(fields)
              .eq('id', matches.first['id'])
              .eq('report_id', targetReport)
              .select('id')
              .single();
        } else {
          final inserted = await _supabase
              .from('service_providers')
              .insert({
                ...fields,
                'report_id': targetReport,
                'source_provider_id': sourceId,
                'created_at': now,
              })
              .select('id')
              .single();
          await _copyAttachments(sourceId, inserted['id'].toString());
        }
      }
      await _loadProviders();
      if (mounted) {
        _message(
          selectedKey == defaultKey
              ? 'Restored to This Month.'
              : 'Restored to the ${_monthLabel(targetMonth)} monthly report.',
        );
      }
    } catch (e) {
      if (mounted) {
        _message('Restore failed: $e', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<bool> _confirmProviderAction(
    String title,
    String message,
    String confirmLabel,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  // Copies of each provider are linked by source_provider_id. Follow only
  // descendants in this property's FUTURE reports; never alter past reports.
  Future<void> _updateFutureProviderCopies(
    String sourceId, {
    required bool archive,
    required String archiveTimestamp,
  }) async {
    final nextMonth = DateTime(_reportMonth!.year, _reportMonth!.month + 1);
    final futureReports = await _supabase
        .from('monthly_reports')
        .select('id')
        .eq('site_id', _siteId)
        .gte('report_month', _dateForDatabase(nextMonth)!);
    final futureReportIds = List<Map<String, dynamic>>.from(
      futureReports,
    ).map((r) => r['id'].toString()).toSet();
    if (futureReportIds.isEmpty) {
      return;
    }

    final queue = <String>[sourceId];
    final seen = <String>{sourceId};
    while (queue.isNotEmpty) {
      final parentId = queue.removeAt(0);
      final children = await _supabase
          .from('service_providers')
          .select('id, report_id, is_archived, archived_at')
          .eq('source_provider_id', parentId);
      for (final child in List<Map<String, dynamic>>.from(children)) {
        final childId = child['id'].toString();
        if (!seen.add(childId)) {
          continue;
        }
        if (!futureReportIds.contains(child['report_id']?.toString())) {
          continue;
        }
        queue.add(childId);
        final isAlreadyArchived = child['is_archived'] == true;
        if (archive && isAlreadyArchived) {
          continue;
        }
        if (!archive) {
          if (!isAlreadyArchived) {
            continue;
          }
          // Restore only copies archived by this same action, not providers
          // archived independently in a later month.
          final childDate = _parseDate(child['archived_at']);
          final originalDate = _parseDate(archiveTimestamp);
          if (childDate == null ||
              originalDate == null ||
              !childDate.isAtSameMomentAs(originalDate)) {
            continue;
          }
        }
        final updated = await _supabase
            .from('service_providers')
            .update({
              'is_archived': archive,
              'archived_at': archive ? archiveTimestamp : null,
              'archive_reason': null,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', childId)
            .eq('report_id', child['report_id'].toString())
            .select('id');
        if (updated.isEmpty) {
          throw StateError(
            'Could not update future provider copy $childId. '
            'Check the Supabase UPDATE and SELECT policies.',
          );
        }
      }
    }
  }

  Future<void> _setProviderArchived(
    Map<String, dynamic> provider, {
    required bool archive,
    DateTime? date,
    String reason = '',
  }) async {
    if (_saving) {
      return;
    }
    if (archive && (date == null || reason.trim().isEmpty)) {
      _message('Archive date and reason are required.', error: true);
      return;
    }
    final originalArchivedAt = provider['archived_at']?.toString() ?? '';
    final archiveTimestamp = archive
        ? '${_dateForDatabase(date!)}T12:00:00+08:00'
        : originalArchivedAt;
    setState(() => _saving = true);
    try {
      final updated = await _supabase
          .from('service_providers')
          .update({
            'is_archived': archive,
            'archived_at': archive ? archiveTimestamp : null,
            'archive_reason': archive ? reason.trim() : null,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', provider['id'])
          .eq('report_id', _reportId)
          .select('id');
      if (updated.isEmpty) {
        throw StateError('No record was updated. Check permissions.');
      }
      await _updateFutureProviderCopies(
        provider['id'].toString(),
        archive: archive,
        archiveTimestamp: archiveTimestamp,
      );
      if (!mounted) {
        return;
      }
      await _loadProviders();
      if (mounted) {
        _message(
          archive
              ? 'Provider archived; previous months remain unchanged.'
              : 'Provider restored to the main list.',
        );
      }
    } catch (e) {
      if (mounted) {
        _message(
          'Could not ${archive ? 'archive' : 'restore'} provider: $e',
          error: true,
        );
        await _loadProviders();
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _showAttachments(Map<String, dynamic> provider) async {
    try {
      final rows = await _supabase
          .from('service_provider_attachments')
          .select()
          .eq('service_provider_id', provider['id'])
          .order('created_at', ascending: false);

      if (!mounted) {
        return;
      }

      final attachments = List<Map<String, dynamic>>.from(rows);

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.white,
          surfaceTintColor: Colors.transparent,
          title: Text(
            '${provider['company_pic']} — Attachments',
            style: const TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 480,
            child: attachments.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No attachments uploaded.'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: attachments.length,
                    separatorBuilder: (context, index) => const Divider(),
                    itemBuilder: (context, index) {
                      final attachment = attachments[index];

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.attach_file,
                          color: AppColors.red,
                        ),
                        title: Text(
                          attachment['file_name']?.toString() ?? 'File',
                        ),
                        trailing: IconButton(
                          tooltip: 'Open attachment',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () async {
                            try {
                              final storagePath =
                                  attachment['storage_path']
                                      ?.toString()
                                      .trim() ??
                                  '';
                              final storedDriveId =
                                  attachment['google_drive_file_id']
                                      ?.toString()
                                      .trim() ??
                                  '';

                              late final Uri fileUri;
                              if (storagePath.startsWith('google-drive/') ||
                                  storedDriveId.isNotEmpty) {
                                // Google Drive files are not in Supabase Storage.
                                // Open them using the ID saved by the upload function.
                                final fileId = storedDriveId.isNotEmpty
                                    ? storedDriveId
                                    : storagePath
                                          .substring('google-drive/'.length)
                                          .trim();
                                if (!RegExp(
                                  r'^[A-Za-z0-9_-]{10,200}$',
                                ).hasMatch(fileId)) {
                                  throw Exception(
                                    'Invalid Google Drive file ID.',
                                  );
                                }
                                fileUri = Uri.https(
                                  'drive.google.com',
                                  '/file/d/$fileId/view',
                                );
                              } else {
                                // Preserve existing support for legacy files in
                                // the Supabase Storage attachment bucket.
                                if (storagePath.isEmpty) {
                                  throw Exception(
                                    'Attachment storage path is missing.',
                                  );
                                }
                                final url = await _supabase.storage
                                    .from(_bucket)
                                    .createSignedUrl(storagePath, 60);
                                fileUri = Uri.parse(url);
                              }

                              final opened = await launchUrl(
                                fileUri,
                                mode: LaunchMode.externalApplication,
                              );

                              if (!opened) {
                                throw Exception('Could not open the file.');
                              }
                            } catch (e) {
                              _message(
                                'Unable to open attachment: $e',
                                error: true,
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      _message('Unable to load attachments: $e', error: true);
    }
  }

  List<Map<String, dynamic>> get _filteredProviders => _providers.where((p) {
    return (_selectedStatuses.isEmpty ||
            _selectedStatuses.contains(_currentStatus(p))) &&
        _matchesSearch(p);
  }).toList();

  List<Map<String, dynamic>> get _filteredUpcomingProviders =>
      _selectedStatuses.isEmpty
      ? _upcomingProviders.where(_matchesSearch).toList()
      : <Map<String, dynamic>>[];

  List<Map<String, dynamic>> get _filteredArchivedProviders =>
      _archivedProviders.where(_matchesSearch).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Service Providers'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving ? null : _loadProviders,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading || _saving ? null : () => _openForm(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Provider'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.red),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.red, size: 44),
              const SizedBox(height: 12),
              const Text(
                'Unable to load service providers.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SelectableText(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadProviders,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }
    final providers = _filteredProviders;
    final upcoming = _filteredUpcomingProviders;
    final archivedByMonth = <String, List<Map<String, dynamic>>>{};
    final uniqueArchiveIds = <String>{};
    for (final provider in _filteredArchivedProviders) {
      if (!uniqueArchiveIds.add(provider['id'].toString())) {
        continue;
      }
      final status = _currentStatus(
        provider,
        reportMonth: _reportMonths[provider['report_id']?.toString()],
      );
      if (_selectedStatuses.isNotEmpty && !_selectedStatuses.contains(status)) {
        continue;
      }
      final sourceDate =
          _parseDate(provider['_archive_effective_date']) ??
          _parseDate(provider['archived_at']) ??
          _reportMonths[provider['report_id']?.toString()] ??
          _reportMonth;
      if (sourceDate == null) {
        continue;
      }
      final month = _monthLabel(sourceDate);
      (archivedByMonth[month] ??= []).add(provider);
    }
    final archivedGroups = archivedByMonth.entries.toList()
      ..sort(
        (a, b) => (_parseMonthLabel(b.key) ?? DateTime(1900)).compareTo(
          _parseMonthLabel(a.key) ?? DateTime(1900),
        ),
      );
    final archiveTotal = archivedGroups.fold<int>(
      0,
      (total, group) => total + group.value.length,
    );

    return RefreshIndicator(
      color: AppColors.red,
      onRefresh: _loadProviders,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSummary(),
          const SizedBox(height: 14),
          _buildSearchAndFilters(),
          const SizedBox(height: 20),
          _sectionHeading(
            'This Month',
            upcoming.isEmpty
                ? ''
                : '${upcoming.length} upcoming next-month appointment(s) '
                      '(excluded from current contract status totals).',
            providers.length + upcoming.length,
          ),
          if (providers.isEmpty && upcoming.isEmpty)
            _providers.isEmpty && _upcomingProviders.isEmpty
                ? _buildEmptyState()
                : _emptySection(
                    'No providers match the selected filters or search.',
                  ),
          for (var i = 0; i < providers.length; i++)
            _buildProviderCard(providers[i], i + 1),
          // Upcoming appointments are displayed in This Month, not a separate
          // section, and are excluded from Active / Renewal Due / Expired totals.
          for (var i = 0; i < upcoming.length; i++)
            _buildProviderCard(
              upcoming[i],
              providers.length + i + 1,
              upcoming: true,
            ),
          const SizedBox(height: 22),
          _sectionHeading('Archived Records', '', archiveTotal),
          if (archivedGroups.isEmpty)
            _emptySection('No archived provider records.')
          else
            for (final entry in archivedGroups)
              Card(
                color: AppColors.white,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: AppColors.border),
                ),
                child: ExpansionTile(
                  key: ValueKey('service-archive-$_reportId-${entry.key}'),
                  title: Text(
                    entry.key,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${entry.value.length} provider record(s)',
                    style: const TextStyle(color: AppColors.grey),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    for (var i = 0; i < entry.value.length; i++)
                      _buildProviderCard(
                        entry.value[i],
                        i + 1,
                        archived: true,
                        snapshotMonth: _parseMonthLabel(entry.key),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // Parses the month label written by _monthLabel, for historical badges.
  DateTime? _parseMonthLabel(String label) {
    const months = [
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
    final parts = label.split(' ');
    if (parts.length != 2) {
      return null;
    }
    final month = months.indexOf(parts[0]) + 1;
    final year = int.tryParse(parts[1]);
    return month == 0 || year == null ? null : DateTime(year, month);
  }

  Widget _sectionHeading(String title, String detail, int count) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(fontSize: 12, color: AppColors.grey),
                ),
              ],
            ],
          ),
        ),
        Text(
          '$count records',
          style: const TextStyle(color: AppColors.grey, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _emptySection(String message) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.white,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.grey)),
  );

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.charcoal,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.red),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CONTRACTS & COMPLIANCE',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Service Providers',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthLabel(_reportMonth ?? DateTime.now())} '
            '• Report ID: $_reportId',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    Widget statusCard(
      String label,
      int count,
      IconData icon,
      Color color,
      String status,
    ) => Expanded(
      child: InkWell(
        onTap: () => _toggleStatus(status),
        borderRadius: BorderRadius.circular(14),
        child: _summaryCard(label, count, icon, color),
      ),
    );
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() {
              _selectedStatuses.clear();
              _searchController.clear();
            }),
            child: _summaryCard(
              'Total Providers',
              _providers.length,
              Icons.business_outlined,
              AppColors.red,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            statusCard(
              'Active',
              _activeCount,
              Icons.verified_outlined,
              const Color(0xFF22683D),
              'Active',
            ),
            const SizedBox(width: 12),
            statusCard(
              'Renewal Due',
              _renewalDueCount,
              Icons.event_repeat_outlined,
              const Color(0xFF966400),
              'Renewal Due',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            statusCard(
              'Expired',
              _expiredCount,
              Icons.warning_amber_outlined,
              AppColors.red,
              'Expired',
            ),
            const SizedBox(width: 12),
            statusCard(
              'No Longer Used',
              _noLongerUsedCount,
              Icons.block_outlined,
              AppColors.grey,
              'Terminated',
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(String label, int count, IconData icon, Color accent) {
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.025),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: accent, size: 24),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$count',
                    style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search provider, service, contact or notes...',
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
            border: const OutlineInputBorder(),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.clear),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text(
              'Showing:',
              style: TextStyle(fontSize: 12, color: AppColors.grey),
            ),
            if (_selectedStatuses.isEmpty)
              const Text('All statuses', style: TextStyle(fontSize: 12)),
            ..._statuses
                .where(_selectedStatuses.contains)
                .map(
                  (status) => InputChip(
                    label: Text(_statusLabel(status)),
                    onDeleted: () => _toggleStatus(status),
                    showCheckmark: false,
                    deleteIcon: const Icon(Icons.close, size: 14),
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: Color(0xFFD8B5B0)),
                    backgroundColor: AppColors.white,
                  ),
                ),
            if (_selectedStatuses.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _selectedStatuses.clear()),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                child: const Text('Clear filter'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.business_outlined, size: 42, color: AppColors.red),
          const SizedBox(height: 12),
          const Text(
            'No service providers found',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Add a provider or adjust your search and status filters.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.grey, height: 1.5),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : () => _openForm(),
            icon: const Icon(Icons.add),
            label: const Text('Add First Provider'),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderCard(
    Map<String, dynamic> provider,
    int number, {
    bool historical = false,
    bool archived = false,
    bool upcoming = false,
    DateTime? snapshotMonth,
  }) {
    final statusAsOf = historical
        ? snapshotMonth
        : archived && _parseDate(provider['restored_month']) == null
        ? _reportMonth
        : snapshotMonth;
    final status = upcoming
        ? 'Upcoming'
        : _currentStatus(provider, reportMonth: statusAsOf);
    final accent = archived
        ? AppColors.grey
        : upcoming
        ? const Color(0xFF966400)
        : _statusColor(status);
    final start = _parseDate(provider['commencement_date']);
    final expiry = _expiryDate(provider);
    final label = provider['company_pic']?.toString() ?? 'Unnamed Provider';
    final archiveAction = provider['_auto_archived'] == true
        ? provider['_auto_archive_cause'] == 'Terminated'
              ? 'Reactivate'
              : 'Renew'
        : 'Restore';
    final schedule = _scheduleDescription(provider);
    final notes = _displayProviderNotes(provider);
    final asOf = snapshotMonth ?? _reportMonth;
    final reference = asOf == null
        ? DateUtils.dateOnly(DateTime.now())
        : _monthEnd(asOf);
    final daysToExpiry = expiry?.difference(reference).inDays;

    Widget dateBox(String title, DateTime? value) => Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8FA),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.grey,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value == null ? 'Not set' : _formatDate(value),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.black,
            ),
          ),
        ],
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: AppColors.red,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_hasText(provider['service'])) ...[
                      const SizedBox(height: 4),
                      Text(
                        provider['service'].toString(),
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Align(
                alignment: Alignment.topRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    archived ? 'Archived' : _statusLabel(status),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Compact horizontal date boxes; wrap neatly on narrow screens.
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              dateBox('Start Date', start),
              dateBox('Expiry / Renewal Date', expiry),
            ],
          ),
          const SizedBox(height: 16),
          if (_hasText(provider['contact']))
            _detailRow('Contact Details', provider['contact'].toString()),
          if (_hasText(notes)) _detailRow('Notes', notes),
          if (_hasText(schedule)) _detailRow('Schedule', schedule),
          if (daysToExpiry != null &&
              !archived &&
              !historical &&
              !upcoming &&
              status != 'Terminated')
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 6),
              child: Text(
                daysToExpiry < 0
                    ? 'Expired ${daysToExpiry.abs()} day(s) before report month end'
                    : daysToExpiry == 0
                    ? 'Expires on report month end'
                    : 'Expires in $daysToExpiry day(s) from report month end',
                style: TextStyle(
                  color: daysToExpiry <= 30 ? AppColors.red : AppColors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (status == 'Terminated' && !archived) ...[
            _detailRow(
              'Date No Longer Used',
              _displayDate(provider['lifecycle_date']),
            ),
            if (_hasText(provider['lifecycle_reason']))
              _detailRow('Reason', provider['lifecycle_reason'].toString()),
          ],
          if (archived) ...[
            _detailRow(
              'Archive Date',
              _displayDate(
                provider['_archive_effective_date'] ?? provider['archived_at'],
              ),
            ),
            if (_hasText(
              provider['_archive_reason'] ?? provider['archive_reason'],
            ))
              _detailRow(
                'Archive Reason',
                (provider['_archive_reason'] ?? provider['archive_reason'])
                    .toString(),
              ),
          ],
          const Divider(height: 26, color: AppColors.border),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: archived
                  ? [
                      // Archived Records: restore or delete the entire company.
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _restoreProvider(provider),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(Icons.restore, size: 18),
                        label: Text(archiveAction),
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _deleteCompany(provider),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Delete'),
                      ),
                    ]
                  : historical
                  ? [
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _showAttachments(provider),
                        icon: const Icon(Icons.attach_file, size: 18),
                        label: const Text('Attachments'),
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _openForm(
                                existing: provider,
                                recordMonth: snapshotMonth,
                              ),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit'),
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _deleteCompany(provider),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Delete'),
                      ),
                    ]
                  : [
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _showAttachments(provider),
                        icon: const Icon(Icons.attach_file, size: 18),
                        label: const Text('Attachments'),
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _openForm(existing: provider),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit'),
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _deleteCompany(provider),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Delete'),
                      ),
                    ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String description) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 155,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.grey, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            description,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ProviderFormResult {
  final Map<String, dynamic> fields;
  final Map<String, dynamic>? staffing;
  final List<XFile> files;
  final bool archive;
  final bool restore;
  final DateTime? archiveDate;
  final String? archiveReason;

  const _ProviderFormResult({
    this.fields = const {},
    this.staffing,
    this.files = const [],
    this.archive = false,
    this.restore = false,
    this.archiveDate,
    this.archiveReason,
  });
}

class _ProviderFormDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final Map<String, dynamic>? staff;
  final List<String> suggestedServices;
  final DateTime? reportMonth;
  final String? effectiveStatus;
  final bool allowArchive;

  const _ProviderFormDialog({
    required this.existing,
    required this.staff,
    required this.suggestedServices,
    required this.reportMonth,
    this.effectiveStatus,
    this.allowArchive = true,
  });

  @override
  State<_ProviderFormDialog> createState() => _ProviderFormDialogState();
}

class _ProviderFormDialogState extends State<_ProviderFormDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _service;
  late final TextEditingController _company;
  late final TextEditingController _contact;
  late final TextEditingController _schedule;
  late final TextEditingController _notes;
  late final TextEditingController _statusReason;
  late final TextEditingController _archiveReason;
  late final TextEditingController _totalStaff;
  late final TextEditingController _dayShiftStaff;
  late final TextEditingController _nightShiftStaff;
  late final TextEditingController _dayShiftSupervisors;
  late final TextEditingController _dayShiftGuards;
  late final TextEditingController _nightShiftSupervisors;
  late final TextEditingController _nightShiftGuards;
  late final TextEditingController _serviceHours;
  late String _staffFrequency;
  late bool _includeInStaff;
  bool _staffChanged = false;
  TimeOfDay? _dayShiftStart;
  TimeOfDay? _dayShiftEnd;
  TimeOfDay? _nightShiftStart;
  TimeOfDay? _nightShiftEnd;
  final Set<int> _dayWeekdays = <int>{};
  final Set<int> _nightWeekdays = <int>{};
  bool _archiveMode = false;
  bool _noLongerUsed = false;
  DateTime? _archiveDate;

  DateTime? _commencement;
  DateTime? _expiry;
  DateTime? _nextExpiry;
  DateTime? _renewalConfirmedDate;
  DateTime? _statusDate;

  late String _status;
  List<XFile> _files = [];

  @override
  void initState() {
    super.initState();

    final provider = widget.existing;

    _service = TextEditingController(
      text: provider?['service']?.toString() ?? '',
    );
    _company = TextEditingController(
      text: provider?['company_pic']?.toString() ?? '',
    );
    _contact = TextEditingController(
      text: provider?['contact']?.toString() ?? '',
    );
    _schedule = TextEditingController(
      text: provider?['schedule_staffing']?.toString() ?? '',
    );
    _notes = TextEditingController(text: provider?['notes']?.toString() ?? '');
    _statusReason = TextEditingController(
      text: provider?['lifecycle_reason']?.toString() ?? '',
    );
    _archiveReason = TextEditingController();

    // The form reads inherited staff data for display, but does not save
    // a new monthly snapshot until a staffing field is explicitly changed.
    final staff = widget.staff;
    String textValue(dynamic value) => value == null ? '' : value.toString();
    _totalStaff = TextEditingController(text: textValue(staff?['total_staff']));
    _dayShiftStaff = TextEditingController(
      text: textValue(staff?['day_shift_staff']),
    );
    _nightShiftStaff = TextEditingController(
      text: textValue(staff?['night_shift_staff']),
    );
    _dayShiftSupervisors = TextEditingController(
      text: textValue(staff?['day_shift_supervisors']),
    );
    _dayShiftGuards = TextEditingController(
      text: textValue(staff?['day_shift_guards']),
    );
    _nightShiftSupervisors = TextEditingController(
      text: textValue(staff?['night_shift_supervisors']),
    );
    _nightShiftGuards = TextEditingController(
      text: textValue(staff?['night_shift_guards']),
    );
    _serviceHours = TextEditingController(
      text: textValue(staff?['service_hours']),
    );
    _staffFrequency = textValue(staff?['frequency']);
    _includeInStaff = staff?['include_in_staff'] != false;
    _dayShiftStart = _parseShiftTime(
      staff?['day_shift_start_time'],
      staff?['day_shift_timing'],
      first: true,
    );
    _dayShiftEnd = _parseShiftTime(
      staff?['day_shift_end_time'],
      staff?['day_shift_timing'],
      first: false,
    );
    _nightShiftStart = _parseShiftTime(
      staff?['night_shift_start_time'],
      staff?['night_shift_timing'],
      first: true,
    );
    _nightShiftEnd = _parseShiftTime(
      staff?['night_shift_end_time'],
      staff?['night_shift_timing'],
      first: false,
    );
    for (final weekday in (staff?['day_shift_weekdays'] as List?) ?? const []) {
      final day = int.tryParse(weekday.toString());
      if (day != null && day >= 1 && day <= 7) _dayWeekdays.add(day);
    }
    for (final weekday
        in (staff?['night_shift_weekdays'] as List?) ?? const []) {
      final day = int.tryParse(weekday.toString());
      if (day != null && day >= 1 && day <= 7) _nightWeekdays.add(day);
    }
    for (final field in [
      _totalStaff,
      _dayShiftStaff,
      _nightShiftStaff,
      _dayShiftSupervisors,
      _dayShiftGuards,
      _nightShiftSupervisors,
      _nightShiftGuards,
      _serviceHours,
    ]) {
      field.addListener(_markStaffChanged);
    }

    final today = DateUtils.dateOnly(DateTime.now());
    final month = widget.reportMonth;
    _archiveDate =
        month == null ||
            (today.year == month.year && today.month == month.month)
        ? today
        : DateTime(month.year, month.month, 1);

    _commencement = DateTime.tryParse(
      provider?['commencement_date']?.toString() ?? '',
    );
    _expiry = DateTime.tryParse(provider?['expiry_date']?.toString() ?? '');
    _nextExpiry = DateTime.tryParse(
      provider?['next_expiry_date']?.toString() ?? '',
    );
    final selected = widget.reportMonth;
    _renewalConfirmedDate = selected == null
        ? DateUtils.dateOnly(DateTime.now())
        : DateTime(selected.year, selected.month + 1, 0);
    _statusDate = DateTime.tryParse(
      provider?['lifecycle_date']?.toString() ?? '',
    );

    _noLongerUsed = provider?['status'] == 'Terminated';
    _status = widget.effectiveStatus == 'Renewal Due'
        ? 'Renewal Due'
        : (provider?['status']?.toString() ?? 'Active');

    if (!_manualStatusOptions.contains(_status)) {
      _status = 'Active';
    }
  }

  @override
  void dispose() {
    _service.dispose();
    _company.dispose();
    _contact.dispose();
    _schedule.dispose();
    _notes.dispose();
    _statusReason.dispose();
    _archiveReason.dispose();
    _totalStaff.dispose();
    _dayShiftStaff.dispose();
    _nightShiftStaff.dispose();
    _dayShiftSupervisors.dispose();
    _dayShiftGuards.dispose();
    _nightShiftSupervisors.dispose();
    _nightShiftGuards.dispose();
    _serviceHours.dispose();
    super.dispose();
  }

  void _markStaffChanged() {
    _staffChanged = true;
  }

  bool get _isSecurity => _service.text.trim().toLowerCase() == 'security';

  static TimeOfDay? _parseClock(dynamic value) {
    final raw =
        value?.toString().trim().toLowerCase().replaceAll(' ', '') ?? '';
    final match = RegExp(
      r'^(\d{1,2})(?::(\d{1,2}))?(?::\d{2})?(am|pm)?$',
    ).firstMatch(raw);
    if (match == null) return null;
    var hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2) ?? '0');
    if (hour == null || minute == null || minute > 59) return null;
    final meridiem = match.group(3);
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      hour = hour % 12 + (meridiem == 'pm' ? 12 : 0);
    }
    if (hour > 23) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static TimeOfDay? _parseShiftTime(
    dynamic structured,
    dynamic legacy, {
    required bool first,
  }) {
    final parsed = _parseClock(structured);
    if (parsed != null) return parsed;
    final parts = (legacy?.toString() ?? '').split(RegExp(r'\s*[-–—]\s*'));
    if (parts.length != 2) return null;
    return _parseClock(parts[first ? 0 : 1]);
  }

  static String? _timeForDatabase(TimeOfDay? time) => time == null
      ? null
      : '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}:00';

  static String _timeLabel(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final suffix = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:${time.minute.toString().padLeft(2, '0')} $suffix';
  }

  static String? _timeRange(TimeOfDay? start, TimeOfDay? end) =>
      start == null || end == null
      ? null
      : '${_timeLabel(start)} - ${_timeLabel(end)}';

  Future<void> _selectShiftTime(
    TimeOfDay? current,
    int defaultHour,
    ValueChanged<TimeOfDay> onSelected,
  ) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: current ?? TimeOfDay(hour: defaultHour, minute: 0),
    );
    if (selected == null || !mounted) return;
    setState(() {
      onSelected(selected);
      _staffChanged = true;
    });
  }

  Widget _shiftTimeButton(
    String label,
    TimeOfDay? value,
    int defaultHour,
    ValueChanged<TimeOfDay?> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: AppColors.grey, fontSize: 12)),
      const SizedBox(height: 5),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: () => _selectShiftTime(
                  value,
                  defaultHour,
                  (time) => onChanged(time),
                ),
                icon: const Icon(Icons.access_time_outlined, size: 17),
                label: Text(
                  value == null ? 'Select time' : _timeLabel(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (value != null)
            IconButton(
              tooltip: 'Clear $label',
              icon: const Icon(Icons.close, size: 17),
              onPressed: () => setState(() {
                onChanged(null);
                _staffChanged = true;
              }),
            ),
        ],
      ),
    ],
  );

  Widget _shiftTimes({
    required TimeOfDay? start,
    required TimeOfDay? end,
    required int defaultStartHour,
    required int defaultEndHour,
    required ValueChanged<TimeOfDay?> onStartChanged,
    required ValueChanged<TimeOfDay?> onEndChanged,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final startField = _shiftTimeButton(
        'Start Time',
        start,
        defaultStartHour,
        onStartChanged,
      );
      final endField = _shiftTimeButton(
        'End Time',
        end,
        defaultEndHour,
        onEndChanged,
      );
      if (constraints.maxWidth < 390) {
        return Column(
          children: [startField, const SizedBox(height: 10), endField],
        );
      }
      return Row(
        children: [
          Expanded(child: startField),
          const SizedBox(width: 10),
          Expanded(child: endField),
        ],
      );
    },
  );

  Widget _securityPositionFields({
    required TextEditingController supervisors,
    required TextEditingController guards,
  }) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        Expanded(child: _staffNumberInput('Security Supervisor', supervisors)),
        const SizedBox(width: 10),
        Expanded(child: _staffNumberInput('Security Guards', guards)),
      ],
    ),
  );

  Widget _staffNumberInput(String label, TextEditingController controller) =>
      TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.isEmpty) return null;
          final number = int.tryParse(text);
          return number == null || number < 0
              ? 'Enter a whole number of 0 or more.'
              : null;
        },
      );

  Widget _weekdaySelector(String label, Set<int> selected) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (var day = 1; day <= 7; day++)
              FilterChip(
                label: Text(names[day - 1]),
                selected: selected.contains(day),
                onSelected: (checked) => setState(() {
                  if (checked) {
                    selected.add(day);
                  } else {
                    selected.remove(day);
                  }
                  _staffChanged = true;
                }),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildServiceScheduleFields() {
    const frequencies = [
      '',
      'Daily',
      'Weekly',
      'Monthly',
      'Quarterly',
      'Yearly',
      'As Required',
      'Other',
    ];
    final available = <String>[
      ...frequencies,
      if (_staffFrequency.isNotEmpty && !frequencies.contains(_staffFrequency))
        _staffFrequency,
    ];
    return Column(
      children: [
        TextFormField(
          controller: _serviceHours,
          decoration: const InputDecoration(
            labelText: 'Service Hours (optional)',
            hintText: 'e.g. 8 hours or 24 hours',
          ),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: _staffFrequency,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Frequency'),
          items: [
            for (final frequency in available)
              DropdownMenuItem<String>(
                value: frequency,
                child: Text(frequency.isEmpty ? 'Not entered' : frequency),
              ),
          ],
          onChanged: (value) => setState(() {
            _staffFrequency = value ?? '';
            _staffChanged = true;
          }),
        ),
      ],
    );
  }

  Widget _buildStaffingFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading('STAFFING & SHIFTS'),
        const SizedBox(height: 6),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include in Staff Management'),
          value: _includeInStaff,
          activeThumbColor: AppColors.red,
          onChanged: (value) => setState(() {
            _includeInStaff = value;
            _staffChanged = true;
          }),
        ),
        if (_includeInStaff) ...[
          const SizedBox(height: 8),
          _staffNumberInput('Total Staff (Pax)', _totalStaff),
          const SizedBox(height: 16),
          const Text(
            'DAY SHIFT',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _staffNumberInput('No. of Pax', _dayShiftStaff),
          if (_isSecurity)
            _securityPositionFields(
              supervisors: _dayShiftSupervisors,
              guards: _dayShiftGuards,
            ),
          const SizedBox(height: 10),
          _shiftTimes(
            start: _dayShiftStart,
            end: _dayShiftEnd,
            defaultStartHour: 8,
            defaultEndHour: 17,
            onStartChanged: (value) => _dayShiftStart = value,
            onEndChanged: (value) => _dayShiftEnd = value,
          ),
          const SizedBox(height: 20),
          const Text(
            'NIGHT SHIFT',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _staffNumberInput('No. of Pax', _nightShiftStaff),
          if (_isSecurity)
            _securityPositionFields(
              supervisors: _nightShiftSupervisors,
              guards: _nightShiftGuards,
            ),
          const SizedBox(height: 10),
          _shiftTimes(
            start: _nightShiftStart,
            end: _nightShiftEnd,
            defaultStartHour: 20,
            defaultEndHour: 8,
            onStartChanged: (value) => _nightShiftStart = value,
            onEndChanged: (value) => _nightShiftEnd = value,
          ),
          if (_staffFrequency.isNotEmpty && _staffFrequency != 'Daily') ...[
            const SizedBox(height: 16),
            _weekdaySelector('Day Shift Working Days', _dayWeekdays),
            const SizedBox(height: 12),
            _weekdaySelector('Night Shift Working Days', _nightWeekdays),
            const SizedBox(height: 6),
            Text(
              _staffFrequency == 'Weekly'
                  ? 'Select each weekday the shift operates.'
                  : 'For monthly or irregular services, weekdays alone do not '
                        'specify the actual visit dates. Monthly staffing totals '
                        'will require an exact schedule.',
              style: const TextStyle(fontSize: 12, color: AppColors.grey),
            ),
          ],
        ],
      ],
    );
  }

  bool _validateStaffing() {
    if (!_staffChanged || !_includeInStaff) return true;
    int? count(TextEditingController field) => int.tryParse(field.text.trim());
    final day = count(_dayShiftStaff);
    final night = count(_nightShiftStaff);

    // Total Staff is the number of distinct employees assigned to this site,
    // not Day Shift + Night Shift deployed at the same time.
    if ((day ?? 0) > 0 && (_dayShiftStart == null || _dayShiftEnd == null)) {
      _showError('Enter both Day Shift start and end times.');
      return false;
    }
    if ((night ?? 0) > 0 &&
        (_nightShiftStart == null || _nightShiftEnd == null)) {
      _showError('Enter both Night Shift start and end times.');
      return false;
    }

    if (_isSecurity) {
      bool checkPositions(
        String shift,
        int? pax,
        TextEditingController supervisors,
        TextEditingController guards,
        dynamic oldPax,
        dynamic oldSupervisors,
        dynamic oldGuards,
      ) {
        final supText = supervisors.text.trim();
        final guardsText = guards.text.trim();
        if (supText.isEmpty && guardsText.isEmpty) {
          // Existing Security providers can retain their historical figures
          // until their shift pax are edited. Never invent a role breakdown.
          final isUnchangedLegacy =
              widget.existing != null &&
              widget.existing?['service']?.toString().trim().toLowerCase() ==
                  'security' &&
              oldSupervisors == null &&
              oldGuards == null &&
              pax == (oldPax == null ? null : int.tryParse(oldPax.toString()));
          if ((pax ?? 0) == 0 || isUnchangedLegacy) return true;
          _showError(
            'Enter $shift Security Supervisor and Guards (use 0 if none).',
          );
          return false;
        }
        if (supText.isEmpty || guardsText.isEmpty) {
          _showError('Enter both $shift Security positions (use 0 if none).');
          return false;
        }
        if (pax == null || count(supervisors)! + count(guards)! != pax) {
          _showError(
            '$shift No. of Pax must equal Security Supervisor + Security Guards.',
          );
          return false;
        }
        return true;
      }

      if (!checkPositions(
        'Day Shift',
        day,
        _dayShiftSupervisors,
        _dayShiftGuards,
        widget.staff?['day_shift_staff'],
        widget.staff?['day_shift_supervisors'],
        widget.staff?['day_shift_guards'],
      )) {
        return false;
      }
      if (!checkPositions(
        'Night Shift',
        night,
        _nightShiftSupervisors,
        _nightShiftGuards,
        widget.staff?['night_shift_staff'],
        widget.staff?['night_shift_supervisors'],
        widget.staff?['night_shift_guards'],
      )) {
        return false;
      }
    }

    if (_staffFrequency == 'Weekly' &&
        (((day ?? 0) > 0 && _dayWeekdays.isEmpty) ||
            ((night ?? 0) > 0 && _nightWeekdays.isEmpty))) {
      _showError('Select working weekdays for each active Weekly shift.');
      return false;
    }
    return true;
  }

  Map<String, dynamic> _staffingPayload() {
    int? count(TextEditingController field) => int.tryParse(field.text.trim());
    final day = count(_dayShiftStaff);
    final night = count(_nightShiftStaff);
    // Write all seven days when saving Daily so a prior Weekly restriction
    // cannot leak forward through the per-field inheritance view.
    List<int>? weekdays(Set<int> selected) => _staffFrequency == 'Daily'
        ? <int>[1, 2, 3, 4, 5, 6, 7]
        : (selected.isEmpty ? null : (selected.toList()..sort()));
    return <String, dynamic>{
      'include_in_staff': _includeInStaff,
      'total_staff': count(_totalStaff),
      'day_shift_staff': day,
      'night_shift_staff': night,
      'day_shift_supervisors': _isSecurity ? count(_dayShiftSupervisors) : null,
      'day_shift_guards': _isSecurity ? count(_dayShiftGuards) : null,
      'night_shift_supervisors': _isSecurity
          ? count(_nightShiftSupervisors)
          : null,
      'night_shift_guards': _isSecurity ? count(_nightShiftGuards) : null,
      'day_shift_timing': _timeRange(_dayShiftStart, _dayShiftEnd),
      'night_shift_timing': _timeRange(_nightShiftStart, _nightShiftEnd),
      'day_shift_start_time': _timeForDatabase(_dayShiftStart),
      'day_shift_end_time': _timeForDatabase(_dayShiftEnd),
      'night_shift_start_time': _timeForDatabase(_nightShiftStart),
      'night_shift_end_time': _timeForDatabase(_nightShiftEnd),
      'day_shift_weekdays': weekdays(_dayWeekdays),
      'night_shift_weekdays': weekdays(_nightWeekdays),
      'service_hours': _serviceHours.text.trim().isEmpty
          ? null
          : _serviceHours.text.trim(),
      'frequency': _staffFrequency.isEmpty ? null : _staffFrequency,
    };
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.redDark),
    );
  }

  Future<void> _pickFiles() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'documents',
        extensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      );

      final files = await openFiles(acceptedTypeGroups: [typeGroup]);

      if (!mounted || files.isEmpty) {
        return;
      }

      final validFiles = <XFile>[];

      for (final file in files) {
        final size = await file.length();

        if (size > 10 * 1024 * 1024) {
          _showError('${file.name} exceeds the 10 MB limit.');
          return;
        }

        validFiles.add(file);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _files = [..._files, ...validFiles];
      });

      _showError('${validFiles.length} file(s) selected.');
    } catch (e) {
      _showError('Unable to select attachments: $e');
    }
  }

  Future<DateTime?> _chooseDate(DateTime? current, String label) async {
    final now = DateTime.now();

    return showDatePicker(
      context: context,
      initialDate: current ?? DateTime(now.year, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      helpText: 'Select $label',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.red,
              onPrimary: AppColors.white,
              surface: AppColors.white,
              onSurface: AppColors.black,
            ),
          ),
          child: child!,
        );
      },
    );
  }

  String _dateLabel(DateTime? date) {
    if (date == null) {
      return 'Not set';
    }

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  Widget _dateField({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onChanged,
  }) {
    return InkWell(
      onTap: () async {
        final selected = await _chooseDate(value, label);
        if (selected != null && mounted) {
          onChanged(selected);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value != null)
                IconButton(
                  tooltip: 'Clear date',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => onChanged(null),
                ),
              const Icon(Icons.calendar_month_outlined),
              const SizedBox(width: 12),
            ],
          ),
        ),
        child: Text(
          _dateLabel(value),
          style: TextStyle(
            color: value == null ? AppColors.grey : AppColors.black,
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (widget.existing?['is_archived'] == true) {
      Navigator.pop(context, const _ProviderFormResult(restore: true));
      return;
    }
    if (_archiveMode && widget.existing != null) {
      if (_archiveDate == null || _archiveReason.text.trim().isEmpty) {
        _showError('Archive date and reason are required.');
        return;
      }
      if (widget.reportMonth != null &&
          (_archiveDate!.year != widget.reportMonth!.year ||
              _archiveDate!.month != widget.reportMonth!.month)) {
        _showError('Archive Date must be within the selected report month.');
        return;
      }
      Navigator.pop(
        context,
        _ProviderFormResult(
          archive: true,
          archiveDate: _archiveDate,
          archiveReason: _archiveReason.text.trim(),
        ),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (!_validateStaffing()) {
      return;
    }

    if (_commencement != null &&
        _expiry != null &&
        DateUtils.dateOnly(
          _expiry!,
        ).isBefore(DateUtils.dateOnly(_commencement!))) {
      _showError('Expiry / Renewal Date cannot be before Start Date.');
      return;
    }
    final isRenewal =
        widget.existing != null &&
        !_noLongerUsed &&
        widget.effectiveStatus == 'Renewal Due' &&
        _status == 'Active';
    if (_expiry == null) {
      _showError('Expiry / Renewal Date is required.');
      return;
    }
    if (isRenewal) {
      if (_nextExpiry == null || !_nextExpiry!.isAfter(_expiry!)) {
        _showError('Enter a new Expiry Date after the previous Expiry Date.');
        return;
      }
      final actionDate = _renewalConfirmedDate;
      if (actionDate == null ||
          actionDate.isAfter(
            DateTime(_expiry!.year, _expiry!.month, _expiry!.day + 1),
          )) {
        _showError(
          'Renewal confirmation must be no later than one day after expiry.',
        );
        return;
      }
      // For older report months, use the recorded legacy renewal reminder
      // when available; otherwise use the current expiry-based rule.
      final reportMonth = widget.reportMonth;
      final historical =
          reportMonth != null &&
          DateTime(
            reportMonth.year,
            reportMonth.month,
          ).isBefore(_renewalRuleCutoverMonth);
      final legacyDate = historical
          ? DateTime.tryParse(
              widget.existing?['renewal_date']?.toString() ?? '',
            )
          : null;
      final reminderBegins = _oneCalendarMonthBefore(legacyDate ?? _expiry!);
      if (actionDate.isBefore(reminderBegins)) {
        _showError(
          'Renewal confirmation cannot precede the Renewal Due period.',
        );
        return;
      }
    }

    if (_noLongerUsed) {
      if (_statusDate == null) {
        _showError('Please select the date the provider stopped being used.');
        return;
      }
      final selectedMonth = widget.reportMonth;
      if (selectedMonth != null &&
          (_statusDate!.year != selectedMonth.year ||
              _statusDate!.month != selectedMonth.month)) {
        _showError('No Longer Used Date must be in the edited report month.');
        return;
      }

      if (_statusReason.text.trim().isEmpty) {
        _showError(
          'Please enter the reason for stopping use of this provider.',
        );
        return;
      }
    }

    Navigator.pop(
      context,
      _ProviderFormResult(
        staffing: _staffChanged ? _staffingPayload() : null,
        fields: {
          'service': _service.text.trim(),
          'company_pic': _company.text.trim(),
          'contact': _nullIfEmpty(_contact.text),
          'schedule_staffing': _nullIfEmpty(_schedule.text),
          'commencement_date': _dateForDatabase(_commencement),
          'expiry_renewal_date': _dateForDatabase(_expiry), // PDF compatibility
          'expiry_date': _dateForDatabase(_expiry),
          'renewal_confirmed_at': isRenewal
              ? _dateForDatabase(_renewalConfirmedDate)
              : widget.existing?['renewal_confirmed_at'],
          'next_expiry_date': isRenewal
              ? _dateForDatabase(_nextExpiry)
              : widget.existing?['next_expiry_date'],
          'notes': _nullIfEmpty(_notes.text),
          'status': _noLongerUsed ? 'Terminated' : 'Active',
          'lifecycle_date': _noLongerUsed
              ? _dateForDatabase(_statusDate)
              : null,
          'lifecycle_reason': _noLongerUsed
              ? _nullIfEmpty(_statusReason.text)
              : null,
        },
        files: _files,
      ),
    );
  }

  static String? _nullIfEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _dateForDatabase(DateTime? date) {
    if (date == null) {
      return null;
    }

    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.existing?['is_archived'] == true) {
      return AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Archived Service Provider',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(
          '"${widget.existing?['company_pic']}" is archived. '
          'Restore it before changing its details. Previous monthly '
          'reports will remain unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const Text('Restore Provider'),
          ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: Text(
        widget.existing == null
            ? 'Add Service Provider'
            : 'Edit Service Provider',
        style: const TextStyle(
          color: AppColors.black,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeading('PROVIDER DETAILS'),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _service.text.trim().isEmpty
                      ? null
                      : _service.text.trim(),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Service Category *',
                  ),
                  items: [
                    for (final category in <String>{
                      ...widget.suggestedServices,
                      if (_service.text.trim().isNotEmpty) _service.text.trim(),
                    })
                      DropdownMenuItem<String>(
                        value: category,
                        child: Text(category),
                      ),
                  ],
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Please select a service category.'
                      : null,
                  onChanged: (category) => setState(() {
                    final wasSecurity = _isSecurity;
                    _service.text = category ?? '';
                    if (wasSecurity != _isSecurity) {
                      // Avoid carrying Security position figures into another category.
                      _staffChanged = true;
                    }
                  }),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _company,
                  decoration: const InputDecoration(
                    labelText: 'Company / Person in Charge (PIC) *',
                    hintText: 'Enter the company or person responsible',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Please enter the company or person in charge.'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _contact,
                  decoration: const InputDecoration(
                    labelText: 'Contact Details',
                    hintText: 'Phone number or email address',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _schedule,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 5,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 14),
                _buildServiceScheduleFields(),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                _buildStaffingFields(),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                _sectionHeading('CONTRACT PERIOD'),
                const SizedBox(height: 14),
                _dateField(
                  label: 'Start Date',
                  value: _commencement,
                  onChanged: (value) {
                    setState(() => _commencement = value);
                  },
                ),
                const SizedBox(height: 14),
                _dateField(
                  label: 'Expiry / Renewal Date *',
                  value: _expiry,
                  onChanged: (value) {
                    setState(() => _expiry = value);
                  },
                ),
                if (widget.effectiveStatus == 'Renewal Due' &&
                    _status == 'Active' &&
                    widget.existing != null) ...[
                  const SizedBox(height: 14),
                  _dateField(
                    label: 'Renewal Confirmation Date *',
                    value: _renewalConfirmedDate,
                    onChanged: (value) =>
                        setState(() => _renewalConfirmedDate = value),
                  ),
                  const SizedBox(height: 14),
                  _dateField(
                    label: 'New Expiry Date *',
                    value: _nextExpiry,
                    onChanged: (value) => setState(() => _nextExpiry = value),
                  ),
                ],
                if (_commencement != null || _expiry != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _commencement = null;
                          _expiry = null;
                        });
                      },
                      child: const Text('Clear Dates'),
                    ),
                  ),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                _sectionHeading('PROVIDER STATUS'),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: _manualStatusOptions.map((status) {
                    return DropdownMenuItem<String>(
                      value: status,
                      child: Text(
                        status == 'Active' ? 'Active' : 'Renewal Due',
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }

                    setState(() {
                      _status = value;

                      // No Longer Used is controlled independently in
                      // Record Management and is not reset here.
                    });
                  },
                ),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                _sectionHeading('ATTACHMENTS'),
                const SizedBox(height: 8),
                const Text(
                  'PDF, JPG, PNG, DOC or DOCX. Maximum 10 MB per file.',
                  style: TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Select Files'),
                ),
                if (_files.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ..._files.asMap().entries.map((entry) {
                    final index = entry.key;
                    final file = entry.value;

                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.insert_drive_file_outlined,
                        color: AppColors.red,
                      ),
                      title: Text(
                        file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove file',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          setState(() => _files.removeAt(index));
                        },
                      ),
                    );
                  }),
                ],
                if (widget.existing != null) ...[
                  const SizedBox(height: 22),
                  const Divider(),
                  const SizedBox(height: 12),
                  _sectionHeading('RECORD MANAGEMENT'),
                  if (widget.allowArchive)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Archive',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      value: _archiveMode,
                      activeThumbColor: AppColors.red,
                      onChanged: (value) => setState(() {
                        _archiveMode = value;
                        if (value) {
                          _noLongerUsed = false;
                        }
                      }),
                    ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'No Longer Used',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    value: _noLongerUsed,
                    activeThumbColor: AppColors.red,
                    onChanged: (value) => setState(() {
                      _noLongerUsed = value;
                      if (value) {
                        _archiveMode = false;
                      }
                      if (!value) {
                        _statusDate = null;
                        _statusReason.clear();
                      }
                    }),
                  ),
                  if (_noLongerUsed) ...[
                    const SizedBox(height: 12),
                    _dateField(
                      label: 'Date No Longer Used *',
                      value: _statusDate,
                      onChanged: (value) => setState(() => _statusDate = value),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _statusReason,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Reason for No Longer Using Provider *',
                        hintText: 'e.g. Contract ended or provider replaced',
                        alignLabelWithHint: true,
                      ),
                      validator: (value) {
                        if (_noLongerUsed &&
                            (value == null || value.trim().isEmpty)) {
                          return 'Please enter the reason.';
                        }
                        return null;
                      },
                    ),
                  ],
                  if (widget.allowArchive && _archiveMode) ...[
                    const SizedBox(height: 12),
                    _dateField(
                      label: 'Archive Date *',
                      value: _archiveDate,
                      onChanged: (value) =>
                          setState(() => _archiveDate = value),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _archiveReason,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Reason for Archiving *',
                        hintText: 'Explain why this provider is archived',
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(
            widget.existing == null
                ? 'Add Provider'
                : _archiveMode
                ? 'Archive Provider'
                : 'Save Changes',
          ),
        ),
      ],
    );
  }

  Widget _sectionHeading(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: AppColors.red,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }
}
