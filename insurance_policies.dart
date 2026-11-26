import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/styles.dart';

class InsurancePoliciesPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const InsurancePoliciesPage({super.key, required this.report});

  @override
  State<InsurancePoliciesPage> createState() => _InsurancePoliciesPageState();
}

class _InsurancePoliciesPageState extends State<InsurancePoliciesPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  String get _siteId => widget.report['site_id']?.toString().trim() ?? '';
  final TextEditingController _searchController = TextEditingController();

  static const String _attachmentBucket = 'insurance-policy-attachments';
  static const int _maxFileSize = 10 * 1024 * 1024;

  static const List<String> _policyCategories = [
    'Fire Insurance',
    'Money Insurance',
    'Burglary',
    'Plate Glass',
    'Fidelity Guarantee',
    'Machinery Breakdown',
    'All Risk',
    'Public Liability',
    'Personal Accident',
    'Errors & Omissions',
  ];

  // Expired is calculated from Valid To; only Active / Terminated are editable.
  static const List<String> _policyStatuses = [
    'Active',
    'Terminated',
    'Expired',
  ];
  static const List<String> _editablePolicyStatuses = ['Active', 'Terminated'];

  List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _archivedRecords = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final Set<String> _selectedStatuses = <String>{};

  // Coverage summaries are saved in their original report month. They are
  // displayed only in months covered by Valid From / Valid To; a newer
  // saved summary replaces the older one when its validity begins.
  Map<String, dynamic>? _coverageSummary;
  bool _coverageLoading = true;
  bool _coverageSaving = false;
  bool _editingCoverage = false;
  String? _coverageError;
  final GlobalKey<FormState> _coverageFormKey = GlobalKey<FormState>();
  final TextEditingController _coverageUnderwriterController =
      TextEditingController();
  final TextEditingController _coverageNotesController =
      TextEditingController();
  final TextEditingController _coverageCostController = TextEditingController();
  DateTime? _coverageValidFrom;
  DateTime? _coverageValidTo;

  // Insurance remains a shared policy register. The selected report only
  // controls the display month; it does not create additional policy rows.
  DateTime get _selectedReportMonth {
    final raw = widget.report['report_month'] ?? widget.report['month'];
    final text = raw?.toString().trim() ?? '';
    DateTime? parsed = DateTime.tryParse(text);
    if (parsed == null && RegExp(r'^\d{4}-\d{2}$').hasMatch(text)) {
      parsed = DateTime.tryParse('$text-01');
    }
    final date = parsed ?? DateTime.now();
    return DateTime(date.year, date.month, 1);
  }

  String get _selectedReportId =>
      widget.report['id']?.toString() ?? 'Not provided';

  static const List<String> _monthNames = [
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

  String _monthLabel(DateTime date) =>
      '${_monthNames[date.month - 1]} ${date.year}';

  // Archive placement and policy status belong to the selected report month,
  // including reports prepared for a future month. The last day of that month
  // is the reporting cutoff; today's date must not override that cutoff.
  DateTime get _statusReferenceDate {
    final reportMonth = _selectedReportMonth;
    return DateTime(reportMonth.year, reportMonth.month + 1, 0);
  }

  // Keep the renewal countdown real-time in the current calendar month.
  // Earlier and future reporting months use their selected month-end instead.
  DateTime get _renewalReferenceDate {
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = _selectedReportMonth;
    return selected.year == today.year && selected.month == today.month
        ? today
        : _statusReferenceDate;
  }

  // The policy can appear only from its Valid From reporting month onwards.
  bool _startsAfterSelectedMonth(Map<String, dynamic> record) {
    final validFrom = _parseDate(record['start_date']);
    return validFrom != null &&
        DateTime(validFrom.year, validFrom.month).isAfter(_selectedReportMonth);
  }

  // Expiry archives on the day after Valid To. A formal termination takes
  // effect on its recorded termination date, without altering stored rows.
  DateTime? _automaticArchiveFrom(Map<String, dynamic> record) {
    final validTo = _parseDate(record['end_date']);
    final expiredFrom = validTo == null
        ? null
        : DateTime(validTo.year, validTo.month, validTo.day + 1);
    final terminatedFrom = record['policy_status'] == 'Terminated'
        ? _parseDate(record['termination_date'])
        : null;
    if (terminatedFrom == null) return expiredFrom;
    final effectiveTermination = DateUtils.dateOnly(terminatedFrom);
    if (expiredFrom == null || effectiveTermination.isBefore(expiredFrom)) {
      return effectiveTermination;
    }
    return expiredFrom;
  }

  String _automaticArchiveCause(Map<String, dynamic> record) {
    final validTo = _parseDate(record['end_date']);
    final terminated = record['policy_status'] == 'Terminated'
        ? _parseDate(record['termination_date'])
        : null;
    if (terminated != null &&
        (validTo == null || !terminated.isAfter(validTo))) {
      return 'Terminated';
    }
    return 'Expired';
  }

  String _policyStatus(Map<String, dynamic> record) {
    final terminated = record['policy_status'] == 'Terminated'
        ? _parseDate(record['termination_date'])
        : null;
    final validTo = _parseDate(record['end_date']);
    final reference = _statusReferenceDate;
    if (terminated != null &&
        !DateUtils.dateOnly(terminated).isAfter(reference) &&
        (validTo == null || !terminated.isAfter(validTo))) {
      return 'Terminated';
    }
    if (validTo != null && DateUtils.dateOnly(validTo).isBefore(reference)) {
      return 'Expired';
    }
    return 'Active';
  }

  // A manual archive takes effect only on its actual archive date.
  // Without archived_at, retain legacy manual archives as undated.
  bool _manuallyArchivedAsOf(Map<String, dynamic> record) {
    if (record['is_archived'] != true) return false;
    final archivedAt = _parseDate(record['archived_at']);
    if (archivedAt == null) return true;
    return !DateUtils.dateOnly(
      archivedAt.toLocal(),
    ).isAfter(_statusReferenceDate);
  }

  bool _automaticallyArchivedAsOf(Map<String, dynamic> record) {
    final archiveFrom = _automaticArchiveFrom(record);
    return archiveFrom != null && !archiveFrom.isAfter(_statusReferenceDate);
  }

  bool _inSelectedMonth(Map<String, dynamic> record) =>
      !_startsAfterSelectedMonth(record) &&
      !_manuallyArchivedAsOf(record) &&
      !_automaticallyArchivedAsOf(record);

  // Keep manual archives in the query: they may belong in an older report
  // that predates their actual archive date.
  List<Map<String, dynamic>> get _allPolicies => [
    ..._records,
    ..._archivedRecords,
  ];

  // Status cards reflect policy validity, including expired/terminated rows
  // retained in Archive. Future-dated policies are not counted.
  List<Map<String, dynamic>> get _applicablePolicies => _allPolicies
      .where((record) => !_startsAfterSelectedMonth(record))
      .toList();

  int _countStatus(String status) => _applicablePolicies
      .where((record) => _policyStatus(record) == status)
      .length;

  List<Map<String, dynamic>> get _filteredRecords {
    final query = _searchController.text.trim().toLowerCase();
    return _allPolicies.where((record) {
      final status = _policyStatus(record);
      if (_selectedStatuses.isNotEmpty && !_selectedStatuses.contains(status)) {
        return false;
      }
      final searchable = [
        record['policy_name'],
        record['insurer'],
        record['policy_number'],
        record['policy_type'],
        record['coverage_details'],
        record['policy_status'],
        record['termination_date'],
        record['termination_reason'],
        record['premium_amount'],
        record['sum_insured'],
        record['start_date'],
        record['end_date'],
        record['archive_reason'],
      ].where((value) => value != null).join(' ').toLowerCase();
      return query.isEmpty || searchable.contains(query);
    }).toList();
  }

  List<Map<String, dynamic>> get _visibleThisMonthRecords =>
      _filteredRecords.where(_inSelectedMonth).toList();

  String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';

  // Display-only archive, matching Licences & Regulatory: expired on the day
  // after Valid To or manually archived as of the reporting reference date.
  // One policy appears once; automatic and manual types are distinguished.
  Map<String, List<Map<String, dynamic>>> get _archivedByMonth {
    final grouped = <String, List<Map<String, dynamic>>>{};
    final seen = <String>{};

    for (final record in _filteredRecords) {
      if (_startsAfterSelectedMonth(record)) continue;
      final id = record['id']?.toString() ?? '';
      if (id.isNotEmpty && !seen.add(id)) continue;

      final manual = _manuallyArchivedAsOf(record);
      final autoFrom = _automaticArchiveFrom(record);
      final automatic =
          !manual &&
          autoFrom != null &&
          !autoFrom.isAfter(_statusReferenceDate);
      if (!manual && !automatic) continue;

      final archiveDate = manual
          ? _parseDate(record['archived_at'])?.toLocal()
          : autoFrom;
      final key = archiveDate == null ? 'undated' : _monthKey(archiveDate);
      final cause = _automaticArchiveCause(record);
      (grouped[key] ??= <Map<String, dynamic>>[]).add({
        ...record,
        '_auto_archived': automatic,
        '_auto_archive_cause': automatic ? cause : null,
        '_archive_effective_date': automatic
            ? _dateForDatabase(autoFrom)
            : record['archived_at'],
        '_archive_reason': automatic
            ? cause == 'Terminated'
                  ? 'Policy terminated effective '
                        '${_displayDate(record['termination_date'])}. '
                        '${record['termination_reason'] ?? ''}'
                  : 'Policy expired on ${_displayDate(record['end_date'])}.'
            : record['archive_reason'],
      });
    }

    return grouped;
  }

  // The one-calendar-month renewal window matches Licences & Regulatory.
  DateTime _oneCalendarMonthBefore(DateTime date) {
    final previous = DateTime(date.year, date.month - 1, 1);
    final lastDay = DateTime(date.year, date.month, 0).day;
    return DateTime(
      previous.year,
      previous.month,
      date.day > lastDay ? lastDay : date.day,
    );
  }

  bool _isRenewalDue(Map<String, dynamic> record) {
    final validTo = _parseDate(record['end_date']);
    if (validTo == null ||
        !_inSelectedMonth(record) ||
        _policyStatus(record) != 'Active') {
      return false;
    }
    final expiry = DateUtils.dateOnly(validTo);
    final reference = _renewalReferenceDate;
    return !reference.isBefore(_oneCalendarMonthBefore(expiry)) &&
        !reference.isAfter(expiry);
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

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshSearch);
    _refreshPage();
  }

  @override
  void dispose() {
    _searchController.removeListener(_refreshSearch);
    _searchController.dispose();
    _coverageUnderwriterController.dispose();
    _coverageNotesController.dispose();
    _coverageCostController.dispose();
    super.dispose();
  }

  void _refreshSearch() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant InsurancePoliciesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['id'] != widget.report['id'] ||
        oldWidget.report['site_id'] != widget.report['site_id']) {
      _editingCoverage = false;
      _refreshPage();
    }
  }

  Future<void> _refreshPage() async {
    await Future.wait([_loadRecords(), _loadCoverageSummary()]);
  }

  Future<void> _loadCoverageSummary() async {
    if (!mounted) return;

    final reportId = widget.report['id']?.toString().trim() ?? '';
    final siteId = _siteId;
    if (reportId.isEmpty || siteId.isEmpty) {
      setState(() {
        _coverageSummary = null;
        _coverageLoading = false;
        _coverageError = 'No monthly report or property is selected.';
      });
      return;
    }

    setState(() {
      _coverageLoading = true;
      _coverageError = null;
    });

    try {
      // A coverage summary applies to every reporting month overlapping its
      // Valid From / Valid To period, including earlier months if backdated.
      // A newer saved version takes precedence once its Valid From begins.
      // After that version expires, the older one must not reappear.
      final selectedMonth = _selectedReportMonth;
      final selectedMonthEnd = DateTime(
        selectedMonth.year,
        selectedMonth.month + 1,
        0,
      );
      final result = await _supabase
          .from('monthly_reports')
          .select(
            'id, report_month, insurance_coverage_underwriter, '
            'insurance_coverage_valid_from, insurance_coverage_valid_to, '
            'insurance_coverage_renewal_notes, insurance_coverage_cost',
          )
          .eq('site_id', siteId)
          .order('report_month', ascending: false);

      const coverageFields = [
        'insurance_coverage_underwriter',
        'insurance_coverage_valid_from',
        'insurance_coverage_valid_to',
        'insurance_coverage_renewal_notes',
        'insurance_coverage_cost',
      ];
      final reports = List<Map<String, dynamic>>.from(result);
      Map<String, dynamic>? selectedReport;
      Map<String, dynamic>? effectiveSummary;
      DateTime? latestEffectiveStart;
      DateTime? latestSavedMonth;
      for (final row in reports) {
        if (row['id']?.toString() == reportId) {
          selectedReport = row;
        }
        // Empty report rows are not coverage changes. An explicit clear is
        // stored as an empty underwriter string by Save Summary.
        if (!coverageFields.any((field) => row[field] != null)) continue;

        final savedMonth = _parseDate(row['report_month']);
        final validFrom = _parseDate(row['insurance_coverage_valid_from']);
        // A missing Valid From retains the legacy behavior: effective from
        // the month in which this summary was saved.
        final starts = validFrom ?? savedMonth;
        if (starts == null || starts.isAfter(selectedMonthEnd)) continue;

        // The newest effective coverage period wins. For the same start date,
        // the most recently saved monthly summary wins. Expired replacements
        // must not reveal an older period again.
        if (latestEffectiveStart == null ||
            starts.isAfter(latestEffectiveStart) ||
            (starts.isAtSameMomentAs(latestEffectiveStart) &&
                savedMonth != null &&
                (latestSavedMonth == null ||
                    savedMonth.isAfter(latestSavedMonth)))) {
          effectiveSummary = row;
          latestEffectiveStart = starts;
          latestSavedMonth = savedMonth;
        }
      }

      final validTo = _parseDate(
        effectiveSummary?['insurance_coverage_valid_to'],
      );
      final appliesToSelectedMonth =
          effectiveSummary != null &&
          (validTo == null || !validTo.isBefore(selectedMonth));

      if (!mounted ||
          reportId != widget.report['id']?.toString().trim() ||
          siteId != _siteId) {
        return;
      }

      setState(() {
        // Keep the card and Edit Summary available even when coverage is not
        // applicable to this reporting month; show the usual Not set values.
        _coverageSummary = selectedReport == null
            ? null
            : appliesToSelectedMonth
            ? Map<String, dynamic>.from(effectiveSummary!)
            : <String, dynamic>{'id': reportId};
        _coverageError = selectedReport == null
            ? 'The selected monthly report could not be found or accessed.'
            : null;
        _coverageLoading = false;
      });
    } catch (e) {
      if (!mounted ||
          reportId != widget.report['id']?.toString().trim() ||
          siteId != _siteId) {
        return;
      }
      setState(() {
        _coverageError = 'Unable to load insurance coverage summary: $e';
        _coverageLoading = false;
      });
    }
  }

  void _startCoverageEdit() {
    if (_coverageSaving || _coverageLoading || _coverageError != null) return;
    final summary = _coverageSummary ?? <String, dynamic>{};
    _coverageUnderwriterController.text =
        summary['insurance_coverage_underwriter']?.toString() ?? '';
    _coverageNotesController.text =
        summary['insurance_coverage_renewal_notes']?.toString() ?? '';
    _coverageCostController.text =
        summary['insurance_coverage_cost']?.toString() ?? '';
    _coverageValidFrom = _parseDate(summary['insurance_coverage_valid_from']);
    _coverageValidTo = _parseDate(summary['insurance_coverage_valid_to']);
    setState(() => _editingCoverage = true);
  }

  Future<void> _saveCoverageSummary() async {
    if (_coverageSaving || _coverageLoading) return;
    if (!(_coverageFormKey.currentState?.validate() ?? false)) return;
    if (_coverageValidFrom != null &&
        _coverageValidTo != null &&
        _coverageValidTo!.isBefore(_coverageValidFrom!)) {
      _showMessage('"Valid To" cannot be earlier than "Valid From".');
      return;
    }

    final reportId = widget.report['id']?.toString().trim() ?? '';
    final siteId = _siteId;
    if (reportId.isEmpty || siteId.isEmpty) {
      _showMessage(
        'Cannot save coverage: no monthly report or property selected.',
      );
      return;
    }

    final costText = _coverageCostController.text.trim().replaceAll(',', '');
    final cost = costText.isEmpty ? null : num.tryParse(costText);

    setState(() => _coverageSaving = true);
    try {
      final updated = await _supabase
          .from('monthly_reports')
          .update({
            // Keep an empty-string marker if every field is cleared. This
            // prevents an older summary from reappearing in later months.
            'insurance_coverage_underwriter': _coverageUnderwriterController
                .text
                .trim(),
            'insurance_coverage_valid_from': _dateForDatabase(
              _coverageValidFrom,
            ),
            'insurance_coverage_valid_to': _dateForDatabase(_coverageValidTo),
            'insurance_coverage_renewal_notes': _nullIfEmpty(
              _coverageNotesController.text,
            ),
            'insurance_coverage_cost': cost,
          })
          .eq('id', reportId)
          .eq('site_id', siteId)
          .select(
            'id, insurance_coverage_underwriter, '
            'insurance_coverage_valid_from, insurance_coverage_valid_to, '
            'insurance_coverage_renewal_notes, insurance_coverage_cost',
          );

      if (updated.isEmpty) {
        throw StateError(
          'No summary saved. Check report access and update permissions.',
        );
      }
      if (!mounted ||
          reportId != widget.report['id']?.toString().trim() ||
          siteId != _siteId) {
        return;
      }
      setState(() {
        _editingCoverage = false;
        _coverageError = null;
      });
      // Recalculate validity after saving; a future-dated or expired summary
      // must not appear in a month outside its Valid From / Valid To range.
      await _loadCoverageSummary();
      if (!mounted) return;
      _showMessage('Insurance coverage summary saved successfully.');
    } catch (e) {
      if (mounted) {
        _showMessage('Could not save insurance coverage summary: $e');
      }
    } finally {
      if (mounted) setState(() => _coverageSaving = false);
    }
  }

  Future<void> _loadRecords() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final siteId = _siteId;
    try {
      if (siteId.isEmpty) {
        throw StateError(
          'Open Insurance Policies from a monthly report with a valid property ID.',
        );
      }
      final result = await _supabase
          .from('insurance_policies')
          .select()
          .eq('site_id', siteId)
          .eq('is_archived', false)
          .order('policy_name', ascending: true);
      final archivedResult = await _supabase
          .from('insurance_policies')
          .select()
          .eq('site_id', siteId)
          .eq('is_archived', true)
          .order('policy_name', ascending: true);

      if (!mounted || siteId != _siteId) return;

      setState(() {
        _records = List<Map<String, dynamic>>.from(result);
        _archivedRecords = List<Map<String, dynamic>>.from(archivedResult);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || siteId != _siteId) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // FILE HELPERS
  // ---------------------------------------------------------------------------

  String _contentType(String fileName) {
    switch (fileName.split('.').last.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  Future<List<Map<String, dynamic>>> _fetchAttachments(String policyId) async {
    final result = await _supabase
        .from('insurance_policy_attachments')
        .select()
        .eq('insurance_policy_id', policyId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(result);
  }

  Future<void> _pickFiles({
    required StateSetter setDialogState,
    required List<XFile> selectedFiles,
  }) async {
    try {
      const typeGroup = XTypeGroup(
        label: 'documents',
        extensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      );

      final files = await openFiles(acceptedTypeGroups: [typeGroup]);

      if (!mounted || files.isEmpty) return;

      final validFiles = <XFile>[];

      for (final file in files) {
        final size = await file.length();

        if (size > _maxFileSize) {
          _showMessage('${file.name} exceeds the 10 MB limit.');
          continue;
        }

        validFiles.add(file);
      }

      if (!mounted) return;

      setDialogState(() {
        for (final file in validFiles) {
          final alreadySelected = selectedFiles.any(
            (existing) =>
                existing.name == file.name && existing.path == file.path,
          );

          if (!alreadySelected) selectedFiles.add(file);
        }
      });
    } catch (e) {
      _showMessage('Unable to select attachments: $e');
    }
  }

  Future<void> _uploadAttachments({
    required String policyId,
    required List<XFile> files,
  }) async {
    final failedFiles = <String>[];

    if (_supabase.auth.currentSession?.accessToken == null) {
      throw Exception('Please log in again before uploading attachments.');
    }

    for (final file in files) {
      try {
        final bytes = await file.readAsBytes();

        if (bytes.isEmpty || bytes.length > _maxFileSize) {
          throw Exception('File must be between 1 byte and 10 MB.');
        }

        // The Edge Function validates the policy, file type, authenticated
        // user, Google Drive upload, and database metadata insertion.
        final response = await _supabase.functions.invoke(
          'upload-to-google-drive',
          body: {
            'insurancePolicyId': policyId,
            'reportId': widget.report['id'],
            'fileName': file.name,
            'mimeType': _contentType(file.name),
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
          throw Exception(reason);
        }
      } catch (e) {
        failedFiles.add(file.name);
        debugPrint('Google Drive upload failed for ${file.name}: $e');
      }
    }

    if (failedFiles.isNotEmpty) {
      throw Exception('Failed to upload: ${failedFiles.join(', ')}');
    }
  }

  // ---------------------------------------------------------------------------
  // ATTACHMENT DELETION
  // ---------------------------------------------------------------------------

  bool _isGoogleDriveAttachment(Map<String, dynamic> attachment) {
    final driveId = attachment['google_drive_file_id']?.toString().trim() ?? '';
    final path = attachment['storage_path']?.toString().trim() ?? '';
    return driveId.isNotEmpty || path.startsWith('google-drive/');
  }

  // Returns true when the file was in Google Drive. Removing a Google Drive
  // attachment here unlinks it from this policy but KEEPS the original file.
  // Actual remote Drive deletion requires a separate authenticated backend.
  Future<bool> _deleteAttachment(Map<String, dynamic> attachment) async {
    final attachmentId = attachment['id']?.toString().trim() ?? '';
    final policyId = attachment['insurance_policy_id']?.toString().trim() ?? '';
    final storagePath = attachment['storage_path']?.toString().trim() ?? '';
    final isDrive = _isGoogleDriveAttachment(attachment);

    if (attachmentId.isEmpty || policyId.isEmpty) {
      throw Exception('Attachment or policy ID is missing.');
    }

    // A Storage object (unlike a Google Drive file) must be removed through
    // the Storage API, never by deleting a row in storage.objects.
    if (!isDrive) {
      if (storagePath.isEmpty) {
        throw Exception('Cannot delete a Storage file with no storage path.');
      }
      await _supabase.storage.from(_attachmentBucket).remove([storagePath]);
    }

    try {
      final deleted = await _supabase
          .from('insurance_policy_attachments')
          .delete()
          .eq('id', attachmentId)
          .eq('insurance_policy_id', policyId)
          .select('id');

      if (deleted.isEmpty) {
        throw Exception(
          'Attachment was not removed. Check Delete and Select permissions.',
        );
      }
    } catch (e) {
      if (!isDrive) {
        throw Exception(
          'The Storage file may have been deleted but the attachment record '
          'could not be removed. Refresh and retry. Details: $e',
        );
      }
      rethrow;
    }

    return isDrive;
  }

  Future<bool> _confirmAndDeleteAttachment(
    Map<String, dynamic> attachment,
  ) async {
    final fileName = attachment['file_name']?.toString() ?? 'this attachment';
    final isDrive = _isGoogleDriveAttachment(attachment);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(
          isDrive ? 'Remove Google Drive Attachment?' : 'Delete Attachment?',
          style: const TextStyle(
            color: AppColors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          isDrive
              ? 'Remove "$fileName" from this policy? The original file '
                    'will remain in Google Drive. This action cannot be undone.'
              : 'Permanently delete "$fileName" from Supabase Storage and '
                    'remove it from this policy? This cannot be undone.',
          style: const TextStyle(color: AppColors.black),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isDrive ? 'Remove from Policy' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return false;

    try {
      final wasDrive = await _deleteAttachment(attachment);
      if (!mounted) return false;

      _showMessage(
        wasDrive
            ? 'Attachment removed from policy. Original file kept in Google Drive.'
            : 'Attachment and stored file deleted.',
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      _showMessage('Could not remove "$fileName": $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // ATTACHMENT VIEWER
  // ---------------------------------------------------------------------------

  Future<void> _showAttachments(Map<String, dynamic> record) async {
    final policyId = record['id'].toString();

    try {
      var attachments = await _fetchAttachments(policyId);

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> refreshAttachments() async {
                try {
                  final latest = await _fetchAttachments(policyId);
                  setDialogState(() => attachments = latest);
                } catch (e) {
                  if (mounted) {
                    _showMessage('Could not refresh attachments: $e');
                  }
                }
              }

              return AlertDialog(
                backgroundColor: AppColors.white,
                surfaceTintColor: Colors.transparent,
                title: const Text(
                  'Policy Attachments',
                  style: TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                content: SizedBox(
                  width: 500,
                  child: attachments.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'No attachments have been uploaded for this policy.',
                            style: TextStyle(color: AppColors.grey),
                          ),
                        )
                      : SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: attachments.map((attachment) {
                              final fileName =
                                  attachment['file_name']?.toString() ??
                                  'Unnamed file';
                              final fileSize = attachment['file_size_bytes'];

                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.insert_drive_file_outlined,
                                  color: AppColors.red,
                                ),
                                title: Text(
                                  fileName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.black,
                                  ),
                                ),
                                subtitle: fileSize == null
                                    ? null
                                    : Text(
                                        _formatFileSize(fileSize),
                                        style: const TextStyle(
                                          color: AppColors.grey,
                                          fontSize: 12,
                                        ),
                                      ),
                                trailing: Wrap(
                                  spacing: 0,
                                  children: [
                                    IconButton(
                                      tooltip: 'Open attachment',
                                      icon: const Icon(
                                        Icons.open_in_new,
                                        color: AppColors.red,
                                      ),
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        _openAttachment(attachment);
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Delete attachment',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: AppColors.red,
                                      ),
                                      onPressed: () async {
                                        final deleted =
                                            await _confirmAndDeleteAttachment(
                                              attachment,
                                            );

                                        if (deleted) {
                                          await refreshAttachments();
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not load policy attachments: $e');
    }
  }

  Future<void> _openAttachment(Map<String, dynamic> attachment) async {
    try {
      final storagePath = attachment['storage_path']?.toString().trim() ?? '';
      final savedDriveId =
          attachment['google_drive_file_id']?.toString().trim() ?? '';

      // Google Drive attachments must open using their individual file IDs,
      // not the parent folder URL or a Supabase Storage signed URL.
      if (savedDriveId.isNotEmpty || storagePath.startsWith('google-drive/')) {
        var fileId = savedDriveId;
        if (fileId.isEmpty) {
          final path = storagePath.substring('google-drive/'.length);
          final pathParts = path
              .split('/')
              .where((part) => part.isNotEmpty)
              .toList();
          if (pathParts.isNotEmpty) fileId = pathParts.last;
        }

        // Prevent malformed metadata from opening an unrelated URL.
        if (!RegExp(r'^[A-Za-z0-9_-]{10,}$').hasMatch(fileId)) {
          _showMessage(
            'This attachment has no valid Google Drive file ID. '
            'Please check its saved attachment record.',
          );
          return;
        }

        final url = Uri.https('drive.google.com', '/file/d/$fileId/view');
        final launched = await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );

        if (!launched && mounted) {
          _showMessage('Unable to open the Google Drive attachment.');
        }
        return;
      }

      // Existing Supabase Storage attachments continue to use signed URLs.
      if (storagePath.isEmpty) {
        _showMessage('The attachment has no valid storage path.');
        return;
      }

      final url = await _supabase.storage
          .from(_attachmentBucket)
          .createSignedUrl(storagePath, 60);

      final launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );

      if (!launched && mounted) {
        _showMessage('Unable to open the attachment.');
      }
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not open the attachment: $e');
    }
  }

  static String _formatFileSize(dynamic value) {
    final bytes = int.tryParse(value.toString());

    if (bytes == null || bytes < 0) return 'Unknown file size';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------------------
  // ADD / EDIT
  // ---------------------------------------------------------------------------

  Future<void> _openForm({Map<String, dynamic>? record}) async {
    if (_saving) return;

    final isEditing = record != null;
    final formKey = GlobalKey<FormState>();
    final selectedFiles = <XFile>[];

    final policyController = TextEditingController(
      text: record?['policy_name']?.toString() ?? '',
    );
    final insurerController = TextEditingController(
      text: record?['insurer']?.toString() ?? '',
    );
    final policyNumberController = TextEditingController(
      text: record?['policy_number']?.toString() ?? '',
    );
    final coverageController = TextEditingController(
      text: record?['coverage_details']?.toString() ?? '',
    );
    final premiumController = TextEditingController(
      text: record?['premium_amount']?.toString() ?? '',
    );
    final sumInsuredController = TextEditingController(
      text: record?['sum_insured']?.toString() ?? '',
    );
    final archiveReasonController = TextEditingController();
    final terminationReasonController = TextEditingController(
      text: record?['termination_reason']?.toString() ?? '',
    );
    bool archiveSelected = false;

    // Load existing attachments for inline display in the edit form.
    List<Map<String, dynamic>> existingAttachments = [];
    String? attachmentLoadError;

    if (isEditing) {
      try {
        existingAttachments = await _fetchAttachments(record['id'].toString());
      } catch (e) {
        attachmentLoadError = e.toString();
      }

      if (!mounted) {
        policyController.dispose();
        insurerController.dispose();
        policyNumberController.dispose();
        coverageController.dispose();
        premiumController.dispose();
        sumInsuredController.dispose();
        archiveReasonController.dispose();
        terminationReasonController.dispose();
        return;
      }
    }

    DateTime? validFrom = _parseDate(record?['start_date']);
    DateTime? validTo = _parseDate(record?['end_date']);

    String policyStatus = record?['policy_status']?.toString() == 'Terminated'
        ? 'Terminated'
        : 'Active';
    DateTime? terminationDate = _parseDate(record?['termination_date']);

    String selectedCategory =
        _policyCategories.contains(policyController.text.trim())
        ? policyController.text.trim()
        : '';

    try {
      final result = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> refreshInlineAttachments() async {
                try {
                  final latest = await _fetchAttachments(
                    record!['id'].toString(),
                  );

                  setDialogState(() {
                    existingAttachments = latest;
                    attachmentLoadError = null;
                  });
                } catch (e) {
                  setDialogState(() {
                    attachmentLoadError = e.toString();
                  });
                }
              }

              return AlertDialog(
                backgroundColor: AppColors.white,
                surfaceTintColor: Colors.transparent,
                title: Text(
                  isEditing ? 'Edit Insurance Policy' : 'Add Insurance Policy',
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                    child: Form(
                      key: formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'POLICY DETAILS',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          DropdownButtonFormField<String>(
                            initialValue: selectedCategory.isEmpty
                                ? null
                                : selectedCategory,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Select a Policy Category',
                              helperText:
                                  'Choose a suggested category or enter a custom policy below.',
                            ),
                            items: _policyCategories.map((category) {
                              return DropdownMenuItem<String>(
                                value: category,
                                child: Text(category),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() {
                                selectedCategory = value;
                                policyController.text = value;
                              });
                            },
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: policyController,
                            decoration: const InputDecoration(
                              labelText: 'Policy *',
                              hintText:
                                  'Choose a category above or type a custom policy',
                              helperText:
                                  'This field accepts predefined and custom policy names.',
                            ),
                            onChanged: (value) {
                              setDialogState(() {
                                selectedCategory =
                                    _policyCategories.contains(value.trim())
                                    ? value.trim()
                                    : '';
                              });
                            },
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Please enter a policy name.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: insurerController,
                            decoration: const InputDecoration(
                              labelText: 'Underwriter',
                              hintText: 'Enter the insurance underwriter',
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: policyNumberController,
                            decoration: const InputDecoration(
                              labelText: 'Policy Number',
                              hintText: 'Enter the policy reference number',
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: coverageController,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Coverage Details',
                              hintText: 'Optional coverage notes or details',
                              alignLabelWithHint: true,
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Divider(),
                          const SizedBox(height: 12),
                          const Text(
                            'POLICY VALIDITY',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _dateField(
                            context: context,
                            label: 'Valid From',
                            value: validFrom,
                            onChanged: (value) {
                              setDialogState(() => validFrom = value);
                            },
                          ),
                          const SizedBox(height: 14),
                          _dateField(
                            context: context,
                            label: 'Valid To',
                            value: validTo,
                            onChanged: (value) {
                              setDialogState(() => validTo = value);
                            },
                          ),
                          const SizedBox(height: 22),
                          const Divider(),
                          const SizedBox(height: 12),
                          const Text(
                            'FINANCIAL DETAILS',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: premiumController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Premium (RM)',
                              hintText: 'e.g. 1250.00',
                            ),
                            validator: _validateAmount,
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: sumInsuredController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Sum Insured (RM)',
                              hintText: 'e.g. 500000.00',
                            ),
                            validator: _validateAmount,
                          ),
                          const SizedBox(height: 22),
                          const Divider(),
                          const SizedBox(height: 12),
                          const Text(
                            'POLICY STATUS',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Expired is calculated automatically from Valid To.',
                            style: TextStyle(
                              color: AppColors.grey,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 14),
                          DropdownButtonFormField<String>(
                            initialValue: policyStatus,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Policy Status *',
                            ),
                            items: _editablePolicyStatuses.map((status) {
                              return DropdownMenuItem<String>(
                                value: status,
                                child: Text(status),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => policyStatus = value);
                              }
                            },
                          ),
                          if (policyStatus == 'Terminated') ...[
                            const SizedBox(height: 14),
                            _dateField(
                              context: context,
                              label: 'Termination Date *',
                              value: terminationDate,
                              onChanged: (value) =>
                                  setDialogState(() => terminationDate = value),
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: terminationReasonController,
                              minLines: 2,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                labelText: 'Termination Reason *',
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) {
                                if (policyStatus != 'Terminated') return null;
                                return value == null || value.trim().isEmpty
                                    ? 'Please enter a termination reason.'
                                    : null;
                              },
                            ),
                          ],
                          const SizedBox(height: 22),
                          const Divider(),
                          const SizedBox(height: 12),
                          const Text(
                            'POLICY ATTACHMENTS',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Attach policy documents, certificates or supporting files. '
                            'Maximum 10 MB per file.',
                            style: TextStyle(
                              color: AppColors.grey,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),

                          // Existing attachments are displayed inline here.
                          if (isEditing) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Existing Attachments',
                                    style: TextStyle(
                                      color: AppColors.black,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Refresh attachments',
                                  onPressed: refreshInlineAttachments,
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                            if (attachmentLoadError != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  'Could not load attachments: '
                                  '$attachmentLoadError',
                                  style: const TextStyle(
                                    color: AppColors.red,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            else if (existingAttachments.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No existing attachments.',
                                  style: TextStyle(
                                    color: AppColors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            else
                              ...existingAttachments.map((attachment) {
                                final fileName =
                                    attachment['file_name']?.toString() ??
                                    'Unnamed file';
                                final fileSize = attachment['file_size_bytes'];

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  decoration: BoxDecoration(
                                    color: AppColors.white,
                                    border: Border.all(color: AppColors.border),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: ListTile(
                                    dense: true,
                                    leading: const Icon(
                                      Icons.insert_drive_file_outlined,
                                      color: AppColors.red,
                                    ),
                                    title: Text(
                                      fileName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.black,
                                        fontSize: 13,
                                      ),
                                    ),
                                    subtitle: fileSize == null
                                        ? null
                                        : Text(
                                            _formatFileSize(fileSize),
                                            style: const TextStyle(
                                              color: AppColors.grey,
                                              fontSize: 11,
                                            ),
                                          ),
                                    trailing: Wrap(
                                      spacing: 0,
                                      children: [
                                        IconButton(
                                          tooltip: 'Open attachment',
                                          icon: const Icon(
                                            Icons.open_in_new,
                                            size: 20,
                                            color: AppColors.red,
                                          ),
                                          onPressed: () =>
                                              _openAttachment(attachment),
                                        ),
                                        IconButton(
                                          tooltip: 'Delete attachment',
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 20,
                                            color: AppColors.red,
                                          ),
                                          onPressed: () async {
                                            final deleted =
                                                await _confirmAndDeleteAttachment(
                                                  attachment,
                                                );

                                            if (deleted) {
                                              await refreshInlineAttachments();
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                          ],

                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _saving
                                ? null
                                : () => _pickFiles(
                                    setDialogState: setDialogState,
                                    selectedFiles: selectedFiles,
                                  ),
                            icon: const Icon(Icons.attach_file),
                            label: const Text('Select Files'),
                          ),
                          if (selectedFiles.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            ...selectedFiles.asMap().entries.map((entry) {
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
                                    setDialogState(() {
                                      selectedFiles.removeAt(index);
                                    });
                                  },
                                ),
                              );
                            }),
                          ],
                          if (isEditing) ...[
                            const SizedBox(height: 20),
                            const Divider(),
                            const SizedBox(height: 10),
                            const Text(
                              'RECORD MANAGEMENT',
                              style: TextStyle(
                                color: AppColors.red,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Checkbox(
                                  // A circular check control, matching the
                                  // approved preview rather than a square.
                                  shape: const CircleBorder(),
                                  activeColor: AppColors.red,
                                  value: archiveSelected,
                                  onChanged: (value) => setDialogState(
                                    () => archiveSelected = value ?? false,
                                  ),
                                ),
                                InkWell(
                                  onTap: () => setDialogState(
                                    () => archiveSelected = !archiveSelected,
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 12,
                                    ),
                                    child: Text('Archive'),
                                  ),
                                ),
                              ],
                            ),
                            if (archiveSelected) ...[
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: archiveReasonController,
                                minLines: 2,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                  labelText: 'Reason for Archiving *',
                                  hintText: 'Enter reason for archiving',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) {
                                  if (!archiveSelected) return null;
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Please enter a reason for archiving.';
                                  }
                                  return null;
                                },
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
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.red,
                      foregroundColor: AppColors.white,
                    ),
                    onPressed: () {
                      if (!formKey.currentState!.validate()) return;
                      // The upload edge function may reject archived policies.
                      // Save newly selected files before archiving the record.
                      if (archiveSelected && selectedFiles.isNotEmpty) {
                        _showMessage(
                          'Save newly selected attachments before archiving '
                          'this policy. Existing attachments are preserved.',
                        );
                        return;
                      }

                      if (validFrom != null &&
                          validTo != null &&
                          validTo!.isBefore(validFrom!)) {
                        _showMessage(
                          '"Valid To" cannot be earlier than "Valid From".',
                        );
                        return;
                      }

                      if (policyStatus == 'Terminated') {
                        if (terminationDate == null) {
                          _showMessage('Please select the termination date.');
                          return;
                        }
                        if (validFrom != null &&
                            terminationDate!.isBefore(validFrom!)) {
                          _showMessage(
                            'Termination cannot predate Valid From.',
                          );
                          return;
                        }
                        if (validTo != null &&
                            terminationDate!.isAfter(validTo!)) {
                          _showMessage('Termination cannot be after Valid To.');
                          return;
                        }
                      }
                      Navigator.of(dialogContext).pop(true);
                    },
                    child: Text(
                      archiveSelected
                          ? 'Archive Policy'
                          : (isEditing ? 'Save Changes' : 'Add Policy'),
                    ),
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
          policyName: policyController.text,
          insurer: insurerController.text,
          policyNumber: policyNumberController.text,
          coverageDetails: coverageController.text,
          validFrom: validFrom,
          validTo: validTo,
          policyStatus: policyStatus,
          terminationDate: policyStatus == 'Terminated'
              ? terminationDate
              : null,
          terminationReason: policyStatus == 'Terminated'
              ? terminationReasonController.text
              : null,
          premiumAmount: premiumController.text,
          sumInsured: sumInsuredController.text,
          files: List<XFile>.from(selectedFiles),
          archiveReason: isEditing && archiveSelected
              ? archiveReasonController.text.trim()
              : null,
        );
      }
    } finally {
      policyController.dispose();
      insurerController.dispose();
      policyNumberController.dispose();
      coverageController.dispose();
      premiumController.dispose();
      sumInsuredController.dispose();
      archiveReasonController.dispose();
      terminationReasonController.dispose();
    }
  }

  static String? _validateAmount(String? value) {
    if (value == null || value.trim().isEmpty) return null;

    final amount = num.tryParse(value.trim());

    if (amount == null || amount < 0) {
      return 'Enter a valid non-negative amount.';
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // SAVE
  // ---------------------------------------------------------------------------

  Future<void> _saveRecord({
    required Map<String, dynamic>? record,
    required String policyName,
    required String insurer,
    required String policyNumber,
    required String coverageDetails,
    required DateTime? validFrom,
    required DateTime? validTo,
    required String policyStatus,
    required DateTime? terminationDate,
    required String? terminationReason,
    required String? premiumAmount,
    required String? sumInsured,
    required List<XFile> files,
    String? archiveReason,
  }) async {
    final premium = _parseAmount(premiumAmount);
    final insured = _parseAmount(sumInsured);

    if (premiumAmount != null &&
        premiumAmount.trim().isNotEmpty &&
        premium == null) {
      _showMessage('Enter a valid premium amount.');
      return;
    }

    if (sumInsured != null && sumInsured.trim().isNotEmpty && insured == null) {
      _showMessage('Enter a valid sum insured amount.');
      return;
    }
    if (archiveReason != null &&
        (record == null || archiveReason.trim().isEmpty)) {
      _showMessage('A saved policy and an archive reason are required.');
      return;
    }

    final data = <String, dynamic>{
      'policy_name': policyName.trim(),
      'insurer': _nullIfEmpty(insurer),
      'policy_number': _nullIfEmpty(policyNumber),
      'coverage_details': _nullIfEmpty(coverageDetails),
      'start_date': _dateForDatabase(validFrom),
      'end_date': _dateForDatabase(validTo),
      'premium_amount': premium,
      'sum_insured': insured,
      'policy_status': policyStatus,
      'termination_date': _dateForDatabase(terminationDate),
      'termination_reason': policyStatus == 'Terminated'
          ? _nullIfEmpty(terminationReason ?? '')
          : null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (archiveReason != null) {
      data.addAll({
        'is_archived': true,
        'archived_at': DateTime.now().toUtc().toIso8601String(),
        'archive_reason': archiveReason.trim(),
      });
    }

    setState(() => _saving = true);

    try {
      late final String policyId;

      if (_siteId.isEmpty) {
        _showMessage('Cannot save policy: no property is selected.');
        return;
      }

      if (record != null) {
        final changed = await _supabase
            .from('insurance_policies')
            .update(data)
            .eq('id', record['id'].toString())
            .eq('site_id', _siteId)
            .select('id');
        if (changed.isEmpty) {
          throw StateError('No policy updated. Check your permissions.');
        }
        policyId = record['id'].toString();
      } else {
        final saved = await _supabase
            .from('insurance_policies')
            .insert({
              ...data,
              // Preserve compatibility with the old renewal-progress column
              // until other reporting consumers have been migrated.
              'renewal_status': 'Pending',
              'site_id': _siteId,
            })
            .select('id')
            .single();

        policyId = saved['id'].toString();
      }

      var uploadMessage = '';

      if (files.isNotEmpty) {
        try {
          await _uploadAttachments(policyId: policyId, files: files);
          uploadMessage = ' ${files.length} attachment(s) uploaded.';
        } catch (e) {
          uploadMessage = ' Policy saved, but some attachments failed: $e';
        }
      }

      if (!mounted) return;

      await _loadRecords();
      if (!mounted) return;

      _showMessage(
        (archiveReason != null
                ? 'Insurance policy archived successfully.'
                : record == null
                ? 'Insurance policy added successfully.'
                : 'Insurance policy updated successfully.') +
            uploadMessage,
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not save the insurance policy: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // RESTORE FROM ARCHIVED RECORDS
  // ---------------------------------------------------------------------------

  Future<void> _restorePolicy(Map<String, dynamic> record) async {
    if (_saving || !mounted) return;
    final policyId = record['id']?.toString();
    if (policyId == null || policyId.isEmpty) return;
    if (_siteId.isEmpty) {
      _showMessage('Cannot restore: no property is selected.');
      return;
    }

    // Expired or terminated policies need valid coverage and Active status;
    // clearing a manual archive flag alone is not sufficient.
    final archiveFrom = _automaticArchiveFrom(record);
    final expiredNow =
        archiveFrom != null &&
        !archiveFrom.isAfter(DateUtils.dateOnly(DateTime.now()));
    if (record['is_archived'] == true && expiredNow) {
      final renewFirst = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('Resolve Status Before Restoring'),
          content: const Text(
            'This manually archived policy is expired or terminated. '
            'Update Valid To and/or change Policy Status to Active first. '
            'Then choose Restore again to clear the manual archive flag.',
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
              child: const Text('Edit Policy'),
            ),
          ],
        ),
      );
      if (renewFirst == true && mounted) await _openForm(record: record);
      return;
    }

    if (record['is_archived'] == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('Restore Insurance Policy?'),
          content: Text(
            'Restore "${record['policy_name']}" from manual archiving? '
            'The saved Valid From and Valid To dates will remain unchanged.',
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
        final updated = await _supabase
            .from('insurance_policies')
            .update({
              'is_archived': false,
              'archived_at': null,
              'archive_reason': null,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', policyId)
            .eq('site_id', _siteId)
            .eq('is_archived', true)
            .select('id');
        if (updated.isEmpty) {
          throw StateError('No policy restored. Check your permissions.');
        }
        if (!mounted) return;
        await _loadRecords();
        if (mounted) {
          _showMessage('Insurance policy restored to This Month.');
        }
      } catch (e) {
        if (mounted) _showMessage('Could not restore policy: $e');
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }

    // Automatic expiry is a view classification. There is no manual archive
    // flag to clear: renew dates in the existing policy edit form instead.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Renew Expired Insurance Policy'),
        content: Text(
          'Update Valid To and/or change Policy Status to Active for '
          '"${record['policy_name']}". The policy will return to This Month '
          'when its dates and status are valid. Its ID and attachments remain.',
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
            child: const Text('Edit Policy'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _openForm(record: record);
  }

  // ---------------------------------------------------------------------------
  // DELETE POLICY (WITH ATTACHMENT LINK CLEANUP)
  // ---------------------------------------------------------------------------

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    if (_saving || !mounted) return;
    final policyId = record['id']?.toString().trim() ?? '';
    if (policyId.isEmpty) {
      _showMessage('Cannot delete a record with no valid policy ID.');
      return;
    }

    // Show the attachment count for informed consent, but DO NOT block
    // policy deletion just because attachments exist.
    late final List<Map<String, dynamic>> attachments;
    try {
      attachments = await _fetchAttachments(policyId);
    } catch (e) {
      if (mounted) _showMessage('Cannot verify linked attachments: $e');
      return;
    }
    if (!mounted) return;

    final attachmentCount = attachments.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Delete Insurance Policy?'),
        content: Text(
          'Permanently delete "${record['policy_name']}"? '
          '${attachmentCount == 0 ? '' : 'Its $attachmentCount attachment link(s) will be removed automatically. '}'
          'The original files in Google Drive or Supabase Storage will be kept. '
          'The policy and its links cannot be restored from this screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete Policy'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      // DB function removes attachment metadata and parent policy atomically.
      // It is SECURITY INVOKER: existing RLS permissions remain in force.
      final deleted = await _supabase.rpc(
        'delete_insurance_policy_with_attachments',
        params: {'p_policy_id': policyId},
      );
      if (deleted != true) {
        throw Exception('The delete transaction was not confirmed.');
      }

      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;
      _showMessage(
        attachmentCount == 0
            ? 'Insurance policy deleted.'
            : 'Insurance policy and $attachmentCount attachment link(s) removed. '
                  'Original cloud files have been retained.',
      );
    } catch (e) {
      if (mounted) _showMessage('Could not delete policy: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // DATE FIELD
  // ---------------------------------------------------------------------------

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

        if (selected != null) onChanged(selected);
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
          value == null ? 'Not selected' : _formatDate(value),
          style: TextStyle(
            color: value == null ? AppColors.grey : AppColors.black,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PAGE LAYOUT
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Insurance Policies'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving || _coverageSaving
                ? null
                : _refreshPage,
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
        label: const Text('Add Policy'),
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
                'Unable to load insurance policies.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
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
      );
    }

    final current = _visibleThisMonthRecords;
    return RefreshIndicator(
      onRefresh: _refreshPage,
      color: AppColors.red,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSummary(),
          const SizedBox(height: 24),
          _buildCoverageStatus(),
          const SizedBox(height: 24),
          _buildSearchAndFilters(),
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'This Month',
                  style: TextStyle(
                    color: AppColors.black,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${current.length} record${current.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: AppColors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (current.isEmpty)
            _buildEmptyState()
          else
            ...current.asMap().entries.map(
              (e) => _buildRecordCard(e.value, number: e.key + 1),
            ),
          const SizedBox(height: 24),
          _buildArchivedSection(),
        ],
      ),
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
            'Insurance Policies',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthLabel(_selectedReportMonth)}'
            ' • Report ID: $_selectedReportId',
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
                'Total Policies',
                _applicablePolicies.length,
                Icons.policy_outlined,
                AppColors.red,
                onTap: () => setState(() => _selectedStatuses.clear()),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Active',
                    _countStatus('Active'),
                    Icons.verified_outlined,
                    const Color(0xFF22683D),
                    onTap: () => _toggleStatus('Active'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Terminated',
                    _countStatus('Terminated'),
                    Icons.block_outlined,
                    AppColors.red,
                    onTap: () => _toggleStatus('Terminated'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _summaryCard(
                    'Expired',
                    _countStatus('Expired'),
                    Icons.warning_amber_outlined,
                    const Color(0xFF966400),
                    onTap: () => _toggleStatus('Expired'),
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
    VoidCallback? onTap,
  }) {
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
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
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
                child: Icon(icon, color: accent, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
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
      ),
    );
  }

  // 9.3 is a monthly-report summary, separate from individual policies.
  Widget _buildCoverageStatus() {
    final summary = _coverageSummary ?? <String, dynamic>{};

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Insurance Coverage Status',
                      style: TextStyle(
                        color: AppColors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
              if (!_editingCoverage &&
                  !_coverageLoading &&
                  _coverageError == null)
                TextButton.icon(
                  onPressed: _coverageSaving ? null : _startCoverageEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
            ],
          ),
          if (_coverageLoading) ...[
            const SizedBox(height: 20),
            const Center(
              child: CircularProgressIndicator(color: AppColors.red),
            ),
          ] else if (_coverageError != null) ...[
            const SizedBox(height: 12),
            Text(
              _coverageError!,
              style: const TextStyle(color: AppColors.red, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loadCoverageSummary,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
            ),
          ] else if (_editingCoverage) ...[
            const SizedBox(height: 18),
            Form(
              key: _coverageFormKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _coverageUnderwriterController,
                    enabled: !_coverageSaving,
                    decoration: const InputDecoration(
                      labelText: 'Underwriter',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final dateWidth = constraints.maxWidth >= 460
                          ? (constraints.maxWidth - 12) / 2
                          : constraints.maxWidth;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: dateWidth,
                            child: _dateField(
                              context: context,
                              label: 'Valid From',
                              value: _coverageValidFrom,
                              onChanged: (date) =>
                                  setState(() => _coverageValidFrom = date),
                            ),
                          ),
                          SizedBox(
                            width: dateWidth,
                            child: _dateField(
                              context: context,
                              label: 'Valid To',
                              value: _coverageValidTo,
                              onChanged: (date) =>
                                  setState(() => _coverageValidTo = date),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _coverageNotesController,
                    enabled: !_coverageSaving,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Renewal Notes',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _coverageCostController,
                    enabled: !_coverageSaving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Cost (RM)',
                      hintText: 'e.g. 84939.25',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final text = (value ?? '').trim().replaceAll(',', '');
                      if (text.isEmpty) return null;
                      final parsed = num.tryParse(text);
                      return parsed == null || parsed < 0
                          ? 'Enter a valid non-negative cost.'
                          : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _coverageSaving
                            ? null
                            : () => setState(() => _editingCoverage = false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.red,
                          foregroundColor: AppColors.white,
                        ),
                        onPressed: _coverageSaving
                            ? null
                            : _saveCoverageSummary,
                        child: Text(
                          _coverageSaving ? 'Saving...' : 'Save Summary',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            _coverageInfoBox(
              'Underwriter',
              summary['insurance_coverage_underwriter'],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final dateWidth = constraints.maxWidth >= 460
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: dateWidth,
                      child: _coverageInfoBox(
                        'Valid From',
                        _displayDate(summary['insurance_coverage_valid_from']),
                      ),
                    ),
                    SizedBox(
                      width: dateWidth,
                      child: _coverageInfoBox(
                        'Valid To',
                        _displayDate(summary['insurance_coverage_valid_to']),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Renewal Notes',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              _hasText(summary['insurance_coverage_renewal_notes'])
                  ? summary['insurance_coverage_renewal_notes'].toString()
                  : 'No notes',
              style: const TextStyle(color: AppColors.black, fontSize: 13),
            ),
            const Divider(height: 26),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Cost (RM)',
                    style: TextStyle(
                      color: AppColors.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _formatMoney(
                    summary['insurance_coverage_cost'],
                  ).replaceFirst('RM ', 'RM'),
                  style: const TextStyle(
                    color: AppColors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _coverageInfoBox(String label, dynamic value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.grey, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            _hasText(value) ? value.toString() : 'Not set',
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

  Widget _buildSearchAndFilters() {
    final statuses = _policyStatuses
        .where((status) => _selectedStatuses.contains(status))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search policy, underwriter or policy number...',
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: _searchController.clear,
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
          runSpacing: 6,
          children: [
            const Text(
              'Showing:',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
            if (statuses.isEmpty)
              const Text(
                'All statuses',
                style: TextStyle(color: AppColors.black, fontSize: 12),
              )
            else ...[
              for (final status in statuses)
                InkWell(
                  onTap: () => _toggleStatus(status),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      border: Border.all(color: const Color(0xFFD8B5B0)),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      status,
                      style: const TextStyle(
                        color: Color(0xFF665552),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              TextButton.icon(
                onPressed: () => setState(() => _selectedStatuses.clear()),
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Clear filter'),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
              ),
            ],
          ],
        ),
      ],
    );
  }

  // Like Licences & Regulatory, no separate website History section is
  // shown. Past/expired policy periods are retained under Archived Records.

  Widget _buildArchivedSection() {
    final grouped = _archivedByMonth;
    final months = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'undated') return 1;
        if (b == 'undated') return -1;
        return b.compareTo(a);
      });
    final count = grouped.values.fold<int>(
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
                'Archived Records',
                style: TextStyle(
                  color: AppColors.black,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text(
              '$count record${count == 1 ? '' : 's'}',
              style: const TextStyle(
                color: AppColors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (months.isEmpty)
          _buildEmptyArchiveState()
        else
          for (final key in months)
            Container(
              key: ValueKey('insurance-archived-$key'),
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
                  horizontal: 16,
                  vertical: 6,
                ),
                title: Text(
                  key == 'undated'
                      ? 'Date not recorded'
                      : _monthLabel(DateTime.parse('$key-01')),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '${grouped[key]!.length} policy record(s)',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: grouped[key]!
                    .asMap()
                    .entries
                    .map(
                      (entry) => _buildRecordCard(
                        entry.value,
                        number: entry.key + 1,
                        archivedView: true,
                      ),
                    )
                    .toList(),
              ),
            ),
      ],
    );
  }

  Widget _buildEmptyArchiveState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: const Text(
        'No archived insurance policies found.',
        style: TextStyle(color: AppColors.grey),
      ),
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
      child: const Column(
        children: [
          Icon(Icons.policy_outlined, size: 42, color: AppColors.red),
          SizedBox(height: 12),
          Text(
            'No insurance policies found',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
              fontSize: 17,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Add a policy or adjust your search and status filters.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.grey, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(
    Map<String, dynamic> record, {
    required int number,
    bool archivedView = false,
  }) {
    final automaticallyArchived = record['_auto_archived'] == true;
    final status = _policyStatus(record);
    final accent = archivedView ? AppColors.grey : _statusColor(status);
    final validTo = _parseDate(record['end_date']);
    final daysToExpiry = validTo == null
        ? null
        : DateUtils.dateOnly(validTo).difference(_renewalReferenceDate).inDays;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
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
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record['policy_name']?.toString() ?? 'Untitled policy',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_hasText(record['insurer'])) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Underwriter: ${record['insurer']}',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (_hasText(record['policy_number'])) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Policy No.: ${record['policy_number']}',
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
              Flexible(
                child: Align(
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
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _dateDetail('Valid From', record['start_date']),
              _dateDetail('Valid To', record['end_date']),
            ],
          ),
          if (!archivedView &&
              daysToExpiry != null &&
              _isRenewalDue(record)) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.event_outlined,
                  color: AppColors.red,
                  size: 17,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    daysToExpiry == 0
                        ? 'Expires today'
                        : 'Renewal due: policy expires in $daysToExpiry day(s)',
                    style: const TextStyle(
                      color: AppColors.red,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (status == 'Terminated') ...[
            const SizedBox(height: 12),
            _detail(
              'Termination Date',
              _displayDate(record['termination_date']),
            ),
            if (_hasText(record['termination_reason']))
              _detail('Termination Reason', record['termination_reason']),
          ],
          if (_hasText(record['coverage_details'])) ...[
            const SizedBox(height: 12),
            _detail(
              'Coverage Details',
              record['coverage_details'],
              wrapDescription: true,
            ),
          ],
          const SizedBox(height: 8),
          _detail('Premium (RM)', _formatMoney(record['premium_amount'])),
          _detail('Sum Insured (RM)', _formatMoney(record['sum_insured'])),
          if (archivedView) ...[
            _detail(
              'Archive Type',
              automaticallyArchived ? 'Automatic' : 'Manual',
            ),
            _detail(
              automaticallyArchived ? 'Archived From' : 'Date Archived',
              _displayDate(
                record['_archive_effective_date'] ?? record['archived_at'],
              ),
            ),
            if (_hasText(record['_archive_reason'] ?? record['archive_reason']))
              _detail(
                'Archive Reason',
                record['_archive_reason'] ?? record['archive_reason'],
              ),
          ],
          const Divider(height: 22),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 4,
              children: [
                if (archivedView)
                  TextButton.icon(
                    onPressed: _saving ? null : () => _restorePolicy(record),
                    icon: const Icon(Icons.restore_outlined, size: 18),
                    label: const Text('Restore'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  )
                else ...[
                  TextButton.icon(
                    onPressed: _saving ? null : () => _showAttachments(record),
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: const Text('Attachments'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Compact boxed dates match Licences & Regulatory.
  Widget _dateDetail(String label, dynamic value) {
    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.grey, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            _displayDate(value),
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // Shared two-column alignment; long coverage text wraps naturally to
  // two or more lines, but is never cut off.
  Widget _detail(String label, dynamic value, {bool wrapDescription = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.grey,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  // Narrow the description on wide cards so the sentence
                  // wraps (normally around two lines). On narrow screens,
                  // use all available width and allow additional lines.
                  maxWidth: wrapDescription ? 540 : double.infinity,
                ),
                child: Text(
                  value?.toString() ?? '-',
                  softWrap: true,
                  style: const TextStyle(
                    color: AppColors.black,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.charcoal),
    );
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  static bool _hasText(dynamic value) =>
      value != null && value.toString().trim().isNotEmpty;

  static String? _nullIfEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String _displayDate(dynamic value) {
    final date = _parseDate(value);
    return date == null ? 'Not set' : _formatDate(date);
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  static String? _dateForDatabase(DateTime? date) {
    if (date == null) return null;

    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static num? _parseAmount(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return num.tryParse(value.trim());
  }

  static String _formatMoney(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) {
      return 'Not set';
    }

    final amount = num.tryParse(value.toString());
    if (amount == null) return value.toString();

    final parts = amount.toStringAsFixed(2).split('.');
    final integerPart = parts[0];
    final grouped = integerPart.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );

    return 'RM $grouped.${parts[1]}';
  }

  static Color _statusColor(String status) {
    switch (status) {
      case 'Active':
        return const Color(0xFF22683D);
      case 'Terminated':
        return AppColors.red;
      case 'Expired':
      default:
        return AppColors.grey;
    }
  }
}
