import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as flutter_widgets;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class ComplaintsResolutionPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const ComplaintsResolutionPage({super.key, required this.report});

  @override
  State<ComplaintsResolutionPage> createState() =>
      _ComplaintsResolutionPageState();
}

class _ComplaintsResolutionPageState extends State<ComplaintsResolutionPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const List<String> _statuses = [
    'Completed',
    'In Progress',
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

  bool _isCarriedForward(Map<String, dynamic> row) =>
      row['_carried_into_month'] == true;

  String? _selectedReportMonth;
  final GlobalKey _recordsAnchorKey = GlobalKey();

  bool _matchesStatus(Map<String, dynamic> row) {
    if (_selectedStatusFilters.isEmpty) return true;
    return _selectedStatusFilters.any(
      (filter) => row['status'] == filter,
    );
  }

  bool _matchesSearch(Map<String, dynamic> row) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      row['unit_complainant'],
      row['description_location'],
      row['action_taken'],
      row['status'],
      row['entry_date'],
      row['deadline'],
      if (row['deadline_is_asap'] == true) 'ASAP',
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
    final aDate = _parseDate(a['entry_date']) ?? DateTime(1900);
    final bDate = _parseDate(b['entry_date']) ?? DateTime(1900);
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

      // Read reports for this property. Complaints activities are limited to
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
          _thisMonthSnapshots = [];
          _historySnapshots = [];
          _selectedReportMonth = selectedMonth;
          _loading = false;
        });
        return;
      }

      final result = await _supabase
          .from('complaints_resolution')
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
      final updatesByComplaints = <String, List<Map<String, dynamic>>>{};
      if (records.isNotEmpty && allSiteReportMonths.isNotEmpty) {
        final updates = await _supabase
            .from('complaint_progress_updates')
            .select(
              'complaint_id, report_id, progress_date, status, '
              'description_location, action_taken, deadline, '
              'deadline_is_asap, entry_date, unit_complainant, '
              'snapshot_version, created_at, id',
            )
            .inFilter('report_id', allSiteReportMonths.keys.toList());
        final recordIds = records.map((r) => r['id']?.toString()).toSet();
        for (final item in updates) {
          final id = item['complaint_id']?.toString();
          if (id != null && recordIds.contains(id)) {
            updatesByComplaints
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
        final beginning = DateTime(original.year, original.month);
        final activityUpdates = updatesByComplaints[record['id']?.toString()] ?? [];
        activityUpdates.sort(_compareProgressUpdates);

        for (var month = beginning;
            !month.isAfter(selectedStart);
            month = DateTime(month.year, month.month + 1)) {
          final snapshot = _snapshotForMonth(record, month, activityUpdates);
          if (snapshot == null) continue;
          if (month.isAtSameMomentAs(selectedStart)) {
            currentSnapshots.add(snapshot);
          } else if (snapshot['status']?.toString() == 'Completed' &&
              snapshot['_completed_date'] != null) {
            // History shows only completed complaint months.
            // Earlier In Progress months are still visible when opening
            // their own monthly report in This Month.
            earlierSnapshots.add(snapshot);
          }
        }
      }
      currentSnapshots.sort(_compareNewest);
      earlierSnapshots.sort((a, b) {
        final aMonth = _parseDate(a['_snapshot_month']) ?? DateTime(1900);
        final bMonth = _parseDate(b['_snapshot_month']) ?? DateTime(1900);
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

  // Only a dated Completed progress event marks a complaint as Completed.
  // Old Overdue and all other undated or unfinished statuses are In Progress.
  // Deadlines remain visible but do not change the complaint's status.
  static String _effectiveStatus({
    required String rawStatus,
    required bool hasDatedCompletion,
  }) {
    return rawStatus == 'Completed' && hasDatedCompletion
        ? 'Completed'
        : 'In Progress';
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
    final startDate = _parseDate(source['entry_date']) ?? original;
    final originMonth = DateTime(original.year, original.month);
    final startedMonth = DateTime(startDate.year, startDate.month);
    final snapshotMonth = DateTime(month.year, month.month);
    if (snapshotMonth.isBefore(originMonth) ||
        snapshotMonth.isBefore(startedMonth)) {
      return null;
    }

    final cutoff = _monthCutoff(snapshotMonth);
    if (cutoff.isBefore(snapshotMonth)) return null;
    Map<String, dynamic>? beforeMonth;
    Map<String, dynamic>? latest;
    bool changedThisMonth = false;
    for (final update in updates) {
      final date = _parseDate(update['progress_date']);
      if (date == null) continue;
      // An edited Start Date may legitimately be earlier than the original.
      // Check the update's own effective Start Date when available.
      final updateStart = _parseDate(update['entry_date']) ?? startDate;
      if (date.isBefore(updateStart)) continue;
      if (date.isBefore(snapshotMonth)) beforeMonth = update;
      if (!date.isAfter(cutoff)) latest = update;
      if (!date.isBefore(snapshotMonth) && !date.isAfter(cutoff)) {
        changedThisMonth = true;
      }
    }

    final startedEarlier = startedMonth.isBefore(snapshotMonth);
    if (startedEarlier &&
        beforeMonth?['status']?.toString() == 'Completed' &&
        !changedThisMonth) {
      // A previously completed complaint stops carrying into later months,
      // except when a new dated progress event reopens it in this month.
      return null;
    }

    final snapshot = Map<String, dynamic>.from(source);
    if (latest != null) {
      // New progress entries contain complete snapshots so edits to ANY
      // field remain specific to their effective reporting month.
      final fullSnapshot = (latest['snapshot_version'] as num?) == 1;
      final fields = fullSnapshot
          ? <String>[
              'entry_date',
              'unit_complainant',
              'description_location',
              'action_taken',
              'deadline',
              'deadline_is_asap',
            ]
          : <String>[
              'description_location',
              'action_taken',
              'deadline',
              'deadline_is_asap',
            ];
      for (final field in fields) {
        snapshot[field] = latest[field];
      }
    }
    final rawStatus =
        (latest?['status'] ?? source['status'] ?? 'Pending').toString();
    final datedCompletion = latest != null && rawStatus == 'Completed';
    snapshot['status'] = _effectiveStatus(
      rawStatus: rawStatus,
      hasDatedCompletion: datedCompletion,
    );
    snapshot['_raw_status'] = snapshot['status'];
    snapshot['_snapshot_month'] = _dateForDatabase(snapshotMonth);
    snapshot['_carried_into_month'] =
        startedEarlier && originMonth.isBefore(snapshotMonth);
    snapshot['_latest_progress_date'] = latest?['progress_date'];
    snapshot['_latest_progress_id'] = latest?['id'];
    snapshot['_completed_date'] =
        datedCompletion ? latest['progress_date'] : null;
    return snapshot;
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

  // A Progress Date belongs to the reporting month being edited. For a
  // previously elapsed report choose its last day; for today's month choose
  // today. No event is automatically applied to a later report month.
  static DateTime _defaultProgressDate(DateTime? reportMonth) {
    final today = DateUtils.dateOnly(DateTime.now());
    if (reportMonth == null) return today;
    final first = DateTime(reportMonth.year, reportMonth.month);
    final last = DateTime(reportMonth.year, reportMonth.month + 1, 0);
    if (today.isBefore(first)) return first;
    if (today.isAfter(last)) return last;
    return today;
  }

  Future<void> _openForm({
    Map<String, dynamic>? record,
    bool editExistingProgress = false,
  }) async {
    if (_saving) return;

    final isEditing = record != null;
    // Editing a This Month card always APPENDS a fresh progress entry. Only
    // the Edit button in the older completed-record History edits that event.
    final isHistoryEdit = isEditing &&
        editExistingProgress &&
        record['_latest_progress_id'] != null;
    final formKey = GlobalKey<FormState>();

    // Use the displayed monthly snapshot, not the original database row;
    // otherwise already-updated values could revert in a future edit.
    final unitController = TextEditingController(
      text: record?['unit_complainant']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: record?['description_location']?.toString() ?? '',
    );
    final actionController = TextEditingController(
      text: record?['action_taken']?.toString() ?? '',
    );

    DateTime? entryDate = _parseDate(record?['entry_date']);
    DateTime? deadline = _parseDate(record?['deadline']);
    bool deadlineIsAsap = record == null
        ? true
        : record['deadline_is_asap'] == true;
    final progressMonth = _parseDate(
      isHistoryEdit ? record['_snapshot_month'] : _selectedReportMonth,
    );
    DateTime? progressDate = isEditing
        ? (isHistoryEdit
            ? _parseDate(record['_latest_progress_date'])
            : _defaultProgressDate(progressMonth))
        : null;
    String? selectedStatus = record?['_raw_status']?.toString() ??
        record?['status']?.toString() ??
        'In Progress';
    if (!_statuses.contains(selectedStatus)) selectedStatus = 'In Progress';

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: !_saving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.white,
              surfaceTintColor: Colors.transparent,
              title: Text(
                isEditing ? 'Edit Complaint' : 'Add Complaint',
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
                        if (isEditing) ...[
                          const Text(
                            'Save a dated progress update for this report. '
                            'Earlier monthly progress remains unchanged.',
                            style: TextStyle(color: AppColors.grey, fontSize: 12),
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
                          label: 'Start Date',
                          value: entryDate,
                          onChanged: (value) {
                            setDialogState(() => entryDate = value);
                          },
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        TextFormField(
                          controller: unitController,
                          decoration: const InputDecoration(
                            labelText: 'Unit / Complainant',
                            hintText: 'Enter unit number or complainant',
                            alignLabelWithHint: true,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        TextFormField(
                          controller: descriptionController,
                          minLines: 3,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Description & Location',
                            hintText: 'Describe the complaint and its location',
                            alignLabelWithHint: true,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        TextFormField(
                          controller: actionController,
                          minLines: 3,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Action Taken',
                            hintText: 'Describe the action taken',
                            alignLabelWithHint: true,
                          ),
                        ),
                        const flutter_widgets.SizedBox(height: 16),
                        _dateField(
                          context: context,
                          label: 'Deadline Date',
                          value: deadline,
                          onChanged: (value) {
                            setDialogState(() => deadline = value);
                          },
                        ),
                        CheckboxListTile(
                          value: deadlineIsAsap,
                          activeColor: AppColors.red,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('ASAP (urgent)'),
                          subtitle: const Text(
                            'Deadline date is optional.',
                          ),
                          onChanged: (value) {
                            setDialogState(() => deadlineIsAsap = value ?? false);
                          },
                        ),
                        if (isEditing || selectedStatus == 'Completed') ...[
                          const flutter_widgets.SizedBox(height: 12),
                          _dateField(
                            context: context,
                            label: 'Progress Date *',
                            value: progressDate,
                            allowClear: false,
                            onChanged: (value) {
                              setDialogState(() => progressDate = value);
                            },
                          ),
                        ],
                        const flutter_widgets.SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: selectedStatus,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Status',
                          ),
                          hint: const Text('Select status'),
                          items: _statuses.map((status) {
                            return DropdownMenuItem<String>(
                              value: status,
                              child: Text(status),
                            );
                          }).toList(),
                          onChanged: (value) {
                            setDialogState(() {
                              selectedStatus = value;
                              // A newly-added Completed complaint also needs
                              // a dated event to appear Completed immediately.
                              if (!isEditing && value == 'Completed') {
                                progressDate ??=
                                    entryDate ?? _defaultProgressDate(progressMonth);
                              }
                            });
                          },
                        ),
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
                  onPressed: () {
                    if (!formKey.currentState!.validate()) return;
                    if ((isEditing || selectedStatus == 'Completed') &&
                        progressDate == null) {
                      _showMessage('Select a Progress Date.');
                      return;
                    }
                    if (progressDate != null && entryDate != null &&
                        progressDate!.isBefore(entryDate!)) {
                      _showMessage('Progress Date cannot precede Start Date.');
                      return;
                    }
                    Navigator.of(dialogContext).pop(true);
                  },
                  child: Text(isEditing ? 'Save Changes' : 'Add Complaint'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      await _saveRecord(
        record: record,
        editExistingProgress: isHistoryEdit,
        entryDate: entryDate,
        deadline: deadline,
        deadlineIsAsap: deadlineIsAsap,
        unitComplainant: unitController.text,
        descriptionLocation: descriptionController.text,
        actionTaken: actionController.text,
        status: selectedStatus,
        progressDate: progressDate,
      );
    }

    unitController.dispose();
    descriptionController.dispose();
    actionController.dispose();
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
    required bool editExistingProgress,
    required DateTime? entryDate,
    required DateTime? deadline,
    required bool deadlineIsAsap,
    required String unitComplainant,
    required String descriptionLocation,
    required String actionTaken,
    required String? status,
    required DateTime? progressDate,
  }) async {
    if (_saving) return;
    final isEditing = record != null;
    if (status == null || !_statuses.contains(status)) {
      _showMessage('Select a valid Status.');
      return;
    }
    if (!isEditing && entryDate != null) {
      final month = _parseDate(_selectedReportMonth);
      if (month != null &&
          (entryDate.year != month.year || entryDate.month != month.month)) {
        _showMessage('Start Date must be within the selected report month.');
        return;
      }
    }
    if ((isEditing || status == 'Completed') && progressDate == null) {
      _showMessage('A Progress Date is required.');
      return;
    }
    if (progressDate != null && entryDate != null &&
        progressDate.isBefore(entryDate)) {
      _showMessage('Progress Date cannot precede Start Date.');
      return;
    }
    if (progressDate != null) {
      final month = _parseDate(
        editExistingProgress ? record!['_snapshot_month'] : _selectedReportMonth,
      );
      if (month != null &&
          (progressDate.year != month.year || progressDate.month != month.month)) {
        _showMessage('Progress Date must be in the report month being edited.');
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final fields = <String, dynamic>{
        'entry_date': _dateForDatabase(entryDate),
        'unit_complainant': _nullIfEmpty(unitComplainant),
        'description_location': _nullIfEmpty(descriptionLocation),
        'action_taken': _nullIfEmpty(actionTaken),
        'deadline': _dateForDatabase(deadline),
        'deadline_is_asap': deadlineIsAsap,
        'status': status,
      };

      if (isEditing) {
        final id = record['id']?.toString();
        if (id == null || id.isEmpty) {
          throw StateError('Complaint ID is missing.');
        }
        final event = <String, dynamic>{
          ...fields,
          'progress_date': _dateForDatabase(progressDate),
          'snapshot_version': 1,
        };
        if (editExistingProgress) {
          // Explicit correction of a historical event; do not rewrite the
          // original source row and change all earlier monthly reports.
          final progressId = record['_latest_progress_id']?.toString();
          if (progressId == null || progressId.isEmpty) {
            throw StateError('Historical Progress ID is missing.');
          }
          final updated = await _supabase
              .from('complaint_progress_updates')
              .update(event)
              .eq('id', progressId)
              .eq('complaint_id', id)
              .select('id');
          if (updated.isEmpty) {
            throw StateError('Could not update the historical progress event.');
          }
        } else {
          // Always INSERT a new dated snapshot, including all editable
          // fields. This preserves each earlier month's action and status.
          final inserted = await _supabase
              .from('complaint_progress_updates')
              .insert({
                ...event,
                'complaint_id': id,
                'report_id': _reportId,
              })
              .select('id');
          if (inserted.isEmpty) {
            throw StateError('Could not create the complaint progress event.');
          }
        }
      } else {
        final created = await _supabase
            .from('complaints_resolution')
            .insert({
              ...fields,
              'report_id': _reportId,
              'line_no': _nextLineNumber(),
              // A completion is evidenced by a dated progress event, never
              // by an undated base-row status that leaks into older months.
              'status': 'In Progress',
            })
            .select('id');
        if (created.isEmpty) {
          throw StateError('Could not add the complaint.');
        }
        // A newly-created Completed complaint needs a dated completion too.
        if (status == 'Completed') {
          final id = created.first['id']?.toString();
          if (id == null || id.isEmpty) {
            throw StateError('Complaint ID missing after insert.');
          }
          await _supabase.from('complaint_progress_updates').insert({
            ...fields,
            'complaint_id': id,
            'report_id': _reportId,
            'progress_date': _dateForDatabase(progressDate),
            'snapshot_version': 1,
          });
        }
      }

      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;
      _showMessage(isEditing
          ? 'Complaint progress saved successfully.'
          : 'Complaint added successfully.');
    } catch (e) {
      if (mounted) _showMessage('Could not save the complaint: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    if (_saving) return;

    final complaintId = record['id']?.toString();
    if (complaintId == null || complaintId.isEmpty) {
      _showMessage('Cannot delete: complaint ID is missing.');
      return;
    }

    setState(() => _saving = true);

    try {
      final result = await _supabase.rpc(
        'delete_complaint_with_progress',
        params: {'p_complaint_id': complaintId},
      );

      if (result != true) {
        throw Exception('Database did not confirm deletion.');
      }

      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;

      _showMessage('Complaint deleted successfully.');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not delete the complaint: $e');
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
        title: const Text('Complaints & Resolution'),
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
        label: const Text('Add Complaint'),
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
            const Text('Unable to load Complaints & Resolution records.'),
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
    final historical = _historicalRecords.where(_matchesSearch).toList();

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
              hintText: 'Search complaint, unit, description or action...',
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
          _emptySection('No matching complaints in this month.')
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
      final key = snapshot['_snapshot_month']?.toString() ?? '';
      if (key.isNotEmpty) grouped.putIfAbsent(key, () => []).add(snapshot);
    }
    final months = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('History', style: TextStyle(
          color: AppColors.black, fontSize: 19, fontWeight: FontWeight.bold,
        ))),
        Text('${history.length} records', style: const TextStyle(
          color: AppColors.grey,
        )),
      ]),
      const flutter_widgets.SizedBox(height: 12),
      if (months.isEmpty) _emptySection('No previous monthly complaint records.')
      else for (final month in months) ...[
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: AppColors.white,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: ExpansionTile(
            key: PageStorageKey('complaints-history-$_reportId-$month'),
            initiallyExpanded: false,
            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            title: Text(_displayReportMonth(month), style: const TextStyle(
              color: AppColors.black, fontWeight: FontWeight.w600,
            )),
            subtitle: Text('${grouped[month]!.length} complaint record(s)',
                style: const TextStyle(color: AppColors.grey, fontSize: 12)),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              for (var i = 0; i < grouped[month]!.length; i++)
                _buildRecordCard(grouped[month]![i],
                  displayNumber: i + 1, historical: true),
            ],
          ),
        ),
      ],
    ]);
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
            'Complaints & Resolution',
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
    return Column(children: [
      SizedBox(width: double.infinity, child: _summaryCard(
        'Total Complaints', _thisMonthRecords.length,
        Icons.description_outlined, AppColors.red,
        onTap: () => _selectStatusFilter(null),
      )),
      const flutter_widgets.SizedBox(height: 10),
      Row(children: [
        Expanded(child: _summaryCard(
          'Completed', _countStatus('Completed'),
          Icons.check_circle_outline, const Color(0xFF22683D),
          onTap: () => _selectStatusFilter('Completed'),
        )),
        const flutter_widgets.SizedBox(width: 10),
        Expanded(child: _summaryCard(
          'In Progress', _countStatus('In Progress'),
          Icons.autorenew, AppColors.red,
          onTap: () => _selectStatusFilter('In Progress'),
        )),
      ]),
    ]);
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
    final isCarried = _isCarriedForward(record);
    final status = record['status']?.toString();
    final accent = _statusColor(status);

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
                          record['unit_complainant'],
                          'Unnamed complainant',
                        ),
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 5),
                      Text(
                        'Start Date: ${_displayDate(record['entry_date'])}',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                      if (isCarried) ...[
                        const flutter_widgets.SizedBox(height: 3),
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
                if (status != null && status.isNotEmpty) ...[
                  const flutter_widgets.SizedBox(width: 8),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(status, textAlign: TextAlign.center,
                      style: TextStyle(
                        color: accent, fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (_hasText(record['description_location'])) ...[
              const flutter_widgets.SizedBox(height: 14),
              _detail('Description & Location', record['description_location']),
            ],
            if (_hasText(record['action_taken'])) ...[
              const flutter_widgets.SizedBox(height: 10),
              _detail('Action Taken', record['action_taken']),
            ],
            // Completed Date is the dated progress event that changed the
            // effective status to Completed. Do not invent a completion date
            // for legacy Completed records without a saved progress event.

            if (status == 'Completed') ...[
              const flutter_widgets.SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 17,
                    color: Color(0xFF22683D),
                  ),
                  const flutter_widgets.SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      record['_completed_date'] == null
                          ? 'Completed Date: Not recorded'
                          : 'Completed Date: ${_displayDate(record['_completed_date'])}',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (record['deadline'] != null ||
                record['deadline_is_asap'] == true) ...[
              const flutter_widgets.SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.event_outlined,
                    size: 17,
                    color: AppColors.red,
                  ),
                  const flutter_widgets.SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Deadline: ${_displayDate(record['deadline'])}',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (record['deadline_is_asap'] == true) ...[
                    const flutter_widgets.SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.red.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'ASAP',
                        style: TextStyle(
                          color: AppColors.red,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _openForm(
                              record: record,
                              editExistingProgress: historical,
                            ),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
                  TextButton.icon(
                    onPressed: _saving ? null : () => _deleteRecord(record),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, dynamic value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.grey,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const flutter_widgets.SizedBox(height: 4),
        Text(
          value.toString(),
          style: const TextStyle(color: AppColors.black, height: 1.45),
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
      case 'Completed':
        return const Color(0xFF22683D);
      case 'In Progress':
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