import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as flutter_widgets;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class AgmEgmResolutionsPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const AgmEgmResolutionsPage({super.key, required this.report});

  @override
  State<AgmEgmResolutionsPage> createState() =>
      _AgmEgmResolutionsPageState();
}

class _AgmEgmResolutionsPageState extends State<AgmEgmResolutionsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const List<String> _statuses = [
    'Approved',
    'Completed',
    'In Progress',
    'Pending',
    'Cancelled',
  ];

  List<Map<String, dynamic>> _records = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String get _reportId => widget.report['id'].toString();
  String? get _siteId => widget.report['site_id']?.toString();

  // Source rows stay unchanged; only the displayed month snapshots differ.
  List<Map<String, dynamic>> _thisMonthSnapshots = [];
  List<Map<String, dynamic>> _historySnapshots = [];
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedStatusFilters = <String>{};

  List<Map<String, dynamic>> get _currentMonthRecords => _records
      .where((record) => record['report_id']?.toString() == _reportId)
      .toList();

  List<Map<String, dynamic>> get _thisMonthRecords => _thisMonthSnapshots;
  List<Map<String, dynamic>> get _historicalRecords => _historySnapshots;

  String? _selectedReportMonth;
  final GlobalKey _recordsAnchorKey = GlobalKey();

  // One resolution can have one or two independent statuses.
  List<String> _recordStatuses(Map<String, dynamic> row) {
    final first = row['status']?.toString();
    final second = row['secondary_status']?.toString();
    final result = <String>[];
    for (final value in _statuses) {
      if (value == first || value == second) result.add(value);
    }
    // Do not rewrite pre-existing legacy values merely by viewing a record.
    if (first != null && first.isNotEmpty && !result.contains(first)) {
      result.add(first);
    }
    return result;
  }

  bool _matchesStatus(Map<String, dynamic> row) {
    if (_selectedStatusFilters.isEmpty) return true;
    final values = _recordStatuses(row);
    return _selectedStatusFilters.any(values.contains);
  }

  bool _matchesSearch(Map<String, dynamic> row) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      row['meeting'],
      row['resolution'],
      row['person_in_charge'],
      row['status'],
      row['secondary_status'],
      row['meeting_date'],
      row['deadline'],
    ].where((value) => value != null).join(' ').toLowerCase().contains(query);
  }

  void _selectStatusFilter(String? status) {
    setState(() {
      if (status == null) {
        _selectedStatusFilters.clear();
      } else if (!_selectedStatusFilters.add(status)) {
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

  int _compareNewest(Map<String, dynamic> a, Map<String, dynamic> b) {
    final aMonth = _parseDate(a['original_report_month']) ?? DateTime(1900);
    final bMonth = _parseDate(b['original_report_month']) ?? DateTime(1900);
    final monthOrder = bMonth.compareTo(aMonth);
    if (monthOrder != 0) return monthOrder;
    final aDate = _parseDate(a['meeting_date']) ?? DateTime(1900);
    final bDate = _parseDate(b['meeting_date']) ?? DateTime(1900);
    final dateOrder = bDate.compareTo(aDate);
    if (dateOrder != 0) return dateOrder;
    final aNo = int.tryParse(a['line_no']?.toString() ?? '') ?? 0;
    final bNo = int.tryParse(b['line_no']?.toString() ?? '') ?? 0;
    return aNo.compareTo(bNo);
  }

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

      // Read all reports for this property. Meeting Date determines when a
      // resolution starts appearing, even when entered in a later report.
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
      allSiteReportMonths.putIfAbsent(_reportId, () => selectedMonth!);
      final selectedStart = DateTime(selectedDate.year, selectedDate.month);
      final reportMonths = allSiteReportMonths;
      final reportIds = reportMonths.keys.toList();

      if (reportIds.isEmpty) {
        if (!mounted) return;
        setState(() {
          _records = [];
          _thisMonthSnapshots = [];
          _historySnapshots = [];
          _selectedReportMonth = selectedMonth;
          _loading = false;
        });
        return;
      }

      final result = await _supabase
          .from('agm_egm_resolutions')
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
      final updatesByResolution = <String, List<Map<String, dynamic>>>{};
      if (records.isNotEmpty && allSiteReportMonths.isNotEmpty) {
        final updates = await _supabase
            .from('agm_egm_progress_updates')
            .select(
              'resolution_id, report_id, progress_date, status, secondary_status, '
              'resolution, person_in_charge, deadline, created_at, id',
            )
            .inFilter('report_id', allSiteReportMonths.keys.toList());
        final recordIds = records.map((r) => r['id']?.toString()).toSet();
        for (final item in updates) {
          final id = item['resolution_id']?.toString();
          if (id != null && recordIds.contains(id)) {
            updatesByResolution
                .putIfAbsent(id, () => [])
                .add(Map<String, dynamic>.from(item));
          }
        }
      }

      final currentSnapshots = <Map<String, dynamic>>[];
      final earlierSnapshots = <Map<String, dynamic>>[];
      for (final record in records) {
        final original = _parseDate(record['original_report_month']);
        if (original == null) continue;
        final meetingDate = _parseDate(record['meeting_date']) ?? original;
        final meetingMonth = DateTime(meetingDate.year, meetingDate.month);
        if (meetingMonth.isAfter(selectedStart)) continue;

        final activityUpdates = updatesByResolution[record['id']?.toString()] ?? [];
        activityUpdates.sort(_compareProgressUpdates);

        // The original meeting month is always This Month. Older resolutions
        // carry forward while In Progress, including the month they close.
        final snapshot = _snapshotForMonth(record, selectedStart, activityUpdates);
        if (snapshot == null) continue;
        final previousMonth = DateTime(selectedStart.year, selectedStart.month - 1);
        final previousSnapshot = _snapshotForMonth(
          record, previousMonth, activityUpdates,
        );
        final carriedForward = meetingMonth.isBefore(selectedStart) &&
            (_isInProgressSnapshot(previousSnapshot) ||
                _isInProgressSnapshot(snapshot));
        if (meetingMonth.isAtSameMomentAs(selectedStart) || carriedForward) {
          if (carriedForward) snapshot['_carried_forward'] = true;
          currentSnapshots.add(snapshot);
        } else {
          snapshot['_history_month'] = _dateForDatabase(meetingMonth);
          earlierSnapshots.add(snapshot);
        }
      }
      currentSnapshots.sort(_compareNewest);
      earlierSnapshots.sort((a, b) {
        final aMonth = _parseDate(a['_history_month']) ?? DateTime(1900);
        final bMonth = _parseDate(b['_history_month']) ?? DateTime(1900);
        final order = bMonth.compareTo(aMonth);
        return order != 0 ? order : _compareNewest(a, b);
      });

      // All categories use consistent newest-first ordering.
      records.sort(_compareNewest);

      if (!mounted) return;

      setState(() {
        _records = records;
        _thisMonthSnapshots = currentSnapshots;
        _historySnapshots = earlierSnapshots;
        _selectedReportMonth = selectedMonth;
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

  static int _compareProgressUpdates(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final aDate = _parseDate(a['progress_date']) ?? DateTime(1900);
    final bDate = _parseDate(b['progress_date']) ?? DateTime(1900);
    final dateOrder = aDate.compareTo(bDate);
    if (dateOrder != 0) return dateOrder;
    final createdOrder = (a['created_at']?.toString() ?? '').compareTo(
      b['created_at']?.toString() ?? '',
    );
    if (createdOrder != 0) return createdOrder;
    return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
  }

  // Historical months use their month-end cutoff. For the current calendar
  // month, exclude future-dated progress entries.
  static DateTime _monthCutoff(DateTime month) {
    final lastDay = DateTime(month.year, month.month + 1, 0);
    final today = DateUtils.dateOnly(DateTime.now());
    return month.year == today.year && month.month == today.month
        ? today
        : lastDay;
  }

  // The progress list is sorted by Progress Date, creation time and ID.
  // Each snapshot is independent: a September completion cannot change
  // August's history. The same source record is never duplicated in Supabase.
  Map<String, dynamic>? _snapshotForMonth(
    Map<String, dynamic> source,
    DateTime month,
    List<Map<String, dynamic>> updates,
  ) {
    final original = _parseDate(source['original_report_month']);
    if (original == null) return null;
    final meetingDate = _parseDate(source['meeting_date']) ?? original;
    final startedMonth = DateTime(meetingDate.year, meetingDate.month);
    final snapshotMonth = DateTime(month.year, month.month);
    if (snapshotMonth.isBefore(startedMonth)) return null;

    final cutoff = _monthCutoff(snapshotMonth);
    if (cutoff.isBefore(snapshotMonth)) return null;
    Map<String, dynamic>? latest;
    var wasCompleted = _recordStatuses(source).contains('Completed');
    String? completedDate;
    for (final update in updates) {
      final date = _parseDate(update['progress_date']);
      if (date == null || date.isBefore(meetingDate)) continue;
      if (!date.isAfter(cutoff)) {
        latest = update;
        final isCompleted = update['status'] == 'Completed' ||
            update['secondary_status'] == 'Completed';
        if (isCompleted && (!wasCompleted || completedDate == null)) {
          // Keep the first completion date of the current completed period.
          completedDate = update['progress_date']?.toString();
        } else if (!isCompleted) {
          completedDate = null;
        }
        wasCompleted = isCompleted;
      }
    }

    final snapshot = Map<String, dynamic>.from(source);
    if (latest != null) {
      for (final field in [
        'resolution',
        'person_in_charge',
        'deadline',
      ]) {
        snapshot[field] = latest[field];
      }
    }
    final rawStatus = (latest?['status'] ?? source['status'] ?? 'Pending')
        .toString();
    snapshot['status'] = rawStatus;
    snapshot['secondary_status'] = latest == null
        ? source['secondary_status']
        : latest['secondary_status'];
    snapshot['_raw_status'] = rawStatus;
    snapshot['_snapshot_month'] = _dateForDatabase(snapshotMonth);
    snapshot['_latest_progress_date'] = latest?['progress_date'];
    snapshot['_latest_progress_id'] = latest?['id'];
    snapshot['_completed_date'] = _recordStatuses(snapshot).contains('Completed')
        ? completedDate
        : null;
    return snapshot;
  }

  bool _isInProgressSnapshot(Map<String, dynamic>? snapshot) {
    if (snapshot == null) return false;
    final statuses = _recordStatuses(snapshot);
    return statuses.contains('In Progress') &&
        !statuses.contains('Completed') &&
        !statuses.contains('Cancelled');
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

  // Summary counts include both new and historical resolutions visible
  // in the selected report, so a September report does not show zero when
  // older AGM resolutions are listed under History.
  List<Map<String, dynamic>> get _allVisibleRecords => [
    ..._thisMonthRecords,
    ..._historicalRecords,
  ];

  int _countStatus(String status) => _allVisibleRecords
      .where((record) => _recordStatuses(record).contains(status))
      .length;

  // The existing dialog and progress buttons remain unchanged.
  Widget _statusSelector(
    Set<String> selected,
    StateSetter setDialogState,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Status (select up to 2)'),
        const flutter_widgets.SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final status in _statuses)
              FilterChip(
                label: Text(status),
                selected: selected.contains(status),
                selectedColor: _statusColor(status).withValues(alpha: 0.15),
                checkmarkColor: _statusColor(status),
                onSelected: (enabled) {
                  if (enabled && selected.length >= 2) return;
                  setDialogState(() {
                    if (enabled) {
                      selected.add(status);
                    } else {
                      selected.remove(status);
                    }
                  });
                },
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openForm({Map<String, dynamic>? record}) async {
    if (_saving) return;

    final isEditing = record != null;
    final isHistoryEdit = record != null &&
        record['_latest_progress_id'] != null &&
        record['_snapshot_month'] != null;
    // Use the source row for identifiers, with historical progress fields
    // loaded from the snapshot when editing an archived month.
    final sourceRecord = record == null
        ? <String, dynamic>{}
        : _records.firstWhere(
            (row) => row['id']?.toString() == record['id']?.toString(),
            orElse: () => record,
          );
    final formKey = GlobalKey<FormState>();
    final historyRecord = record ?? <String, dynamic>{};

    final meetingController = TextEditingController(
      text: sourceRecord['meeting']?.toString() ?? '',
    );
    final resolutionController = TextEditingController(
      text: (isHistoryEdit ? historyRecord['resolution'] :
          sourceRecord['resolution'])?.toString() ?? '',
    );
    final personController = TextEditingController(
      text: (isHistoryEdit ? historyRecord['person_in_charge'] :
          sourceRecord['person_in_charge'])?.toString() ?? '',
    );

    DateTime? meetingDate = _parseDate(sourceRecord['meeting_date']);
    DateTime? deadline = _parseDate(
      isHistoryEdit ? historyRecord['deadline'] : sourceRecord['deadline'],
    );
    DateTime? historyProgressDate = isHistoryEdit
        ? _parseDate(historyRecord['_latest_progress_date'])
        : null;
    final formStatuses = _recordStatuses(
      isHistoryEdit ? historyRecord : sourceRecord,
    );
    final selectedStatuses = <String>{
      for (final value in formStatuses)
        if (_statuses.contains(value)) value,
    };
    if (selectedStatuses.isEmpty) selectedStatuses.add('Pending');

    // Keep the form and its controllers alive until the dialog is fully
    // removed from the overlay (not merely until Navigator.pop completes).
    final dialogRoute = DialogRoute<bool>(
      context: context,
      barrierDismissible: !_saving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.white,
              surfaceTintColor: Colors.transparent,
              title: Text(
                isEditing ? 'Edit Resolution' : 'Add Resolution',
                style: const TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: flutter_widgets.SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (record != null &&
                            record['_snapshot_month'] != null &&
                            record['report_id']?.toString() != _reportId) ...[
                          const Text(
                            'Editing this source resolution can change how it '
                            'appears in multiple monthly reports. For a '
                            'month-specific status, use a dated Progress update.',
                            style: TextStyle(color: AppColors.red, fontSize: 12),
                          ),
                          const flutter_widgets.SizedBox(height: 12),
                        ],
                        Text(
                          isEditing
                              ? 'Record No. ${record['line_no']}'
                              : 'Record No. ${_nextLineNumber()}',
                          style: const TextStyle(
                            color: AppColors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 18),
                        _dateField(
                          context: context,
                          label: 'Meeting Date',
                          value: meetingDate,
                          onChanged: (value) {
                            setDialogState(() => meetingDate = value);
                          },
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        TextFormField(
                          controller: meetingController,
                          decoration: const InputDecoration(
                            labelText: 'Meeting',
                            hintText: 'Enter AGM or EGM meeting',
                            alignLabelWithHint: true,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        TextFormField(
                          controller: resolutionController,
                          minLines: 3,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Resolution',
                            hintText: 'Enter the resolution or decision',
                            alignLabelWithHint: true,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        TextFormField(
                          controller: personController,
                          minLines: 3,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Person-in-Charge',
                            hintText: 'Enter the responsible person',
                            alignLabelWithHint: true,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        _dateField(
                          context: context,
                          label: 'Deadline',
                          value: deadline,
                          onChanged: (value) {
                            setDialogState(() => deadline = value);
                          },
                        ),
                        if (isHistoryEdit) ...[
                          const flutter_widgets.SizedBox(height: 16),
                          _dateField(
                            context: context,
                            label: 'Progress Date',
                            value: historyProgressDate,
                            onChanged: (value) => setDialogState(
                              () => historyProgressDate = value,
                            ),
                          ),
                        ],
                        const flutter_widgets.SizedBox(height: 16),
                        _statusSelector(selectedStatuses, setDialogState),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selectedStatuses.isEmpty ? null : () {
                    if (formKey.currentState!.validate()) {
                      Navigator.of(dialogContext).pop(true);
                    }
                  },
                  child: Text(isEditing ? 'Save Changes' : 'Add Resolution'),
                ),
              ],
            );
          },
        );
      },
    );

    final result = await Navigator.of(context, rootNavigator: true)
        .push<bool>(dialogRoute);
    await dialogRoute.completed;

    if (result == true && mounted) {
      final orderedStatuses = _statuses.where(selectedStatuses.contains).toList();
      await _saveRecord(
        record: record,
        meetingDate: meetingDate,
        deadline: deadline,
        meeting: meetingController.text,
        resolutionText: resolutionController.text,
        personInCharge: personController.text,
        status: orderedStatuses.first,
        secondaryStatus: orderedStatuses.length > 1 ? orderedStatuses[1] : null,
        historyProgressDate: historyProgressDate,
      );
    }

    meetingController.dispose();
    resolutionController.dispose();
    personController.dispose();
  }

  Widget _dateField({
    required BuildContext context,
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onChanged,
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
              if (value != null)
                IconButton(
                  tooltip: 'Clear date',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => onChanged(null),
                ),
              const Icon(Icons.calendar_month_outlined),
              const flutter_widgets.SizedBox(width: 12),
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
    required DateTime? meetingDate,
    required DateTime? deadline,
    required String meeting,
    required String resolutionText,
    required String personInCharge,
    required String? status,
    required String? secondaryStatus,
    required DateTime? historyProgressDate,
  }) async {
    if (_saving) return;

    final isEditing = record != null;
    final historyRecord = record ?? <String, dynamic>{};

    final historyProgressId = historyRecord['_latest_progress_id']?.toString();
    final historyMonth = historyRecord['_snapshot_month']?.toString();
    final editingHistoryEvent = isEditing &&
        historyProgressId != null && historyMonth != null;
    if (editingHistoryEvent && historyProgressDate == null) {
      _showMessage('A historical progress event requires a Progress Date.');
      return;
    }
    if (editingHistoryEvent &&
        meetingDate != null &&
        historyProgressDate != null &&
        historyProgressDate.isBefore(meetingDate)) {
      _showMessage('Progress Date cannot precede Meeting Date.');
      return;
    }

    setState(() => _saving = true);

    try {
      final lineNumber = isEditing
          ? record['line_no'] as int
          : _nextLineNumber();

      final data = <String, dynamic>{
        'report_id': isEditing ? record['report_id'] : _reportId,
        'line_no': lineNumber,
        'meeting_date': _dateForDatabase(meetingDate),
        'meeting': _nullIfEmpty(meeting),
        'resolution': _nullIfEmpty(resolutionText),
        'person_in_charge': _nullIfEmpty(personInCharge),
        'deadline': _dateForDatabase(deadline),
        'status': status,
        'secondary_status': secondaryStatus,
      };

      if (isEditing) {
        if (editingHistoryEvent) {
          // History Edit changes the dated event that produced this snapshot.
          // It must not overwrite all previous months with a new base status.
          final originalSource = _records.firstWhere(
            (r) => r['id']?.toString() == record['id']?.toString(),
            orElse: () => record,
          );
          final sourceChanges = <String, dynamic>{};
          if (_dateForDatabase(meetingDate) !=
              originalSource['meeting_date']?.toString()) {
            sourceChanges['meeting_date'] = _dateForDatabase(meetingDate);
          }
          if (_nullIfEmpty(meeting) !=
              originalSource['meeting']) {
            sourceChanges['meeting'] =
                _nullIfEmpty(meeting);
          }
          var sourceSaved = false;
          try {
            if (sourceChanges.isNotEmpty) {
              final updatedSource = await _supabase
                  .from('agm_egm_resolutions')
                  .update(sourceChanges)
                  .eq('id', record['id'].toString())
                  .eq('report_id', record['report_id'].toString())
                  .select('id');
              if (updatedSource.isEmpty) {
                throw Exception('Could not edit the resolution source.');
              }
              sourceSaved = true;
            }
            final updatedProgress = await _supabase
                .from('agm_egm_progress_updates')
                .update({
                  'progress_date': _dateForDatabase(historyProgressDate),
                  'status': status,
                  'secondary_status': secondaryStatus,
                  'resolution': _nullIfEmpty(resolutionText),
                  'person_in_charge': _nullIfEmpty(personInCharge),
                  'deadline': _dateForDatabase(deadline),
                })
                .eq('id', historyProgressId)
                .eq('resolution_id', record['id'].toString())
                .select('id');
            if (updatedProgress.isEmpty) {
              throw Exception('Could not update the dated progress event.');
            }
          } catch (_) {
            if (sourceSaved) {
              final oldValues = <String, dynamic>{};
              for (final key in sourceChanges.keys) {
                oldValues[key] = originalSource[key];
              }
              try {
                await _supabase
                    .from('agm_egm_resolutions')
                    .update(oldValues)
                    .eq('id', record['id'].toString())
                    .eq('report_id', record['report_id'].toString());
              } catch (rollbackError) {
                debugPrint('Resolution history rollback error: $rollbackError');
              }
            }
            rethrow;
          }
        } else {
          final updated = await _supabase
              .from('agm_egm_resolutions')
              .update(
                data
                  ..remove('report_id')
                  ..remove('line_no'),
              )
              .eq('id', record['id'].toString())
              .eq('report_id', record['report_id'].toString())
              .select('id');
          if (updated.isEmpty) {
            throw Exception(
              'No record was updated. Check your Supabase UPDATE policy.',
            );
          }
        }
      } else {
        await _supabase.from('agm_egm_resolutions').insert(data);
      }

      if (!mounted) return;

      await _loadRecords();

      if (!mounted) return;

      _showMessage(
        isEditing
            ? 'Resolution updated successfully.'
            : 'Resolution added successfully.',
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not save the record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Append a dated progress event. The selected Progress Date controls
  // which report month shows its status. Correcting Meeting Date updates the
  // originating resolution, not a copied monthly snapshot.
  Future<void> _updateMonthlyProgress(Map<String, dynamic> record) async {
    if (_saving) return;
    final reportMonth = _parseDate(_selectedReportMonth);
    if (reportMonth == null || record['id'] == null) {
      _showMessage('Could not identify the reporting month or resolution.');
      return;
    }

    final meetingController = TextEditingController(
      text: record['meeting']?.toString() ?? '',
    );
    final resolutionController = TextEditingController(
      text: record['resolution']?.toString() ?? '',
    );
    final personController = TextEditingController(
      text: record['person_in_charge']?.toString() ?? '',
    );
    final now = DateUtils.dateOnly(DateTime.now());
    DateTime? meetingDate = _parseDate(record['meeting_date']);
    final previousMeetingDate = _dateForDatabase(meetingDate);
    // When updating History in a past report, default Progress Date to that
    // report's last day so the status applies to the report being viewed.
    final selectedMonthEnd = DateTime(reportMonth.year, reportMonth.month + 1, 0);
    DateTime? progressDate = selectedMonthEnd.isBefore(now) ? selectedMonthEnd : now;
    DateTime? deadline = _parseDate(record['deadline']);
    final selectedStatuses = <String>{
      for (final value in _recordStatuses(record))
        if (_statuses.contains(value)) value,
    };
    if (selectedStatuses.isEmpty) selectedStatuses.add('Pending');

    try {
      final progressDialogRoute = DialogRoute<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: AppColors.white,
            title: const Text('Update Resolution Progress'),
            content: flutter_widgets.SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: meetingController,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(labelText: 'Meeting'),
                    ),
                    const flutter_widgets.SizedBox(height: 16),
                    _dateField(
                      context: context,
                      label: 'Meeting Date',
                      value: meetingDate,
                      onChanged: (date) =>
                          setDialogState(() => meetingDate = date),
                    ),
                    const flutter_widgets.SizedBox(height: 12),
                    _dateField(
                      context: context,
                      label: 'Progress Date',
                      value: progressDate,
                      onChanged: (date) =>
                          setDialogState(() => progressDate = date),
                    ),
                    const flutter_widgets.SizedBox(height: 12),
                    _statusSelector(selectedStatuses, setDialogState),
                    const flutter_widgets.SizedBox(height: 12),
                    TextFormField(
                      controller: resolutionController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Resolution',
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 12),
                    TextFormField(
                      controller: personController,
                      minLines: 1,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Person-in-Charge',
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 12),
                    _dateField(
                      context: context,
                      label: 'Deadline',
                      value: deadline,
                      onChanged: (date) =>
                          setDialogState(() => deadline = date),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selectedStatuses.isEmpty
                    ? null : () => Navigator.pop(dialogContext, true),
                child: const Text('Save Progress'),
              ),
            ],
          ),
        ),
      );
      final confirmed = await Navigator.of(context, rootNavigator: true)
          .push<bool>(progressDialogRoute);
      await progressDialogRoute.completed;
      if (confirmed != true || !mounted) return;
      final selectedProgressDate = progressDate;
      final selectedMeetingDate = meetingDate;
      if (selectedProgressDate == null) {
        _showMessage('Please select a Progress Date.');
        return;
      }
      if (selectedMeetingDate != null &&
          selectedProgressDate.isBefore(selectedMeetingDate)) {
        _showMessage('Progress Date cannot precede Meeting Date.');
        return;
      }
      final newMeetingDate = _dateForDatabase(selectedMeetingDate);
      final newMeeting = _nullIfEmpty(meetingController.text);
      final sourceChanges = <String, dynamic>{};
      final previousSourceValues = <String, dynamic>{};
      if (newMeetingDate != previousMeetingDate) {
        sourceChanges['meeting_date'] = newMeetingDate;
        previousSourceValues['meeting_date'] = previousMeetingDate;
      }
      if (newMeeting != record['meeting']) {
        sourceChanges['meeting'] = newMeeting;
        previousSourceValues['meeting'] = record['meeting'];
      }
      setState(() => _saving = true);
      var sourceSaved = false;
      try {
        if (sourceChanges.isNotEmpty) {
          final changed = await _supabase
              .from('agm_egm_resolutions')
              .update(sourceChanges)
              .eq('id', record['id'].toString())
              .eq('report_id', record['report_id'].toString())
              .select('id');
          if (changed.isEmpty) {
            throw Exception('Meeting details were not updated. Check permissions.');
          }
          sourceSaved = true;
        }
        final orderedStatuses = _statuses.where(selectedStatuses.contains).toList();
        await _supabase.from('agm_egm_progress_updates').insert({
          'resolution_id': record['id'],
          'report_id': _reportId,
          'progress_date': _dateForDatabase(selectedProgressDate),
          'status': orderedStatuses.first,
          'secondary_status': orderedStatuses.length > 1 ? orderedStatuses[1] : null,
          'resolution': _nullIfEmpty(resolutionController.text),
          'person_in_charge': _nullIfEmpty(personController.text),
          'deadline': _dateForDatabase(deadline),
        });
        if (!mounted) return;
        await _loadRecords();
        if (mounted) {
          _showMessage('Progress saved for the selected progress date.');
        }
      } catch (e) {
        if (sourceSaved) {
          try {
            final restored = await _supabase
                .from('agm_egm_resolutions')
                .update(previousSourceValues)
                .eq('id', record['id'].toString())
                .eq('report_id', record['report_id'].toString())
                .select('id');
            if (restored.isEmpty) {
              throw Exception('Previous meeting details could not be restored.');
            }
          } catch (rollbackError) {
            if (mounted) {
              _showMessage('Progress failed: $e. Meeting details rollback also '
                  'failed: $rollbackError');
            }
            return;
          }
        }
        if (mounted) _showMessage('Could not save progress: $e');
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    } finally {
      meetingController.dispose();
      resolutionController.dispose();
      personController.dispose();
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    if (_saving) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete record?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);

    try {
      final deleted = await _supabase
          .from('agm_egm_resolutions')
          .delete()
          .eq('id', record['id'].toString())
          .eq('report_id', record['report_id'].toString())
          .select('id');
      if (deleted.isEmpty) {
        throw Exception('No record was deleted. Check your Supabase DELETE policy.');
      }

      if (!mounted) return;

      await _loadRecords();

      if (!mounted) return;

      _showMessage('Resolution deleted successfully.');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not delete the record: $e');
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

    final raw = value.toString();
    final date = DateTime.tryParse(
      RegExp(r'^\d{4}-\d{2}$').hasMatch(raw) ? '$raw-01' : raw,
    );
    if (date == null) return raw;

    return '${_monthName(date.month)} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('AGM / EGM Resolutions'),
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
          const flutter_widgets.SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // The records are already loaded. Reloading the entire page just
        // before opening a route can rebuild the tree during navigation.
        onPressed: _loading || _saving || _error != null
            ? null
            : () => _openForm(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Resolution'),
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: AppColors.red, size: 44),
            const flutter_widgets.SizedBox(height: 12),
            const Text('Unable to load AGM / EGM Resolutions records.'),
            const flutter_widgets.SizedBox(height: 8),
            SelectableText(_error!, style: const TextStyle(color: AppColors.grey)),
            const flutter_widgets.SizedBox(height: 16),
            FilledButton(onPressed: _loadRecords, child: const Text('Try again')),
          ]),
        ),
      );
    }

    final thisMonth = _thisMonthRecords
        .where((row) => _matchesStatus(row) && _matchesSearch(row)).toList()
      ..sort(_compareNewest);
    final historical = _historicalRecords
        .where((row) => _matchesStatus(row) && _matchesSearch(row))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _buildHeader(),
        const flutter_widgets.SizedBox(height: 20),
        _buildSummary(),
        const flutter_widgets.SizedBox(height: 22),
        Column(key: _recordsAnchorKey, children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search meeting, resolution, person-in-charge...',
              prefixIcon: const Icon(Icons.search, color: AppColors.grey),
              suffixIcon: _searchController.text.isEmpty ? null : IconButton(
                onPressed: _searchController.clear,
                icon: const Icon(Icons.clear),
                tooltip: 'Clear search',
              ),
            ),
          ),
          const flutter_widgets.SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: Wrap(
            spacing: 7,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Showing:', style: TextStyle(
                color: AppColors.grey, fontSize: 12,
              )),
              if (_selectedStatusFilters.isEmpty)
                const Text('All statuses', style: TextStyle(
                  color: AppColors.grey, fontSize: 12,
                )),
              for (final filter in _statuses.where(
                  (item) => _selectedStatusFilters.contains(item)))
                Chip(
                  label: Text(filter),
                  onDeleted: () => _selectStatusFilter(filter),
                  visualDensity: VisualDensity.compact,
                ),
              if (_selectedStatusFilters.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _selectStatusFilter(null),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Clear filter'),
                ),
            ],
          )),
        ]),
        const flutter_widgets.SizedBox(height: 18),
        _buildRecordSection('This Month', thisMonth, _thisMonthRecords.length),
        const flutter_widgets.SizedBox(height: 24),
        _buildHistorySection(historical),
      ],
    );
  }

  Widget _buildRecordSection(
    String title,
    List<Map<String, dynamic>> rows,
    int total,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(
            fontSize: 19, fontWeight: FontWeight.bold, color: AppColors.black,
          ))),
          Text('$total records', style: const TextStyle(color: AppColors.grey)),
        ]),
        const flutter_widgets.SizedBox(height: 12),
        if (rows.isEmpty)
          _emptySection('No matching resolutions in this month.')
        else
          for (var i = 0; i < rows.length; i++)
            _buildRecordCard(rows[i], displayNumber: i + 1),
      ],
    );
  }

  Widget _emptySection(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.grey)),
  );

  Widget _buildHistorySection(List<Map<String, dynamic>> history) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final snapshot in history) {
      // History includes all statuses, grouped by the original Meeting Date.
      // It does not duplicate the same resolution once for each past month.
      final key = snapshot['_history_month']?.toString() ?? '';
      if (key.isNotEmpty) grouped.putIfAbsent(key, () => []).add(snapshot);
    }
    final months = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final totalHistoryRecords = grouped.values.fold<int>(
      0,
      (total, records) => total + records.length,
    );

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
              '$totalHistoryRecords record(s)',
              style: const TextStyle(color: AppColors.grey),
            ),
          ],
        ),
        const flutter_widgets.SizedBox(height: 12),
        if (months.isEmpty)
          _emptySection('No resolutions from previous months.')
        else
          for (final month in months)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ExpansionTile(
                key: PageStorageKey('resolutions-history-$_reportId-$month'),
                initiallyExpanded: false,
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                title: Text(
                  _displayReportMonth(month),
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${grouped[month]!.length} record(s)',
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontSize: 12,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  for (var i = 0; i < grouped[month]!.length; i++)
                    _buildRecordCard(
                      grouped[month]![i],
                      displayNumber: i + 1,
                      historical: true,
                    ),
                ],
              ),
            ),
      ],
    );
  }

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
          const flutter_widgets.SizedBox(height: 8),
          const Text(
            'AGM / EGM Resolutions',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const flutter_widgets.SizedBox(height: 8),
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
        final width = constraints.maxWidth >= 640
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: _summaryCard(
                'Total Resolutions',
                _allVisibleRecords.length,
                Icons.assignment_outlined,
                AppColors.red,
                onTap: () => _selectStatusFilter(null),
              ),
            ),
            const flutter_widgets.SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Approved',
                    _countStatus('Approved'),
                    Icons.verified_outlined,
                    const Color(0xFF22683D),
                    onTap: () => _selectStatusFilter('Approved'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Completed',
                    _countStatus('Completed'),
                    Icons.check_circle_outline,
                    const Color(0xFF22683D),
                    onTap: () => _selectStatusFilter('Completed'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Pending',
                    _countStatus('Pending'),
                    Icons.schedule,
                    const Color(0xFF966400),
                    onTap: () => _selectStatusFilter('Pending'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Cancelled',
                    _countStatus('Cancelled'),
                    Icons.cancel_outlined,
                    AppColors.red,
                    onTap: () => _selectStatusFilter('Cancelled'),
                  ),
                ),
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
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 106),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const flutter_widgets.SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(
                color: AppColors.grey, fontSize: 12,
                fontWeight: FontWeight.w600,
              )),
              const flutter_widgets.SizedBox(height: 5),
              Text('$count', style: const TextStyle(
                color: AppColors.black, fontSize: 22,
                fontWeight: FontWeight.w800,
              )),
            ],
          )),
        ]),
      ),
    );
  }

  Widget _buildRecordCard(
    Map<String, dynamic> record, {
    required int displayNumber,
    bool historical = false,
  }) {
    final statuses = _recordStatuses(record);
    final completedDate = statuses.contains('Completed')
        ? record['_completed_date']
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$displayNumber',
                    style: const TextStyle(
                      color: AppColors.red,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                ),
                const flutter_widgets.SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayValue(
                          record['meeting'],
                          'Unnamed meeting',
                        ),
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (record['_carried_forward'] == true) ...[
                        const flutter_widgets.SizedBox(height: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.red.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Carried Forward',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (statuses.isNotEmpty) ...[
                  const flutter_widgets.SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 185),
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      alignment: WrapAlignment.end,
                      children: [
                        for (final status in statuses)
                          InkWell(
                            onTap: _statuses.contains(status)
                                ? () => _selectStatusFilter(status)
                                : null,
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _statusColor(status).withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                status,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _statusColor(status),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const flutter_widgets.SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final showCompleted = completedDate != null;
                final count = showCompleted ? 3 : 2;
                const spacing = 8.0;
                final minCardWidth = showCompleted ? 125.0 : 140.0;
                final oneRow = constraints.maxWidth >=
                    count * minCardWidth + (count - 1) * spacing;
                final width = oneRow
                    ? (constraints.maxWidth - (count - 1) * spacing) / count
                    : constraints.maxWidth;
                return Wrap(
                  spacing: spacing,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: width,
                      child: _dateBox('Meeting Date', record['meeting_date']),
                    ),
                    SizedBox(
                      width: width,
                      child: _dateBox('Deadline', record['deadline']),
                    ),
                    if (showCompleted)
                      SizedBox(
                        width: width,
                        child: _dateBox('Completed Date', completedDate),
                      ),
                  ],
                );
              },
            ),
            if (_hasText(record['resolution'])) ...[
              const flutter_widgets.SizedBox(height: 14),
              _detail('Resolution', record['resolution']),
            ],
            if (_hasText(record['person_in_charge'])) ...[
              const flutter_widgets.SizedBox(height: 10),
              _detail('Person-in-Charge', record['person_in_charge']),
            ],
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (historical) ...[
                    TextButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _updateMonthlyProgress(record),
                      icon: const Icon(Icons.autorenew, size: 18),
                      label: const Text('Update Progress'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.red,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : () => _deleteRecord(record),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.red,
                      ),
                    ),
                  ] else ...[
                    TextButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _updateMonthlyProgress(record),
                      icon: const Icon(Icons.autorenew, size: 18),
                      label: const Text('Update Progress'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.red,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : () => _deleteRecord(record),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.red,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateBox(String label, dynamic value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.charcoal.withValues(alpha: 0.045),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: AppColors.grey, fontSize: 11)),
          const flutter_widgets.SizedBox(height: 4),
          Text(
            _displayDate(value),
            style: const TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // Labels on the left, full descriptions on the right.
  Widget _detail(String label, dynamic value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 126,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.grey,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const flutter_widgets.SizedBox(width: 12),
        Expanded(
          child: Text(
            value.toString(),
            softWrap: true,
            style: const TextStyle(
              color: AppColors.black,
              height: 1.45,
              fontSize: 13,
            ),
          ),
        ),
      ],
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
      case 'Approved':
      case 'Completed':
        return const Color(0xFF22683D);
      case 'In Progress':
        return AppColors.grey;
      case 'Pending':
        return const Color(0xFF966400);
      case 'Cancelled':
        return AppColors.red;
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