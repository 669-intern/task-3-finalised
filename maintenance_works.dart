import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class MaintenanceWorksPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const MaintenanceWorksPage({super.key, required this.report});

  @override
  State<MaintenanceWorksPage> createState() => _MaintenanceWorksPageState();
}

class _MaintenanceWorksPageState extends State<MaintenanceWorksPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const List<String> _statuses = [
    'Completed',
    'In Progress',
    'Pending',
    'Cancelled',
    'On Hold',
  ];

  List<Map<String, dynamic>> _records = [];
  // Previous monthly snapshots, calculated from dated progress updates.
  final Map<String, List<Map<String, dynamic>>> _historyByMonth = {};
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedStatusFilters = <String>{};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String get _reportId => widget.report['id'].toString();
  String? get _siteId => widget.report['site_id']?.toString();

  // Records are projected to the selected month's effective status.
  // The originating report ID is never changed by carry-forward logic.
  List<Map<String, dynamic>> get _currentMonthRecords => _records
      .where((record) => record['report_id']?.toString() == _reportId)
      .toList();

  // All active work in the selected month, including carried-forward items.
  // This is a display-only grouping; no database rows are copied or moved.
  List<Map<String, dynamic>> get _thisMonthRecords => [
    ..._currentMonthRecords,
    ..._records.where(_isCarriedForward),
  ];

  // These flags are calculated from saved progress at the selected month's
  // cutoff, rather than mutating the original maintenance record.
  bool _isCarriedForward(Map<String, dynamic> row) =>
      row['_carried_into_month'] == true;

  String? _selectedReportMonth;
  String? _resolvedSiteId;
  final GlobalKey _recordsAnchorKey = GlobalKey();

  bool _matchesStatus(Map<String, dynamic> row) {
    if (_selectedStatusFilters.isEmpty) return true;
    final status = row['status']?.toString();
    return _selectedStatusFilters.contains(status) ||
        (_selectedStatusFilters.contains('Cancelled / On Hold') &&
            (status == 'Cancelled' || status == 'On Hold'));
  }

  bool _matchesSearch(Map<String, dynamic> row) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      row['work_activity'],
      row['challenge'],
      row['action_taken'],
      row['entry_date'],
      row['deadline'],
      row['status'],
      row['line_no'],
    ].where((value) => value != null).join(' ').toLowerCase().contains(query);
  }

  bool _matchesFilters(Map<String, dynamic> row) =>
      _matchesStatus(row) && _matchesSearch(row);

  void _toggleStatusFilter(String status) {
    setState(() {
      if (!_selectedStatusFilters.add(status)) {
        _selectedStatusFilters.remove(status);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _recordsAnchorKey.currentContext;
      if (mounted && anchor != null) {
        Scrollable.ensureVisible(
          anchor,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.02,
        );
      }
    });
  }

  void _clearStatusFilters() {
    setState(() => _selectedStatusFilters.clear());
  }

  int _compareNewest(Map<String, dynamic> a, Map<String, dynamic> b) {
    final aMonth = _parseDate(a['original_report_month']) ?? DateTime(1900);
    final bMonth = _parseDate(b['original_report_month']) ?? DateTime(1900);
    final monthOrder = bMonth.compareTo(aMonth);
    if (monthOrder != 0) return monthOrder;
    final aDate = _parseDate(a['entry_date']) ?? DateTime(1900);
    final bDate = _parseDate(b['entry_date']) ?? DateTime(1900);
    final dateOrder = bDate.compareTo(aDate);
    if (dateOrder != 0) return dateOrder;
    final aNo = int.tryParse(a['line_no']?.toString() ?? '') ?? 0;
    final bNo = int.tryParse(b['line_no']?.toString() ?? '') ?? 0;
    return aNo.compareTo(bNo);
  }

  // Cut off historical months at their actual last day. Never treat a
  // future day of the selected calendar month as already overdue.
  static DateTime _monthCutoff(DateTime month) {
    final lastDay = DateTime(month.year, month.month + 1, 0);
    final now = DateUtils.dateOnly(DateTime.now());
    return month.year == now.year && month.month == now.month
        ? now
        : lastDay;
  }

  // Overdue is a monthly-report display status, not a database status.
  // A September deadline stays In Progress/Pending in September and becomes
  // Overdue in October if no dated Completed update has been saved.
  static String _effectiveStatus({
    required String rawStatus,
    required DateTime? deadline,
    required DateTime reportMonth,
    required bool completedByDatedProgress,
  }) {
    final actualStatus = rawStatus == 'Completed' && !completedByDatedProgress
        ? 'In Progress'
        : rawStatus;
    if (actualStatus == 'Completed') return 'Completed';
    if (deadline != null &&
        DateTime(
          reportMonth.year,
          reportMonth.month,
        ).isAfter(DateTime(deadline.year, deadline.month))) {
      return 'Overdue';
    }
    return actualStatus;
  }

  // The main maintenance_works row is the ORIGINAL record, not a mutable
  // "latest" copy. Every later change is an immutable, dated progress snapshot.
  static const Map<String, String> _progressFieldNames = {
    'entry_date': 'Start Date',
    'work_activity': 'Work / Activity',
    'challenge': 'Challenge',
    'action_taken': 'Action Taken',
    'deadline': 'Deadline',
    'status': 'Status',
    'progress_date': 'Update Date',
  };

  Map<String, dynamic> _progressValues(Map<String, dynamic> row) => {
    for (final key in _progressFieldNames.keys)
      if (key != 'progress_date') key: row[key],
  };

  // Older progress rows contain only status/challenge/action/deadline. A new
  // snapshot_version=1 event also contains start date and activity, including
  // intentional NULL values. This retains compatibility with legacy records.
  void _applyProgressValues(
    Map<String, dynamic> values,
    Map<String, dynamic> event,
  ) {
    for (final key in ['challenge', 'action_taken', 'deadline', 'status']) {
      values[key] = event[key];
    }
    if (event['snapshot_version'] == 1) {
      values['entry_date'] = event['entry_date'];
      values['work_activity'] = event['work_activity'];
    }
  }

  dynamic _normalizedFieldValue(String key, dynamic value) {
    if (key == 'entry_date' ||
        key == 'deadline' ||
        key == 'progress_date') {
      return _dateForDatabase(_parseDate(value));
    }
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  Map<String, dynamic> _fieldChanges(
    Map<String, dynamic> before,
    Map<String, dynamic> after, {
    bool includeUpdateDate = false,
  }) {
    final changes = <String, dynamic>{};
    for (final key in _progressFieldNames.keys) {
      if (!includeUpdateDate && key == 'progress_date') continue;
      final oldValue = _normalizedFieldValue(key, before[key]);
      final newValue = _normalizedFieldValue(key, after[key]);
      if (oldValue != newValue) {
        changes[key] = {'before': oldValue, 'after': newValue};
      }
    }
    return changes;
  }

  // Project the immutable events only through the selected report's cutoff.
  // Every event carries ALL editable values; older events never get overwritten.
  Map<String, dynamic>? _snapshotForMonth(
    Map<String, dynamic> source,
    DateTime monthStart,
    List<Map<String, dynamic>> updates,
  ) {
    final originalReport = _parseDate(source['original_report_month']);
    final startDate = _parseDate(source['entry_date']) ?? originalReport;
    if (originalReport == null || startDate == null) return null;
    final origin = DateTime(originalReport.year, originalReport.month);
    final started = DateTime(startDate.year, startDate.month);
    if (origin.isAfter(monthStart) || started.isAfter(monthStart)) return null;

    final cutoff = _monthCutoff(monthStart);
    if (cutoff.isBefore(monthStart)) return null;
    final initialValues = _progressValues(source);
    final effectiveValues = Map<String, dynamic>.from(initialValues);
    final visibleProgress = <Map<String, dynamic>>[];
    Map<String, dynamic>? beforeMonth;
    Map<String, dynamic>? latest;
    var changedThisMonth = false;

    for (final update in updates) {
      final date = _parseDate(update['progress_date']);
      if (date == null || date.isAfter(cutoff)) continue;
      final previous = Map<String, dynamic>.from(effectiveValues);
      _applyProgressValues(effectiveValues, update);
      final enriched = Map<String, dynamic>.from(update);
      enriched['_values_after'] = Map<String, dynamic>.from(effectiveValues);
      enriched['_computed_changes'] = _fieldChanges(previous, effectiveValues);
      visibleProgress.add(enriched);
      latest = update;
      if (date.isBefore(monthStart)) {
        beforeMonth = update;
      } else {
        changedThisMonth = true;
      }
    }

    // Completed work disappears from subsequent months unless reopened.
    final finishedBeforeMonth = beforeMonth?['status'] == 'Completed';
    if (started.isBefore(monthStart) &&
        finishedBeforeMonth &&
        !changedThisMonth) {
      return null;
    }

    final snapshot = Map<String, dynamic>.from(source)
      ..addAll(effectiveValues);
    final raw = (effectiveValues['status'] ?? 'Pending').toString();
    final completed = latest != null && raw == 'Completed';
    snapshot['status'] = _effectiveStatus(
      rawStatus: raw,
      deadline: _parseDate(snapshot['deadline']),
      reportMonth: monthStart,
      completedByDatedProgress: completed,
    );
    snapshot['_raw_status'] = raw == 'Completed' && !completed
        ? 'In Progress'
        : raw;
    snapshot['_latest_progress_date'] = latest?['progress_date'];
    snapshot['_latest_progress_id'] = latest?['id'];
    snapshot['_completion_date'] = completed ? latest['progress_date'] : null;
    snapshot['_carried_into_month'] =
        started.isBefore(monthStart) && origin.isBefore(monthStart);
    snapshot['_snapshot_month'] = _historyMonthKey(monthStart);
    snapshot['_initial_values'] = initialValues;
    snapshot['_progress_history'] = visibleProgress.reversed.toList();
    return snapshot;
  }

  // yyyy-MM sorts chronologically without relying on the displayed label.
  String _historyMonthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshSearch);

    if (widget.report['id'] == null) {
      _loading = false;
      _error = 'The monthly report ID is missing.';
    } else {
      _loadRecords();
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_refreshSearch);
    _searchController.dispose();
    super.dispose();
  }

  void _refreshSearch() {
    if (mounted) setState(() {});
  }

  Future<void> _loadRecords() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Fetch the current report to identify its property.
      final currentReport = await _supabase
          .from('monthly_reports')
          .select('id, site_id, report_month')
          .eq('id', _reportId)
          .maybeSingle();

      if (currentReport == null) {
        throw Exception('The monthly report could not be found.');
      }

      final siteId = currentReport['site_id']?.toString() ?? _siteId;
      final selectedMonth = currentReport['report_month']?.toString();

      if (siteId == null || siteId.isEmpty) {
        throw Exception(
          'The property for this report could not be identified.',
        );
      }

      // Read reports for this property. Maintenance activities are limited to
      // the selected month and earlier; progress is applied by its actual date.
      final reports = await _supabase
          .from('monthly_reports')
          .select('id, report_month')
          .eq('site_id', siteId);

      final allSiteReportMonths = <String, String>{};
      for (final item in reports) {
        final id = item['id']?.toString();
        final month = item['report_month']?.toString();
        if (id != null && month != null && _parseDate(month) != null) {
          allSiteReportMonths[id] = month;
        }
      }

      final selectedDate = _parseDate(selectedMonth);
      if (selectedDate == null) {
        throw Exception(
          'The selected monthly report has no valid report_month.',
        );
      }
      final selectedStart = DateTime(selectedDate.year, selectedDate.month);
      final reportMonths = Map<String, String>.from(allSiteReportMonths)
        ..removeWhere((id, month) {
          final date = _parseDate(month)!;
          return DateTime(date.year, date.month).isAfter(selectedStart);
        });
      final reportIds = reportMonths.keys.toList();

      if (reportIds.isEmpty) {
        if (!mounted) return;
        setState(() {
          _records = [];
          _historyByMonth.clear();
          _selectedReportMonth = selectedMonth;
          _resolvedSiteId = siteId;
          _loading = false;
        });
        return;
      }

      final result = await _supabase
          .from('maintenance_works')
          .select()
          .inFilter('report_id', reportIds);
      final records = List<Map<String, dynamic>>.from(result);

      for (final record in records) {
        final originalReportId = record['report_id']?.toString();
        record['original_report_month'] = reportMonths[originalReportId];
      }

      // Fetch progress linked to ANY report of this site. A progress update
      // entered while viewing October but dated November must apply in
      // November. Conversely, an update entered in November and dated October
      // must apply in October. Its entry report is not its effective date.
      // The database SELECT policy still restricts visibility by site.
      final updatesByMaintenance = <String, List<Map<String, dynamic>>>{};
      if (records.isNotEmpty && allSiteReportMonths.isNotEmpty) {
        final updates = await _supabase
            .from('maintenance_progress_updates')
            .select(
              'maintenance_id, report_id, progress_date, status, '
              'challenge, action_taken, deadline, entry_date, work_activity, '
              'snapshot_version, changed_fields, revises_progress_id, '
              'created_at, id',
            )
            .inFilter('report_id', allSiteReportMonths.keys.toList());
        final recordIds = records.map((r) => r['id']?.toString()).toSet();
        for (final item in updates) {
          final id = item['maintenance_id']?.toString();
          if (id != null && recordIds.contains(id)) {
            updatesByMaintenance
                .putIfAbsent(id, () => [])
                .add(Map<String, dynamic>.from(item));
          }
        }
      }

      // Sort each record's dated progress events once. When multiple events
      // have the same Progress Date, latest creation time and ID break ties.
      for (final updates in updatesByMaintenance.values) {
        updates.sort((a, b) {
          final dateA = _parseDate(a['progress_date']) ?? DateTime(1900);
          final dateB = _parseDate(b['progress_date']) ?? DateTime(1900);
          final byDate = dateA.compareTo(dateB);
          if (byDate != 0) return byDate;
          final byCreated = (a['created_at']?.toString() ?? '').compareTo(
            b['created_at']?.toString() ?? '',
          );
          if (byCreated != 0) return byCreated;
          return (a['id']?.toString() ?? '').compareTo(
            b['id']?.toString() ?? '',
          );
        });
      }

      // History contains ONLY Completed monthly snapshots. Unfinished work,
      // including Overdue work, stays in This Month and carries forward until
      // a dated Completed progress event occurs. Prior months keep their own
      // statuses and never inherit a future completion.
      final historyByMonth = <String, List<Map<String, dynamic>>>{};
      final previousMonths = <String, DateTime>{};
      for (final value in reportMonths.values) {
        final date = _parseDate(value);
        if (date == null) continue;
        final month = DateTime(date.year, date.month);
        if (month.isBefore(selectedStart)) {
          previousMonths[_historyMonthKey(month)] = month;
        }
      }
      for (final entry in previousMonths.entries) {
        final monthRecords = <Map<String, dynamic>>[];
        for (final source in records) {
          final id = source['id']?.toString();
          final snapshot = _snapshotForMonth(
            source,
            entry.value,
            updatesByMaintenance[id] ?? const <Map<String, dynamic>>[],
          );
          if (snapshot != null && snapshot['status'] == 'Completed') {
            monthRecords.add(snapshot);
          }
        }
        if (monthRecords.isNotEmpty) {
          monthRecords.sort(_compareNewest);
          historyByMonth[entry.key] = monthRecords;
        }
      }

      // This Month uses the same date rules. Completion in a prior month
      // excludes a record from later carry-forward; a dated reopening in
      // the selected month makes it visible again.
      final currentSnapshots = <Map<String, dynamic>>[];
      for (final source in records) {
        final id = source['id']?.toString();
        final snapshot = _snapshotForMonth(
          source,
          selectedStart,
          updatesByMaintenance[id] ?? const <Map<String, dynamic>>[],
        );
        if (snapshot != null) currentSnapshots.add(snapshot);
      }
      currentSnapshots.sort(_compareNewest);

      if (!mounted) return;
      setState(() {
        _records = currentSnapshots;
        _historyByMonth
          ..clear()
          ..addAll(historyByMonth);
        _selectedReportMonth = selectedMonth;
        _resolvedSiteId = siteId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  int _nextLineNumber() {
    final used = _currentMonthRecords
        .map((record) => int.tryParse(record['line_no']?.toString() ?? ''))
        .whereType<int>()
        .toSet();

    var number = 1;
    while (used.contains(number)) {
      number++;
    }

    return number;
  }

  int _countStatus(String status) {
    return _thisMonthRecords
        .where((record) => record['status'] == status)
        .length;
  }

  int get _cancelledOrOnHold {
    return _thisMonthRecords.where((record) {
      return record['status'] == 'Cancelled' || record['status'] == 'On Hold';
    }).length;
  }

  Future<void> _openForm({
    Map<String, dynamic>? record,
    Map<String, dynamic>? historyEntry,
    bool historical = false,
    bool carriedForward = false,
  }) async {
    if (_saving) return;

    // A carried-forward item may be edited from the current report without
    // moving its original work record to this report.
    if (!historical &&
        !carriedForward &&
        record != null &&
        record['report_id']?.toString() != _reportId) {
      _showMessage(
        'Open the original monthly report to update this historical record.',
      );
      return;
    }

    final isEditing = record != null;
    final formKey = GlobalKey<FormState>();

    // When revising a past event, prefill THAT event's values, not the latest
    // values for the report. Saving still appends a new, traceable revision.
    final formValues = <String, dynamic>{
      ...?record,
      if (historyEntry?['_values_after'] is Map)
        ...Map<String, dynamic>.from(historyEntry!['_values_after'] as Map),
    };
    final activityController = TextEditingController(
      text: formValues['work_activity']?.toString() ?? '',
    );
    final challengeController = TextEditingController(
      text: formValues['challenge']?.toString() ?? '',
    );
    final actionController = TextEditingController(
      text: formValues['action_taken']?.toString() ?? '',
    );

    DateTime? entryDate = _parseDate(formValues['entry_date']);
    DateTime? deadline = _parseDate(formValues['deadline']);
    final historicalMonth = record?['_snapshot_month']?.toString();
    final selectedMonth = _parseDate(
      historical && historicalMonth != null
          ? '$historicalMonth-01'
          : _selectedReportMonth,
    );
    final now = DateUtils.dateOnly(DateTime.now());
    // A new progress entry defaults to this report month, never to the
    // previous event's date (which could otherwise rewrite an old month).
    final defaultProgressDate = selectedMonth == null
        ? now
        : DateTime(selectedMonth.year, selectedMonth.month).isAfter(now)
        ? DateTime(selectedMonth.year, selectedMonth.month, 1)
        : _monthCutoff(selectedMonth);
    DateTime? progressDate = isEditing
        ? (_parseDate(historyEntry?['progress_date']) ?? defaultProgressDate)
        : null;
    String? selectedStatus = historyEntry == null
        ? (record?['_raw_status']?.toString() ??
              formValues['status']?.toString())
        : formValues['status']?.toString();
    if (selectedStatus == 'Overdue' ||
        (selectedStatus == 'Completed' &&
            record?['_latest_progress_date'] == null)) {
      selectedStatus = 'In Progress';
    }
    // One combined form for every editable maintenance field.
    final formDialogRoute = DialogRoute<bool>(
      context: context,
      barrierDismissible: !_saving,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: isEditing
              ? const Color(0xFFFCE8E9)
              : AppColors.white,
          surfaceTintColor: Colors.transparent,
          title: Text(
            isEditing ? 'Update Progress' : 'Add Maintenance Record',
            style: const TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 590,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      isEditing
                          ? _displayValue(
                              record['work_activity'], 'Maintenance record')
                          : 'Record No. ${_nextLineNumber()}',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (isEditing) ...[
                      _dateField(
                        context: context,
                        label: 'Update Date *',
                        value: progressDate,
                        allowClear: false,
                        onChanged: (value) =>
                            setDialogState(() => progressDate = value),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _dateField(
                      context: context,
                      label: 'Start Date',
                      value: entryDate,
                      onChanged: (value) =>
                          setDialogState(() => entryDate = value),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: activityController,
                      decoration: const InputDecoration(
                        labelText: 'Work / Activity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: challengeController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Challenge',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: actionController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Action Taken',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedStatus,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      hint: const Text('Select status'),
                      items: _statuses.map((status) {
                        return DropdownMenuItem<String>(
                          value: status,
                          child: Text(status),
                        );
                      }).toList(),
                      onChanged: (value) =>
                          setDialogState(() => selectedStatus = value),
                    ),
                    const SizedBox(height: 12),
                    _dateField(
                      context: context,
                      label: 'Deadline',
                      value: deadline,
                      onChanged: (value) =>
                          setDialogState(() => deadline = value),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(isEditing ? 'Close' : 'Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.red),
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                if (selectedStatus == null) {
                  _showMessage('Select a Status.');
                  return;
                }
                if (isEditing && progressDate == null) {
                  _showMessage('Select an Update Date.');
                  return;
                }
                if (progressDate != null &&
                    entryDate != null &&
                    progressDate!.isBefore(entryDate!)) {
                  _showMessage('Update Date cannot precede Start Date.');
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              child: Text(isEditing ? 'Save Progress' : 'Add Record'),
            ),
          ],
        ),
      ),
    );

    final result = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(formDialogRoute);
    await formDialogRoute.completed;

    if (result == true && mounted) {
      await _saveRecord(
        record: record,
        previousValues: formValues,
        revisedEvent: historyEntry,
        historical: historical,
        carriedForward: carriedForward,
        entryDate: entryDate,
        deadline: deadline,
        workActivity: activityController.text,
        challenge: challengeController.text,
        actionTaken: actionController.text,
        status: selectedStatus,
        progressDate: progressDate,
      );
    }

    activityController.dispose();
    challengeController.dispose();
    actionController.dispose();
  }

  Future<void> _showProgressHistory(
    Map<String, dynamic> record, {
    bool historical = false,
    bool carriedForward = false,
  }) async {
    if (!mounted || _saving) return;

    final historyRoute = DialogRoute<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFFFCE8E9),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Progress History',
          style: TextStyle(
            color: AppColors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: 590,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.65,
            ),
            child: SingleChildScrollView(
              child: _buildFullProgressHistory(
                record,
                onCorrect: (entry) => Navigator.of(dialogContext).pop(entry),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    final event = await Navigator.of(context, rootNavigator: true)
        .push<Map<String, dynamic>>(historyRoute);
    await historyRoute.completed;

    if (!mounted || event == null) return;
    await _openForm(
      record: record,
      historyEntry: event,
      historical: historical,
      carriedForward: carriedForward,
    );
  }

  Widget _historyDetailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: AppColors.black, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullProgressHistory(
    Map<String, dynamic> record, {
    required ValueChanged<Map<String, dynamic>> onCorrect,
  }) {
    final events = (record['_progress_history'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];
    final initial = record['_initial_values'] is Map
        ? Map<String, dynamic>.from(record['_initial_values'] as Map)
        : _progressValues(record);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _displayValue(record['work_activity'], 'Maintenance record'),
          style: const TextStyle(color: AppColors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Text(
          '${events.length + 1} history ${events.isEmpty ? 'record' : 'records'}',
          style: const TextStyle(
            color: AppColors.black,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < events.length; i++)
          _buildFullProgressEvent(record, events[i], i, onCorrect),
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.white,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExpansionTile(
            initiallyExpanded: events.isEmpty,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text(
              'Initial Progress',
              style: TextStyle(
                color: AppColors.black,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final key in _progressFieldNames.keys)
                      if (key != 'progress_date' && key != 'work_activity')
                        _historyDetailLine(
                          _progressFieldNames[key]!,
                          _historyFieldValue(key, initial[key]),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFullProgressEvent(
    Map<String, dynamic> record,
    Map<String, dynamic> event,
    int index,
    ValueChanged<Map<String, dynamic>> onCorrect,
  ) {
    final values = event['_values_after'] is Map
        ? Map<String, dynamic>.from(event['_values_after'] as Map)
        : <String, dynamic>{
            for (final key in _progressFieldNames.keys)
              if (key != 'progress_date') key: event[key],
          };
    final isCorrection = event['revises_progress_id'] != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        key: ValueKey(
          'maintenance-progress-${record['id']}-${event['id'] ?? index}',
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${_displayDate(event['progress_date'])} | '
                '${event['status'] ?? 'Updated'}'
                '${isCorrection ? ' | Correction' : ''}',
                style: const TextStyle(
                  color: AppColors.black,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Correct this progress entry',
              onPressed: _saving ? null : () => onCorrect(event),
              icon: const Icon(Icons.edit_outlined, size: 18),
              color: AppColors.red,
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final key in _progressFieldNames.keys)
                  if (key != 'progress_date' && key != 'work_activity')
                    _historyDetailLine(
                      _progressFieldNames[key]!,
                      _historyFieldValue(key, values[key]),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateField({
    required BuildContext context,
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onChanged,
    bool allowClear = true,
  }) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();

        final selected = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime(now.year, now.month, now.day),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
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

        if (selected != null) {
          onChanged(selected);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (allowClear && value != null)
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
          value == null ? 'Not selected' : _formatDate(value),
          style: TextStyle(
            color: value == null ? AppColors.grey : AppColors.black,
          ),
        ),
      ),
    );
  }

  Future<void> _saveRecord({
    required Map<String, dynamic>? record,
    required Map<String, dynamic> previousValues,
    Map<String, dynamic>? revisedEvent,
    bool historical = false,
    bool carriedForward = false,
    required DateTime? entryDate,
    required DateTime? deadline,
    required String workActivity,
    required String challenge,
    required String actionTaken,
    required String? status,
    required DateTime? progressDate,
  }) async {
    if (_saving) return;
    final isEditing = record != null;
    if (status == null) {
      _showMessage('Status is required.');
      return;
    }
    if (isEditing && progressDate == null) {
      _showMessage('Update Date is required.');
      return;
    }
    if (entryDate != null &&
        progressDate != null &&
        progressDate.isBefore(entryDate)) {
      _showMessage('Update Date cannot precede Start Date.');
      return;
    }
    if (record != null &&
        !historical &&
        !carriedForward &&
        record['report_id']?.toString() != _reportId) {
      _showMessage('Open the original monthly report to update this record.');
      return;
    }
    if (!isEditing && entryDate != null) {
      final reportMonth = _parseDate(_selectedReportMonth);
      if (reportMonth != null &&
          (entryDate.year != reportMonth.year ||
              entryDate.month != reportMonth.month)) {
        _showMessage('Start Date must be in the selected report month.');
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final details = <String, dynamic>{
        'entry_date': _dateForDatabase(entryDate),
        'work_activity': _nullIfEmpty(workActivity),
      };
      final newValues = <String, dynamic>{
        ...details,
        'status': status,
        'challenge': _nullIfEmpty(challenge),
        'action_taken': _nullIfEmpty(actionTaken),
        'deadline': _dateForDatabase(deadline),
        'progress_date': _dateForDatabase(progressDate),
      };
      if (record != null) {
        final workId = record['id']?.toString();
        if (workId == null || workId.isEmpty) {
          throw Exception('Maintenance ID is missing.');
        }
        final oldValues = <String, dynamic>{
          ...previousValues,
          'status': revisedEvent != null
              ? previousValues['status']
              : (previousValues['_raw_status'] ?? previousValues['status']),
          'progress_date': revisedEvent?['progress_date'] ??
              record['_latest_progress_date'],
        };
        final changedFields = _fieldChanges(
          oldValues,
          newValues,
          includeUpdateDate: true,
        );

        // Append-only progress: preserve every previous value, including the
        // old start date, work/activity, action, status and deadline.
        await _supabase.from('maintenance_progress_updates').insert({
          ...newValues,
          'maintenance_id': workId,
          'report_id': _reportId,
          'snapshot_version': 1,
          'changed_fields': changedFields,
          'revises_progress_id': revisedEvent?['id'],
        });
      } else {
        final lineNo = _nextLineNumber();
        final inserted = await _supabase
            .from('maintenance_works')
            .insert({
              ...details,
              'report_id': _reportId,
              'line_no': lineNo,
              'challenge': newValues['challenge'],
              'action_taken': newValues['action_taken'],
              'deadline': newValues['deadline'],
              // A dated completion is determined by a dated progress event.
              'status': status == 'Completed' ? 'In Progress' : status,
            })
            .select('id')
            .single();
        if (inserted['id'] == null) {
          throw Exception('Inserted maintenance ID is missing.');
        }
      }

      if (!mounted) return;
      await _loadRecords();
      if (mounted) {
        _showMessage(
          isEditing
              ? 'Progress saved to history. Earlier updates were preserved.'
              : 'Maintenance record added successfully.',
        );
      }
    } catch (e) {
      if (mounted) _showMessage('Could not save the maintenance record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Delete the WHOLE selected work and ALL its dated progress events.
  // A single database RPC provides one transaction: either everything is
  // deleted, or a failure rolls the operation back. No confirmation dialog.
  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    if (_saving || _loading) return;
    final workId = record['id']?.toString();
    final siteId = _resolvedSiteId ?? _siteId;
    if (workId == null || workId.isEmpty || siteId == null || siteId.isEmpty) {
      _showMessage('Could not identify the maintenance item or property.');
      return;
    }

    setState(() => _saving = true);
    try {
      final removed = await _supabase.rpc(
        'delete_maintenance_work_with_progress',
        params: {'p_maintenance_id': workId, 'p_site_id': siteId},
      );
      if (removed != true) {
        throw Exception('The database did not confirm deletion.');
      }

      if (!mounted) return;
      await _loadRecords();
      if (mounted && _error == null) {
        _showMessage('Maintenance record deleted successfully.');
      } else if (mounted) {
        _showMessage('Record deleted, but refreshing the page failed.');
      }
    } catch (e) {
      if (mounted) _showMessage('Could not delete maintenance record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.charcoal),
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String? _dateForDatabase(DateTime? date) {
    if (date == null) return null;

    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  static String? _nullIfEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _displayReportMonth(dynamic value) {
    if (value == null) return 'Unknown month';

    final date = DateTime.tryParse(value.toString());
    if (date == null) return value.toString();

    return '${_monthName(date.month)} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Maintenance & Works'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving ? null : _loadRecords,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading || _saving
            ? null
            : () async {
                await _loadRecords();

                if (!mounted || _loading || _error != null) return;

                await _openForm();
              },
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Record'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
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
                'Unable to load Maintenance & Works records.',
                style: TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                style: const TextStyle(color: AppColors.grey),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadRecords,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final thisMonth = _thisMonthRecords.where(_matchesFilters).toList()
      ..sort(_compareNewest);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _buildHeader(),
        const SizedBox(height: 20),
        _buildSummary(),
        const SizedBox(height: 20),
        Column(
          key: _recordsAnchorKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSearchAndFilters(),
            const SizedBox(height: 18),
            _buildThisMonthSection(thisMonth),
          ],
        ),
        const SizedBox(height: 24),
        _buildHistorySection(),
      ],
    );
  }

  Widget _buildSearchAndFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search work, activity, challenge, action or date...',
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: _searchController.clear,
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        if (_selectedStatusFilters.isEmpty)
          const Text(
            'Showing: All statuses',
            style: TextStyle(color: AppColors.grey, fontSize: 12),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'Showing:',
                style: TextStyle(color: AppColors.grey, fontSize: 12),
              ),
              for (final selected in _statuses)
                if (_selectedStatusFilters.contains(selected))
                  Chip(label: Text(selected)),
              if (_selectedStatusFilters.contains('Cancelled / On Hold'))
                const Chip(label: Text('Cancelled / On Hold')),
              TextButton.icon(
                onPressed: _clearStatusFilters,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Clear filter'),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildThisMonthSection(List<Map<String, dynamic>> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'This Month',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
            ),
            Text(
              '${rows.length} record${rows.length == 1 ? '' : 's'}',
              style: const TextStyle(color: AppColors.grey),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (rows.isEmpty)
          _buildEmptyState('No matching maintenance records this month.')
        else
          for (var index = 0; index < rows.length; index++)
            _buildRecordCard(rows[index], displayNumber: index + 1),
      ],
    );
  }

  Widget _buildHistorySection() {
    final months = _historyByMonth.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final visibleMonths = <MapEntry<String, List<Map<String, dynamic>>>>[];
    for (final month in months) {
      final rows = _historyByMonth[month]!.where(_matchesFilters).toList()
        ..sort(_compareNewest);
      if (rows.isNotEmpty) {
        visibleMonths.add(MapEntry(month, rows));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'History',
                style: TextStyle(
                  color: AppColors.black,
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text(
              '${visibleMonths.fold<int>(0, (sum, month) => sum + month.value.length)} records',
              style: const TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (visibleMonths.isEmpty)
          _buildEmptyState('No historical maintenance records.')
        else
          for (final month in visibleMonths)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ExpansionTile(
                key: PageStorageKey(
                  'maintenance-history-${month.key}-$_reportId',
                ),
                initiallyExpanded: false,
                title: Text(
                  _displayReportMonth('${month.key}-01'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${month.value.length} maintenance record(s)',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                children: [
                  for (var i = 0; i < month.value.length; i++)
                    _buildRecordCard(
                      month.value[i],
                      displayNumber: i + 1,
                      historical: true,
                    ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildEmptyState(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.grey)),
  );

  Widget _buildHeader() {
    final reportMonth =
        widget.report['report_month'] ??
        widget.report['month'] ??
        widget.report['report_date'];

    final monthLabel = _displayReportMonth(reportMonth);

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
            'OPERATIONS',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Maintenance & Works',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$monthLabel • Report ID: $_reportId',
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 850
            ? 4
            : constraints.maxWidth >= 500
                ? 2
                : 1;
        final gap = 10.0;
        final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
        final cards = <Widget>[
          _summaryCard(
            'Completed',
            _countStatus('Completed'),
            Icons.check_circle_outline,
            const Color(0xFF178250),
            selected: _selectedStatusFilters.contains('Completed'),
            onTap: () => _toggleStatusFilter('Completed'),
          ),
          _summaryCard(
            'In Progress',
            _countStatus('In Progress'),
            Icons.autorenew_outlined,
            AppColors.red,
            selected: _selectedStatusFilters.contains('In Progress'),
            onTap: () => _toggleStatusFilter('In Progress'),
          ),
          _summaryCard(
            'Pending',
            _countStatus('Pending'),
            Icons.schedule_outlined,
            const Color(0xFFC58A14),
            selected: _selectedStatusFilters.contains('Pending'),
            onTap: () => _toggleStatusFilter('Pending'),
          ),
          _summaryCard(
            'Cancelled / On Hold',
            _cancelledOrOnHold,
            Icons.pause_circle_outline,
            AppColors.grey,
            selected: _selectedStatusFilters.contains('Cancelled / On Hold'),
            onTap: () => _toggleStatusFilter('Cancelled / On Hold'),
          ),
        ];
        return Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: _summaryCard(
                'Total Maintenance & Works',
                _thisMonthRecords.length,
                Icons.handyman_outlined,
                AppColors.red,
                wide: true,
                onTap: _clearStatusFilters,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final card in cards) SizedBox(width: width, child: card),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _summaryCard(
    String label,
    int count,
    IconData icon,
    Color accent, {
    required VoidCallback onTap,
    bool wide = false,
    bool selected = false,
  }) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: wide ? 88 : 90),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent : AppColors.border,
              width: selected ? 1.6 : 1,
            ),
            color: selected ? accent.withValues(alpha: 0.04) : null,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(color: AppColors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecordCard(
    Map<String, dynamic> record, {
    required int displayNumber,
    bool historical = false,
  }) {
    final isThisMonth =
        !historical && record['report_id']?.toString() == _reportId;
    final isCarried = _isCarriedForward(record);
    final status = record['status']?.toString() ?? 'Pending';
    final accent = _statusColor(status);

    return Container(
      width: double.infinity,
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
                width: 43,
                height: 43,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$displayNumber',
                  style: const TextStyle(
                    color: AppColors.red,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayValue(record['work_activity'], 'Untitled activity'),
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Start Date: ${_displayDate(record['entry_date'])}',
                      style: const TextStyle(color: AppColors.grey, fontSize: 12),
                    ),
                    if (isCarried) ...[
                      const SizedBox(height: 4),
                      const Text(
                        'Carried forward',
                        style: TextStyle(
                          color: AppColors.red,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _detail('Challenge', _displayValue(record['challenge'], '-')),
          _detail('Action Taken', _displayValue(record['action_taken'], '-')),
          _detail('Deadline', _displayDate(record['deadline'])),
          if (status == 'Completed' && record['_latest_progress_date'] != null)
            _detail('Completed Date', _displayDate(record['_latest_progress_date'])),
          const Divider(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => _openForm(
                            record: record,
                            historical: historical,
                            carriedForward: !historical && !isThisMonth && isCarried,
                          ),
                  icon: const Icon(Icons.update, size: 17),
                  label: const Text('Update Progress'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
                TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => _showProgressHistory(
                            record,
                            historical: historical,
                            carriedForward: !historical && !isThisMonth && isCarried,
                          ),
                  icon: const Icon(Icons.history, size: 17),
                  label: const Text('Progress History'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : () => _deleteRecord(record),
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('Delete'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _historyFieldValue(String key, dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return 'Not set';
    if (key == 'entry_date' ||
        key == 'deadline' ||
        key == 'progress_date') {
      return _displayDate(value);
    }
    return value.toString();
  }

  Widget _detail(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelWidth = constraints.maxWidth < 480
              ? constraints.maxWidth * 0.36
              : 212.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.grey,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  value?.toString() ?? '-',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.black,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static bool _hasText(dynamic value) {
    return value != null && value.toString().trim().isNotEmpty;
  }

  static String _displayValue(dynamic value, String fallback) {
    return _hasText(value) ? value.toString() : fallback;
  }

  static String _displayDate(dynamic value) {
    if (value == null) return 'Not set';

    final date = DateTime.tryParse(value.toString());
    return date == null ? value.toString() : _formatDate(date);
  }

  static Color _statusColor(String? status) {
    switch (status) {
      case 'Completed':
        return const Color(0xFF22683D);
      case 'In Progress':
        return AppColors.red;
      case 'Pending':
        return const Color(0xFF966400);
      case 'Cancelled':
      case 'On Hold':
        return AppColors.grey;
      default:
        return AppColors.black;
    }
  }

  static String _monthName(int month) {
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

    return months[month - 1];
  }
}