import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class ComplianceBestPracticesPage extends StatefulWidget {
  // This master register is shown relative to the selected monthly report.
  // It is not a separate copy of each record for each month.
  final Map<String, dynamic> report;

  const ComplianceBestPracticesPage({
    super.key,
    required this.report,
  });

  @override
  State<ComplianceBestPracticesPage> createState() =>
      _ComplianceBestPracticesPageState();
}

class _ComplianceBestPracticesPageState
    extends State<ComplianceBestPracticesPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<_ComplianceRecord> _records = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // New selections use Yes/No only. Existing N/A records can still be edited
  // without automatically replacing their stored values.
  static const List<String> _options = ['Yes', 'No'];
  static const List<String> _lifecycleStatuses = [
    'Renewed',
    'Retired',
    'Superseded',
  ];
  final Set<String> _selectedCompliantStatuses = <String>{};

  DateTime get _selectedReportMonth {
    final raw = widget.report['report_month'] ?? widget.report['month'];
    final text = raw?.toString().trim() ?? '';
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return DateTime(parsed.year, parsed.month);

    // Also accept report months stored as YYYY-MM or Month YYYY.
    final numeric = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(text);
    if (numeric != null) {
      final year = int.tryParse(numeric.group(1)!);
      final month = int.tryParse(numeric.group(2)!);
      if (year != null && month != null && month >= 1 && month <= 12) {
        return DateTime(year, month);
      }
    }
    final named = RegExp(r'^([A-Za-z]+) (\d{4})$').firstMatch(text);
    if (named != null) {
      final index = _monthNames.indexWhere((m) =>
          m.toLowerCase() == named.group(1)!.toLowerCase());
      final year = int.tryParse(named.group(2)!);
      if (index >= 0 && year != null) return DateTime(year, index + 1);
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  String get _selectedReportId =>
      widget.report['id']?.toString() ?? 'Not provided';

  // The selected report determines property ownership. Never load a shared
  // register or fall back to another property when this identifier is absent.
  String get _selectedSiteId =>
      widget.report['site_id']?.toString().trim() ?? '';

  static const List<String> _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  String _monthLabel(DateTime date) =>
      '${_monthNames[date.month - 1]} ${date.year}';

  DateTime? _nextReviewDate(_ComplianceRecord record) =>
      DateTime.tryParse(record.nextReviewDate ?? '');

  DateTime? _lastReviewDate(_ComplianceRecord record) =>
      DateTime.tryParse(record.lastReviewDate ?? '');

  // History and Archive use the selected monthly report's cutoff date.
  DateTime get _reportCutoffDate {
    final reportMonth = _selectedReportMonth;
    return DateTime(reportMonth.year, reportMonth.month + 1, 0);
  }

  // Overdue warnings use the actual date, not the selected report month.
  DateTime get _todayDate => DateUtils.dateOnly(DateTime.now());

  DateTime? _archiveDate(_ComplianceRecord record) {
    final saved = record.archivedAt;
    return saved == null ? null : DateTime.tryParse(saved)?.toLocal();
  }

  bool _isInactiveStatus(_ComplianceRecord record) =>
      record.status == 'Retired' || record.status == 'Superseded';

  // A service date is a reminder, NOT an expiry date. Only a formal
  // retirement, supersession or manual archive ends an ongoing requirement.
  bool _isArchivedForReport(_ComplianceRecord record) {
    if (!record.isArchived && !_isInactiveStatus(record)) return false;
    final archivedAt = _archiveDate(record);
    // Older records may have no effective archive date. Do not invent one.
    if (archivedAt == null) return true;
    return !DateUtils.dateOnly(archivedAt).isAfter(_reportCutoffDate);
  }

  bool _isOverdue(_ComplianceRecord record) {
    if (_isArchivedForReport(record)) return false;
    final next = _nextReviewDate(record);
    return next != null && DateUtils.dateOnly(next).isBefore(_todayDate);
  }

  List<_ComplianceRecord> get _thisMonthRecords =>
      _records.where((record) => !_isArchivedForReport(record)).toList();

  // The current table stores only the most recent Last Review Date for each
  // practice. History can show that recorded review, but cannot reconstruct
  // older completed activities without a separate activity-history source.
  List<_ComplianceRecord> get _historicalRecords => _records.where((record) {
        final completed = _lastReviewDate(record);
        return completed != null &&
            !DateUtils.dateOnly(completed).isAfter(_reportCutoffDate);
      }).toList();

  List<_ComplianceRecord> get _archivedRecords =>
      _records.where(_isArchivedForReport).toList();

  bool _matchesSearch(_ComplianceRecord record) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final searchText = [
      record.name,
      record.category,
      record.description,
      record.responsiblePerson,
      record.reviewFrequency,
      record.lastReviewDate ?? '',
      record.nextReviewDate ?? '',
      record.status,
      record.requiredStatus,
      record.compliantStatus,
      record.actionRemarks,
    ].join(' ').toLowerCase();
    return searchText.contains(query);
  }

  bool _matchesStatus(_ComplianceRecord record) =>
      _selectedCompliantStatuses.isEmpty ||
      _selectedCompliantStatuses.contains(record.compliantStatus);

  List<_ComplianceRecord> get _visibleThisMonth => _thisMonthRecords
      .where((record) => _matchesSearch(record) && _matchesStatus(record))
      .toList();

  List<_ComplianceRecord> get _visibleHistory => _historicalRecords
      .where((record) => _matchesSearch(record) && _matchesStatus(record))
      .toList();

  List<_ComplianceRecord> get _visibleArchived => _archivedRecords
      .where((record) => _matchesSearch(record) && _matchesStatus(record))
      .toList();

  int get _compliantCount =>
      _thisMonthRecords.where((r) => r.compliantStatus == 'Yes').length;

  int get _nonCompliantCount =>
      _thisMonthRecords.where((r) => r.compliantStatus == 'No').length;

  void _toggleCompliantStatus(String status) {
    setState(() {
      if (!_selectedCompliantStatuses.add(status)) {
        _selectedCompliantStatuses.remove(status);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadRecords();
  }

  @override
  void didUpdateWidget(covariant ComplianceBestPracticesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final siteChanged =
        oldWidget.report['site_id'] != widget.report['site_id'];
    if (siteChanged ||
        oldWidget.report['id'] != widget.report['id'] ||
        oldWidget.report['report_month'] != widget.report['report_month'] ||
        oldWidget.report['month'] != widget.report['month']) {
      _selectedCompliantStatuses.clear();
      _searchController.removeListener(_onSearchChanged);
      _searchController.clear();
      _searchController.addListener(_onSearchChanged);
    }
    if (siteChanged) _loadRecords();
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

  Future<void> _loadRecords() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final siteId = _selectedSiteId;
    try {
      if (siteId.isEmpty) {
        throw StateError(
          'The selected monthly report has no property ID. '
          'Open the report from its property before managing compliance.',
        );
      }
      // Load current and archived records only for the selected property.
      // A passed Next Service Date never archives a practice.
      final response = await _supabase
          .from('compliance_best_practices')
          .select()
          .eq('site_id', siteId)
          .order('name');
      final records = (response as List)
          .map((row) => _ComplianceRecord.fromMap(
              Map<String, dynamic>.from(row)))
          .toList();
      if (!mounted || _selectedSiteId != siteId) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Compliance records load error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || _selectedSiteId != siteId) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveRecord(_ComplianceRecord record) async {
    if (_saving) return;
    final siteId = _selectedSiteId;
    if (siteId.isEmpty) {
      _showMessage('Cannot save: the selected report has no property ID.');
      return;
    }
    setState(() => _saving = true);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      _ComplianceRecord? previous;
      if (record.id != null) {
        for (final saved in _records) {
          if (saved.id == record.id) {
            previous = saved;
            break;
          }
        }
      }
      final newInactive = _isInactiveStatus(record);
      final previousInactive =
          previous != null && _isInactiveStatus(previous);
      final data = <String, dynamic>{
        'name': record.name.trim(),
        'category': _nullableText(record.category),
        'description': _nullableText(record.description),
        'responsible_person': _nullableText(record.responsiblePerson),
        'review_frequency': _nullableText(record.reviewFrequency),
        'last_review_date': record.lastReviewDate,
        'next_review_date': record.nextReviewDate,
        'status': record.status,
        'item_practice': record.name.trim(),
        'required_status': record.requiredStatus,
        'compliant_status': record.compliantStatus,
        'action_remarks': record.actionRemarks.trim(),
        // Keep the existing persistent master-list storage convention.
        'report_id': null,
        'line_no': null,
        'updated_at': now,
      };
      // Record the effective lifecycle date when a requirement is formally
      // retired/superseded. Keep is_archived unchanged for PDF compatibility;
      // the lifecycle status determines the on-page Archive classification.
      if (newInactive && !previousInactive) {
        data['archived_at'] = now;
        data['archive_reason'] = 'Status changed to ${record.status}';
      } else if (!newInactive && previousInactive) {
        data['archived_at'] = null;
        data['archive_reason'] = null;
      }
      if (record.id != null) {
        final changed = await _supabase
            .from('compliance_best_practices')
            .update(data)
            .eq('id', record.id!)
            .eq('site_id', siteId)
            .eq('is_archived', false)
            .select('id');
        if (changed.isEmpty) {
          throw StateError('Update did not affect a record. Check your permissions.');
        }
      } else {
        // This property-wide register is not duplicated each month.
        await _supabase.from('compliance_best_practices').insert({
          ...data,
          'site_id': siteId,
          'is_archived': false,
        });
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Compliance record saved successfully.');
    } catch (e, stackTrace) {
      debugPrint('Compliance record save error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) _showMessage('Failed to save compliance record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Restoring an inactive requirement must change its lifecycle, not its
  // scheduled service date. Keep the saved review dates untouched.
  Future<void> _restoreArchivedRecord(_ComplianceRecord record) async {
    if (_saving || record.id == null || !mounted) return;
    final siteId = _selectedSiteId;
    if (siteId.isEmpty) {
      _showMessage('Cannot restore: the selected report has no property ID.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Restore Compliance Record'),
        content: Text(
          'Restore "${record.name}" to the active compliance register? '
          'Its Last Review Date and Next Service Date will remain unchanged. '
          'An overdue service will continue to be flagged until updated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final rows = await _supabase
          .from('compliance_best_practices')
          .update({
            'status': 'Renewed',
            'is_archived': false,
            'archived_at': null,
            'archive_reason': null,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', record.id!)
          .eq('site_id', siteId)
          .select('id');
      if (rows.isEmpty) {
        throw StateError('No record updated. Check your permissions.');
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Compliance record restored to This Month.');
    } catch (e) {
      if (mounted) _showMessage('Could not restore compliance record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _nullableText(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _deleteRecord(_ComplianceRecord record) async {
    if (_saving || record.id == null || !mounted) return;
    final siteId = _selectedSiteId;
    if (siteId.isEmpty) {
      _showMessage('Cannot delete: the selected report has no property ID.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete Compliance Record?'),
        content: Text(
          'Permanently delete "${record.name}"? '
          'This record will be removed from This Month and History. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final deleted = await _supabase
          .from('compliance_best_practices')
          .delete()
          .eq('id', record.id!)
          .eq('site_id', siteId)
          .eq('is_archived', false)
          .select('id');
      if (deleted.isEmpty) {
        throw StateError('No record deleted. Check your permissions.');
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Compliance record deleted.');
    } catch (e, stackTrace) {
      debugPrint('Compliance record delete error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) _showMessage('Could not delete compliance record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showRecordDialog({
    _ComplianceRecord? existing,
  }) async {
    if (_saving) return;

    final isEditing = existing != null;
    final formKey = GlobalKey<FormState>();

    final nameController = TextEditingController(
      text: existing?.name ?? '',
    );
    final categoryController = TextEditingController(
      text: existing?.category ?? '',
    );
    final descriptionController = TextEditingController(
      text: existing?.description ?? '',
    );
    final responsibleController = TextEditingController(
      text: existing?.responsiblePerson ?? '',
    );
    final frequencyController = TextEditingController(
      text: existing?.reviewFrequency ?? '',
    );
    final lastReviewController = TextEditingController(
      text: existing?.lastReviewDate ?? '',
    );
    final nextReviewController = TextEditingController(
      text: existing?.nextReviewDate ?? '',
    );
    final remarksController = TextEditingController(
      text: existing?.actionRemarks ?? '',
    );

    String requiredStatus = existing?.requiredStatus ?? 'Yes';
    String compliantStatus = existing?.compliantStatus ?? 'Yes';
    String lifecycleStatus = existing?.status ?? 'Renewed';

    // Avoid passing an unsupported existing value into the dropdown.
    if (!_lifecycleStatuses.contains(lifecycleStatus)) {
      lifecycleStatus = 'Renewed';
    }

    try {
      final result = await showDialog<_ComplianceRecord>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: AppColors.white,
            surfaceTintColor: Colors.transparent,
            title: Text(
              isEditing
                  ? 'Edit Compliance Record'
                  : 'Add Compliance Record',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          isEditing
                              ? 'MASTER RECORD'
                              : 'NEW MASTER RECORD',
                          style: const TextStyle(
                            color: AppColors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name / Item / Practice *',
                          hintText: 'Enter the compliance practice',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a name or practice.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: categoryController,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          hintText: 'e.g. Building Operations',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: descriptionController,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: responsibleController,
                        decoration: const InputDecoration(
                          labelText: 'Responsible Person',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: frequencyController,
                        decoration: const InputDecoration(
                          labelText: 'Maintenance Period (Months)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: lastReviewController,
                        decoration: const InputDecoration(
                          labelText: 'Last Review Date',
                          hintText: 'YYYY-MM-DD (optional)',
                          border: OutlineInputBorder(),
                          suffixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                        validator: _validateOptionalDate,
                        onTap: () async {
                          final date = await _pickDate(
                            context,
                            lastReviewController.text,
                          );
                          if (date != null) {
                            lastReviewController.text = _dateToString(date);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: nextReviewController,
                        decoration: const InputDecoration(
                          labelText: 'Next Service Date',
                          hintText: 'YYYY-MM-DD (optional)',
                          border: OutlineInputBorder(),
                          suffixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                        validator: _validateOptionalDate,
                        onTap: () async {
                          final date = await _pickDate(
                            context,
                            nextReviewController.text,
                          );
                          if (date != null) {
                            nextReviewController.text = _dateToString(date);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: lifecycleStatus,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Record Status',
                          border: OutlineInputBorder(),
                        ),
                        items: _lifecycleStatuses
                            .map(
                              (value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => lifecycleStatus = value);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: requiredStatus,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Required',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          if (requiredStatus == 'N/A')
                            const DropdownMenuItem<String>(
                              value: 'N/A',
                              enabled: false,
                              child: Text('N/A (previously saved)'),
                            ),
                          ..._options.map((value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              )),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => requiredStatus = value);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: compliantStatus,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Compliant',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          if (compliantStatus == 'N/A')
                            const DropdownMenuItem<String>(
                              value: 'N/A',
                              enabled: false,
                              child: Text('N/A (previously saved)'),
                            ),
                          ..._options.map((value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              )),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => compliantStatus = value);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: remarksController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Remarks',
                          hintText: 'Enter remarks',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: AppColors.white,
                ),
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;

                  Navigator.pop(
                    dialogContext,
                    _ComplianceRecord(
                      id: existing?.id,
                      name: nameController.text.trim(),
                      category: categoryController.text.trim(),
                      description: descriptionController.text.trim(),
                      responsiblePerson: responsibleController.text.trim(),
                      reviewFrequency: frequencyController.text.trim(),
                      lastReviewDate: _normaliseDate(
                        lastReviewController.text,
                      ),
                      nextReviewDate: _normaliseDate(
                        nextReviewController.text,
                      ),
                      status: lifecycleStatus,
                      requiredStatus: requiredStatus,
                      compliantStatus: compliantStatus,
                      actionRemarks: remarksController.text.trim(),
                    ),
                  );
                },
                child: Text(isEditing ? 'Save Changes' : 'Add Record'),
              ),
            ],
          ),
        ),
      );

      if (result != null && mounted) {
        await _saveRecord(result);
      }
    } finally {
      nameController.dispose();
      categoryController.dispose();
      descriptionController.dispose();
      responsibleController.dispose();
      frequencyController.dispose();
      lastReviewController.dispose();
      nextReviewController.dispose();
      remarksController.dispose();
    }
  }

  String? _validateOptionalDate(String? value) {
    if (value == null || value.trim().isEmpty) return null;

    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null || !_isDateOnly(value.trim())) {
      return 'Enter a valid date in YYYY-MM-DD format.';
    }

    return null;
  }

  bool _isDateOnly(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return false;

    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
        _dateToString(parsed) == value;
  }

  String? _normaliseDate(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _dateToString(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  Future<DateTime?> _pickDate(
    BuildContext context,
    String currentValue,
  ) async {
    final parsed = DateTime.tryParse(currentValue.trim());
    final now = DateTime.now();

    return showDatePicker(
      context: context,
      initialDate: parsed ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.charcoal,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Color _answerColor(String value) {
    if (value == 'Yes') return const Color(0xFF22683D);
    if (value == 'No') return AppColors.red;
    return AppColors.grey;
  }

  Widget _statusChip(String label, String value) {
    final color = _answerColor(value);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$label: $value',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          )),
    );
  }

  Widget _lifecycleChip(String status) {
    final color = status == 'Renewed'
        ? const Color(0xFF22683D)
        : status == 'Retired'
            ? AppColors.grey
            : AppColors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('Status: $status',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          )),
    );
  }

  // Match the compact labelled-value rows in Licences & Regulatory.
  Widget _detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
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
              value,
              softWrap: true,
              style: const TextStyle(
                color: AppColors.black,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewDateBox(String label, String? date) {
    return Container(
      width: 172,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8FA),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(9),
      ),
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
          const SizedBox(height: 5),
          Text(
            _displayDate(date),
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(_ComplianceRecord record, int number,
      {bool archivedMirror = false, bool historical = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
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
                      record.name,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (record.category.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        record.category,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    // Description belongs below the category, not below the
                    // whole title/status row. Flutter wraps long text naturally.
                    if (record.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        record.description,
                        softWrap: true,
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _statusChip('Required', record.requiredStatus),
                      _statusChip('Compliant', record.compliantStatus),
                      _lifecycleChip(record.status),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (record.lastReviewDate != null ||
              record.nextReviewDate != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (record.lastReviewDate != null)
                  _reviewDateBox('Last Review Date', record.lastReviewDate),
                if (record.nextReviewDate != null)
                  _reviewDateBox('Next Service Date', record.nextReviewDate),
              ],
            ),
          ],
          // Flag missed service dates only on current ongoing practices.
          if (!archivedMirror && !historical && _isOverdue(record)) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.warning_amber_outlined,
                    color: AppColors.red, size: 17),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Next Service Date overdue',
                    style: TextStyle(
                      color: AppColors.red,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (record.responsiblePerson.trim().isNotEmpty ||
              record.reviewFrequency.trim().isNotEmpty ||
              record.actionRemarks.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            if (record.responsiblePerson.trim().isNotEmpty)
              _detailLine('Responsible', record.responsiblePerson),
            if (record.reviewFrequency.trim().isNotEmpty)
              _detailLine('Maintenance Period (Months)', record.reviewFrequency),
            if (record.actionRemarks.trim().isNotEmpty)
              _detailLine('Remarks', record.actionRemarks),
          ],
          const Divider(height: 22),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (archivedMirror)
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _restoreArchivedRecord(record),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.red,
                    ),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Restore'),
                  )
                else ...[
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _showRecordDialog(existing: record),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.red,
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: _saving ? null : () => _deleteRecord(record),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.red,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _displayDate(String? value) {
    final parsed = DateTime.tryParse(value ?? '');
    if (parsed == null) return 'Not set';
    return '${parsed.day.toString().padLeft(2, '0')}/'
        '${parsed.month.toString().padLeft(2, '0')}/'
        '${parsed.year}';
  }

  Widget _summaryCard(String label, int count, IconData icon,
      Color accent, {VoidCallback? onTap}) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minHeight: 108),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(height: 6),
                    Text('$count',
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
        ),
      ),
    );
  }

  Widget _buildSummary() {
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 520;
      final bottom = <Widget>[
        _summaryCard('Compliant', _compliantCount,
            Icons.check_circle_outline, const Color(0xFF22683D),
            onTap: () => _toggleCompliantStatus('Yes')),
        _summaryCard('Non-Compliant', _nonCompliantCount,
            Icons.warning_amber_outlined, AppColors.red,
            onTap: () => _toggleCompliantStatus('No')),
      ];
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: _summaryCard('Total Compliance Items',
                _thisMonthRecords.length,
                Icons.fact_check_outlined, AppColors.red,
                onTap: () => setState(() =>
                    _selectedCompliantStatuses.clear())),
          ),
          const SizedBox(height: 12),
          if (narrow)
            ...[
              SizedBox(width: double.infinity, child: bottom[0]),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: bottom[1]),
            ]
          else
            Row(
              children: [
                Expanded(child: bottom[0]),
                const SizedBox(width: 12),
                Expanded(child: bottom[1]),
              ],
            ),
        ],
      );
    });
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
                letterSpacing: 1.5,
              )),
          const SizedBox(height: 8),
          const Text('Compliance & Best Practices',
              style: TextStyle(
                color: AppColors.white,
                fontSize: 25,
                fontWeight: FontWeight.w800,
              )),
          const SizedBox(height: 8),
          Text('${_monthLabel(_selectedReportMonth)} '
              ' • Report ID: $_selectedReportId',
              style: const TextStyle(
                color: Color(0xFFE0E0E0),
                fontSize: 13,
                height: 1.5,
              )),
        ],
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
            hintText: 'Search item, category, responsible person or remarks...',
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: _searchController.clear,
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear),
                  ),
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
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text('Showing:',
                style: TextStyle(color: AppColors.grey, fontSize: 12)),
            if (_selectedCompliantStatuses.isEmpty)
              const Text('All statuses',
                  style: TextStyle(color: AppColors.black, fontSize: 12))
            else ...[
              if (_selectedCompliantStatuses.contains('Yes'))
                _filterChip('Compliant', 'Yes'),
              if (_selectedCompliantStatuses.contains('No'))
                _filterChip('Non-Compliant', 'No'),
              TextButton.icon(
                onPressed: () => setState(() =>
                    _selectedCompliantStatuses.clear()),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                icon: const Icon(Icons.close, size: 14),
                label: const Text('Clear filter'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _filterChip(String label, String status) {
    return InkWell(
      onTap: () => _toggleCompliantStatus(status),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFFD8B5B0)),
        ),
        child: Text(label, style: const TextStyle(
          color: Color(0xFF665552),
          fontSize: 12,
          fontWeight: FontWeight.w400,
        )),
      ),
    );
  }

  Widget _sectionHeading(String title, String subtitle, int count) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.black,
                  )),
            ),
            Text('$count ${count == 1 ? 'record' : 'records'}',
                style: const TextStyle(
                  color: AppColors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
        if (subtitle.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(
            color: AppColors.grey, fontSize: 12,
          )),
        ],
      ],
    );
  }

  Map<String, List<_ComplianceRecord>> _historyByMonth() {
    final grouped = <String, List<_ComplianceRecord>>{};
    for (final record in _visibleHistory) {
      final review = _lastReviewDate(record);
      if (review == null) continue;
      final key = '${review.year.toString().padLeft(4, '0')}-'
          '${review.month.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(key, () => <_ComplianceRecord>[]).add(record);
    }
    return grouped;
  }

  Widget _buildHistorySection() {
    final grouped = _historyByMonth();
    final months = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final count = _visibleHistory.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading('History', '', count),
        const SizedBox(height: 14),
        if (months.isEmpty)
          _emptyCard('No historical compliance records found.')
        else
          ...months.map((key) {
            final records = grouped[key]!;
            final month = DateTime.parse('$key-01');
            return Container(
              key: ValueKey('compliance-history-$key'),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: false,
                tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 7),
                title: Text(_monthLabel(month),
                    style: const TextStyle(
                      color: AppColors.black,
                      fontWeight: FontWeight.bold,
                    )),
                subtitle: Text(
                  '${records.length} compliance '
                  '${records.length == 1 ? 'record' : 'records'}',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: records.asMap().entries.map((entry) =>
                    _buildRecordCard(
                      entry.value,
                      entry.key + 1,
                      historical: true,
                    )).toList(),
              ),
            );
          }),
      ],
    );
  }

  // Inactive practices are archived by their explicit lifecycle status or
  // manual archive flag, never by an overdue Next Service Date.
  Map<String, List<_ComplianceRecord>> _archivedByMonth() {
    final grouped = <String, List<_ComplianceRecord>>{};
    for (final record in _visibleArchived) {
      final archivedAt = _archiveDate(record);
      final key = archivedAt == null
          ? 'undated'
          : '${archivedAt.year.toString().padLeft(4, '0')}-'
              '${archivedAt.month.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(key, () => <_ComplianceRecord>[]).add(record);
    }
    return grouped;
  }

  Widget _buildArchivedSection() {
    final grouped = _archivedByMonth();
    final months = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'undated') return 1;
        if (b == 'undated') return -1;
        return b.compareTo(a);
      });
    final count = _visibleArchived.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading('Archived Records', '', count),
        const SizedBox(height: 14),
        if (months.isEmpty)
          _emptyCard('No archived compliance records found.')
        else
          ...months.map((key) {
            final records = grouped[key]!;
            final monthLabel = key == 'undated'
                ? 'Date not recorded'
                : _monthLabel(DateTime.parse('$key-01'));
            return Container(
              key: ValueKey('compliance-archived-$key'),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: false,
                tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 7),
                title: Text(
                  monthLabel,
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  '${records.length} compliance '
                  '${records.length == 1 ? 'record' : 'records'}',
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontSize: 12,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: records.asMap().entries.map((entry) =>
                    _buildRecordCard(
                      entry.value,
                      entry.key + 1,
                      archivedMirror: true,
                    )).toList(),
              ),
            );
          }),
      ],
    );
  }

  Widget _emptyCard(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(message, style: const TextStyle(color: AppColors.grey)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Compliance & Best Practices',
            style: TextStyle(fontWeight: FontWeight.bold)),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading || _saving ? null : () => _showRecordDialog(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Record'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: _loading
              ? const Center(child: CircularProgressIndicator(
                  color: AppColors.red))
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline,
                                color: AppColors.red, size: 42),
                            const SizedBox(height: 12),
                            const Text('Unable to load compliance records.',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            SelectableText(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _loadRecords,
                              child: const Text('Try Again'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadRecords,
                      color: AppColors.red,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 20),
                          _buildSummary(),
                          const SizedBox(height: 24),
                          _buildSearchAndFilters(),
                          const SizedBox(height: 20),
                          _sectionHeading(
                            'This Month',
                            '',
                            _visibleThisMonth.length,
                          ),
                          const SizedBox(height: 14),
                          if (_visibleThisMonth.isEmpty)
                            _emptyCard('No compliance records match this month and filters.')
                          else
                            ..._visibleThisMonth.asMap().entries.map((entry) =>
                                _buildRecordCard(entry.value, entry.key + 1)),
                          const SizedBox(height: 24),
                          _buildHistorySection(),
                          const SizedBox(height: 24),
                          _buildArchivedSection(),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}

class _ComplianceRecord {
  final String? id;
  final String name;
  final String category;
  final String description;
  final String responsiblePerson;
  final String reviewFrequency;
  final String? lastReviewDate;
  final String? nextReviewDate;
  final String status;
  final String requiredStatus;
  final String compliantStatus;
  final String actionRemarks;
  final bool isArchived;
  final String? archivedAt;

  const _ComplianceRecord({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.responsiblePerson,
    required this.reviewFrequency,
    required this.lastReviewDate,
    required this.nextReviewDate,
    required this.status,
    required this.requiredStatus,
    required this.compliantStatus,
    required this.actionRemarks,
    this.isArchived = false,
    this.archivedAt,
  });

  factory _ComplianceRecord.fromMap(Map<String, dynamic> map) {
    String validOption(dynamic value) {
      const options = ['Yes', 'No', 'N/A'];
      final result = value?.toString() ?? 'Yes';
      return options.contains(result) ? result : 'Yes';
    }

    String dateValue(dynamic value) {
      if (value == null) return '';
      return value.toString().split('T').first;
    }

    final itemPractice = map['item_practice']?.toString().trim() ?? '';
    final name = map['name']?.toString().trim() ?? '';

    return _ComplianceRecord(
      id: map['id']?.toString(),
      name: name.isNotEmpty
          ? name
          : itemPractice.isNotEmpty
              ? itemPractice
              : 'Untitled compliance record',
      category: map['category']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      responsiblePerson: map['responsible_person']?.toString() ?? '',
      reviewFrequency: map['review_frequency']?.toString() ?? '',
      lastReviewDate: _emptyToNull(dateValue(map['last_review_date'])),
      nextReviewDate: _emptyToNull(dateValue(map['next_review_date'])),
      status: map['status']?.toString() == 'Active'
          ? 'Renewed'
          : (map['status']?.toString() ?? 'Renewed'),
      requiredStatus: validOption(map['required_status']),
      compliantStatus: validOption(map['compliant_status']),
      actionRemarks: map['action_remarks']?.toString() ?? '',
      isArchived: map['is_archived'] == true,
      archivedAt: map['archived_at']?.toString(),
    );
  }

  static String? _emptyToNull(String value) {
    return value.isEmpty ? null : value;
  }
}