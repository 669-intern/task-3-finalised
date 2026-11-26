import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/styles.dart';

class _LicenceUploadResult {
  final int uploaded;
  final List<String> errors;
  const _LicenceUploadResult(this.uploaded, this.errors);
}

class LicenseRegulatoryPage extends StatefulWidget {
  final Map<String, dynamic>? report;

  const LicenseRegulatoryPage({super.key, this.report});

  @override
  State<LicenseRegulatoryPage> createState() => _LicenseRegulatoryPageState();
}

class _LicenseRegulatoryPageState extends State<LicenseRegulatoryPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  static const String _attachmentBucket = 'licence-regulatory-attachments';

  // Statuses shown by clickable multi-select summary cards.
  static const List<String> _statuses = [
    'Active',
    'Renewal Due',
    'Expired',
    'Terminated',
    'Eligible to Archive',
  ];

  static const List<String> _manualStatusOptions = ['Active', 'Terminated'];

  // Licence validity uses Valid To and the actual calendar date. The saved
  // change_history remains an audit log, not a separate History section.
  DateTime get _selectedReportMonth {
    final raw = widget.report?['report_month'] ?? widget.report?['month'];
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    final date = parsed ?? DateTime.now();
    return DateTime(date.year, date.month, 1);
  }

  String get _selectedReportId =>
      widget.report?['id']?.toString() ?? 'Not provided';

  // All licence records belong to the property selected in the monthly report.
  String get _siteId => widget.report?['site_id']?.toString().trim() ?? '';

  // Use the end of past report months, but never look beyond today's actual
  // date. A future reporting month cannot archive a licence prematurely.
  DateTime get _statusReferenceDate {
    final today = DateUtils.dateOnly(DateTime.now());
    final monthEnd = DateTime(
      _selectedReportMonth.year,
      _selectedReportMonth.month + 1,
      0,
    );
    return monthEnd.isBefore(today) ? monthEnd : today;
  }

  // Archive begins the day AFTER Valid To or the effective termination date.
  // This is a display classification; historical rows and flags are retained.
  DateTime? _automaticArchiveFrom(Map<String, dynamic> record) {
    final expiry = _parseDate(record['expiry_date']);
    DateTime? from = expiry == null
        ? null
        : DateTime(expiry.year, expiry.month, expiry.day + 1);
    final status = record['status']?.toString();
    final stop = (status == 'Terminated' || status == 'Replaced')
        ? _parseDate(record['lifecycle_date'])
        : null;
    if (stop != null) {
      final stoppedFrom = DateTime(stop.year, stop.month, stop.day + 1);
      if (from == null || stoppedFrom.isBefore(from)) {
        from = stoppedFrom;
      }
    }
    return from;
  }

  String _automaticArchiveCause(Map<String, dynamic> record) {
    final expiry = _parseDate(record['expiry_date']);
    final status = record['status']?.toString();
    final stop = (status == 'Terminated' || status == 'Replaced')
        ? _parseDate(record['lifecycle_date'])
        : null;
    return stop != null && (expiry == null || !stop.isAfter(expiry))
        ? 'Terminated'
        : 'Expired';
  }

  bool _manuallyArchivedAsOf(Map<String, dynamic> record) {
    if (record['is_archived'] != true) return false;
    final archivedAt = _parseDate(record['archived_at']);
    if (archivedAt == null) return true; // Preserve legacy manual archives.
    return !DateUtils.dateOnly(archivedAt.toLocal())
        .isAfter(_statusReferenceDate);
  }

  bool _startsAfterSelectedMonth(Map<String, dynamic> record) {
    final start = _parseDate(record['issue_date']);
    return start != null &&
        DateTime(start.year, start.month).isAfter(_selectedReportMonth);
  }

  bool _inSelectedMonth(Map<String, dynamic> record) {
    if (_startsAfterSelectedMonth(record) ||
        _manuallyArchivedAsOf(record)) {
      return false;
    }
    final autoFrom = _automaticArchiveFrom(record);
    return autoFrom == null || autoFrom.isAfter(_statusReferenceDate);
  }

  List<Map<String, dynamic>> get _thisMonthRecords =>
      _filteredRecords.where(_inSelectedMonth).toList();

  // Counts include licences that were manually archived later than the
  // selected historical month, so opening old reports still shows their rows.
  List<Map<String, dynamic>> get _applicableRecords =>
      [..._records, ..._archivedRecords].where(_inSelectedMonth).toList();

  List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _archivedRecords = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final Set<String> _selectedStatuses = <String>{};

  // A selected card adds its status; clicking it again removes that status.
  void _toggleStatus(String status) {
    setState(() {
      if (!_selectedStatuses.add(status)) {
        _selectedStatuses.remove(status);
      }
    });
  }

  bool _matchesSearch(Map<String, dynamic> record, String query) {
    if (query.isEmpty) return true;
    final searchable = [
      record['name'],
      record['issuing_authority'],
      record['renewal_frequency'],
      record['remarks'],
      record['lifecycle_reason'],
      record['archive_reason'],
      _effectiveStatus(record),
    ].where((value) => value != null).join(' ').toLowerCase();
    return searchable.contains(query);
  }

  List<Map<String, dynamic>> get _filteredRecords {
    final query = _searchController.text.trim().toLowerCase();
    return [..._records, ..._archivedRecords].where((record) {
      final status = _effectiveStatus(record);
      final matchesStatus =
          _selectedStatuses.isEmpty ||
          _selectedStatuses.any(
            (selected) =>
                selected == status ||
                (selected == 'Eligible to Archive' &&
                    _isEligibleForArchive(record)),
          );
      return matchesStatus && _matchesSearch(record, query);
    }).toList();
  }

  List<Map<String, dynamic>> get _filteredArchivedRecords {
    final query = _searchController.text.trim().toLowerCase();
    return _archivedRecords
        .where((record) => _matchesSearch(record, query))
        .toList();
  }

  // Summary statuses count only records applicable to the chosen month.
  int get _activeCount => _applicableRecords
      .where((r) => _effectiveStatus(r) == 'Active')
      .length;

  int get _renewalDueCount => _applicableRecords
      .where((r) => _effectiveStatus(r) == 'Renewal Due')
      .length;

  int get _expiredCount => _applicableRecords
      .where((r) => _effectiveStatus(r) == 'Expired')
      .length;

  // Preserve the existing cumulative Terminated summary without double-counting
  // the same row when it also appears in Archived Records.
  int get _terminatedCount => [
        ..._records,
        ..._archivedRecords,
      ].where((r) => !_startsAfterSelectedMonth(r) &&
          _effectiveStatus(r) == 'Terminated').length;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshSearch);
    _loadRecords();
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
      if (_siteId.isEmpty) {
        throw StateError('Open this page from a monthly report with a valid property site_id.');
      }
      // Licence records are property-wide, not limited to their creation month.
      // The backend's RLS policies separately validate the user's site access.
      final active = await _supabase
          .from('licences_regulatory')
          .select()
          .eq('site_id', _siteId)
          .eq('is_archived', false)
          .order('name', ascending: true);

      final archived = await _supabase
          .from('licences_regulatory')
          .select()
          .eq('site_id', _siteId)
          .eq('is_archived', true)
          .order('name', ascending: true);

      if (!mounted) return;
      setState(() {
        _records = List<Map<String, dynamic>>.from(active);
        _archivedRecords = List<Map<String, dynamic>>.from(archived);
        _loading = false;
      });
      // Deletion of a licence is atomic in PostgreSQL. If Storage cleanup
      // previously failed, retry the queued files without blocking the page.
      await _cleanupPendingLicenceFiles();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // The change_history JSONB column retains dated, read-only snapshots.
  // It is a change log, not an inferred monthly report snapshot.
  static List<Map<String, dynamic>> _historyList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> _appendHistory(
    Map<String, dynamic>? original,
    Map<String, dynamic> after, {
    required String action,
    required String recordedAt,
  }) {
    final items = _historyList(original?['change_history']);
    items.add({
      'recorded_at': recordedAt,
      'action': action,
      'name': after['name'],
      'issuing_authority': after['issuing_authority'],
      'renewal_frequency': after['renewal_frequency'],
      'remarks': after['remarks'],
      'issue_date': after['issue_date'],
      'expiry_date': after['expiry_date'],
      'status': after['status'],
      'lifecycle_date': after['lifecycle_date'],
      'lifecycle_reason': after['lifecycle_reason'],
      'is_archived': after['is_archived'] == true,
      'archived_at': after['archived_at'],
      'archive_reason': after['archive_reason'],
    });
    return items;
  }

  static String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';

  static String _monthHeading(String key) {
    const names = <String>[
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
    final parts = key.split('-');
    if (parts.length != 2) return key;
    final month = int.tryParse(parts[1]);
    if (month == null || month < 1 || month > 12) return key;
    return '${names[month - 1]} ${parts[0]}';
  }

  // Archived Records contains manually archived licences and licences whose
  // Valid To or termination date has ACTUALLY passed as of this report view.
  // It is not a second database table, and no saved row is changed here.
  Map<String, List<Map<String, dynamic>>> get _archivedByMonth {
    final grouped = <String, List<Map<String, dynamic>>>{};
    final seen = <String>{};
    final reference = _statusReferenceDate;

    for (final record in [..._filteredRecords, ..._filteredArchivedRecords]) {
      if (_startsAfterSelectedMonth(record)) continue;
      final id = record['id']?.toString() ?? '';
      if (id.isNotEmpty && !seen.add(id)) continue;

      final isManual = _manuallyArchivedAsOf(record);
      final automaticFrom = _automaticArchiveFrom(record);
      final isAutomatic = !isManual &&
          automaticFrom != null &&
          !automaticFrom.isAfter(reference);
      if (!isManual && !isAutomatic) continue;

      final date = isManual
          ? _parseDate(record['archived_at'])?.toLocal()
          : automaticFrom;
      final key = date == null ? 'undated' : _monthKey(date);
      if (isAutomatic) {
        final cause = _automaticArchiveCause(record);
        (grouped[key] ??= <Map<String, dynamic>>[]).add({
          ...record,
          '_auto_archived': true,
          '_auto_archive_cause': cause,
          '_archive_effective_date': _dateForDatabase(automaticFrom),
          '_archive_reason': cause == 'Terminated'
              ? 'Licence stopped being used on '
                  '${_displayDate(record['lifecycle_date'])}.'
              : 'Licence expired on ${_displayDate(record['expiry_date'])}.',
        });
      } else {
        (grouped[key] ??= <Map<String, dynamic>>[]).add(record);
      }
    }

    for (final rows in grouped.values) {
      rows.sort((a, b) => (a['name']?.toString() ?? '')
          .compareTo(b['name']?.toString() ?? ''));
    }
    return grouped;
  }

  // Remove files whose licence/attachment metadata was deleted successfully.
  // Queue rows remain until Storage confirms removal and can be retried on refresh.
  Future<void> _cleanupPendingLicenceFiles() async {
    if (_siteId.isEmpty) return;
    try {
      final pending = await _supabase
          .from('licence_regulatory_cleanup_queue')
          .select('storage_path')
          .eq('site_id', _siteId)
          .limit(100);
      final paths = List<Map<String, dynamic>>.from(pending)
          .map((r) => r['storage_path']?.toString() ?? '')
          .where((p) => p.isNotEmpty)
          .toList();
      if (paths.isEmpty) return;
      await _supabase.storage.from(_attachmentBucket).remove(paths);
      await _supabase
          .from('licence_regulatory_cleanup_queue')
          .delete()
          .eq('site_id', _siteId)
          .inFilter('storage_path', paths);
    } catch (e) {
      debugPrint('Licence attachment cleanup will be retried: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // ATTACHMENTS
  // ---------------------------------------------------------------------------

  Future<void> _showAttachments(
    Map<String, dynamic> record, {
    bool readOnly = false,
  }) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _LicenceAttachmentsDialog(
        licenceId: record['id'].toString(),
        supabase: _supabase,
        onUpload: () => _uploadAttachment(record),
        onOpen: _openAttachment,
        onDelete: _deleteAttachment,
        readOnly: readOnly,
      ),
    );
  }

  Future<void> _uploadAttachment(Map<String, dynamic> record) async {
    try {
      const typeGroup = XTypeGroup(
        label: 'documents',
        extensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'jpg', 'jpeg', 'png'],
      );
      final selected = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (!mounted || selected.isEmpty) return;
      final result = await _uploadSelectedFiles(record, selected);
      if (!mounted) return;
      _showMessage(
        result.errors.isEmpty
            ? '${result.uploaded} attachment(s) uploaded successfully.'
            : '${result.uploaded} uploaded; ${result.errors.length} failed. '
                  '${result.errors.first}',
      );
    } catch (e, stackTrace) {
      debugPrint('Licence attachment picker error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) _showMessage('File selection or upload failed: $e');
    }
  }

  // Works for attachments selected in Add / Update AND the existing
  // Attachments popup. Preserve the existing bucket and metadata table.
  Future<_LicenceUploadResult> _uploadSelectedFiles(
    Map<String, dynamic> record,
    List<XFile> files,
  ) async {
    final licenceId = record['id']?.toString();
    if (licenceId == null || licenceId.isEmpty) {
      return const _LicenceUploadResult(0, ['Licence ID is missing.']);
    }
    var uploaded = 0;
    final errors = <String>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      try {
        final size = await file.length();
        if (size <= 0 || size > 10 * 1024 * 1024) {
          errors.add('${file.name} must be between 1 byte and 10 MB.');
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          errors.add('${file.name} is empty or unreadable.');
          continue;
        }
        final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final storagePath =
            '$licenceId/${DateTime.now().microsecondsSinceEpoch}_${index}_$safeName';
        await _supabase.storage
            .from(_attachmentBucket)
            .uploadBinary(
              storagePath,
              bytes,
              fileOptions: const FileOptions(upsert: false),
            );
        try {
          await _supabase.from('licence_regulatory_attachments').insert({
            'licence_id': licenceId,
            'file_name': file.name,
            'storage_path': storagePath,
            'file_size_bytes': bytes.length,
            'uploaded_by': _supabase.auth.currentUser?.id,
          });
        } catch (_) {
          await _supabase.storage.from(_attachmentBucket).remove([storagePath]);
          rethrow;
        }
        uploaded++;
      } catch (e) {
        errors.add('${file.name}: $e');
        debugPrint('Licence attachment upload failed for ${file.name}: $e');
      }
    }
    return _LicenceUploadResult(uploaded, errors);
  }

  Future<void> _openAttachment(Map<String, dynamic> attachment) async {
    try {
      final path = attachment['storage_path']?.toString();

      if (path == null || path.isEmpty) {
        _showMessage('Attachment path is missing.');
        return;
      }

      final signedUrl = await _supabase.storage
          .from(_attachmentBucket)
          .createSignedUrl(path, 300);

      final opened = await launchUrl(
        Uri.parse(signedUrl),
        mode: LaunchMode.externalApplication,
      );

      if (!opened && mounted) {
        _showMessage('Could not open the attachment.');
      }
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not open attachment: $e');
    }
  }

  Future<void> _deleteAttachment(Map<String, dynamic> attachment) async {
    if (_saving || _siteId.isEmpty) return;
    try {
      final path = attachment['storage_path']?.toString() ?? '';
      final id = attachment['id']?.toString() ?? '';
      if (path.isEmpty || id.isEmpty) {
        _showMessage('Attachment information is incomplete.');
        return;
      }
      // Remove the metadata first; an unauthorized deletion must never remove
      // the physical file. If Storage fails, keep an explicit cleanup queue.
      final deleted = await _supabase
          .from('licence_regulatory_attachments')
          .delete()
          .eq('id', id)
          .select('id')
          .maybeSingle();
      if (deleted == null) {
        throw StateError('No attachment deleted. Check property access and DELETE policies.');
      }
      try {
        await _supabase.storage.from(_attachmentBucket).remove([path]);
      } catch (storageError) {
        try {
          await _supabase.from('licence_regulatory_cleanup_queue').insert({
            'storage_path': path,
            'site_id': _siteId,
          });
          debugPrint('Licence file cleanup queued: $storageError');
          _showMessage('Attachment removed from the record; file cleanup is pending.');
        } catch (queueError) {
          _showMessage('Attachment metadata was deleted, but file cleanup ' 
              'failed and could not be queued: $queueError');
        }
        return;
      }
      if (mounted) _showMessage('Attachment deleted.');
    } catch (e) {
      if (mounted) _showMessage('Could not delete attachment: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // STATUS
  // ---------------------------------------------------------------------------

  String _effectiveStatus(Map<String, dynamic> record) {
    final savedStatus = record['status']?.toString() ?? 'Active';

    // A future-dated termination must not take effect early just because
    // a future monthly report has already been created.
    final referenceDate = _statusReferenceDate;
    if (savedStatus == 'Terminated' || savedStatus == 'Replaced') {
      final ended = _parseDate(record['lifecycle_date']);
      if (ended == null || !ended.isAfter(referenceDate)) {
        return 'Terminated';
      }
    }

    final expiry = _parseDate(record['expiry_date']);
    if (expiry == null) return 'Active';

    final expiryDay = DateUtils.dateOnly(expiry);
    if (expiryDay.isBefore(referenceDate)) return 'Expired';
    if (!referenceDate.isBefore(_oneCalendarMonthBefore(expiryDay))) {
      return 'Renewal Due';
    }
    return 'Active';
  }

  DateTime _oneCalendarMonthBefore(DateTime date) {
    final previous = DateTime(date.year, date.month - 1, 1);
    final lastDay = DateTime(date.year, date.month, 0).day;
    return DateTime(
      previous.year,
      previous.month,
      date.day > lastDay ? lastDay : date.day,
    );
  }

  bool _isEligibleForArchive(Map<String, dynamic> record) {
    final status = record['status']?.toString();
    return (status == 'Terminated' || status == 'Replaced') &&
        record['lifecycle_date'] != null &&
        _hasText(record['lifecycle_reason']);
  }

  // ---------------------------------------------------------------------------
  // ADD / EDIT FORM
  // ---------------------------------------------------------------------------

  Future<void> _openForm({Map<String, dynamic>? record}) async {
    if (_saving || !mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LicenceFormDialog(
        record: record,
        manualStatusOptions: _manualStatusOptions,
        onMessage: _showMessage,
      ),
    );

    if (result == null || !mounted) return;

    // The Archive switch opens the existing confirmation/reason dialog.
    if (result['_action'] == 'archive') {
      if (record != null) await _archiveRecord(record);
      return;
    }

    await _saveRecord(
      record: record,
      name: result['name'] as String,
      issuingAuthority: result['issuingAuthority'] as String,
      renewalFrequency: result['renewalFrequency'] as String,
      remarks: result['remarks'] as String,
      validFrom: result['validFrom'] as DateTime?,
      validTo: result['validTo'] as DateTime?,
      status: result['status'] as String,
      lifecycleDate: result['lifecycleDate'] as DateTime?,
      lifecycleReason: result['lifecycleReason'] as String,
      files: (result['_files'] as List<XFile>?) ?? <XFile>[],
    );
  }

  Future<void> _saveRecord({
    required Map<String, dynamic>? record,
    required String name,
    required String issuingAuthority,
    required String renewalFrequency,
    required String remarks,
    required DateTime? validFrom,
    required DateTime? validTo,
    required String status,
    required DateTime? lifecycleDate,
    required String lifecycleReason,
    required List<XFile> files,
  }) async {
    if (_siteId.isEmpty) {
      _showMessage('Select a property report before saving a licence.');
      return;
    }
    if (validFrom != null && validTo != null && validTo.isBefore(validFrom)) {
      _showMessage('"Valid To" cannot be earlier than "Valid From".');
      return;
    }

    if (status == 'Terminated' &&
        (lifecycleDate == null || lifecycleReason.trim().isEmpty)) {
      _showMessage('Enter the termination date and reason.');
      return;
    }

    final hasLifecycle = status == 'Terminated';
    final now = DateTime.now().toUtc().toIso8601String();
    final data = <String, dynamic>{
      'name': name.trim(),
      'issuing_authority': _nullIfEmpty(issuingAuthority),
      'renewal_frequency': _nullIfEmpty(renewalFrequency),
      'remarks': _nullIfEmpty(remarks),
      'issue_date': _dateForDatabase(validFrom),
      'expiry_date': _dateForDatabase(validTo),
      'status': status,
      'lifecycle_date': hasLifecycle ? _dateForDatabase(lifecycleDate) : null,
      'lifecycle_reason': hasLifecycle ? _nullIfEmpty(lifecycleReason) : null,
      'updated_at': now,
    };

    if (!mounted) return;
    setState(() => _saving = true);

    try {
      late final Map<String, dynamic> saved;
      if (record != null) {
        final changes = {...record, ...data};
        data['change_history'] = _appendHistory(
          record,
          changes,
          action: 'Updated',
          recordedAt: now,
        );
        saved = Map<String, dynamic>.from(
          await _supabase
              .from('licences_regulatory')
              .update(data)
              .eq('id', record['id'].toString())
              .eq('site_id', _siteId)
              .select()
              .single(),
        );
      } else {
        data['change_history'] = _appendHistory(
          null,
          {...data, 'is_archived': false},
          action: 'Added',
          recordedAt: now,
        );
        saved = Map<String, dynamic>.from(
          await _supabase
              .from('licences_regulatory')
              .insert({...data, 'site_id': _siteId})
              .select()
              .single(),
        );
      }

      // Upload only AFTER the licence row is saved, because attachments
      // require its newly generated ID.
      final upload = files.isEmpty
          ? const _LicenceUploadResult(0, [])
          : await _uploadSelectedFiles(saved, files);

      if (!mounted) return;
      await _loadRecords();
      if (!mounted) return;

      final outcome = record == null
          ? 'Licence / requirement added.'
          : 'Licence / requirement updated.';
      if (upload.errors.isNotEmpty) {
        _showMessage(
          '$outcome ${upload.uploaded} attachment(s) uploaded; '
          '${upload.errors.length} failed: ${upload.errors.first}',
        );
      } else {
        _showMessage(
          files.isEmpty
              ? outcome
              : '$outcome ${upload.uploaded} attachment(s) uploaded.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not save the record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Delete a whole licence, its embedded change_history and all attachment
  // metadata in a single database transaction. No confirmation dialog.
  // The SQL RPC also queues Storage files for safe cleanup on refresh.
  Future<void> _deleteLicence(Map<String, dynamic> record) async {
    if (_saving || !mounted) return;
    final id = record['id']?.toString() ?? '';
    final recordSite = record['site_id']?.toString() ?? '';
    if (id.isEmpty || _siteId.isEmpty || recordSite != _siteId) {
      _showMessage('Cannot delete: record ID or selected property does not match.');
      return;
    }
    setState(() => _saving = true);
    try {
      // The RPC uses SECURITY INVOKER and the signed-in user's site-scoped
      // DELETE RLS policies. It throws if no parent row was deleted.
      await _supabase.rpc('delete_licence_regulatory_full', params: {
        'p_licence_id': id,
        'p_site_id': _siteId,
      });
      // Verify the exact row is gone instead of trusting a zero-row result.
      final stillExists = await _supabase
          .from('licences_regulatory')
          .select('id')
          .eq('id', id)
          .eq('site_id', _siteId)
          .maybeSingle();
      if (stillExists != null) {
        throw StateError('The licence still exists. Deletion was not confirmed.');
      }
      await _cleanupPendingLicenceFiles();
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Licence and associated records deleted.');
    } catch (e) {
      if (mounted) _showMessage('Unable to delete licence: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // ARCHIVE / RESTORE
  // ---------------------------------------------------------------------------

  Future<void> _archiveRecord(Map<String, dynamic> record) async {
    if (_saving) return;

    // Manual Archive is an independent record-management action; it does
    // not silently change the licence's expiry or termination status.
    final reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ArchiveLicenceDialog(record: record),
    );

    if (reason == null || !mounted) return;

    setState(() => _saving = true);

    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final changes = <String, dynamic>{
        'is_archived': true,
        'archived_at': now,
        'archive_reason': reason,
        'updated_at': now,
      };
      changes['change_history'] = _appendHistory(
        record,
        {...record, ...changes},
        action: 'Archived',
        recordedAt: now,
      );
      await _supabase
          .from('licences_regulatory')
          .update(changes)
          .eq('id', record['id'].toString())
          .eq('site_id', _siteId)
          .select('id')
          .single();

      if (!mounted) return;

      await _loadRecords();
      if (!mounted) return;

      _showMessage('Record archived.');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not archive the record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restoreRecord(Map<String, dynamic> record) async {
    if (_saving) return;

    // Expired/terminated historical rows are shown in Archived as mirrors,
    // even though they were never manually archived. To restore those,
    // open the existing edit form: update Valid To and/or change status.
    // This preserves the same row ID, attached files and change history.
    if (record['is_archived'] != true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.white,
          title: const Text('Restore Historical Licence'),
          content: const Text(
            'Update the Valid To date and, if applicable, '
            'change the status back to Active. The licence will appear in '
            'This Month only when its new dates cover the selected month.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _openForm(record: record);
      }
      return;
    }

    // A manual archive cannot make an expired/terminated licence valid.
    // Update its validity/status first, then use Restore to clear the manual flag.
    final automaticFrom = _automaticArchiveFrom(record);
    final today = DateUtils.dateOnly(DateTime.now());
    if (automaticFrom != null && !automaticFrom.isAfter(today)) {
      final renew = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.white,
          title: const Text('Renew Before Restoring'),
          content: const Text(
            'This licence has expired or been terminated. Update Valid To '
            'and the status first. After saving valid dates, choose Restore '
            'again to remove the manual archive flag.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Edit Licence'),
            ),
          ],
        ),
      );
      if (renew == true && mounted) await _openForm(record: record);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Restore Record'),
        content: Text(
          'Restore "${record['name']}" to the active records list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);

    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final changes = <String, dynamic>{
        'is_archived': false,
        'archived_at': null,
        'archive_reason': null,
        'updated_at': now,
      };
      changes['change_history'] = _appendHistory(
        record,
        {...record, ...changes},
        action: 'Restored',
        recordedAt: now,
      );
      await _supabase
          .from('licences_regulatory')
          .update(changes)
          .eq('id', record['id'].toString())
          .eq('site_id', _siteId)
          .select('id')
          .single();

      if (!mounted) return;

      await _loadRecords();
      if (!mounted) return;

      _showMessage('Record restored.');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not restore the record: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // MESSAGES
  // ---------------------------------------------------------------------------

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.charcoal),
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
        title: const Text('Licences & Regulatory'),
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
        onPressed: _loading || _saving ? null : () => _openForm(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Licence'),
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
                'Unable to load licence records.',
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
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final records = _thisMonthRecords;

    return RefreshIndicator(
      onRefresh: _loadRecords,
      color: AppColors.red,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSummary(),
          const SizedBox(height: 24),
          // Search and status filters stay above both record sections.
          _buildSearchAndFilters(),
          const SizedBox(height: 20),
          // Keep the current-month heading and count above its records.
          // Archived Records are displayed below This Month.
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
                '${records.length} record${records.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: AppColors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (records.isEmpty)
            _buildEmptyState()
          else
            ...records.asMap().entries.map(
              (entry) => _buildRecordCard(entry.value, number: entry.key + 1),
            ),
          const SizedBox(height: 20),
          _buildArchivedSection(),
        ],
      ),
    );
  }

  Widget _buildArchivedSection() {
    final grouped = _archivedByMonth;
    // Show newest archived month first, with undated legacy records last.
    final months = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'undated') return 1;
        if (b == 'undated') return -1;
        return b.compareTo(a);
      });
    final total = grouped.values.fold<int>(
      0,
      (count, rows) => count + rows.length,
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
              '$total records',
              style: const TextStyle(color: AppColors.grey),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (months.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.white,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              'No archived licence records found.',
              style: TextStyle(color: AppColors.grey),
            ),
          ),
        for (final month in months)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: AppColors.white,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ExpansionTile(
              key: ValueKey('licence-archived-month-$month'),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 7,
              ),
              title: Text(
                month == 'undated' ? 'Date not recorded' : _monthHeading(month),
                style: const TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                '${grouped[month]!.length} archived record(s)',
                style: const TextStyle(color: AppColors.grey, fontSize: 12),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: grouped[month]!
                  .asMap()
                  .entries
                  .map(
                    (entry) => _buildRecordCard(
                      entry.value,
                      number: entry.key + 1,
                      archived: true,
                    ),
                  )
                  .toList(),
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
            'Licences & Regulatory',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthHeading(_monthKey(_selectedReportMonth))} '
            '• Report ID: $_selectedReportId',
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
        final cardWidth = constraints.maxWidth >= 640
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Column(
          children: [
            // Full-width total card resets the multi-select status filter.
            SizedBox(
              width: double.infinity,
              child: _summaryCard(
                'Total Licences / Requirements',
                _applicableRecords.length,
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
                  width: cardWidth,
                  child: _summaryCard(
                    'Active',
                    _activeCount,
                    Icons.verified_outlined,
                    const Color(0xFF22683D),
                    onTap: () => _toggleStatus('Active'),
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _summaryCard(
                    'Renewal Due',
                    _renewalDueCount,
                    Icons.event_repeat_outlined,
                    const Color(0xFF966400),
                    onTap: () => _toggleStatus('Renewal Due'),
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _summaryCard(
                    'Expired',
                    _expiredCount,
                    Icons.warning_amber_outlined,
                    AppColors.red,
                    onTap: () => _toggleStatus('Expired'),
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _summaryCard(
                    'Terminated',
                    _terminatedCount,
                    Icons.block_outlined,
                    AppColors.grey,
                    onTap: () => _toggleStatus('Terminated'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // All summary card icons and text align left. Selected status cards use
  // the same neutral grey border, with no red selected outline.
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
                child: Icon(icon, color: accent, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$count',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 21,
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

  Widget _buildSearchAndFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search licence, authority, frequency or remarks...',
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
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
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'Showing:',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
            if (_selectedStatuses.isEmpty)
              const Text('All statuses', style: TextStyle(fontSize: 12))
            else ...[
              for (final status in _statuses)
                if (_selectedStatuses.contains(status))
                  InkWell(
                    onTap: () => _toggleStatus(status),
                    borderRadius: BorderRadius.circular(7),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.white,
                        border: Border.all(color: const Color(0xFFD8B5B0)),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        status,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: Color(0xFF665552),
                        ),
                      ),
                    ),
                  ),
              TextButton.icon(
                onPressed: () => setState(() => _selectedStatuses.clear()),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                icon: const Icon(Icons.close, size: 15),
                label: const Text('Clear filter'),
              ),
            ],
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
      child: const Column(
        children: [
          Icon(Icons.policy_outlined, size: 42, color: AppColors.red),
          SizedBox(height: 12),
          Text(
            'No licence / requirement records found',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
              fontSize: 17,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Use Add Licence to create a record, or adjust your search filters.',
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
    bool archived = false,
    bool historical = false,
  }) {
    final status = archived && record['_auto_archived'] == true
        ? (record['_auto_archive_cause'] == 'Terminated'
            ? 'Terminated'
            : 'Expired')
        : _effectiveStatus(record);
    final accent = archived ? AppColors.grey : _statusColor(status);
    final validTo = _parseDate(record['expiry_date']);
    final daysToExpiry = validTo == null
        ? null
        : DateUtils.dateOnly(validTo).difference(_statusReferenceDate).inDays;

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
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
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
                      record['name']?.toString() ?? 'Untitled requirement',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_hasText(record['issuing_authority'])) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Authority / Vendor: ${record['issuing_authority']}',
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
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      archived ? 'Archived' : status,
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
          // Compact horizontal dates; only the two licence date fields.
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _dateBox('Valid From', record['issue_date']),
              _dateBox('Valid To', record['expiry_date']),
            ],
          ),
          if (_hasText(record['renewal_frequency'])) ...[
            const SizedBox(height: 12),
            _detail('Renewal Frequency', record['renewal_frequency']),
          ],
          if (_hasText(record['remarks'])) ...[
            const SizedBox(height: 3),
            _detail('Remarks', record['remarks']),
          ],
          if (!archived &&
              !historical &&
              daysToExpiry != null &&
              status != 'Terminated' &&
              status != 'Replaced') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  daysToExpiry < 0
                      ? Icons.warning_amber_outlined
                      : Icons.event_outlined,
                  color: AppColors.red,
                  size: 17,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    daysToExpiry < 0
                        ? 'Expired ${daysToExpiry.abs()} day(s) ago'
                        : daysToExpiry == 0
                        ? 'Expires today'
                        : 'Expires in $daysToExpiry day(s)',
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
              'Date No Longer Used',
              _displayDate(record['lifecycle_date']),
            ),
            if (_hasText(record['lifecycle_reason']))
              _detail('Reason', record['lifecycle_reason']),
          ],
          if (archived) ...[
            const SizedBox(height: 12),
            _detail(
              'Archive Type',
              record['_auto_archived'] == true ? 'Automatic' : 'Manual',
            ),
            _detail(
              record['_auto_archived'] == true
                  ? 'Archived From'
                  : 'Date Archived',
              _displayDate(
                record['_archive_effective_date'] ?? record['archived_at'],
              ),
            ),
            if (_hasText(record['_archive_reason'] ?? record['archive_reason']))
              _detail(
                'Reason for Archiving',
                record['_archive_reason'] ?? record['archive_reason'],
              ),
          ],
          const Divider(height: 22),
          // Align makes this Wrap occupy the right side of the record card.
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: _saving ? null : () => _showAttachments(record),
                  icon: const Icon(Icons.attach_file, size: 18),
                  label: const Text('Attachments'),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : () => _openForm(record: record),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : () => _deleteLicence(record),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
                if (archived)
                  TextButton.icon(
                    onPressed: _saving ? null : () => _restoreRecord(record),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                    icon: const Icon(Icons.unarchive_outlined, size: 18),
                    label: const Text('Restore'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateBox(String label, dynamic value) {
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
            _displayDate(value),
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

  // Labels on the left, corresponding descriptions on the right.
  Widget _detail(String label, dynamic value) {
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
              value?.toString() ?? '',
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

  static Color _statusColor(String status) {
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
}

// -----------------------------------------------------------------------------
// ADD / EDIT DIALOG
//
// The dialog owns its controllers. They are disposed only when the dialog's
// State is disposed, not by the page while Flutter is updating the fields.
// -----------------------------------------------------------------------------

class _LicenceFormDialog extends StatefulWidget {
  const _LicenceFormDialog({
    required this.record,
    required this.manualStatusOptions,
    required this.onMessage,
  });

  final Map<String, dynamic>? record;
  final List<String> manualStatusOptions;
  final ValueChanged<String> onMessage;

  @override
  State<_LicenceFormDialog> createState() => _LicenceFormDialogState();
}

class _LicenceFormDialogState extends State<_LicenceFormDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _authorityController;
  late final TextEditingController _frequencyController;
  late final TextEditingController _remarksController;
  late final TextEditingController _lifecycleReasonController;

  DateTime? _validFrom;
  DateTime? _validTo;
  DateTime? _lifecycleDate;
  late String _selectedStatus;
  bool _archiveSelected = false;
  final List<XFile> _selectedFiles = <XFile>[];

  bool get _isEditing => widget.record != null;

  @override
  void initState() {
    super.initState();

    final record = widget.record;

    _nameController = TextEditingController(
      text: record?['name']?.toString() ?? '',
    );
    _authorityController = TextEditingController(
      text: record?['issuing_authority']?.toString() ?? '',
    );
    _frequencyController = TextEditingController(
      text: record?['renewal_frequency']?.toString() ?? '',
    );
    _remarksController = TextEditingController(
      text: record?['remarks']?.toString() ?? '',
    );
    _lifecycleReasonController = TextEditingController(
      text: record?['lifecycle_reason']?.toString() ?? '',
    );

    _validFrom = _parseDate(record?['issue_date']);
    _validTo = _parseDate(record?['expiry_date']);
    _lifecycleDate = _parseDate(record?['lifecycle_date']);

    _selectedStatus = record?['status']?.toString() ?? 'Active';

    // Existing Replaced data is kept but displayed using Terminated status.
    if (_selectedStatus == 'Replaced') _selectedStatus = 'Terminated';
    if (!widget.manualStatusOptions.contains(_selectedStatus)) {
      _selectedStatus = 'Active';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _authorityController.dispose();
    _frequencyController.dispose();
    _remarksController.dispose();
    _lifecycleReasonController.dispose();
    super.dispose();
  }

  Future<void> _selectAttachments() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'documents',
        extensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'jpg', 'jpeg', 'png'],
      );
      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (!mounted || files.isEmpty) return;
      final valid = <XFile>[];
      for (final file in files) {
        final length = await file.length();
        if (length <= 0 || length > 10 * 1024 * 1024) {
          widget.onMessage('${file.name} must be between 1 byte and 10 MB.');
          continue;
        }
        valid.add(file);
      }
      if (!mounted) return;
      setState(() => _selectedFiles.addAll(valid));
    } catch (e) {
      if (mounted) widget.onMessage('Unable to select attachments: $e');
    }
  }

  void _submit() {
    if (_isEditing && _archiveSelected) {
      // Archiving uses the already saved licence. Confirmation and the
      // archive reason are collected by the existing archive dialog.
      Navigator.of(context).pop(<String, dynamic>{'_action': 'archive'});
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    if (_validFrom != null &&
        _validTo != null &&
        _validTo!.isBefore(_validFrom!)) {
      widget.onMessage('"Valid To" cannot be earlier than "Valid From".');
      return;
    }

    if (_selectedStatus == 'Terminated' &&
        (_lifecycleDate == null ||
            _lifecycleReasonController.text.trim().isEmpty)) {
      widget.onMessage(
        'Enter the date and reason this licence was terminated.',
      );
      return;
    }

    Navigator.of(context).pop(<String, dynamic>{
      'name': _nameController.text,
      'issuingAuthority': _authorityController.text,
      'renewalFrequency': _frequencyController.text,
      'remarks': _remarksController.text,
      'validFrom': _validFrom,
      'validTo': _validTo,
      'status': _selectedStatus,
      'lifecycleDate': _lifecycleDate,
      'lifecycleReason': _lifecycleReasonController.text,
      '_files': List<XFile>.from(_selectedFiles),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: Text(
        _isEditing
            ? 'Update Licence / Requirement'
            : 'Add Licence / Requirement',
        style: const TextStyle(
          color: AppColors.black,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LICENCE DETAILS',
                  style: TextStyle(
                    color: AppColors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'License / Requirement *',
                    hintText: 'Enter the licence or requirement',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a licence or requirement.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _authorityController,
                  decoration: const InputDecoration(
                    labelText: 'Authority / Vendor',
                    hintText: 'Enter the authority or vendor',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _frequencyController,
                  decoration: const InputDecoration(
                    labelText: 'Renewal Frequency',
                    hintText: 'e.g. Annually, Every 2 years',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _remarksController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Remarks',
                    hintText: 'Additional notes or requirements',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                const Text(
                  'VALIDITY PERIOD',
                  style: TextStyle(
                    color: AppColors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                _dateField(
                  label: 'Valid From',
                  value: _validFrom,
                  onChanged: (value) {
                    setState(() => _validFrom = value);
                  },
                ),
                const SizedBox(height: 14),
                _dateField(
                  label: 'Valid To',
                  value: _validTo,
                  onChanged: (value) {
                    setState(() => _validTo = value);
                  },
                ),
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                const Text(
                  'RENEWAL STATUS',
                  style: TextStyle(
                    color: AppColors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _selectedStatus,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: widget.manualStatusOptions.map((status) {
                    return DropdownMenuItem<String>(
                      value: status,
                      child: Text(
                        status == 'Active' ? 'Active (Automatic)' : status,
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null) return;

                    setState(() {
                      _selectedStatus = value;

                      if (_selectedStatus != 'Terminated') {
                        _lifecycleDate = null;
                        _lifecycleReasonController.clear();
                      }
                    });
                  },
                ),
                if (_selectedStatus == 'Terminated') ...[
                  const SizedBox(height: 22),
                  const Divider(),
                  const SizedBox(height: 12),
                  const Text(
                    'TERMINATION DETAILS',
                    style: TextStyle(
                      color: AppColors.red,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _dateField(
                    label: 'Date No Longer Used *',
                    value: _lifecycleDate,
                    onChanged: (value) {
                      setState(() => _lifecycleDate = value);
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _lifecycleReasonController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Reason for Termination *',
                      hintText: 'e.g. Licence no longer required',
                      alignLabelWithHint: true,
                    ),
                    validator: (value) {
                      if (_selectedStatus == 'Terminated' &&
                          (value == null || value.trim().isEmpty)) {
                        return 'Please enter the reason for termination.';
                      }
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: 22),
                const Divider(),
                const SizedBox(height: 12),
                const Text(
                  'ATTACHMENTS',
                  style: TextStyle(
                    color: AppColors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Upload PDF, Word, Excel or image files. '
                  'Maximum 10 MB each. Files upload after saving the licence.',
                  style: TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _selectAttachments,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Select Attachments'),
                ),
                if (_selectedFiles.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (var i = 0; i < _selectedFiles.length; i++)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.attach_file,
                        color: AppColors.red,
                      ),
                      title: Text(
                        _selectedFiles[i].name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove selected file',
                        icon: const Icon(Icons.close),
                        onPressed: () =>
                            setState(() => _selectedFiles.removeAt(i)),
                      ),
                    ),
                ],
                if (_isEditing) ...[
                  const SizedBox(height: 18),
                  const Divider(),
                  const SizedBox(height: 12),
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
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Archive'),
                    value: _archiveSelected,
                    activeThumbColor: AppColors.red,
                    onChanged: (value) =>
                        setState(() => _archiveSelected = value),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEditing ? 'Save Changes' : 'Add Record'),
        ),
      ],
    );
  }

  Widget _dateField({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onChanged,
  }) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final initialDate = value ?? DateTime(now.year, now.month, now.day);

        final selected = await showDatePicker(
          context: context,
          initialDate: initialDate,
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

        if (!mounted || selected == null) return;
        onChanged(selected);
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

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }
}

// -----------------------------------------------------------------------------
// ARCHIVE DIALOG
//
// The archive reason controller is owned and disposed by this dialog.
// -----------------------------------------------------------------------------

class _ArchiveLicenceDialog extends StatefulWidget {
  const _ArchiveLicenceDialog({required this.record});

  final Map<String, dynamic> record;

  @override
  State<_ArchiveLicenceDialog> createState() => _ArchiveLicenceDialogState();
}

class _ArchiveLicenceDialogState extends State<_ArchiveLicenceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _reasonController;

  @override
  void initState() {
    super.initState();
    _reasonController = TextEditingController(
      text: widget.record['archive_reason']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: const Text(
        'Archive Licence / Requirement',
        style: TextStyle(color: AppColors.black, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Archive "${widget.record['name']}"? '
                  'The record will be retained and can be restored later.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _reasonController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Reason for Archiving *',
                    hintText: 'Enter why this record needs to be archived.',
                    alignLabelWithHint: true,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Archive reason is required.';
                    }
                    return null;
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_reasonController.text.trim());
          },
          child: const Text('Archive'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// ATTACHMENT DIALOG
// -----------------------------------------------------------------------------

class _LicenceAttachmentsDialog extends StatefulWidget {
  const _LicenceAttachmentsDialog({
    required this.licenceId,
    required this.supabase,
    required this.onUpload,
    required this.onOpen,
    required this.onDelete,
    this.readOnly = false,
  });

  final bool readOnly;
  final String licenceId;
  final SupabaseClient supabase;
  final Future<void> Function() onUpload;
  final Future<void> Function(Map<String, dynamic>) onOpen;
  final Future<void> Function(Map<String, dynamic>) onDelete;

  @override
  State<_LicenceAttachmentsDialog> createState() =>
      _LicenceAttachmentsDialogState();
}

class _LicenceAttachmentsDialogState extends State<_LicenceAttachmentsDialog> {
  late Future<List<Map<String, dynamic>>> _attachmentsFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAttachments();
  }

  void _loadAttachments() {
    _attachmentsFuture = widget.supabase
        .from('licence_regulatory_attachments')
        .select()
        .eq('licence_id', widget.licenceId)
        .order('created_at', ascending: false)
        .then((rows) => List<Map<String, dynamic>>.from(rows));
  }

  Future<void> _refreshAttachments() async {
    if (!mounted) return;
    setState(_loadAttachments);
  }

  Future<void> _upload() async {
    if (_busy) return;

    setState(() => _busy = true);

    try {
      await widget.onUpload();
      await _refreshAttachments();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not refresh attachments: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic> attachment) async {
    if (_busy) return;

    setState(() => _busy = true);

    try {
      await widget.onOpen(attachment);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> attachment) async {
    if (_busy) return;

    setState(() => _busy = true);

    try {
      await widget.onDelete(attachment);
      await _refreshAttachments();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: const Text(
        'Licence Attachments',
        style: TextStyle(color: AppColors.black, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 520,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _attachmentsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 120,
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.red),
                ),
              );
            }

            if (snapshot.hasError) {
              return SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    'Unable to load attachments:\n${snapshot.error}',
                    style: const TextStyle(color: AppColors.red),
                  ),
                ),
              );
            }

            final attachments = snapshot.data ?? [];

            if (attachments.isEmpty) {
              return const SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    'No attachments uploaded yet.',
                    style: TextStyle(color: AppColors.grey),
                  ),
                ),
              );
            }

            return SizedBox(
              height: 320,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: attachments.length,
                separatorBuilder: (_, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final attachment = attachments[index];

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.insert_drive_file_outlined,
                      color: AppColors.red,
                    ),
                    title: Text(
                      attachment['file_name']?.toString() ??
                          'Unnamed attachment',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _attachmentSize(attachment['file_size_bytes']),
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
                          onPressed: _busy ? null : () => _open(attachment),
                          icon: const Icon(Icons.open_in_new, size: 19),
                        ),
                        IconButton(
                          tooltip: 'Delete attachment',
                          onPressed: _busy || widget.readOnly
                              ? null
                              : () => _delete(attachment),
                          icon: const Icon(
                            Icons.delete_outline,
                            color: AppColors.red,
                            size: 19,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _busy || widget.readOnly ? null : _upload,
          icon: const Icon(Icons.upload_file),
          label: Text(_busy ? 'Please wait...' : 'Upload Files'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  static String _attachmentSize(dynamic value) {
    final bytes = int.tryParse(value?.toString() ?? '') ?? 0;

    if (bytes < 1024) return '$bytes B';

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}