import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as flutter_widgets;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class LiftIncidentsPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const LiftIncidentsPage({super.key, required this.report});

  @override
  State<LiftIncidentsPage> createState() => _LiftIncidentsPageState();
}

class _LiftIncidentsPageState extends State<LiftIncidentsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const List<String> _categories = [
    'Lift System',
    'Access Card',
    'Power Supply',
    'Vandalism',
    'Others',
  ];

  static const List<String> _statuses = [
    'Completed',
    'In Progress',
    'Pending',
    'Cancelled',
    'On Hold',
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

  bool _isOpen(Map<String, dynamic> row) => const {
    'In Progress',
    'Pending',
    'On Hold',
  }.contains(row['status']?.toString());

  bool _isCarriedForward(Map<String, dynamic> row) =>
      row['_carried_into_month'] == true;

  String? _selectedReportMonth;
  final GlobalKey _recordsAnchorKey = GlobalKey();

  bool _matchesStatus(Map<String, dynamic> row) {
    if (_selectedStatusFilters.isEmpty) return true;
    return _selectedStatusFilters.any((filter) {
      if (filter == 'Cancelled / On Hold') {
        return row['status'] == 'Cancelled' || row['status'] == 'On Hold';
      }
      if (filter == 'Open Incidents') return _isOpen(row);
      return row['status'] == filter;
    });
  }

  bool _matchesSearch(Map<String, dynamic> row) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      row['tower'],
      row['lift_no'],
      row['incident_category'],
      row['description'],
      row['status'],
      row['incident_date'],
      row['turnaround_hours'],
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
    final aDate = _parseDate(a['incident_date']) ?? DateTime(1900);
    final bDate = _parseDate(b['incident_date']) ?? DateTime(1900);
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

      // Read reports for this property. Incidents activities are limited to
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
          .from('lift_incidents')
          .select()
          .inFilter('report_id', reportIds);
      final records = List<Map<String, dynamic>>.from(result);

      for (final record in records) {
        final originalReportId = record['report_id']?.toString();
        record['original_report_month'] = reportMonths[originalReportId];
      }

      final updatesByIncident = <String, List<Map<String, dynamic>>>{};
      if (records.isNotEmpty && allSiteReportMonths.isNotEmpty) {
        final updates = await _supabase
            .from('lift_incident_progress_updates')
            .select(
              'incident_id, report_id, progress_date, status, '
              'description, turnaround_hours, remarks, mantrap, created_at, id',
            )
            .inFilter('report_id', allSiteReportMonths.keys.toList());
        final recordIds = records.map((r) => r['id']?.toString()).toSet();
        for (final item in updates) {
          final id = item['incident_id']?.toString();
          if (id != null && recordIds.contains(id)) {
            updatesByIncident
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
        final activityUpdates =
            updatesByIncident[record['id']?.toString()] ?? [];
        activityUpdates.sort(_compareProgressUpdates);

        for (
          var month = beginning;
          !month.isAfter(selectedStart);
          month = DateTime(month.year, month.month + 1)
        ) {
          final snapshot = _snapshotForMonth(record, month, activityUpdates);
          if (snapshot == null) continue;
          if (month.isAtSameMomentAs(selectedStart)) {
            currentSnapshots.add(snapshot);
          } else if (snapshot['status']?.toString() == 'Completed') {
            // History shows only completed lift incident months.
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

  // Date-effective snapshots use only updates recorded by the relevant month.
  // An incident is carried forward until a Completed event ends the sequence.
  // A later dated progress entry can explicitly reopen the same incident.
  static DateTime _monthCutoff(DateTime month) {
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final today = DateUtils.dateOnly(DateTime.now());
    return month.year == today.year && month.month == today.month
        ? today
        : monthEnd;
  }

  Map<String, dynamic>? _snapshotForMonth(
    Map<String, dynamic> source,
    DateTime month,
    List<Map<String, dynamic>> updates,
  ) {
    final original = _parseDate(source['original_report_month']);
    if (original == null) return null;
    final incidentDate = _parseDate(source['incident_date']) ?? original;
    final originMonth = DateTime(original.year, original.month);
    final incidentMonth = DateTime(incidentDate.year, incidentDate.month);
    final currentMonth = DateTime(month.year, month.month);
    if (currentMonth.isBefore(originMonth) ||
        currentMonth.isBefore(incidentMonth)) {
      return null;
    }
    final cutoff = _monthCutoff(currentMonth);
    if (cutoff.isBefore(currentMonth)) return null;

    Map<String, dynamic>? beforeMonth;
    Map<String, dynamic>? latest;
    bool hasUpdateThisMonth = false;
    for (final update in updates) {
      final date = _parseDate(update['progress_date']);
      if (date == null || date.isBefore(incidentDate)) continue;
      if (date.isBefore(currentMonth)) beforeMonth = update;
      if (!date.isAfter(cutoff)) latest = update;
      if (!date.isBefore(currentMonth) && !date.isAfter(cutoff)) {
        hasUpdateThisMonth = true;
      }
    }

    final carried = currentMonth.isAfter(incidentMonth);
    final enteringStatus = beforeMonth == null
        ? source['status']?.toString()
        : beforeMonth['status']?.toString();
    final enteringIsOpen = const {'In Progress', 'Pending', 'On Hold'}
        .contains(enteringStatus);
    // Do not duplicate completed or cancelled incidents in later months.
    if (carried && !enteringIsOpen && !hasUpdateThisMonth) return null;

    final snapshot = Map<String, dynamic>.from(source);
    if (latest != null) {
      for (final field in [
        'status', 'description', 'turnaround_hours', 'remarks',
      ]) {
        snapshot[field] = latest[field];
      }

      if (latest['mantrap'] != null) {
        snapshot['mantrap'] = latest['mantrap'];
      }
    }

    final status = snapshot['status']?.toString();
    snapshot['_snapshot_month'] = _dateForDatabase(currentMonth);
    snapshot['_carried_into_month'] = carried;
    snapshot['_latest_progress_date'] = latest == null
        ? null
        : latest['progress_date'];
    snapshot['_latest_progress_id'] = latest == null ? null : latest['id'];
    snapshot['_completed_date'] = status == 'Completed' && latest != null
        ? latest['progress_date']
        : null;
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

  int get _cancelledOrOnHold {
    return _thisMonthRecords.where((record) {
      return record['status'] == 'Cancelled' || record['status'] == 'On Hold';
    }).length;
  }

  static bool _hasProgressInSnapshotMonth(Map<String, dynamic>? record) {
    if (record == null || record['_latest_progress_id'] == null) return false;
    final month = _parseDate(record['_snapshot_month']);
    final event = _parseDate(record['_latest_progress_date']);
    return month != null &&
        event != null &&
        month.year == event.year &&
        month.month == event.month;
  }

  static DateTime? _defaultProgressDate(DateTime? month) {
    if (month == null) return null;
    return _monthCutoff(month);
  }

  Future<void> _openForm({Map<String, dynamic>? record}) async {
    if (_saving) return;
    final sourceRecord = record == null
        ? <String, dynamic>{}
        : _records.firstWhere(
            (row) => row['id']?.toString() == record['id']?.toString(),
            orElse: () => record,
          );
    final editing = record != null;
    final editingProgress = record != null &&
        (_isCarriedForward(record) || _hasProgressInSnapshotMonth(record));
    final historySnapshot = record ?? <String, dynamic>{};
    final key = GlobalKey<FormState>();
    final towerController = TextEditingController(
      text: sourceRecord['tower']?.toString() ?? '',
    );
    final liftController = TextEditingController(
      text: sourceRecord['lift_no']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: (editingProgress
          ? historySnapshot['description']
          : sourceRecord['description'])?.toString() ?? '',
    );
    final hoursController = TextEditingController(
      text: (editingProgress
          ? historySnapshot['turnaround_hours']
          : sourceRecord['turnaround_hours'])?.toString() ?? '',
    );

    bool? mantrap = (editingProgress
        ? historySnapshot['mantrap']
        : sourceRecord['mantrap']) as bool?;

    DateTime? incidentDate = _parseDate(sourceRecord['incident_date']);
    String? category = sourceRecord['incident_category']?.toString();
    if (!_categories.contains(category)) category = null;
    String? status = (editingProgress
        ? historySnapshot['status']
        : sourceRecord['status'])?.toString();
    if (!_statuses.contains(status)) status = null;
    DateTime? historyProgressDate = editingProgress
        ? (_hasProgressInSnapshotMonth(historySnapshot)
            ? _parseDate(historySnapshot['_latest_progress_date'])
            : _defaultProgressDate(_parseDate(historySnapshot['_snapshot_month'])))
        : null;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            backgroundColor: AppColors.white,
            surfaceTintColor: Colors.transparent,
            title: Text(
              editing ? 'Edit Lift Incident' : 'Add Lift Incident',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            content: flutter_widgets.SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Form(
                  key: key,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (record != null &&
                          record['_snapshot_month'] != null &&
                          record['report_id']?.toString() != _reportId) ...[
                        const Text(
                          'Changing Tower, Lift No., Category or Incident Date can affect '
                          'older months. Other fields are saved as dated progress.',
                          style: TextStyle(color: AppColors.red, fontSize: 12),
                        ),
                        const flutter_widgets.SizedBox(height: 12),
                      ],
                      Text(
                        editing
                            ? 'Record No. ${historySnapshot['line_no']}'
                            : 'Record No. ${_nextLineNumber()}',
                        style: const TextStyle(
                          color: AppColors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 16),
                      _dateField(
                        context: context,
                        label: 'Incident Date',
                        value: incidentDate,
                        onChanged: (d) => update(() => incidentDate = d),
                      ),
                      if (editingProgress) ...[
                        const flutter_widgets.SizedBox(height: 12),
                        _dateField(
                          context: context,
                          label: 'Progress Date',
                          value: historyProgressDate,
                          onChanged: (d) =>
                              update(() => historyProgressDate = d),
                        ),
                      ],
                      const flutter_widgets.SizedBox(height: 12),
                      TextFormField(
                        controller: towerController,
                        decoration: const InputDecoration(
                          labelText: 'Tower',
                          hintText: 'Tower or block',
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 12),
                      TextFormField(
                        controller: liftController,
                        decoration: const InputDecoration(
                          labelText: 'Lift No.',
                          hintText: 'Lift identifier',
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: category,
                        decoration: const InputDecoration(
                          labelText: 'Incident Category',
                        ),
                        items: _categories
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                        onChanged: (v) => update(() => category = v),
                      ),

                      const flutter_widgets.SizedBox(height: 12),

                      DropdownButtonFormField<bool>(
                        initialValue: mantrap,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Mantrap',
                        ),
                        hint: const Text('Select Yes or No'),
                        items: const [
                          DropdownMenuItem<bool>(
                            value: true,
                            child: Text('Yes'),
                          ),
                          DropdownMenuItem<bool>(
                            value: false,
                            child: Text('No'),
                          ),
                        ],
                        validator: (value) =>
                            value == null ? 'Please select Yes or No' : null,
                        onChanged: (value) {
                          update(() => mantrap = value);
                        },
                      ),

                      const flutter_widgets.SizedBox(height: 12),
                      TextFormField(
                        controller: descriptionController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 12),
                      TextFormField(
                        controller: hoursController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Turnaround (Hours)',
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: status,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: _statuses
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                        onChanged: (v) => update(() => status = v),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final value = hoursController.text.trim();
                  if (value.isNotEmpty &&
                      (double.tryParse(value) == null ||
                          double.parse(value) < 0)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Enter a valid non-negative turnaround time.',
                        ),
                      ),
                    );
                    return;
                  }
                  if (key.currentState!.validate()) {
                    Navigator.pop(dialogContext, true);
                  }
                },
                child: Text(editing ? 'Save Changes' : 'Add Incident'),
              ),
            ],
          ),
        ),
      );
      if (confirmed == true && mounted) {
        await _saveRecord(
          record: record,
          incidentDate: incidentDate,
          tower: towerController.text,
          liftNo: liftController.text,
          category: category,
          mantrap: mantrap,
          description: descriptionController.text,
          turnaroundHours: hoursController.text,
          status: status,
          historyProgressDate: historyProgressDate,
        );
      }
    } finally {
      towerController.dispose();
      liftController.dispose();
      descriptionController.dispose();
      hoursController.dispose();
    }
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
    required DateTime? incidentDate,
    required String tower,
    required String liftNo,
    required String? category,
    required bool? mantrap,
    required String description,
    required String turnaroundHours,
    required String? status,
    DateTime? historyProgressDate,
  }) async {
    if (_saving) return;
    final editing = record != null;
    final snapshot = record ?? <String, dynamic>{};
    final originalMonth = editing
        ? _parseDate(snapshot['original_report_month'])
        : _parseDate(_selectedReportMonth);
    if (incidentDate != null && originalMonth != null &&
        (incidentDate.year != originalMonth.year ||
         incidentDate.month != originalMonth.month)) {
      _showMessage('Incident Date must stay within the original report month.');
      return;
    }
    final hoursText = turnaroundHours.trim();
    final hours = hoursText.isEmpty ? null : double.tryParse(hoursText);
    if (hoursText.isNotEmpty && (hours == null || hours < 0)) {
      _showMessage('Enter a valid non-negative turnaround time.');
      return;
    }

    final editingProgress = editing &&
        (_isCarriedForward(snapshot) || _hasProgressInSnapshotMonth(snapshot));
    final eventId = _hasProgressInSnapshotMonth(snapshot)
        ? snapshot['_latest_progress_id']?.toString()
        : null;
    final snapshotMonth = _parseDate(snapshot['_snapshot_month']);
    if (editingProgress) {
      if (snapshotMonth == null || historyProgressDate == null) {
        _showMessage('Please select a Progress Date.');
        return;
      }
      if (historyProgressDate.year != snapshotMonth.year ||
          historyProgressDate.month != snapshotMonth.month) {
        _showMessage('Progress Date must be within the selected report month.');
        return;
      }
      if (historyProgressDate.isAfter(_monthCutoff(snapshotMonth))) {
        _showMessage('Progress Date cannot be in the future.');
        return;
      }
      if (incidentDate != null && historyProgressDate.isBefore(incidentDate)) {
        _showMessage('Progress Date cannot precede Incident Date.');
        return;
      }
    }

    setState(() => _saving = true);
    try {
      if (editingProgress) {
        // For a carried-forward incident, Edit saves a dated event in the
        // displayed month; it never rewrites an older month's progress event.
        final originalSource = _records.firstWhere(
          (r) => r['id']?.toString() == snapshot['id']?.toString(),
          orElse: () => snapshot,
        );
        final identityFields = <String, dynamic>{
          'incident_date': _dateForDatabase(incidentDate),
          'tower': _nullIfEmpty(tower),
          'lift_no': _nullIfEmpty(liftNo),
          'incident_category': category,
        };
        final identityChanges = <String, dynamic>{};
        for (final entry in identityFields.entries) {
          if (entry.value?.toString() != originalSource[entry.key]?.toString()) {
            identityChanges[entry.key] = entry.value;
          }
        }
        var sourceSaved = false;
        try {
          if (identityChanges.isNotEmpty) {
            final modified = await _supabase
                .from('lift_incidents')
                .update(identityChanges)
                .eq('id', snapshot['id'].toString())
                .eq('report_id', snapshot['report_id'].toString())
                .select('id');
            if (modified.length != 1) {
              throw Exception('Could not update the incident identity fields.');
            }
            sourceSaved = true;
          }
          final progressValues = <String, dynamic>{
            'progress_date': _dateForDatabase(historyProgressDate),
            'status': status ?? 'Pending',
            'description': _nullIfEmpty(description),
            'turnaround_hours': hours,
            'mantrap': mantrap,
          };
          if (eventId != null) {
            final modified = await _supabase
                .from('lift_incident_progress_updates')
                .update(progressValues)
                .eq('id', eventId)
                .eq('incident_id', snapshot['id'].toString())
                .select('id');
            if (modified.length != 1) {
              throw Exception('Could not update the dated progress event.');
            }
          } else {
            // A carried-forward month with no progress entry receives a NEW
            // dated event, leaving earlier monthly history intact.
            final inserted = await _supabase
                .from('lift_incident_progress_updates')
                .insert({
                  ...progressValues,
                  'incident_id': snapshot['id'],
                  'report_id': _reportId,
                })
                .select('id');
            if (inserted.length != 1) {
              throw Exception('Could not create the monthly progress event.');
            }
          }
        } catch (_) {
          if (sourceSaved) {
            // Best-effort compensation for the separate identity UPDATE.
            final oldFields = <String, dynamic>{};
            for (final key in identityChanges.keys) {
              oldFields[key] = originalSource[key];
            }
            try {
              await _supabase
                  .from('lift_incidents')
                  .update(oldFields)
                  .eq('id', snapshot['id'].toString())
                  .eq('report_id', snapshot['report_id'].toString());
            } catch (rollbackError) {
              debugPrint('Lift identity rollback failed: $rollbackError');
            }
          }
          rethrow;
        }
      } else {
          final payload = <String, dynamic>{
            'incident_date': _dateForDatabase(incidentDate),
            'tower': _nullIfEmpty(tower),
            'lift_no': _nullIfEmpty(liftNo),
            'incident_category': category,
            'mantrap': mantrap,
            'description': _nullIfEmpty(description),
            'turnaround_hours': hours,
            'status': status ?? 'Pending',
          };
        if (editing) {
          final modified = await _supabase
              .from('lift_incidents')
              .update(payload)
              .eq('id', snapshot['id'].toString())
              .eq('report_id', snapshot['report_id'].toString())
              .select('id');
          if (modified.length != 1) {
            throw Exception('No incident was updated. Check the UPDATE policy.');
          }
        } else {
          final inserted = await _supabase
              .from('lift_incidents')
              .insert({
                ...payload,
                'report_id': _reportId,
                'line_no': _nextLineNumber(),
              })
              .select('id');
          if (inserted.length != 1) {
            throw Exception('Could not create the lift incident.');
          }
        }
      }
      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;
      if (_error != null) {
        _showMessage('Saved, but the list could not refresh: $_error');
      } else {
        _showMessage(editing
            ? 'Lift incident updated successfully.'
            : 'Lift incident added successfully.');
      }
    } catch (error) {
      if (mounted) _showMessage('Could not save lift incident: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    if (_saving) return;
    final incidentId = record['id']?.toString();
    if (incidentId == null || incidentId.isEmpty) {
      _showMessage('Could not identify the lift incident to delete.');
      return;
    }
    setState(() => _saving = true);
    try {
      // One database transaction deletes ALL progress events, then the
      // original lift incident. The RPC checks report and property access.
      final deleted = await _supabase.rpc(
        'delete_lift_incident_with_progress',
        params: {
          'p_incident_id': incidentId,
          'p_selected_report_id': _reportId,
        },
      );
      if (deleted != true) {
        throw Exception('The database did not confirm deletion.');
      }
      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;
      if (_error != null) {
        _showMessage('Incident deleted, but refresh failed: $_error');
      } else {
        _showMessage('Lift incident deleted successfully.');
      }
    } catch (error) {
      if (mounted) _showMessage('Could not delete lift incident: $error');
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
        title: const Text('Lift Incidents'),
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
        label: const Text('Add Lift Incident'),
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
              const flutter_widgets.SizedBox(height: 12),
              const Text('Unable to load Lift Incidents records.'),
              const flutter_widgets.SizedBox(height: 8),
              SelectableText(
                _error!,
                style: const TextStyle(color: AppColors.grey),
              ),
              const flutter_widgets.SizedBox(height: 16),
              FilledButton(
                onPressed: _loadRecords,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final thisMonth =
        _thisMonthRecords
            .where((row) => _matchesStatus(row) && _matchesSearch(row))
            .toList()
          ..sort(_compareNewest);
    final historical = _historicalRecords.where(_matchesSearch).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _buildHeader(),
        const flutter_widgets.SizedBox(height: 20),
        _buildSummary(),
        const flutter_widgets.SizedBox(height: 22),
        Column(
          key: _recordsAnchorKey,
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText:
                    'Search tower, lift, category or description...',
                prefixIcon: const Icon(Icons.search, color: AppColors.grey),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _searchController.clear,
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear search',
                      ),
              ),
            ),
            const flutter_widgets.SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 7,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Showing:',
                    style: TextStyle(color: AppColors.grey, fontSize: 12),
                  ),
                  if (_selectedStatusFilters.isEmpty)
                    const Text(
                      'All statuses',
                      style: TextStyle(color: AppColors.grey, fontSize: 12),
                    ),
                  for (final filter in _statuses.where(
                    (item) => _selectedStatusFilters.contains(item),
                  ))
                    Chip(
                      label: Text(filter),
                      onDeleted: () => _selectStatusFilter(filter),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (_selectedStatusFilters.contains('Cancelled / On Hold'))
                    Chip(
                      label: const Text('Cancelled / On Hold'),
                      onDeleted: () =>
                          _selectStatusFilter('Cancelled / On Hold'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (_selectedStatusFilters.contains('Open Incidents'))
                    Chip(
                      label: const Text('Open Incidents'),
                      onDeleted: () => _selectStatusFilter('Open Incidents'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (_selectedStatusFilters.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _selectStatusFilter(null),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Clear filter'),
                    ),
                ],
              ),
            ),
          ],
        ),
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
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
            ),
            Text(
              '$total records',
              style: const TextStyle(color: AppColors.grey),
            ),
          ],
        ),
        const flutter_widgets.SizedBox(height: 12),
        if (rows.isEmpty)
          _emptySection('No matching lift incidents in this month.')
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
              '${history.length} records',
              style: const TextStyle(color: AppColors.grey),
            ),
          ],
        ),
        const flutter_widgets.SizedBox(height: 12),
        if (months.isEmpty)
          _emptySection('No previous completed lift incidents.')
        else
          for (final month in months) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ExpansionTile(
                key: PageStorageKey('incidents-history-$_reportId-$month'),
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
                '${grouped[month]!.length} history records',
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
                    ),
                ],
              ),
            ),
          ],
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
            'Lift Incidents',
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
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: _summaryCard(
            'Total Lift Incidents',
            _thisMonthRecords.length,
            Icons.assignment_outlined,
            AppColors.red,
            onTap: () => _selectStatusFilter(null),
          ),
        ),
        const flutter_widgets.SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'Completed',
                _countStatus('Completed'),
                Icons.check_circle_outline,
                const Color(0xFF22683D),
                onTap: () => _selectStatusFilter('Completed'),
              ),
            ),
            const flutter_widgets.SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'In Progress',
                _countStatus('In Progress'),
                Icons.autorenew,
                AppColors.red,
                onTap: () => _selectStatusFilter('In Progress'),
              ),
            ),
          ],
        ),
        const flutter_widgets.SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'Pending',
                _countStatus('Pending'),
                Icons.schedule,
                const Color(0xFF966400),
                onTap: () => _selectStatusFilter('Pending'),
              ),
            ),
            const flutter_widgets.SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'Cancelled / On Hold',
                _cancelledOrOnHold,
                Icons.pause_circle_outline,
                AppColors.grey,
                onTap: () => _selectStatusFilter('Cancelled / On Hold'),
              ),
            ),
          ],
        ),
      ],
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: accent, size: 22),
            ),
            const flutter_widgets.SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const flutter_widgets.SizedBox(height: 5),
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

  Widget _buildRecordCard(
    Map<String, dynamic> record, {
    required int displayNumber,
  }) {
    final isCarried = _isCarriedForward(record);
    final status = record['status']?.toString();
    final accent = _statusColor(status);
    final tower = _displayValue(record['tower'], 'Tower not specified');
    final lift = _displayValue(record['lift_no'], 'Lift not specified');
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
                        '$tower • $lift',
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const flutter_widgets.SizedBox(height: 5),
                      Text(
                        'Incident Date: ${_displayDate(record['incident_date'])}',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                      if (isCarried) ...[
                        const flutter_widgets.SizedBox(height: 4),
                        const Text(
                          'Carried Forward',
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          status,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (_hasText(record['incident_category'])) ...[
              const flutter_widgets.SizedBox(height: 14),
              _detail('Category', record['incident_category']),
            ],
            const flutter_widgets.SizedBox(height: 10),
            _detail(
              'Mantrap',
              record['mantrap'] == true
                  ? 'Yes'
                  : record['mantrap'] == false
                      ? 'No'
                      : 'Not set',
            ),
            if (_hasText(record['description'])) ...[
              const flutter_widgets.SizedBox(height: 10),
              _detail('Description', record['description']),
            ],
            if (record['turnaround_hours'] != null) ...[
              const flutter_widgets.SizedBox(height: 10),
              _detail('Turnaround (Hours)', record['turnaround_hours']),
            ],
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
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : () => _openForm(record: record),
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