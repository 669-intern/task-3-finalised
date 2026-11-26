import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

// Renovation Works - current report and earlier months for the same site.
// Requires the two additive columns in renovation_works_sql.sql.
class RenovationWorks extends StatefulWidget {
  final Map<String, dynamic> report;

  const RenovationWorks({super.key, required this.report});

  @override
  State<RenovationWorks> createState() => _RenovationWorksState();
}

class _RenovationWorksState extends State<RenovationWorks> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  static const List<String> _statuses = [
    'In Progress',
    'Completed',
    'Pending',
    'On Hold',
    'Cancelled',
  ];

  List<_RenovationRecord> _allRecords = [];
  final Set<String> _filterStatuses = <String>{};
  DateTime? _reportMonth;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String get _reportId => widget.report['id'].toString();
  String? get _siteId => widget.report['site_id']?.toString();

  // Keep finalized reports read-only; changes require an editable report.
  bool get _readOnly =>
      widget.report['status']?.toString().toLowerCase() != 'draft';

  List<_RenovationRecord> get _records =>
      _allRecords.where(_isActiveInMonth).toList()..sort(_sortRenovations);

  List<_RenovationRecord> get _historicalRecords =>
      _allRecords
          .where((r) => !_isActiveInMonth(r) && _startedByMonth(r))
          .toList()
        ..sort(_sortRenovations);

  List<_RenovationRecord> get _visibleCurrent =>
      _records.where(_passesFilters).toList();

  List<_RenovationRecord> get _visibleHistory =>
      _historicalRecords.where(_passesFilters).toList();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    if (widget.report['id'] == null) {
      _loading = false;
      _error = 'The monthly report ID is missing.';
    } else {
      _loadRecords();
    }
  }

  @override
  void didUpdateWidget(covariant RenovationWorks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['id'] != widget.report['id'] ||
        oldWidget.report['report_month'] != widget.report['report_month'] ||
        oldWidget.report['site_id'] != widget.report['site_id']) {
      _filterStatuses.clear();
      _searchController.clear();
      _loadRecords();
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  static int _sortRenovations(_RenovationRecord a, _RenovationRecord b) {
    final ad = a.startDate ?? a.openedMonth ?? DateTime(2000);
    final bd = b.startDate ?? b.openedMonth ?? DateTime(2000);
    final order = bd.compareTo(ad);
    return order != 0 ? order : b.lineNo.compareTo(a.lineNo);
  }

  bool _startedByMonth(_RenovationRecord r) {
    final month = _reportMonth;
    if (month == null) return r.sourceReportId == _reportId;
    final start = r.startDate ?? r.openedMonth;
    return start != null &&
        !_firstOfMonth(start).isAfter(_firstOfMonth(month));
  }

  // Progress Date is the only date used to determine status and archival.
  // Future progress updates must not alter the view of an earlier report.
  Map<String, dynamic>? _progressAsOfMonth(_RenovationRecord r) {
    final history = _sortedProgress(r.progressHistory);
    final month = _reportMonth;
    if (month == null) return history.isEmpty ? null : history.last;
    final nextMonth = DateTime(month.year, month.month + 1, 1);
    for (final event in history.reversed) {
      final date = _parseDate(event['progress_date']);
      if (date != null && date.isBefore(nextMonth)) return event;
    }
    return null;
  }

  // The effective status is the most recent progress update up to the
  // selected month. Pre-existing records without progress dates retain a
  // read-only fallback to the former database completion date.
  String _effectiveStatus(_RenovationRecord r) {
    final latest = _progressAsOfMonth(r);
    if (latest != null) {
      return latest['status']?.toString() ?? r.renovationStatus;
    }

    final history = _sortedProgress(r.progressHistory);
    if (history.isNotEmpty) {
      final first = history.first;
      final previous = first['previous_status']?.toString();
      // A creation event marked Completed is not completed before its date.
      if (first['status'] == 'Completed' && previous == 'Completed') {
        return 'In Progress';
      }
      return previous ?? (first['status']?.toString() == 'Completed'
          ? 'In Progress'
          : first['status']?.toString() ?? r.renovationStatus);
    }

    final month = _reportMonth;
    final legacyDate = r.legacyCompletedDate;
    if (r.renovationStatus == 'Completed' &&
        month != null &&
        legacyDate != null &&
        _firstOfMonth(legacyDate).isAfter(month)) {
      return 'In Progress';
    }
    return r.renovationStatus;
  }

  // A Completed progress event dated in October remains in This Month for
  // October and moves to History in November. A later re-opening event puts
  // the renovation back in This Month from that event's month onwards.
  DateTime? _completionProgressDate(_RenovationRecord r) {
    if (_effectiveStatus(r) != 'Completed') return null;
    final latest = _progressAsOfMonth(r);
    if (latest != null) return _parseDate(latest['progress_date']);

    // Legacy fallback only: no earlier dated progress event is available.
    final legacyDate = r.legacyCompletedDate;
    final month = _reportMonth;
    return legacyDate != null &&
            (month == null || !_firstOfMonth(legacyDate).isAfter(month))
        ? legacyDate
        : null;
  }

  bool _isActiveInMonth(_RenovationRecord r) {
    if (!_startedByMonth(r)) return false;
    final month = _reportMonth;
    if (month == null) return r.sourceReportId == _reportId;
    final completed = _completionProgressDate(r);
    return completed == null || !_firstOfMonth(completed).isBefore(month);
  }

  bool _passesFilters(_RenovationRecord record) {
    final status = _effectiveStatus(record);
    if (_filterStatuses.isNotEmpty && !_filterStatuses.contains(status)) {
      return false;
    }
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;

    final searchable = <String>[
      record.unit,
      record.renovationType,
      status,
      record.refundStatus,
      record.duration,
      _displayDate(record.startDate),
      for (final item in record.progressHistory)
        _displayDate(_parseDate(item['progress_date'])),
      _displayDate(record.depositPaidDate),
      record.depositAmount.toStringAsFixed(2),
      for (final item in record.progressHistory) ...[
        item['remarks']?.toString() ?? '',
        item['action_taken']?.toString() ?? '',
      ],
    ].join(' ').toLowerCase();
    return searchable.contains(query);
  }

  void _toggleStatus(String status) {
    setState(() {
      if (!_filterStatuses.add(status)) _filterStatuses.remove(status);
    });
  }

  Future<void> _loadRecords() async {
    if (!mounted || widget.report['id'] == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      String? siteId = _siteId;
      if (siteId == null || siteId.isEmpty) {
        final row = await _supabase
            .from('monthly_reports')
            .select('site_id,report_month')
            .eq('id', _reportId)
            .single();
        siteId = row['site_id']?.toString();
      }
      if (siteId == null || siteId.isEmpty) {
        throw StateError('Selected property is missing.');
      }

      final response = await _supabase
          .from('renovation_works')
          .select()
          .eq('site_id', siteId)
          .order('line_no', ascending: true);

      final records = (response as List)
          .map((row) =>
              _RenovationRecord.fromMap(Map<String, dynamic>.from(row)))
          .toList();

      DateTime? month = _parseDate(widget.report['report_month']);
      if (month == null) {
        final row = await _supabase
            .from('monthly_reports')
            .select('report_month')
            .eq('id', _reportId)
            .single();
        month = _parseDate(row['report_month']);
      }
      if (month == null) throw StateError('Selected report month is missing.');

      if (!mounted) return;
      setState(() {
        _allRecords = records;
        _reportMonth = _firstOfMonth(month!);
        _loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Renovation Works load error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int _nextLineNo() {
    final own =
        _allRecords.where((r) => r.sourceReportId == _reportId).toList();
    if (own.isEmpty) return 1;
    return own.map((r) => r.lineNo).reduce((a, b) => a > b ? a : b) + 1;
  }

  Future<void> _showRecordDialog() async {
    if (_saving || !mounted || _readOnly || _reportMonth == null) return;
    final result = await showDialog<_RenovationRecord>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RenovationAddDialog(
        reportMonth: _reportMonth!,
        nextLineNo: _nextLineNo(),
      ),
    );
    if (!mounted || result == null) return;
    await _saveRecord(result);
  }

  Future<void> _saveRecord(_RenovationRecord record) async {
    if (_saving || !mounted || _readOnly) return;
    if (record.lineNo < 1 || record.lineNo > 32767) {
      _showMessage('The maximum supported record number has been reached.');
      return;
    }
    setState(() => _saving = true);
    try {
      final start = record.startDate;
      final month = _reportMonth;
      if (start == null || month == null) {
        throw StateError('Starting date and report month are required.');
      }
      if (_firstOfMonth(start).isAfter(month)) {
        throw StateError('Starting Date cannot be after the report month.');
      }

      String? siteId = _siteId;
      if (siteId == null || siteId.isEmpty) {
        final reportRow = await _supabase
            .from('monthly_reports')
            .select('site_id')
            .eq('id', _reportId)
            .single();
        siteId = reportRow['site_id']?.toString();
      }
      if (siteId == null || siteId.isEmpty) {
        throw StateError('Selected monthly report has no site_id.');
      }

      await _supabase.from('renovation_works').insert({
        'report_id': _reportId,
        'site_id': siteId,
        'line_no': record.lineNo,
        'opened_month': _dbDate(_firstOfMonth(start)),
        'unit': record.unit.trim(),
        'renovation_type': record.renovationType.trim(),
        'duration': record.duration.trim(),
        'deposit_amount': record.depositAmount,
        'deposit_paid_date': _dbDate(record.depositPaidDate),
        'renovation_status': record.renovationStatus,
        'refund_status': record.refundStatus,
        'start_date': _dbDate(start),
        // Retain the legacy database column for existing PDF/SQL consumers;
        // its value is derived solely from the latest Completed progress event.
        'completed_date': record.renovationStatus == 'Completed' &&
                record.progressHistory.isNotEmpty
            ? record.progressHistory.last['progress_date']
            : null,
        'progress_history': record.progressHistory,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).select('id').single();

      await _loadRecords();
      if (mounted) _showMessage('Renovation record saved successfully.');
    } catch (e) {
      if (mounted) _showMessage('Failed to save renovation record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Edit an active (including carried-forward) renovation. The full record
  // details remain editable, but this month's status is a dated progress event,
  // so edits cannot overwrite another month's status history by accident.
  Future<void> _editCurrentRecord(_RenovationRecord record) async {
    if (_saving || !mounted || _readOnly || _loading || _reportMonth == null) {
      return;
    }
    final selectedMonth = _reportMonth!;
    final edited = await showDialog<_RenovationHistoryEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RenovationHistoryEditDialog(
        record: record,
        reportMonth: selectedMonth,
        selectedReportId: _reportId,
        initialStatus: _effectiveStatus(record),
      ),
    );
    if (edited == null || !mounted || _saving || _readOnly) return;
    if (record.id == null || record.id!.isEmpty) {
      _showMessage(
        'Cannot edit: this renovation has no database ID. '
        'Run the supplied SQL preflight to check the id column.',
      );
      return;
    }

    final progressDate = edited.progressDate;
    if (progressDate == null || !_isInMonth(progressDate, selectedMonth)) {
      _showMessage('Progress Date must fall within the selected report month.');
      return;
    }
    if (progressDate.isBefore(edited.startDate)) {
      _showMessage('Progress Date cannot be before Starting Date.');
      return;
    }

    setState(() => _saving = true);
    try {
      final history = _sortedProgress(record.progressHistory);
      // Replace the latest event entered for this reporting month, if present;
      // never replace progress from a different month. Original creation
      // events can have no report_id; these are left intact.
      var editIndex = -1;
      for (var i = 0; i < history.length; i++) {
        final date = _parseDate(history[i]['progress_date']);
        if (date != null &&
            _isInMonth(date, selectedMonth) &&
            history[i]['report_id']?.toString() == _reportId) {
          editIndex = i;
        }
      }
      final previousStatus = editIndex >= 0
          ? (history[editIndex]['previous_status']?.toString() ??
              _effectiveStatus(record))
          : _effectiveStatus(record);
      final event = <String, dynamic>{
        'progress_date': _dbDate(progressDate),
        'status': edited.status,
        'previous_status': previousStatus,
        'start_date': _dbDate(edited.startDate),
        'remarks': edited.remarks.trim(),
        'action_taken': edited.actionTaken.trim(),
        'saved_at': DateTime.now().toUtc().toIso8601String(),
        'report_id': _reportId,
      };
      if (editIndex >= 0) {
        history[editIndex] = event;
      } else {
        history.add(event);
      }
      final ordered = _sortedProgress(history);
      final latest = ordered.last;
      final latestStatus = latest['status']?.toString() ?? edited.status;
      final latestDate = _parseDate(latest['progress_date']);
      // Stored for compatibility only; Progress Date is authoritative.
      final completed = latestStatus == 'Completed' ? latestDate : null;

      final updated = await _supabase
          .from('renovation_works')
          .update({
            'unit': edited.unit.trim(),
            'renovation_type': edited.renovationType.trim(),
            'opened_month': _dbDate(_firstOfMonth(edited.startDate)),
            'start_date': _dbDate(edited.startDate),
            'renovation_status': latestStatus,
            'completed_date': _dbDate(completed),
            'duration': edited.duration.trim(),
            'deposit_amount': edited.depositAmount,
            'deposit_paid_date': _dbDate(edited.depositPaidDate),
            'refund_status': edited.refundStatus,
            'progress_history': ordered,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', record.id!)
          .select('id');
      if (updated.length != 1) {
        throw StateError(
          'No record updated. Check property access and UPDATE/SELECT policies.',
        );
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Renovation record updated successfully.');
    } catch (e) {
      if (mounted) _showMessage('Unable to edit renovation record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // History actions edit the original renovation row without creating a
  // new progress event for the currently selected reporting month.
  Future<void> _editHistoricalRecord(_RenovationRecord record) async {
    if (_saving || !mounted || _readOnly || _loading) return;
    final edited = await showDialog<_RenovationHistoryEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RenovationHistoryEditDialog(
        record: record,
        historicalViewMonth: _reportMonth,
      ),
    );
    if (edited == null || !mounted || _saving || _readOnly) return;
    if (record.id == null || record.id!.isEmpty) {
      _showMessage(
        'Cannot edit: this renovation has no database ID. '
        'Run the supplied SQL preflight to check the id column.',
      );
      return;
    }

    final progressDate = edited.progressDate;
    if (progressDate == null || progressDate.isBefore(edited.startDate)) {
      _showMessage('Progress Date must be on or after Starting Date.');
      return;
    }

    setState(() => _saving = true);
    try {
      // Correct the most recent event visible in this report, not a later
      // event from a future month. Do not add a new event in this report month.
      final progress = _sortedProgress(record.progressHistory);
      final month = _reportMonth;
      var editIndex = -1;
      for (var i = 0; i < progress.length; i++) {
        final date = _parseDate(progress[i]['progress_date']);
        if (date != null &&
          (month == null ||
              date.isBefore(DateTime(month.year, month.month + 1, 1)))) {
          editIndex = i;
        }
      }
      if (editIndex >= 0) {
        progress[editIndex]['status'] = edited.status;
        progress[editIndex]['start_date'] = _dbDate(edited.startDate);
        progress[editIndex]['progress_date'] = _dbDate(progressDate);
      } else {
        // Convert a legacy row with no dated history to the new model.
        progress.add({
          'progress_date': _dbDate(progressDate),
          'status': edited.status,
          'previous_status': record.renovationStatus,
          'start_date': _dbDate(edited.startDate),
          'remarks': '',
          'action_taken': '',
          'saved_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final ordered = _sortedProgress(progress);
      final latest = ordered.last;
      final latestStatus = latest['status']?.toString() ?? edited.status;
      final latestProgressDate = _parseDate(latest['progress_date']);

      final updated = await _supabase
          .from('renovation_works')
          .update({
            'unit': edited.unit.trim(),
            'renovation_type': edited.renovationType.trim(),
            'opened_month': _dbDate(_firstOfMonth(edited.startDate)),
            'start_date': _dbDate(edited.startDate),
            'renovation_status': latestStatus,
            // Compatibility column; never an independently selected date.
            'completed_date': latestStatus == 'Completed'
                ? _dbDate(latestProgressDate)
                : null,
            'duration': edited.duration.trim(),
            'deposit_amount': edited.depositAmount,
            'deposit_paid_date': _dbDate(edited.depositPaidDate),
            'refund_status': edited.refundStatus,
            'progress_history': ordered,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', record.id!)
          .select('id');
      if (updated.length != 1) {
        throw StateError('No record updated. Check permissions or report lock.');
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Renovation record updated successfully.');
    } catch (e) {
      if (mounted) _showMessage('Unable to edit renovation record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Permanently remove one exact database row (including its JSON progress_history).
  // This uses the immutable primary key, never report_id + line_no, because
  // older or carried-forward rows can have null/changed report sequence fields.
  // No confirmation dialog, per the requested workflow.
  Future<void> _deleteRecord(_RenovationRecord record) async {
    if (_saving || !mounted || _readOnly || _loading) return;

    final recordId = record.id?.trim();
    if (recordId == null || recordId.isEmpty) {
      _showMessage(
        'Cannot delete this record because its database ID is missing. '
        'Check renovation_works.id using the SQL preflight.',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      // First verify the identity and property of the actual saved row.
      // A read that returns zero must not be mistaken for a successful delete.
      final existing = await _supabase
          .from('renovation_works')
          .select('id,site_id,report_id')
          .eq('id', recordId)
          .maybeSingle();
      if (existing == null) {
        throw StateError(
          'Record is no longer visible. Refresh the page, then retry. '
          'If it still appears, check the SELECT RLS policy.',
        );
      }

      final actualSiteId = existing['site_id']?.toString();
      String? selectedSiteId = _siteId;
      if (selectedSiteId == null || selectedSiteId.isEmpty) {
        final selectedReport = await _supabase
            .from('monthly_reports')
            .select('site_id')
            .eq('id', _reportId)
            .single();
        selectedSiteId = selectedReport['site_id']?.toString();
      }
      if (actualSiteId == null || actualSiteId.isEmpty ||
          selectedSiteId == null || selectedSiteId.isEmpty ||
          actualSiteId != selectedSiteId) {
        throw StateError(
          'The renovation belongs to a different property. Nothing was deleted.',
        );
      }

      // Use the ID (not the visual card number/line_no). The extra site filter
      // is defence in depth; the server-side RLS DELETE policy is authoritative.
      await _supabase
          .from('renovation_works')
          .delete()
          .eq('id', recordId)
          .eq('site_id', selectedSiteId)
          .select('id');

      // PostgREST may return an empty DELETE result for 0 matched / RLS rows.
      // Re-read the same ID to confirm the row truly disappeared.
      final remaining = await _supabase
          .from('renovation_works')
          .select('id')
          .eq('id', recordId)
          .maybeSingle();
      if (remaining != null) {
        throw StateError(
          'Deletion was denied by the database. The row still exists. '
          'Install the supplied renovation DELETE policy and confirm '
          'that your account can edit a draft report for this property.',
        );
      }

      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;
      if (_error != null) {
        _showMessage('The record was deleted, but refresh failed: $_error');
      } else {
        _showMessage('Renovation record deleted successfully.');
      }
    } catch (e) {
      if (mounted) _showMessage('Unable to delete renovation record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: AppColors.charcoal,
        behavior: SnackBarBehavior.floating,
      ));
  }

  String _money(double amount) => amount.toStringAsFixed(2);

  Color _statusColor(String status) {
    switch (status) {
      case 'Completed':
      case 'Refunded':
        return const Color(0xFF22683D);
      case 'In Progress':
      case 'Pending':
        return const Color(0xFF9A6700);
      case 'Cancelled':
      case 'Forfeited':
        return AppColors.red;
      case 'On Hold':
        return const Color(0xFF596579);
      default:
        return AppColors.grey;
    }
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    bool selected = false,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.border,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.025),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 25),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.grey,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 6),
                Text(value,
                    style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String label, String status) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Text(
        '$label: $status',
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(
                    color: AppColors.grey,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '—' : value,
                style: const TextStyle(
                    color: AppColors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(
    _RenovationRecord record,
    int number, {
    bool historical = false,
  }) {
    final canModify = !_readOnly && !_saving && !_loading;
    final opened = record.startDate ?? record.openedMonth;
    final statusForMonth = _effectiveStatus(record);
    final progressForMonth = _progressAsOfMonth(record);
    final progressDateForMonth = progressForMonth == null
        ? null : _parseDate(progressForMonth['progress_date']);
    final carriedForward = !historical &&
        record.openedMonth != null &&
        _reportMonth != null &&
        _firstOfMonth(record.openedMonth!).isBefore(_reportMonth!);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
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
                child: Text('$number',
                    style: const TextStyle(
                        color: AppColors.red,
                        fontWeight: FontWeight.bold,
                        fontSize: 17)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(record.unit,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(record.renovationType,
                        style: const TextStyle(color: AppColors.grey)),
                    if (carriedForward)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('Carried forward',
                            style: TextStyle(color: AppColors.red, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _statusChip('Renovation', statusForMonth),
                      const SizedBox(height: 8),
                      _statusChip('Refund', record.refundStatus),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _detailRow('Starting Date', _displayDate(opened)),
          if (progressDateForMonth != null)
            _detailRow('Progress Date', _displayDate(progressDateForMonth)),
          _detailRow('Duration', record.duration),
          _detailRow('Deposit', 'RM ${_money(record.depositAmount)}'),
          _detailRow('Deposit Paid', _displayDate(record.depositPaidDate)),
          const SizedBox(height: 12),
          const Divider(color: AppColors.border),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: canModify
                      ? () => historical
                          ? _editHistoricalRecord(record)
                          : _editCurrentRecord(record)
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Edit'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
                TextButton.icon(
                  onPressed: canModify ? () => _deleteRecord(record) : null,
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

  Widget _sectionTitle(String label, String detail, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(detail,
                        style: const TextStyle(
                            color: AppColors.grey, fontSize: 12)),
                  ],
                ],
              ),
            ),
            Text('$count records',
                style: const TextStyle(color: AppColors.grey, fontSize: 12)),
          ],
        ),
      );

  // Only month cards expand; the History heading stays outside them.
  Widget _buildHistoryDropdown(List<_RenovationRecord> history) {
    final grouped = <DateTime, List<_RenovationRecord>>{};
    for (final record in history) {
      final date = _completionProgressDate(record) ??
          record.startDate ?? record.openedMonth;
      if (date != null) {
        final month = _firstOfMonth(date);
        grouped.putIfAbsent(month, () => <_RenovationRecord>[]).add(record);
      }
    }
    final months = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'History',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${history.length} records',
                style: const TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
        if (history.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No historical records match.',
              style: TextStyle(color: AppColors.grey),
            ),
          )
        else
          for (final month in months)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: ExpansionTile(
                  key: PageStorageKey(
                    'renovation-history-$_reportId-${month.year}-${month.month}',
                  ),
                  initiallyExpanded: false,
                  backgroundColor: AppColors.white,
                  collapsedBackgroundColor: AppColors.white,
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  title: Text(
                    _monthName(month),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${grouped[month]!.length} renovation record(s)',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.grey,
                    ),
                  ),
                  children: [
                    for (var i = 0; i < grouped[month]!.length; i++)
                      _buildRecordCard(
                        grouped[month]![i],
                        i + 1,
                        historical: true,
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

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
          const Text('PROPERTY MANAGEMENT',
              style: TextStyle(
                  color: AppColors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5)),
          const SizedBox(height: 8),
          const Text('Renovation Works',
              style: TextStyle(
                  color: AppColors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('${_monthName(_reportMonth)} • Report ID: $_reportId',
              style: const TextStyle(
                  color: Color(0xFFE0E0E0), fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() => Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: AppColors.white,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            const Icon(Icons.construction_outlined,
                size: 42, color: AppColors.red),
            const SizedBox(height: 12),
            Text(
              _searchController.text.trim().isNotEmpty ||
                      _filterStatuses.isNotEmpty
                  ? 'No renovations match the search or filters'
                  : 'No renovation records for this month',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Add a record or adjust the filters.',
                style: TextStyle(color: AppColors.grey)),
          ],
        ),
      );

  Widget _buildErrorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.red, size: 44),
              const SizedBox(height: 12),
              const Text('Unable to load renovation works.',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SelectableText(_error ?? 'An unexpected error occurred.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.grey)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadRecords,
                style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );

  Widget _buildSearchAndFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
            hintText: 'Search unit, renovation type, status, details...',
            filled: true,
            fillColor: AppColors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 19),
                    onPressed: _searchController.clear,
                  ),
          ),
        ),
        if (_filterStatuses.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Showing:',
                  style: TextStyle(fontSize: 12, color: AppColors.grey)),
              for (final status in _statuses.where(_filterStatuses.contains))
                InkWell(
                  onTap: () => _toggleStatus(status),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFFD8B5B0),
                      ),
                    ),
                    child: Text(
                      status, style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF665552),
                        ),
                        ),
                  ),
                ),
              TextButton.icon(
                onPressed: () => setState(_filterStatuses.clear),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                icon: const Icon(Icons.close, size: 15),
                label: const Text('Clear filter'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSummary(List<_RenovationRecord> current) {
    final month = _reportMonth;
    final totalDeposits = month == null
        ? 0.0
        : _allRecords.where((r) {
            final paid = r.depositPaidDate;
            return paid != null && _isInMonth(paid, month);
          }).fold<double>(0, (sum, r) => sum + r.depositAmount);

    return Column(
      children: [
        // Full-width total card: tap to show all this month's renovations.
        SizedBox(
          width: double.infinity,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              _searchController.clear();
              setState(() => _filterStatuses.clear());
            },
            child: _summaryCard(
              title: 'Total Renovations',
              value: '${current.length}',
              icon: Icons.construction_outlined,
              color: AppColors.red,
            ),
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, constraints) {
          final columns = constraints.maxWidth >= 600 ? 2 : 1;
          final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
          final items = <Widget>[
            for (final status in _statuses)
              SizedBox(
                width: width,
                child: InkWell(
                  onTap: () => _toggleStatus(status),
                  borderRadius: BorderRadius.circular(14),
                  child: _summaryCard(
                    title: status,
                    value:
                        '${current.where((r) => _effectiveStatus(r) == status).length}',
                    icon: status == 'Completed'
                        ? Icons.check_circle_outline
                        : status == 'Cancelled'
                            ? Icons.event_busy_outlined
                            : status == 'On Hold'
                                ? Icons.pause_circle_outline
                                : status == 'Pending'
                                    ? Icons.pending_actions_outlined
                                    : Icons.construction_outlined,
                    color: _statusColor(status),
                    selected: _filterStatuses.contains(status),
                  ),
                ),
              ),
            SizedBox(
              width: width,
              child: _summaryCard(
                title: 'Total Deposits (This Month)',
                value: 'RM ${_money(totalDeposits)}',
                icon: Icons.account_balance_wallet_outlined,
                color: AppColors.grey,
              ),
            ),
          ];
          return Wrap(spacing: 12, runSpacing: 12, children: items);
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _records;
    final visible = _visibleCurrent;
    final history = _visibleHistory;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Renovation Works'),
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
        ],
      ),
      floatingActionButton: _readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _loading || _saving ? null : _showRecordDialog,
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Record'),
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.red))
              : _error != null
                  ? _buildErrorState()
                  : RefreshIndicator(
                      onRefresh: _loadRecords,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 18),
                          _buildSummary(current),
                          const SizedBox(height: 22),
                          _buildSearchAndFilters(),
                          const SizedBox(height: 10),
                          _sectionTitle(
                            'This Month',
                            '',
                            visible.length,
                          ),
                          if (visible.isEmpty)
                            _buildEmptyState()
                          else
                            for (var i = 0; i < visible.length; i++)
                              _buildRecordCard(visible[i], i + 1),
                          const SizedBox(height: 18),
                          _buildHistoryDropdown(history),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}

class _RenovationRecord {
  // Immutable database primary key; unlike line_no this never changes with sorting.
  final String? id;
  final int lineNo;
  final String? sourceReportId;
  final DateTime? openedMonth;
  final String unit;
  final String renovationType;
  final String duration;
  final double depositAmount;
  final DateTime? depositPaidDate;
  final String renovationStatus;
  final String refundStatus;
  final DateTime? startDate;
  // Pre-existing database value; only used when dated progress is missing.
  final DateTime? legacyCompletedDate;
  final List<Map<String, dynamic>> progressHistory;

  const _RenovationRecord({
    required this.id,
    required this.lineNo,
    required this.sourceReportId,
    required this.openedMonth,
    required this.unit,
    required this.renovationType,
    required this.duration,
    required this.depositAmount,
    required this.depositPaidDate,
    required this.renovationStatus,
    required this.refundStatus,
    required this.startDate,
    required this.legacyCompletedDate,
    required this.progressHistory,
  });

  factory _RenovationRecord.fromMap(Map<String, dynamic> map) {
    dynamic historyValue = map['progress_history'];
    if (historyValue is String) {
      try {
        historyValue = jsonDecode(historyValue);
      } catch (_) {
        historyValue = [];
      }
    }
    final history = <Map<String, dynamic>>[];
    if (historyValue is List) {
      for (final item in historyValue) {
        if (item is Map) {
          history.add(Map<String, dynamic>.from(item));
        }
      }
    }

    return _RenovationRecord(
      id: map['id']?.toString(),
      lineNo: (map['line_no'] as num?)?.toInt() ??
          int.tryParse(map['line_no']?.toString() ?? '') ??
          0,
      sourceReportId: map['report_id']?.toString(),
      openedMonth: _parseDate(map['opened_month']),
      unit: map['unit']?.toString() ?? '',
      renovationType: map['renovation_type']?.toString() ?? '',
      duration: map['duration']?.toString() ?? '',
      depositAmount: (map['deposit_amount'] as num?)?.toDouble() ??
          double.tryParse(map['deposit_amount']?.toString() ?? '') ??
          0,
      depositPaidDate: _parseDate(map['deposit_paid_date']),
      renovationStatus: map['renovation_status']?.toString() ?? 'Pending',
      refundStatus: map['refund_status']?.toString() ?? 'N/A',
      startDate: _parseDate(map['start_date']),
      legacyCompletedDate: _parseDate(map['completed_date']),
      progressHistory: history,
    );
  }
}

// Editing a historical renovation corrects its existing data without adding a
// progress event to the month currently being viewed.
class _RenovationHistoryEditResult {
  final String unit;
  final String renovationType;
  final String status;
  final String refundStatus;
  final DateTime startDate;
  final String duration;
  final double depositAmount;
  final DateTime? depositPaidDate;
  final DateTime? progressDate;
  final String remarks;
  final String actionTaken;

  const _RenovationHistoryEditResult({
    required this.unit,
    required this.renovationType,
    required this.status,
    required this.refundStatus,
    required this.startDate,
    required this.duration,
    required this.depositAmount,
    required this.depositPaidDate,
    this.progressDate,
    this.remarks = '',
    this.actionTaken = '',
  });
}

class _RenovationHistoryEditDialog extends StatefulWidget {
  final _RenovationRecord record;
  final DateTime? reportMonth;
  final String? selectedReportId;
  final String? initialStatus;
  final DateTime? historicalViewMonth;

  const _RenovationHistoryEditDialog({
    required this.record,
    this.reportMonth,
    this.selectedReportId,
    this.initialStatus,
    this.historicalViewMonth,
  });

  @override
  State<_RenovationHistoryEditDialog> createState() =>
      _RenovationHistoryEditDialogState();
}

class _RenovationHistoryEditDialogState
    extends State<_RenovationHistoryEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _unitController;
  late final TextEditingController _typeController;
  late final TextEditingController _durationController;
  late final TextEditingController _depositController;
  late final TextEditingController _remarksController;
  late final TextEditingController _actionController;
  DateTime? _progressDate;
  late String _status;
  late String _refundStatus;
  DateTime? _startDate;
  DateTime? _depositPaidDate;

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _unitController = TextEditingController(text: record.unit);
    _typeController = TextEditingController(text: record.renovationType);
    _durationController = TextEditingController(text: record.duration);
    _depositController = TextEditingController(
        text: record.depositAmount.toStringAsFixed(2));
    _status = widget.initialStatus ?? record.renovationStatus;
    _refundStatus = record.refundStatus;
    _startDate = record.startDate ?? record.openedMonth;
    _depositPaidDate = record.depositPaidDate;

    final month = widget.reportMonth;
    final thisMonthEvents = month == null
        ? <Map<String, dynamic>>[]
        : _sortedProgress(record.progressHistory).where((event) {
            final date = _parseDate(event['progress_date']);
            return date != null &&
                _isInMonth(date, month) &&
                event['report_id']?.toString() == widget.selectedReportId;
          }).toList();
    Map<String, dynamic>? last =
        thisMonthEvents.isEmpty ? null : thisMonthEvents.last;
    final today = DateUtils.dateOnly(DateTime.now());
    if (month != null) {
      final start = _firstOfMonth(month);
      final monthEnd = DateTime(month.year, month.month + 1, 0);
      final defaultDate = _isInMonth(today, month) ? today : start;
      final opened = _startDate ?? start;
      final validDate = opened.isAfter(defaultDate) ? opened : defaultDate;
      _progressDate = last == null
          ? (validDate.isAfter(monthEnd) ? monthEnd : validDate)
          : (_parseDate(last['progress_date']) ?? defaultDate);
    } else {
      final allEvents = _sortedProgress(record.progressHistory);
      final viewMonth = widget.historicalViewMonth;
      final eligible = allEvents.where((event) {
        final date = _parseDate(event['progress_date']);
        return date != null &&
            (viewMonth == null ||
                date.isBefore(DateTime(viewMonth.year, viewMonth.month + 1, 1)));
      }).toList();
      last = eligible.isEmpty ? null : eligible.last;
      _progressDate = _parseDate(last?['progress_date']) ??
          record.legacyCompletedDate ?? _startDate;
    }
    _remarksController = TextEditingController(
      text: last?['remarks']?.toString() ?? '',
    );
    _actionController = TextEditingController(
      text: last?['action_taken']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _unitController.dispose();
    _typeController.dispose();
    _durationController.dispose();
    _depositController.dispose();
    _remarksController.dispose();
    _actionController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_startDate == null) {
      _dialogError(context, 'Starting Date is required.');
      return;
    }
    if (_progressDate == null) {
      _dialogError(context, 'Progress Date is required.');
      return;
    }
    if (widget.reportMonth != null &&
        !_isInMonth(_progressDate!, widget.reportMonth!)) {
      _dialogError(context, 'Progress Date must be in the selected month.');
      return;
    }
    if (_progressDate!.isBefore(_startDate!)) {
      _dialogError(context, 'Progress Date cannot be before Starting Date.');
      return;
    }
    Navigator.of(context).pop(_RenovationHistoryEditResult(
      unit: _unitController.text.trim(),
      renovationType: _typeController.text.trim(),
      status: _status,
      refundStatus: _refundStatus,
      startDate: _startDate!,
      duration: _durationController.text.trim(),
      depositAmount: double.parse(_depositController.text.trim()),
      depositPaidDate: _depositPaidDate,
      progressDate: _progressDate,
      remarks: _remarksController.text,
      actionTaken: _actionController.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: const Text('Edit Renovation Record'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _unitController,
                  decoration: _inputDecoration('Unit'),
                  validator: (s) => s == null || s.trim().isEmpty
                      ? 'Please enter a unit.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _typeController,
                  decoration: _inputDecoration('Renovation Type'),
                  validator: (s) => s == null || s.trim().isEmpty
                      ? 'Please enter renovation type.'
                      : null,
                ),
                const SizedBox(height: 12),
                _RenovationDateField(
                  label: 'Starting Date',
                  value: _startDate,
                  onChanged: (date) => setState(() => _startDate = date),
                ),
                const SizedBox(height: 12),
                _RenovationDateField(
                  label: 'Progress Date',
                  value: _progressDate,
                  onChanged: (date) => setState(() => _progressDate = date),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _renovationStatuses.contains(_status)
                      ? _status : 'Pending',
                  decoration: _inputDecoration('Renovation Status'),
                  items: _renovationStatuses
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (s) {
                    if (s != null) setState(() => _status = s);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _durationController,
                  decoration: _inputDecoration('Duration'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _depositController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: _inputDecoration('Deposit Amount (RM)'),
                  validator: _validateAmount,
                ),
                const SizedBox(height: 12),
                _RenovationDateField(
                  label: 'Deposit Payment Date',
                  value: _depositPaidDate,
                  canClear: true,
                  onChanged: (date) => setState(() => _depositPaidDate = date),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _refundOptions.contains(_refundStatus)
                      ? _refundStatus : 'N/A',
                  decoration: _inputDecoration('Refund Status'),
                  items: _refundOptions
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (s) {
                    if (s != null) setState(() => _refundStatus = s);
                  },
                ),
                if (widget.reportMonth != null) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _remarksController,
                    minLines: 2,
                    maxLines: 3,
                    decoration: _inputDecoration('Description / Remarks'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _actionController,
                    minLines: 2,
                    maxLines: 3,
                    decoration: _inputDecoration('Action Taken'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.red,
            foregroundColor: AppColors.white,
          ),
          child: const Text('Save Changes'),
        ),
      ],
    );
  }
}

class _RenovationAddDialog extends StatefulWidget {
  final DateTime reportMonth;
  final int nextLineNo;

  const _RenovationAddDialog({
    required this.reportMonth,
    required this.nextLineNo,
  });

  @override
  State<_RenovationAddDialog> createState() => _RenovationAddDialogState();
}

class _RenovationAddDialogState extends State<_RenovationAddDialog> {
  final _formKey = GlobalKey<FormState>();
  final _unitController = TextEditingController();
  final _typeController = TextEditingController();
  final _durationController = TextEditingController();
  final _depositController = TextEditingController(text: '0.00');
  DateTime? _startDate;
  DateTime? _depositPaidDate;
  late DateTime _progressDate;
  String _status = 'Pending';
  String _refundStatus = 'N/A';

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _progressDate = _isInMonth(today, widget.reportMonth)
        ? DateTime(today.year, today.month, today.day)
        : widget.reportMonth;
    _startDate = widget.reportMonth;
  }

  @override
  void dispose() {
    _unitController.dispose();
    _typeController.dispose();
    _durationController.dispose();
    _depositController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_startDate == null) {
      _dialogError(context, 'Starting Date is required.');
      return;
    }
    if (_firstOfMonth(_startDate!).isAfter(widget.reportMonth)) {
      _dialogError(context, 'Starting Date cannot be after report month.');
      return;
    }
    if (!_isInMonth(_progressDate, widget.reportMonth)) {
      _dialogError(context, 'Progress Date must be in the selected month.');
      return;
    }
    if (_startDate!.isAfter(_progressDate)) {
      _dialogError(context, 'Starting Date cannot be after Progress Date.');
      return;
    }
    final amount = double.tryParse(_depositController.text.trim()) ?? 0;
    if (amount > 0 && _depositPaidDate == null) {
      _dialogError(context, 'Enter Deposit Payment Date for a paid deposit.');
      return;
    }
    final duration = _status == 'Completed'
        ? _durationBetween(_startDate!, _progressDate)
        : _durationController.text.trim();
    final history = <Map<String, dynamic>>[
      {
        'progress_date': _dbDate(_progressDate),
        'status': _status,
        'previous_status': _status,
        'start_date': _dbDate(_startDate),
        'remarks': '',
        'action_taken': '',
        'saved_at': DateTime.now().toUtc().toIso8601String(),
      },
    ];

    Navigator.of(context).pop(_RenovationRecord(
      id: null,
      lineNo: widget.nextLineNo,
      sourceReportId: null,
      openedMonth: _firstOfMonth(_startDate!),
      unit: _unitController.text.trim(),
      renovationType: _typeController.text.trim(),
      duration: duration,
      depositAmount: amount,
      depositPaidDate: _depositPaidDate,
      renovationStatus: _status,
      refundStatus: _refundStatus,
      startDate: _startDate,
      legacyCompletedDate: null,
      progressHistory: history,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: const Text('Add Renovation Record'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _unitController,
                  decoration: _inputDecoration('Unit'),
                  validator: (s) => s == null || s.trim().isEmpty
                      ? 'Please enter a unit.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _typeController,
                  decoration: _inputDecoration('Renovation Type'),
                  validator: (s) => s == null || s.trim().isEmpty
                      ? 'Please enter renovation type.'
                      : null,
                ),
                const SizedBox(height: 12),
                _RenovationDateField(
                  label: 'Starting Date',
                  value: _startDate,
                  onChanged: (date) => setState(() => _startDate = date),
                ),
                const SizedBox(height: 12),
                _RenovationDateField(
                  label: 'Progress Date',
                  value: _progressDate,
                  onChanged: (date) {
                    if (date != null) setState(() => _progressDate = date);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: _inputDecoration('Renovation Status'),
                  items: _renovationStatuses
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (s) {
                    if (s != null) setState(() => _status = s);
                  },
                ),
                const SizedBox(height: 12),
                if (_status != 'Completed') ...[
                  TextFormField(
                    controller: _durationController,
                    decoration: _inputDecoration('Duration (optional)'),
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _depositController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: _inputDecoration('Deposit Amount (RM)'),
                  validator: _validateAmount,
                ),
                const SizedBox(height: 12),
                _RenovationDateField(
                  label: 'Deposit Payment Date',
                  value: _depositPaidDate,
                  canClear: true,
                  onChanged: (date) =>
                      setState(() => _depositPaidDate = date),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _refundStatus,
                  decoration: _inputDecoration('Refund Status'),
                  items: _refundOptions
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (s) {
                    if (s != null) setState(() => _refundStatus = s);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white),
          child: const Text('Add Record'),
        ),
      ],
    );
  }
}

class _RenovationDateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool canClear;

  const _RenovationDateField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.canClear = false,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: _inputDecoration(label),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final selected = await showDatePicker(
                  context: context,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (selected != null) onChanged(selected);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(_displayDate(value)),
              ),
            ),
          ),
          if (canClear && value != null)
            IconButton(
              tooltip: 'Clear date',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: () => onChanged(null),
              icon: const Icon(Icons.close, size: 17),
            ),
          IconButton(
            tooltip: 'Choose date',
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () async {
              final selected = await showDatePicker(
                context: context,
                initialDate: value ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (selected != null) onChanged(selected);
            },
            icon: const Icon(Icons.calendar_today_outlined, size: 19),
          ),
        ],
      ),
    );
  }
}

const _renovationStatuses = [
  'Pending',
  'In Progress',
  'On Hold',
  'Completed',
  'Cancelled',
];
const _refundOptions = ['N/A', 'Pending', 'Refunded', 'Forfeited'];

InputDecoration _inputDecoration(String label) => InputDecoration(
      labelText: label,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
    );

String? _validateAmount(String? value) {
  final amount = double.tryParse(value?.trim() ?? '');
  if (amount == null || !amount.isFinite || amount < 0) {
    return 'Enter a valid amount (0 or more).';
  }
  return null;
}

void _dialogError(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

DateTime? _parseDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return DateTime(value.year, value.month, value.day);
  final parsed = DateTime.tryParse(value.toString());
  return parsed == null ? null : DateTime(parsed.year, parsed.month, parsed.day);
}

DateTime _firstOfMonth(DateTime date) => DateTime(date.year, date.month, 1);

bool _isInMonth(DateTime date, DateTime month) =>
    date.year == month.year && date.month == month.month;

String? _dbDate(DateTime? date) => date == null
    ? null
    : '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

String _displayDate(DateTime? date) => date == null
    ? 'Not set'
    : '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';

String _durationBetween(DateTime start, DateTime end) {
  final days = DateTime(end.year, end.month, end.day)
      .difference(DateTime(start.year, start.month, start.day))
      .inDays;
  return '${days < 0 ? 0 : days} days';
}

List<Map<String, dynamic>> _sortedProgress(
    List<Map<String, dynamic>> history) {
  final sorted = history.map((x) => Map<String, dynamic>.from(x)).toList();
  sorted.sort((a, b) {
    final ad = _parseDate(a['progress_date']) ?? DateTime(2000);
    final bd = _parseDate(b['progress_date']) ?? DateTime(2000);
    final comparison = ad.compareTo(bd);
    if (comparison != 0) return comparison;
    return (a['saved_at']?.toString() ?? '')
        .compareTo(b['saved_at']?.toString() ?? '');
  });
  return sorted;
}

String _monthName(DateTime? date) {
  if (date == null) return 'Monthly Report';
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${months[date.month - 1]} ${date.year}';
}