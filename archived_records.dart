import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'widgets/styles.dart';
import 'property_sites_service.dart';
import 'site_profile_page.dart';
import 'contracts-compliance/service_providers.dart';
import 'contracts-compliance/license_regulatory.dart';
import 'contracts-compliance/insurance_policies.dart';
import 'contracts-compliance/insurance_claims.dart';
import 'contracts-compliance/compliance_best_practices.dart';

class ArchivedRecordsPage extends StatefulWidget {
  // The caller should pass the selected monthly report. Navigator route
  // arguments are also supported; never substitute another reporting month.
  final Map<String, dynamic>? report;

  const ArchivedRecordsPage({super.key, this.report});

  @override
  State<ArchivedRecordsPage> createState() => _ArchivedRecordsPageState();
}

class _ArchivedEntry {
  final String table;
  final String module;
  final Map<String, dynamic> record;

  const _ArchivedEntry({
    required this.table,
    required this.module,
    required this.record,
  });

  String get id => record['id'].toString();

  String get key => table == 'site_profile'
      ? '$table:${record['_site_profile_kind']}:$id'
      : '$table:$id';
}

class _TableLoadResult {
  final String table;
  final String module;
  final List<Map<String, dynamic>> records;
  final String? error;

  const _TableLoadResult({
    required this.table,
    required this.module,
    this.records = const [],
    this.error,
  });
}

class _ArchiveReportContext {
  final DateTime month;
  final String? id;
  final String? siteId;

  const _ArchiveReportContext({
    required this.month,
    required this.id,
    required this.siteId,
  });
}

class _ArchivedRecordsPageState extends State<ArchivedRecordsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const Map<String, String> _modules = {
    'compliance_best_practices': 'Compliance & Best Practices',
    'insurance_claims': 'Insurance Claims',
    'insurance_policies': 'Insurance Policies',
    'licences_regulatory': 'Licences & Regulatory',
    'service_providers': 'Service Providers',
    'site_profile': 'Site Profile',
  };

  List<_ArchivedEntry> _records = [];
  Map<String, String> _loadErrors = {};

  bool _loading = true;
  String _selectedModule = 'All Modules';
  String _selectedYear = 'All Years';
  String _selectedArchiveMonth = 'All Months';
  String? _resolvedSiteName;
  DateTime _archiveCutoffDate = DateUtils.dateOnly(DateTime.now());
  DateTime _reportingMonth = DateTime(DateTime.now().year, DateTime.now().month);
  String? _resolvedReportId;
  String? _resolvedSiteId;
  Map<String, dynamic>? _routeReport;
  bool _routeContextInitialized = false;
  int _loadVersion = 0;

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

  final Set<String> _restoring = {};
  final Set<String> _deleting = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A report passed through Navigator route arguments is supported without
    // changing the existing ArchivedRecordsPage constructor.
    final routeReport = _reportFromRouteArguments(
      ModalRoute.of(context)?.settings.arguments,
    );
    if (!_routeContextInitialized ||
        _reportContextKey(_routeReport) != _reportContextKey(routeReport)) {
      _routeContextInitialized = true;
      _routeReport = routeReport;
      _loadRecords();
    }
  }

  @override
  void didUpdateWidget(covariant ArchivedRecordsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The same page can be reused when the sidebar opens another report.
    if (_reportContextKey(oldWidget.report) !=
        _reportContextKey(widget.report)) {
      _loadRecords();
    }
  }

  // ============================================================
  // LOAD ARCHIVED RECORDS
  // ============================================================

  DateTime? _providerDate(dynamic value) =>
      DateTime.tryParse(value?.toString() ?? '');

  DateTime _providerMonth(DateTime date) => DateTime(date.year, date.month, 1);

  // All archive eligibility and timestamp filters use the Malaysia calendar,
  // regardless of the browser's local timezone or the selected report month.
  DateTime _malaysiaToday() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(now.year, now.month, now.day);
  }

  DateTime? _malaysiaArchiveDay(dynamic raw) {
    final value = _providerDate(raw);
    if (value == null) return null;
    // Date-only values are already effective calendar dates, not instants.
    final day = raw.toString().length == 10
        ? value
        : value.toUtc().add(const Duration(hours: 8));
    return DateTime(day.year, day.month, day.day);
  }

  DateTime? _entryArchiveDay(Map<String, dynamic> record) =>
      _malaysiaArchiveDay(record['_archive_effective_date']) ??
      _malaysiaArchiveDay(record['archived_at']);

  Map<String, dynamic>? _reportFromRouteArguments(dynamic arguments) {
    if (arguments is! Map) return null;
    final source = Map<String, dynamic>.from(arguments);
    final nested = source['report'] ?? source['selectedReport'];
    if (nested is Map) return Map<String, dynamic>.from(nested);
    if (source.containsKey('report_month') ||
        source.containsKey('reportMonth') ||
        source.containsKey('report_id') ||
        source.containsKey('site_id') ||
        source.containsKey('selected_month') ||
        (source.containsKey('month') && source.containsKey('year'))) {
      return source;
    }
    return null;
  }

  String _reportContextKey(Map<String, dynamic>? report) {
    if (report == null) return '';
    return [
      report['id'],
      report['report_id'],
      report['site_id'],
      report['siteId'],
      report['report_month'],
      report['reportMonth'],
      report['selected_month'],
      report['month'],
      report['year'],
      report['report_year'],
    ].map((value) => value?.toString() ?? '').join('|');
  }

  DateTime? _selectedReportMonth(Map<String, dynamic> source) {
    final raw = source['report_month'] ??
        source['reportMonth'] ??
        source['selected_month'] ??
        source['month_year'] ??
        source['month'];
    if (raw is DateTime) return _providerMonth(raw);
    final parsed = _providerDate(raw);
    if (parsed != null) return _providerMonth(parsed);

    // Also accept a month/year pair from an existing navigation route.
    final rawYear = source['year'] ?? source['report_year'];
    final year = int.tryParse(rawYear?.toString() ?? '');
    final month = int.tryParse(raw?.toString() ?? '');
    if (year != null && year >= 1900 && month != null &&
        month >= 1 && month <= 12) {
      return DateTime(year, month);
    }
    return null;
  }

  // Only the selected monthly_reports record is authoritative. Looking up the
  // latest report here can show a different month and property from the sidebar.
  Future<_ArchiveReportContext> _resolveReportContext() async {
    final source = widget.report ?? _routeReport;
    if (source == null) {
      throw StateError(
        'No Monthly Report was supplied. Open the required Monthly Report '
        'and pass its report context when opening Archived Records.',
      );
    }

    final suppliedMonth = _selectedReportMonth(source);
    final suppliedId = _firstText([source['report_id'], source['id']]);
    final suppliedSiteId = _firstText([source['site_id'], source['siteId']]);
    Map<String, dynamic>? matched;

    // The selected property and month take precedence over a potentially
    // stale ID, so the header cannot mix October with January's Report ID.
    if (suppliedMonth != null && suppliedSiteId != null) {
      matched = await _supabase
          .from('monthly_reports')
          .select('id,site_id,report_month')
          .eq('site_id', suppliedSiteId)
          .eq('report_month', _providerDateForQuery(suppliedMonth))
          .maybeSingle();
    } else if (suppliedId != null) {
      matched = await _supabase
          .from('monthly_reports')
          .select('id,site_id,report_month')
          .eq('id', suppliedId)
          .maybeSingle();
    }

    if (matched == null) {
      throw StateError(
        'The selected Monthly Report could not be identified. '
        'Open the report for the correct property and month first.',
      );
    }
    final actualDate = _providerDate(matched['report_month']);
    final actualId = _firstText([matched['id']]);
    final actualSiteId = _firstText([matched['site_id']]);
    if (actualDate == null || actualId == null || actualSiteId == null) {
      throw StateError('The selected Monthly Report has incomplete details.');
    }
    final actualMonth = _providerMonth(actualDate);
    if (suppliedMonth != null && actualMonth != suppliedMonth) {
      throw StateError('The selected month does not match its Report ID.');
    }
    if (suppliedSiteId != null && actualSiteId != suppliedSiteId) {
      throw StateError('The selected property does not match its Report ID.');
    }
    return _ArchiveReportContext(
      month: actualMonth,
      id: actualId,
      siteId: actualSiteId,
    );
  }

  String _formatMonthYear(DateTime date) =>
      '${_monthNames[date.month - 1]} ${date.year}';

  String _providerDateForQuery(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  // Automatic expiry takes effect the calendar day AFTER the expiry date.
  // Evaluate against today in Malaysia, independently of the report month.
  // Explicit termination retains the existing following-month rule.
  DateTime? _providerAutomaticArchiveFrom(
    Map<String, dynamic> provider,
    DateTime asOfDate,
  ) {
    final expiry = _providerDate(provider['expiry_date']);
    final confirmed = _providerDate(provider['renewal_confirmed_at']);
    final nextExpiry = _providerDate(provider['next_expiry_date']);
    final validRenewal =
        expiry != null &&
        confirmed != null &&
        !confirmed.isAfter(asOfDate) &&
        nextExpiry != null &&
        nextExpiry.isAfter(expiry);
    final effectiveExpiry = validRenewal ? nextExpiry : expiry;

    final stop = _providerDate(provider['lifecycle_date']);
    if (provider['status'] == 'Terminated' &&
        stop != null &&
        (effectiveExpiry == null || !stop.isAfter(effectiveExpiry))) {
      // Retain the existing following-month rule for termination.
      return DateTime(stop.year, stop.month + 1, 1);
    }
    return effectiveExpiry == null
        ? null
        : DateTime(
            effectiveExpiry.year,
            effectiveExpiry.month,
            effectiveExpiry.day + 1,
          );
  }

  String _providerAutomaticArchiveCause(
    Map<String, dynamic> provider,
    DateTime asOfDate,
  ) {
    final expiry = _providerDate(provider['expiry_date']);
    final confirmed = _providerDate(provider['renewal_confirmed_at']);
    final nextExpiry = _providerDate(provider['next_expiry_date']);
    final validRenewal =
        expiry != null &&
        confirmed != null &&
        !confirmed.isAfter(asOfDate) &&
        nextExpiry != null &&
        nextExpiry.isAfter(expiry);
    final effectiveExpiry = validRenewal ? nextExpiry : expiry;
    final stop = _providerDate(provider['lifecycle_date']);
    return provider['status'] == 'Terminated' &&
            stop != null &&
            (effectiveExpiry == null || !stop.isAfter(effectiveExpiry))
        ? 'Terminated'
        : 'Expired';
  }

  // Monthly copies are linked by source_provider_id. Read all accessible
  // snapshots and group each lineage once; don't touch saved archive flags.
  Future<_TableLoadResult> _loadArchivedServiceProviders(
    DateTime asOfDate,
    String siteId,
  ) async {
    const table = 'service_providers';
    const module = 'Service Providers';
    const pageSize = 500;
    try {
      final reportMonths = <String, DateTime>{};
      final reportSites = <String, String>{};
      // Resolve provider ownership through this property's report IDs.
      // The latest snapshot through the current calendar month determines
      // whether a lineage is still archived or has since been renewed.
      var offset = 0;
      while (true) {
        final response = await _supabase
            .from('monthly_reports')
            .select('id,report_month,site_id')
            .eq('site_id', siteId)
            .lte('report_month', _providerDateForQuery(_providerMonth(asOfDate)))
            .order('id')
            .range(offset, offset + pageSize - 1);
        final rows = List<Map<String, dynamic>>.from(response);
        for (final row in rows) {
          final id = row['id']?.toString();
          final month = _providerDate(row['report_month']);
          if (id != null && month != null) {
            final reportMonth = _providerMonth(month);
            final siteId = row['site_id']?.toString() ?? '';
            reportMonths[id] = reportMonth;
            reportSites[id] = siteId;
          }
        }
        if (rows.length < pageSize) break;
        offset += pageSize;
      }

      final all = <Map<String, dynamic>>[];
      final reportIds = reportMonths.keys.toList();
      const reportBatchSize = 50;
      for (var start = 0; start < reportIds.length; start += reportBatchSize) {
        final ids = reportIds.skip(start).take(reportBatchSize).toList();
        offset = 0;
        while (true) {
          final response = await _supabase
              .from(table)
              .select()
              .inFilter('report_id', ids)
              .order('id')
              .range(offset, offset + pageSize - 1);
          final rows = List<Map<String, dynamic>>.from(response);
          all.addAll(rows);
          if (rows.length < pageSize) break;
          offset += pageSize;
        }
      }

      final byId = <String, Map<String, dynamic>>{
        for (final row in all)
          if (row['id'] != null) row['id'].toString(): row,
      };
      String rootOf(Map<String, dynamic> row) {
        var id = row['id'].toString();
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

      final groups = <String, List<Map<String, dynamic>>>{};
      for (final row in all) {
        final reportId = row['report_id']?.toString() ?? '';
        final site = reportSites[reportId];
        if (site != siteId) continue;
        (groups['$site:${rootOf(row)}'] ??= []).add(row);
      }
      final cutoffMonth = _providerMonth(asOfDate);
      final archived = <Map<String, dynamic>>[];
      for (final group in groups.values) {
        final snapshots = group.where((row) {
          final reportId = row['report_id']?.toString() ?? '';
          final month = reportMonths[reportId];
          return month == null
              ? row['is_archived'] == true
              : !month.isAfter(cutoffMonth);
        }).toList();
        if (snapshots.isEmpty) continue;
        snapshots.sort((a, b) {
          final am = reportMonths[a['report_id']?.toString()] ?? DateTime(1900);
          final bm = reportMonths[b['report_id']?.toString()] ?? DateTime(1900);
          final order = am.compareTo(bm);
          if (order != 0) return order;
          final updated = (a['updated_at']?.toString() ?? '').compareTo(
            b['updated_at']?.toString() ?? '',
          );
          return updated != 0
              ? updated
              : (a['id']?.toString() ?? '').compareTo(
                  b['id']?.toString() ?? '',
                );
        });
        final latest = snapshots.last;
        if (latest['history_deleted_at'] != null) continue;
        if (latest['is_archived'] == true) {
          final archivedAt = _malaysiaArchiveDay(latest['archived_at']);
          if (archivedAt == null || !archivedAt.isAfter(asOfDate)) {
            archived.add(latest);
          }
          continue;
        }
        final automaticFrom = _providerAutomaticArchiveFrom(latest, asOfDate);
        if (automaticFrom == null || automaticFrom.isAfter(asOfDate)) {
          continue;
        }
        final cause = _providerAutomaticArchiveCause(latest, asOfDate);
        archived.add(<String, dynamic>{
          ...latest,
          '_auto_archived': true,
          '_auto_archive_cause': cause,
          '_archive_effective_date': _providerDateForQuery(automaticFrom),
          '_archive_reason': cause == 'Terminated'
              ? 'Provider stopped being used on '
                    '${_formatDate(latest['lifecycle_date'])}.'
              : 'Contract expired on '
                    '${_formatDate(latest['expiry_date'])}.',
        });
      }

      return _TableLoadResult(table: table, module: module, records: archived);
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  // Licences are property-wide rows, not monthly provider snapshots. An
  // automatic archive is calculated from the REAL date, never a future report.
  DateTime? _licenceAutomaticArchiveFrom(Map<String, dynamic> record) {
    final expiry = _providerDate(record['expiry_date']);
    DateTime? from = expiry == null
        ? null
        : DateTime(expiry.year, expiry.month, expiry.day + 1);
    final status = record['status']?.toString();
    final stop = (status == 'Terminated' || status == 'Replaced')
        ? _providerDate(record['lifecycle_date'])
        : null;
    if (stop != null) {
      final stoppedFrom = DateTime(stop.year, stop.month, stop.day + 1);
      if (from == null || stoppedFrom.isBefore(from)) from = stoppedFrom;
    }
    return from;
  }

  String _licenceAutomaticArchiveCause(Map<String, dynamic> record) {
    final expiry = _providerDate(record['expiry_date']);
    final status = record['status']?.toString();
    final stop = (status == 'Terminated' || status == 'Replaced')
        ? _providerDate(record['lifecycle_date'])
        : null;
    return stop != null && (expiry == null || !stop.isAfter(expiry))
        ? 'Terminated'
        : 'Expired';
  }

  bool _licenceRequiresRenewal(Map<String, dynamic> record) {
    if (record['_auto_archived'] == true) return true;
    final from = _licenceAutomaticArchiveFrom(record);
    return from != null && !from.isAfter(_archiveCutoffDate);
  }

  Future<_TableLoadResult> _loadArchivedLicences(
    DateTime asOfDate,
    String siteId,
  ) async {
    const table = 'licences_regulatory';
    const module = 'Licences & Regulatory';
    const pageSize = 500;
    try {
      final archived = <Map<String, dynamic>>[];
      final seen = <String>{};
      var offset = 0;
      while (true) {
        final response = await _supabase
            .from(table)
            .select()
            .eq('site_id', siteId)
            .order('id')
            .range(offset, offset + pageSize - 1);
        final rows = List<Map<String, dynamic>>.from(response);
        for (final record in rows) {
          final id = record['id']?.toString() ?? '';
          if (id.isNotEmpty && !seen.add(id)) continue;
          final isManual = _manuallyArchivedByCutoff(record, asOfDate);
          if (isManual) {
            archived.add(record);
            continue;
          }
          final from = _licenceAutomaticArchiveFrom(record);
          if (from == null || from.isAfter(asOfDate)) continue;
          final cause = _licenceAutomaticArchiveCause(record);
          archived.add(<String, dynamic>{
            ...record,
            '_auto_archived': true,
            '_auto_archive_cause': cause,
            '_archive_effective_date': _providerDateForQuery(from),
            '_archive_reason': cause == 'Terminated'
                ? 'Licence stopped being used on '
                      '${_formatDate(record['lifecycle_date'])}.'
                : 'Licence expired on '
                      '${_formatDate(record['expiry_date'])}.',
          });
        }
        if (rows.length < pageSize) break;
        offset += pageSize;
      }
      return _TableLoadResult(table: table, module: module, records: archived);
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  // Read all accessible rows, not only rows marked is_archived. The five
  // registers also contain display-only automatic archives.
  Future<List<Map<String, dynamic>>> _loadArchiveCandidates(
    String table,
    String siteId,
  ) async {
    const pageSize = 500;
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final response = await _supabase
          .from(table)
          .select()
          .eq('site_id', siteId)
          .order('id')
          .range(offset, offset + pageSize - 1);
      final batch = List<Map<String, dynamic>>.from(response);
      rows.addAll(batch);
      if (batch.length < pageSize) break;
      offset += pageSize;
    }
    return rows;
  }

  bool _manuallyArchivedByCutoff(
    Map<String, dynamic> record,
    DateTime asOfDate,
  ) {
    if (record['is_archived'] != true) return false;
    final archivedAt = _malaysiaArchiveDay(record['archived_at']);
    // Keep legacy manual archives with no archive timestamp.
    return archivedAt == null || !archivedAt.isAfter(asOfDate);
  }

  // Compliance Next Service Date is a reminder, never an archive trigger.
  // Retired and Superseded requirements belong in Archive even when their
  // persistent is_archived flag remains false.
  Future<_TableLoadResult> _loadArchivedCompliance(
    DateTime asOfDate,
    String siteId,
  ) async {
    const table = 'compliance_best_practices';
    const module = 'Compliance & Best Practices';
    try {
      final archived = <Map<String, dynamic>>[];
      final candidates = await _loadArchiveCandidates(table, siteId);
      for (final record in candidates) {
        final status = record['status']?.toString() ?? '';
        final inactive = status == 'Retired' || status == 'Superseded';
        final manual = _manuallyArchivedByCutoff(record, asOfDate);
        // For lifecycle-only archives, the effective retirement/supersession
        // date takes precedence over the time it was recorded.
        final effectiveDay = _malaysiaArchiveDay(record['lifecycle_date']) ??
            _malaysiaArchiveDay(record['archived_at']);
        if (!manual &&
            (!inactive ||
                (effectiveDay != null && effectiveDay.isAfter(asOfDate)))) {
          continue;
        }
        if (manual) {
          archived.add(record);
        } else {
          archived.add(<String, dynamic>{
            ...record,
            '_auto_archived': true,
            '_auto_archive_cause': status,
            if (effectiveDay != null)
              '_archive_effective_date': _providerDateForQuery(effectiveDay),
            '_archive_reason':
                record['archive_reason'] ??
                'Compliance requirement marked $status.',
          });
        }
      }
      return _TableLoadResult(table: table, module: module, records: archived);
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  // Exactly the same policy lifecycle dates used by Insurance Policies:
  // expiry starts the following day; termination takes effect on its date.
  DateTime? _policyAutomaticArchiveFrom(Map<String, dynamic> policy) {
    final validTo = _providerDate(policy['end_date']);
    final expiredFrom = validTo == null
        ? null
        : DateTime(validTo.year, validTo.month, validTo.day + 1);
    final termination = policy['policy_status'] == 'Terminated'
        ? _providerDate(policy['termination_date'])
        : null;
    if (termination == null) return expiredFrom;
    final terminatedFrom = DateUtils.dateOnly(termination);
    return expiredFrom == null || terminatedFrom.isBefore(expiredFrom)
        ? terminatedFrom
        : expiredFrom;
  }

  String _policyAutomaticArchiveCause(Map<String, dynamic> policy) {
    final validTo = _providerDate(policy['end_date']);
    final termination = policy['policy_status'] == 'Terminated'
        ? _providerDate(policy['termination_date'])
        : null;
    return termination != null &&
            (validTo == null || !termination.isAfter(validTo))
        ? 'Terminated'
        : 'Expired';
  }

  String _policyStatusAsOfCutoff(Map<String, dynamic> policy) {
    final asOfDate = _archiveCutoffDate;
    final validTo = _providerDate(policy['end_date']);
    final terminated = policy['policy_status'] == 'Terminated'
        ? _providerDate(policy['termination_date'])
        : null;
    if (terminated != null &&
        !DateUtils.dateOnly(terminated).isAfter(asOfDate) &&
        (validTo == null || !terminated.isAfter(validTo))) {
      return 'Terminated';
    }
    if (validTo != null && DateUtils.dateOnly(validTo).isBefore(asOfDate)) {
      return 'Expired';
    }
    return 'Active';
  }

  Future<_TableLoadResult> _loadArchivedInsurancePolicies(
    DateTime asOfDate,
    String siteId,
  ) async {
    const table = 'insurance_policies';
    const module = 'Insurance Policies';
    try {
      final archived = <Map<String, dynamic>>[];
      final candidates = await _loadArchiveCandidates(table, siteId);
      for (final record in candidates) {
        final validFrom = _providerDate(record['start_date']);
        if (validFrom != null &&
            DateUtils.dateOnly(validFrom).isAfter(asOfDate)) {
          continue;
        }
        if (_manuallyArchivedByCutoff(record, asOfDate)) {
          archived.add(record);
          continue;
        }
        final automaticFrom = _policyAutomaticArchiveFrom(record);
        if (automaticFrom == null || automaticFrom.isAfter(asOfDate)) continue;
        final cause = _policyAutomaticArchiveCause(record);
        archived.add(<String, dynamic>{
          ...record,
          '_auto_archived': true,
          '_auto_archive_cause': cause,
          '_archive_effective_date': _providerDateForQuery(automaticFrom),
          '_archive_reason': cause == 'Terminated'
              ? 'Policy terminated on '
                    '${_formatDate(record['termination_date'])}.'
              : 'Policy expired on ${_formatDate(record['end_date'])}.',
        });
      }
      return _TableLoadResult(table: table, module: module, records: archived);
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  // Insurance Claims only automatically archive if the effective status
  // is Closed AND the day after Closure Date has arrived. Paid, Approved
  // and Rejected do not automatically archive. Dated status_history events
  // are honored without modifying the saved claim.
  Map<String, dynamic> _claimSnapshotAtCutoff(
    Map<String, dynamic> record,
    DateTime asOfDate,
  ) {
    final snapshot = Map<String, dynamic>.from(record);
    final history = record['status_history'];
    Map<String, dynamic>? latest;
    if (history is List) {
      for (final item in history) {
        if (item is! Map) continue;
        final event = Map<String, dynamic>.from(item);
        final eventDate = _providerDate(event['date']);
        if (eventDate == null || eventDate.isAfter(asOfDate)) continue;
        // Keep the same saved-event order as the Insurance Claims module.
        latest = event;
      }
    }
    if (latest != null) {
      for (final field in [
        'status',
        'amount_approved',
        'amount_paid',
        'closure_date',
      ]) {
        if (latest.containsKey(field)) snapshot[field] = latest[field];
      }
    }
    return snapshot;
  }

  DateTime? _claimAutomaticArchiveFrom(
    Map<String, dynamic> record,
    DateTime asOfDate,
  ) {
    final snapshot = _claimSnapshotAtCutoff(record, asOfDate);
    if (snapshot['status']?.toString() != 'Closed') return null;
    final closed = _providerDate(snapshot['closure_date']);
    if (closed == null) return null;
    return DateTime(closed.year, closed.month, closed.day + 1);
  }

  Future<_TableLoadResult> _loadArchivedInsuranceClaims(
    DateTime asOfDate,
    String siteId,
  ) async {
    const table = 'insurance_claims';
    const module = 'Insurance Claims';
    try {
      final archived = <Map<String, dynamic>>[];
      final candidates = await _loadArchiveCandidates(table, siteId);
      for (final record in candidates) {
        final submitted =
            _providerDate(record['submitted_date']) ??
            _providerDate(record['incident_date']);
        if (submitted != null &&
            DateUtils.dateOnly(submitted).isAfter(asOfDate)) {
          continue;
        }
        final manual = _manuallyArchivedByCutoff(record, asOfDate);
        final manualFrom = manual
            ? _malaysiaArchiveDay(record['archived_at'])
            : null;
        final archiveFrom = _claimAutomaticArchiveFrom(record, asOfDate);
        final automatic = archiveFrom != null && !archiveFrom.isAfter(asOfDate);
        if (!manual && !automatic) continue;
        // Follow Insurance Claims: an undated legacy manual archive stays
        // undated; otherwise the earlier dated archive event takes priority.
        if (manual &&
            (manualFrom == null ||
                !automatic ||
                !manualFrom.isAfter(archiveFrom))) {
          archived.add(record);
          continue;
        }
        final snapshot = _claimSnapshotAtCutoff(record, asOfDate);
        archived.add(<String, dynamic>{
          ...snapshot,
          '_auto_archived': true,
          '_auto_archive_cause': 'Closed',
          '_archive_effective_date': _providerDateForQuery(archiveFrom!),
          '_archive_reason':
              'Claim closed on '
              '${_formatDate(snapshot['closure_date'])}.',
        });
      }
      return _TableLoadResult(table: table, module: module, records: archived);
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  // Read the same authenticated committee history and terms as Site Profile.
  // Do not query or edit its historical tables directly: the property-sites
  // service applies the existing per-property access rules.
  Future<List<Map<String, dynamic>>> _loadSiteProfileTerms(
    String siteId,
    DateTime reportingMonth,
  ) async {
    var session = _supabase.auth.currentSession;
    if (session == null) {
      throw StateError('Sign in to view Site Profile archived records.');
    }
    if (session.isExpired) {
      session = (await _supabase.auth.refreshSession()).session;
      if (session == null) {
        throw StateError('The session has expired. Please sign in again.');
      }
    }
    final response = await _supabase.functions.invoke(
      'property-sites',
      body: {
        'action': 'get_committee_terms_authenticated',
        'site_id': siteId,
        'report_month': _providerDateForQuery(reportingMonth),
      },
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
    );
    final data = response.data;
    if (data is! Map || data['terms'] is! List) {
      throw StateError('The property service returned invalid committee terms.');
    }
    return (data['terms'] as List)
        .whereType<Map>()
        .map((term) => Map<String, dynamic>.from(term))
        .toList();
  }

  bool _closedCommitteeTerm(Map<String, dynamic> term) =>
      term['is_closed'] == true || term['status'] == 'closed';

  bool _restoredCommitteeTerm(Map<String, dynamic> term) =>
      !_closedCommitteeTerm(term) &&
      (term['is_restored_history'] == true || term['status'] == 'restored');

  // Manual closure uses its actual date; automatic expiry uses the first
  // inactive month, not the date the server happened to synchronize expiry.
  DateTime? _committeeArchiveDay(Map<String, dynamic> term) {
    if (term['closed_by'] != null) {
      return _malaysiaArchiveDay(term['closed_at']);
    }
    final end = _providerDate(term['effective_until']);
    return end == null ? null : DateTime(end.year, end.month + 1);
  }

  bool _committeeMemberEffective(
    Map<String, dynamic> member,
    DateTime month,
  ) {
    final from = _providerDate(member['effective_from']);
    final removed = _providerDate(member['removed_from']);
    return from != null &&
        !month.isBefore(_providerMonth(from)) &&
        (removed == null || month.isBefore(_providerMonth(removed)));
  }

  // Match the live Site Profile lifecycle. The selected report month is
  // never used to predict closure or to reactivate a restored term.
  Future<_TableLoadResult> _loadArchivedSiteProfile(
    DateTime asOfDate,
    String? siteId,
  ) async {
    const table = 'site_profile';
    const module = 'Site Profile';
    if (siteId == null || siteId.trim().isEmpty) {
      return const _TableLoadResult(table: table, module: module);
    }
    try {
      final currentMonth = _providerMonth(asOfDate);
      final terms = await _loadSiteProfileTerms(siteId, currentMonth);
      final members =
          await PropertySitesService.getCommitteeHistoryAuthenticated(
            siteId: siteId,
          );
      final termsById = <String, Map<String, dynamic>>{
        for (final term in terms)
          if (term['id'] != null) term['id'].toString(): term,
      };
      final archived = <Map<String, dynamic>>[];

      for (final term in terms) {
        if (!_closedCommitteeTerm(term) || term['needs_date_review'] == true) {
          continue;
        }
        final firstArchived = _committeeArchiveDay(term);
        if (firstArchived != null && firstArchived.isAfter(asOfDate)) continue;
        final manual = term['closed_by'] != null;
        final end = _providerDate(term['effective_until']);
        final roster = members
            .where(
              (member) =>
                  member['term_id']?.toString() == term['id']?.toString(),
            )
            .toList();
        final distinctMemberIds = roster
            .map((member) =>
                member['member_id']?.toString() ?? member['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        final memberNames = roster
            .map((member) {
              final name = member['member_name']?.toString().trim() ?? '';
              final designation = member['designation']?.toString().trim() ?? '';
              if (name.isEmpty) return '';
              return designation.isEmpty ? name : '$name ($designation)';
            })
            .where((name) => name.isNotEmpty)
            .toSet()
            .join(', ');
        archived.add({
          ...term,
          'site_id': siteId,
          '_site_profile_kind': 'term',
          '_auto_archived': !manual,
          '_auto_archive_cause': 'Closed',
          if (firstArchived != null)
            '_archive_effective_date': _providerDateForQuery(firstArchived),
          '_archive_reason': manual
              ? 'Committee term was closed manually.'
              : end == null
                  ? 'Committee term was closed.'
                  : 'Committee term ended in ${_formatMonthYear(_providerMonth(end))}.',
          '_member_count': distinctMemberIds.length,
          '_member_summary': memberNames,
        });
      }

      for (final member in members) {
        // Site Profile only considers an explicit removal an archived member.
        final reason = member['removal_reason']?.toString().trim() ?? '';
        if (reason.isEmpty) continue;
        // Site Profile stores Removed From as the FIRST inactive month.
        // Effective Until is the preceding month; archive from the next one.
        final removed = _providerDate(member['removed_from']);
        if (removed == null) continue;
        final firstArchived = _providerMonth(removed);
        if (firstArchived.isAfter(currentMonth)) continue;
        final termId = member['term_id']?.toString();
        final term = termsById[termId];
        // A closed or restored historical term already contains its full roster.
        if (term == null ||
            _closedCommitteeTerm(term) ||
            _restoredCommitteeTerm(term)) {
          continue;
        }
        final identity = member['member_id']?.toString();
        if (identity == null || identity.isEmpty) continue;
        // A restored active version replaces the archive card; the original
        // membership history stays in the database for past reports and PDFs.
        final activeReplacement = members.any((other) =>
            other['id']?.toString() != member['id']?.toString() &&
            other['member_id']?.toString() == identity &&
            other['term_id']?.toString() == termId &&
            _committeeMemberEffective(other, currentMonth));
        if (activeReplacement) continue;
        archived.add({
          ...member,
          'site_id': siteId,
          '_site_profile_kind': 'member',
          '_term_name': term['term_name'],
          '_term_effective_until': term['effective_until'],
          '_auto_archived': false,
          '_archive_effective_date': _providerDateForQuery(firstArchived),
          '_archive_reason': reason,
        });
      }
      return _TableLoadResult(table: table, module: module, records: archived);
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  Future<_TableLoadResult> _loadTable(
    String table,
    String module,
    DateTime asOfDate, {
    required String siteId,
  }) async {
    if (table == 'site_profile') {
      return _loadArchivedSiteProfile(asOfDate, siteId);
    }
    if (table == 'service_providers') {
      return _loadArchivedServiceProviders(asOfDate, siteId);
    }
    if (table == 'licences_regulatory') {
      return _loadArchivedLicences(asOfDate, siteId);
    }
    if (table == 'insurance_policies') {
      return _loadArchivedInsurancePolicies(asOfDate, siteId);
    }
    if (table == 'insurance_claims') {
      return _loadArchivedInsuranceClaims(asOfDate, siteId);
    }
    if (table == 'compliance_best_practices') {
      return _loadArchivedCompliance(asOfDate, siteId);
    }
    try {
      final response = await _supabase
          .from(table)
          .select()
          .eq('site_id', siteId)
          .eq('is_archived', true)
          .order('archived_at', ascending: false);

      return _TableLoadResult(
        table: table,
        module: module,
        records: List<Map<String, dynamic>>.from(response),
      );
    } catch (e) {
      return _TableLoadResult(
        table: table,
        module: module,
        error: e.toString(),
      );
    }
  }

  Future<void> _loadRecords() async {
    if (!mounted) return;
    final loadVersion = ++_loadVersion;

    setState(() {
      _loading = true;
      _loadErrors = {};
    });

    // Load the selected property's current archive across all years. The
    // independent filters select an archive year/month without modifying
    // the report context or treating future expiry dates as archived.
    final archiveCutoff = _malaysiaToday();
    late final _ArchiveReportContext reportContext;
    late final String siteName;
    try {
      reportContext = await _resolveReportContext();
      final accessible = await PropertySitesService.listSitesAuthenticated();
      final matching = accessible.sites.where(
        (site) => site['id']?.toString() == reportContext.siteId,
      );
      if (matching.isEmpty) {
        throw StateError('You do not have access to the selected property.');
      }
      siteName =
          _firstText([matching.first['site_name']]) ?? 'Selected property';
    } catch (e) {
      if (!mounted || loadVersion != _loadVersion) return;
      setState(() {
        _records = [];
        _resolvedReportId = null;
        _resolvedSiteId = null;
        _resolvedSiteName = null;
        _loadErrors = {'Reporting Period': e.toString()};
        _loading = false;
      });
      return;
    }

    if (!mounted || loadVersion != _loadVersion) return;

    final results = await Future.wait(
      _modules.entries.map(
        (entry) => _loadTable(
          entry.key,
          entry.value,
          archiveCutoff,
          siteId: reportContext.siteId!,
        ),
      ),
    );

    if (!mounted || loadVersion != _loadVersion) return;

    final records = <_ArchivedEntry>[];
    final errors = <String, String>{};
    final seen = <String>{};

    for (final result in results) {
      if (result.error != null) {
        errors[result.module] = result.error!;
        continue;
      }

      for (final record in result.records) {
        final id = record['id']?.toString() ?? '';
        final identity = result.table == 'site_profile'
            ? '${result.table}:${record['_site_profile_kind']}:$id'
            : '${result.table}:$id';
        if (id.isEmpty || !seen.add(identity)) continue;
        final archiveDay = _entryArchiveDay(record);
        if (archiveDay != null && archiveDay.isAfter(archiveCutoff)) continue;
        records.add(
          _ArchivedEntry(
            table: result.table,
            module: result.module,
            record: record,
          ),
        );
      }
    }

    records.sort((a, b) {
      final aDate = _entryArchiveDay(a.record);
      final bDate = _entryArchiveDay(b.record);

      if (aDate == null && bDate == null) return a.key.compareTo(b.key);
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      final byDate = bDate.compareTo(aDate);
      return byDate != 0 ? byDate : a.key.compareTo(b.key);
    });

    if (!mounted || loadVersion != _loadVersion) return;
    setState(() {
      final contextChanged = _resolvedSiteId != reportContext.siteId ||
          _reportingMonth.year != reportContext.month.year;
      if (contextChanged) {
        _selectedYear = reportContext.month.year.toString();
        _selectedArchiveMonth = 'All Months';
        _selectedModule = 'All Modules';
      }
      _archiveCutoffDate = archiveCutoff;
      _reportingMonth = reportContext.month;
      _resolvedReportId = reportContext.id;
      _resolvedSiteId = reportContext.siteId;
      _resolvedSiteName = siteName;
      _records = records;
      _loadErrors = errors;
      _loading = false;
    });
  }

  List<String> get _availableArchiveYears {
    final years = <int>{_reportingMonth.year};
    final selected = int.tryParse(_selectedYear);
    if (selected != null) years.add(selected);
    for (final entry in _records) {
      final date = _entryArchiveDay(entry.record);
      if (date != null) years.add(date.year);
    }
    final ordered = years.toList()..sort((a, b) => b.compareTo(a));
    return ['All Years', ...ordered.map((year) => year.toString())];
  }

  List<_ArchivedEntry> get _filteredRecords => _records.where((entry) {
    if (_selectedModule != 'All Modules' && entry.module != _selectedModule) {
      return false;
    }
    final date = _entryArchiveDay(entry.record);
    // Undated legacy archives must not be assigned an invented year/month.
    if (date == null) {
      return _selectedYear == 'All Years' &&
          _selectedArchiveMonth == 'All Months';
    }
    return (_selectedYear == 'All Years' ||
            date.year.toString() == _selectedYear) &&
        (_selectedArchiveMonth == 'All Months' ||
            _monthNames[date.month - 1] == _selectedArchiveMonth);
  }).toList();

  String get _archivePeriodLabel {
    if (_selectedYear == 'All Years') {
      return _selectedArchiveMonth == 'All Months'
          ? 'All Years'
          : '$_selectedArchiveMonth (All Years)';
    }
    return _selectedArchiveMonth == 'All Months'
        ? 'January - December $_selectedYear'
        : '$_selectedArchiveMonth $_selectedYear';
  }

  // ============================================================
  // DISPLAY HELPERS
  // ============================================================

  String _formatDate(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) {
      return '—';
    }

    final date = DateTime.tryParse(value.toString());

    if (date == null) {
      return value.toString();
    }

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  // Display the same Malaysia calendar day used by the filters and sorting.
  String _archiveDateLabel(Map<String, dynamic> record) =>
      _formatDate(_entryArchiveDay(record));

  String _committeeMonthLabel(dynamic value) {
    final date = _providerDate(value);
    return date == null ? 'Not set' : _formatMonthYear(_providerMonth(date));
  }

  String? _firstText(List<dynamic> values) {
    for (final value in values) {
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }

    return null;
  }

  String _titleFor(_ArchivedEntry entry) {
    final record = entry.record;

    switch (entry.table) {
      case 'site_profile':
        return record['_site_profile_kind'] == 'term'
            ? (_firstText([record['term_name']]) ?? 'Committee Term')
            : (_firstText([record['member_name']]) ?? 'Committee Member');

      case 'compliance_best_practices':
        return _firstText([record['name'], record['item_practice']]) ??
            'Compliance Record';

      case 'insurance_claims':
        return _firstText([record['claim_number']]) ?? 'Insurance Claim';

      case 'insurance_policies':
        return _firstText([record['policy_category'], record['policy_name']]) ??
            'Insurance Policy';

      case 'licences_regulatory':
        return _firstText([record['name']]) ?? 'Licence / Requirement';

      case 'service_providers':
        return _firstText([record['company_pic'], record['service']]) ??
            'Service Provider';

      default:
        return 'Archived Record';
    }
  }

  IconData _moduleIcon(String table, {String? kind}) {
    switch (table) {
      case 'site_profile':
        return kind == 'term' ? Icons.groups_outlined : Icons.person_outline;

      case 'compliance_best_practices':
        return Icons.fact_check_outlined;

      case 'insurance_claims':
        return Icons.receipt_long_outlined;

      case 'insurance_policies':
        return Icons.policy_outlined;

      case 'licences_regulatory':
        return Icons.verified_user_outlined;

      case 'service_providers':
        return Icons.business_outlined;

      default:
        return Icons.archive_outlined;
    }
  }

  // ============================================================
  // RECORD DETAILS
  // ============================================================

  List<MapEntry<String, String>> _recordDetails(_ArchivedEntry entry) {
    final record = entry.record;
    final details = <MapEntry<String, String>>[];

    void add(String label, dynamic value) {
      if (value == null || value.toString().trim().isEmpty) {
        return;
      }

      details.add(MapEntry(label, value.toString()));
    }

    switch (entry.table) {
      case 'site_profile':
        if (record['_site_profile_kind'] == 'term') {
          add('Record Type', 'Closed Committee Term');
          if (record['effective_from'] != null) {
            add(
              'Effective From',
              _committeeMonthLabel(record['effective_from']),
            );
          }
          if (record['effective_until'] != null) {
            add(
              'Effective Until',
              _committeeMonthLabel(record['effective_until']),
            );
          }
          add('Total Recorded Members', record['_member_count']);
          add('Recorded Members', record['_member_summary']);
        } else {
          add('Record Type', 'Removed Committee Member');
          add('Committee Term', record['_term_name']);
          add('Designation', record['designation']);
          if (record['effective_from'] != null) {
            add(
              'Effective From',
              _committeeMonthLabel(record['effective_from']),
            );
          }
          final removal = _providerDate(record['removed_from']);
          if (removal != null) {
            add(
              'Effective Until',
              _formatMonthYear(DateTime(removal.year, removal.month - 1)),
            );
            add('Removed From', _formatMonthYear(_providerMonth(removal)));
          }
        }
        break;

      case 'compliance_best_practices':
        add('Category', record['category']);
        add('Responsible Person', record['responsible_person']);
        add('Review Frequency', record['review_frequency']);

        if (record['last_review_date'] != null) {
          add('Last Review Date', _formatDate(record['last_review_date']));
        }

        if (record['next_review_date'] != null) {
          add('Next Review Date', _formatDate(record['next_review_date']));
        }

        add('Status', record['status']);
        add('Required Status', record['required_status']);
        add('Compliance Status', record['compliant_status']);
        add('Report ID', record['report_id']);
        add('Report Line', record['line_no']);
        add('Description', record['description']);
        add('Practice', record['item_practice']);
        add('Action Remarks', record['action_remarks']);

        if (record['lifecycle_date'] != null) {
          add('Lifecycle Date', _formatDate(record['lifecycle_date']));
        }

        add('Lifecycle Reason', record['lifecycle_reason']);
        break;

      case 'insurance_claims':
        add('Claim Type', record['claim_type']);
        add('Status', record['status']);
        add('Claimed Amount (RM)', record['amount_claimed']);
        add('Approved Amount (RM)', record['amount_approved']);
        add('Paid Amount (RM)', record['amount_paid']);

        if (record['incident_date'] != null) {
          add('Incident Date', _formatDate(record['incident_date']));
        }

        if (record['submitted_date'] != null) {
          add('Submitted Date', _formatDate(record['submitted_date']));
        }

        add('Incident Description', record['incident_description']);
        break;

      case 'insurance_policies':
        add('Insurer', record['insurer']);
        add('Policy Number', record['policy_number']);
        add('Policy Type', record['policy_type']);
        add('Status', _policyStatusAsOfCutoff(record));

        if (record['start_date'] != null) {
          add('Start Date', _formatDate(record['start_date']));
        }

        if (record['end_date'] != null) {
          add('End Date', _formatDate(record['end_date']));
        }

        if (record['renewal_date'] != null) {
          add('Renewal Date', _formatDate(record['renewal_date']));
        }
        break;

      case 'licences_regulatory':
        add('Record Type', record['record_type']);
        add('Issuing Authority', record['issuing_authority']);
        add('Reference Number', record['reference_number']);
        add(
          'Archive Type',
          record['_auto_archived'] == true ? 'Automatic' : 'Manual',
        );
        add(
          'Status',
          record['_auto_archived'] == true
              ? (record['_auto_archive_cause'] == 'Terminated'
                    ? 'Terminated'
                    : 'Expired')
              : record['status'],
        );

        if (record['issue_date'] != null) {
          add('Issue Date', _formatDate(record['issue_date']));
        }

        if (record['expiry_date'] != null) {
          add('Expiry Date', _formatDate(record['expiry_date']));
        }

        if (record['renewal_date'] != null) {
          add('Renewal Date', _formatDate(record['renewal_date']));
        }

        add('Responsible Person', record['responsible_person']);
        add('Remarks', record['remarks']);
        break;

      case 'service_providers':
        add('Service', record['service']);
        add('Contact', record['contact']);
        add(
          'Archive Type',
          record['_auto_archived'] == true ? 'Automatic' : 'Manual',
        );
        add(
          'Status',
          record['_auto_archived'] == true
              ? (record['_auto_archive_cause'] == 'Terminated'
                    ? 'No Longer Used'
                    : 'Expired')
              : record['status'],
        );

        if (record['commencement_date'] != null) {
          add('Start Date', _formatDate(record['commencement_date']));
        }

        if (record['expiry_date'] != null) {
          add('Expiry / Renewal Date', _formatDate(record['expiry_date']));
        }

        add('Schedule / Staffing', record['schedule_staffing']);
        add('Notes', record['notes']);
        add('Lifecycle Reason', record['lifecycle_reason']);
        break;
    }

    return details;
  }

  // ============================================================
  // DUPLICATE CHECK
  // ============================================================

  String _normaliseName(dynamic value) {
    return value?.toString().trim().toLowerCase() ?? '';
  }

  Future<bool> _hasActiveComplianceDuplicate(_ArchivedEntry entry) async {
    final archivedName = _normaliseName(
      _firstText([entry.record['name'], entry.record['item_practice']]),
    );

    if (archivedName.isEmpty) return false;
    final siteId = _firstText([entry.record['site_id']]);
    if (siteId == null || siteId != _resolvedSiteId) {
      throw StateError('The archived record does not belong to this property.');
    }

    final response = await _supabase
        .from('compliance_best_practices')
        .select('id, name, item_practice, status')
        .eq('site_id', siteId)
        .eq('is_archived', false);

    final activeRecords = List<Map<String, dynamic>>.from(response);

    return activeRecords.any((record) {
      if (record['id']?.toString() == entry.id ||
          record['status'] == 'Retired' || record['status'] == 'Superseded') {
        return false;
      }

      final activeName = _normaliseName(
        _firstText([record['name'], record['item_practice']]),
      );

      return activeName == archivedName;
    });
  }

  // ============================================================
  // RESTORE RECORD
  // ============================================================

  // Restoring a provider must go through its monthly module: a direct
  // is_archived=false update would revive an expired contract without dates
  // and would fail to reconcile linked future monthly copies.
  Future<void> _manageServiceProvider(_ArchivedEntry entry) async {
    if (_restoring.contains(entry.key)) return;
    setState(() => _restoring.add(entry.key));
    try {
      final sourceReportId = entry.record['report_id']?.toString();
      if (sourceReportId == null || sourceReportId.isEmpty) {
        throw StateError('This provider has no linked monthly report.');
      }
      final source = await _supabase
          .from('monthly_reports')
          .select('site_id')
          .eq('id', sourceReportId)
          .maybeSingle();
      final siteId = source?['site_id']?.toString();
      if (siteId == null || siteId.isEmpty || siteId != _resolvedSiteId) {
        throw StateError('The provider does not belong to the selected property.');
      }
      final effectiveArchive = _entryArchiveDay(entry.record);
      final earliestMonth = effectiveArchive == null
          ? DateTime(1900)
          : _providerMonth(effectiveArchive);
      final report = await _supabase
          .from('monthly_reports')
          .select('id,site_id,report_month')
          .eq('site_id', siteId)
          .gte('report_month', _providerDateForQuery(earliestMonth))
          .order('report_month', ascending: false)
          .limit(1)
          .maybeSingle();
      if (report == null) {
        throw StateError(
          'Create or open a monthly report from '
          '${_formatDate(earliestMonth)} onward before restoring or renewing '
          'this provider.',
        );
      }
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              ServiceProvidersPage(report: Map<String, dynamic>.from(report)),
        ),
      );
      if (mounted) await _loadRecords();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to open Service Providers: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring.remove(entry.key));
    }
  }

  Future<void> _manageLicence(_ArchivedEntry entry) async {
    if (_restoring.contains(entry.key)) return;
    setState(() => _restoring.add(entry.key));
    try {
      final siteId = entry.record['site_id']?.toString() ?? '';
      if (siteId.isEmpty || siteId != _resolvedSiteId) {
        throw StateError('The licence does not belong to the selected property.');
      }
      final report = await _supabase
          .from('monthly_reports')
          .select('id,site_id,report_month')
          .eq('site_id', siteId)
          .order('report_month', ascending: false)
          .limit(1)
          .maybeSingle();
      if (report == null) {
        throw StateError(
          'Open or create a monthly report for this property to renew '
          'or reactivate the licence.',
        );
      }
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              LicenseRegulatoryPage(report: Map<String, dynamic>.from(report)),
        ),
      );
      if (mounted) await _loadRecords();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to open Licences & Regulatory: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring.remove(entry.key));
    }
  }

  // Committee terms and members must be managed using Site Profile's
  // authenticated actions. A generic archive restore/delete would corrupt
  // historical membership periods, so this page never writes those rows.
  Future<void> _manageSiteProfile(_ArchivedEntry entry) async {
    if (_restoring.contains(entry.key)) return;
    final siteId = _firstText([entry.record['site_id']]);
    if (siteId == null || siteId != _resolvedSiteId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The Site Profile property is missing.')),
      );
      return;
    }
    // Site Profile manages the live committee lifecycle independently of the
    // selected report. Open the archive event's month when it is known.
    final archiveDay = _entryArchiveDay(entry.record);
    final targetMonth = archiveDay == null
        ? _reportingMonth
        : _providerMonth(archiveDay);
    setState(() => _restoring.add(entry.key));
    try {
      final sameReportMonth =
          targetMonth.year == _reportingMonth.year &&
          targetMonth.month == _reportingMonth.month &&
          siteId == _resolvedSiteId;
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SiteProfilePage(
            siteId: siteId,
            reportMonth: targetMonth,
            reportId: sameReportMonth ? _resolvedReportId : null,
          ),
        ),
      );
      if (mounted) await _loadRecords();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to open Site Profile: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring.remove(entry.key));
    }
  }

  Future<void> _deleteArchivedLicence(_ArchivedEntry entry) async {
    if (entry.table != 'licences_regulatory' ||
        _restoring.contains(entry.key) ||
        _deleting.contains(entry.key)) {
      return;
    }

    final licenceId = entry.id;
    final siteId = entry.record['site_id']?.toString() ?? '';

    if (licenceId.isEmpty || siteId.isEmpty || siteId != _resolvedSiteId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Licence ID or property ID is missing.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete Licence?'),
        content: Text(
          'Permanently delete "${_titleFor(entry)}" '
          'and its associated records? '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _deleting.add(entry.key));

    try {
      await _supabase.rpc(
        'delete_licence_regulatory_full',
        params: {'p_licence_id': licenceId, 'p_site_id': siteId},
      );

      final remaining = await _supabase
          .from('licences_regulatory')
          .select('id')
          .eq('id', licenceId)
          .eq('site_id', siteId)
          .maybeSingle();

      if (remaining != null) {
        throw StateError('The licence could not be deleted.');
      }

      if (!mounted) return;

      await _loadRecords();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Licence deleted successfully.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to delete licence: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(entry.key));
      }
    }
  }

  Future<void> _manageArchivedModule(_ArchivedEntry entry) async {
    if (_restoring.contains(entry.key)) return;
    setState(() => _restoring.add(entry.key));
    try {
      final siteId = entry.record['site_id']?.toString().trim() ?? '';
      if (siteId.isEmpty || siteId != _resolvedSiteId) {
        throw StateError('The record does not belong to the selected property.');
      }
      final effectiveArchive = _entryArchiveDay(entry.record);
      final earliestMonth = effectiveArchive == null
          ? DateTime(1900)
          : _providerMonth(effectiveArchive);
      final report = await _supabase
          .from('monthly_reports')
          .select('id,site_id,report_month')
          .eq('site_id', siteId)
          .gte('report_month', _providerDateForQuery(earliestMonth))
          .order('report_month', ascending: false)
          .limit(1)
          .maybeSingle();
      if (report == null) {
        throw StateError(
          'Open or create a monthly report for this property from '
          '${_formatDate(earliestMonth)} onward to manage this record.',
        );
      }
      if (!mounted) return;
      final selectedReport = Map<String, dynamic>.from(report);
      if (entry.table == 'insurance_policies') {
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => InsurancePoliciesPage(report: selectedReport),
          ),
        );
      } else if (entry.table == 'insurance_claims') {
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => InsuranceClaimsPage(report: selectedReport),
          ),
        );
      } else if (entry.table == 'compliance_best_practices') {
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ComplianceBestPracticesPage(report: selectedReport),
          ),
        );
      }
      if (mounted) await _loadRecords();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to open ${entry.module}: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring.remove(entry.key));
    }
  }


Future<void> _deleteArchivedEntry(_ArchivedEntry entry) async {
  if (!mounted ||
      _restoring.contains(entry.key) ||
      _deleting.contains(entry.key)) {
    return;
  }

  // Preserve the existing licence deletion procedure.
  if (entry.table == 'licences_regulatory') {
    await _deleteArchivedLicence(entry);
    return;
  }

  // Service Providers has linked monthly copies, staff and attachments.
  // Use its existing full-company deletion procedure.
  if (entry.table == 'service_providers') {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete Service Provider?'),
        content: const Text(
          'This company may have linked records across multiple '
          'reporting months. Open Service Providers and use its '
          'Delete function to remove the entire company safely.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open Service Providers'),
          ),
        ],
      ),
    );

    if (proceed == true && mounted) {
      await _manageServiceProvider(entry);
    }
    return;
  }

  if (entry.table != 'insurance_policies' &&
      entry.table != 'insurance_claims' &&
      entry.table != 'compliance_best_practices') {
    return;
  }

  final id = entry.record['id']?.toString().trim() ?? '';
  final siteId = entry.record['site_id']?.toString().trim() ?? '';

  if (id.isEmpty || siteId.isEmpty || siteId != _resolvedSiteId) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Record ID or property ID is missing.'),
        backgroundColor: AppColors.red,
      ),
    );
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.white,
      title: Text('Delete ${entry.module} Record?'),
      content: Text(
        'Permanently delete "${_titleFor(entry)}"? '
        'This action cannot be undone. '
        '${entry.table == 'insurance_policies' ? 'Policy attachment links will also be removed; original cloud files are retained.' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.red,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );

  if (confirmed != true || !mounted) return;

  setState(() => _deleting.add(entry.key));

  try {
    if (entry.table == 'insurance_policies') {
      // Confirm this policy belongs to the expected property.
      final policy = await _supabase
          .from('insurance_policies')
          .select('id')
          .eq('id', id)
          .eq('site_id', siteId)
          .maybeSingle();

      if (policy == null) {
        throw StateError('Policy not found for this property.');
      }

      // Uses the existing attachment-safe deletion RPC.
      final deleted = await _supabase.rpc(
        'delete_insurance_policy_with_attachments',
        params: {'p_policy_id': id},
      );

      if (deleted != true) {
        throw StateError('Policy deletion was not confirmed.');
      }
    } else {
      // Insurance Claims and Compliance & Best Practices.
      final deleted = await _supabase
          .from(entry.table)
          .delete()
          .eq('id', id)
          .eq('site_id', siteId)
          .select('id');

      if (deleted.isEmpty) {
        throw StateError(
          'No record deleted. Check your Supabase permissions.',
        );
      }
    }

    if (!mounted) return;

    await _loadRecords();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${entry.module} record deleted successfully.'),
      ),
    );
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to delete record: $e'),
          backgroundColor: AppColors.red,
        ),
      );
    }
  } finally {
    if (mounted) {
      setState(() => _deleting.remove(entry.key));
    }
  }
}

  Future<void> _restore(_ArchivedEntry entry) async {
    if (_restoring.contains(entry.key)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.restore_rounded, color: AppColors.red, size: 34),
        title: const Text(
          'Restore Archived Record',
          style: TextStyle(color: AppColors.black, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Restore "${_titleFor(entry)}" to the active '
          '${entry.module} register?',
          style: const TextStyle(color: AppColors.grey, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.grey),
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _restoring.add(entry.key));

    try {
      // Do not restore an archived duplicate into the active compliance
      // master list when a matching active practice already exists.
      if (entry.table == 'compliance_best_practices') {
        final duplicateExists = await _hasActiveComplianceDuplicate(entry);

        if (!mounted) return;

        if (duplicateExists) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text(
                  'An active compliance practice with this name '
                  'already exists. The archived record was not restored. '
                  'Edit the active record instead.',
                ),
                backgroundColor: AppColors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );

          return;
        }
      }

      final siteId = _firstText([entry.record['site_id']]);
      if (siteId == null || siteId != _resolvedSiteId) {
        throw StateError('The archived record does not belong to this property.');
      }
      final now = DateTime.now().toUtc().toIso8601String();

      final restored = await _supabase
          .from(entry.table)
          .update({
            'is_archived': false,
            'archived_at': null,
            'archive_reason': null,
            'updated_at': now,
          })
          .eq('id', entry.id)
          .eq('site_id', siteId)
          .eq('is_archived', true)
          .select('id')
          .maybeSingle();

      if (restored == null) {
        throw Exception(
          'The record was not restored. It may already have been '
          'restored or you may not have permission to update it.',
        );
      }

      await _loadRecords();

      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${entry.module} record restored.'),
            backgroundColor: AppColors.black,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
    } catch (e, stackTrace) {
      debugPrint('Archived record restore error: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Unable to restore record: $e'),
            backgroundColor: AppColors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => _restoring.remove(entry.key));
      }
    }
  }

  // ============================================================
  // PAGE LAYOUT - annual property archive and independent filters.
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text(
          'Archived Records',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadRecords,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _whitePanel(Widget child, {EdgeInsetsGeometry? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
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
      child: child,
    );
  }

  Widget _buildTopHeader() {
    return Container(
      width: double.infinity,
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
            'PROPERTY MANAGEMENT',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Archived Records',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _loadErrors.containsKey('Reporting Period')
                ? 'Select a property and open its monthly report.'
                : '${_resolvedSiteName ?? 'Selected property'} • $_archivePeriodLabel',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalCard() {
    return _whitePanel(
      Row(
        children: [
          Container(
            height: 46,
            width: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.archive_outlined,
              size: 24,
              color: AppColors.red,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Total Archived Records',
                  style: TextStyle(
                    color: AppColors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${_filteredRecords.length}',
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
      padding: const EdgeInsets.all(18),
    );
  }

  Widget _archiveFilterDropdown({
    required String label,
    required String value,
    required List<String> options,
    required IconData icon,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey('archive-filter-$label-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.grey),
        filled: true,
        fillColor: AppColors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      items: options
          .map((option) => DropdownMenuItem<String>(
                value: option,
                child: Text(option, overflow: TextOverflow.ellipsis, maxLines: 1),
              ))
          .toList(),
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }

  Widget _buildModuleFilter() {
    return _whitePanel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.filter_list_outlined,
                color: AppColors.red,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Filter Records',
                  style: TextStyle(
                    color: AppColors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _selectedYear = _reportingMonth.year.toString();
                  _selectedArchiveMonth = 'All Months';
                  _selectedModule = 'All Modules';
                }),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                child: const Text('Reset Filters'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final filters = <Widget>[
                _archiveFilterDropdown(
                  label: 'Year',
                  value: _selectedYear,
                  options: _availableArchiveYears,
                  icon: Icons.calendar_today_outlined,
                  onChanged: (value) => setState(() => _selectedYear = value),
                ),
                _archiveFilterDropdown(
                  label: 'Month',
                  value: _selectedArchiveMonth,
                  options: ['All Months', ..._monthNames],
                  icon: Icons.calendar_month_outlined,
                  onChanged: (value) =>
                      setState(() => _selectedArchiveMonth = value),
                ),
                _archiveFilterDropdown(
                  label: 'Module',
                  value: _selectedModule,
                  options: ['All Modules', ..._modules.values],
                  icon: Icons.folder_open_outlined,
                  onChanged: (value) => setState(() => _selectedModule = value),
                ),
              ];
              if (constraints.maxWidth >= 720) {
                return Row(
                  children: [
                    for (var i = 0; i < filters.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: filters[i]),
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  for (var i = 0; i < filters.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    filters[i],
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6A23C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFF9A6700)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Some modules could not be loaded',
                  style: TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final error in _loadErrors.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${error.key}: ${error.value}',
                style: const TextStyle(color: AppColors.black, fontSize: 12),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _loadRecords,
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              icon: const Icon(Icons.refresh, size: 17),
              label: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return _whitePanel(
      Column(
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            color: AppColors.grey,
            size: 38,
          ),
          const SizedBox(height: 12),
          const Text(
            'No matching archived records',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Try changing the year, month or module filter.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _loadRecords,
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('Refresh Records'),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.red),
      );
    }

    final records = _filteredRecords;

    return RefreshIndicator(
      color: AppColors.red,
      onRefresh: _loadRecords,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 90),
        children: [
          _buildTopHeader(),
          const SizedBox(height: 20),
          _buildTotalCard(),
          const SizedBox(height: 16),
          _buildModuleFilter(),
          const SizedBox(height: 22),
          if (_loadErrors.isNotEmpty) ...[
            _buildErrorCard(),
            const SizedBox(height: 20),
          ],
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Archived Items',
                  style: TextStyle(
                    color: AppColors.black,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${records.length} ${records.length == 1 ? 'record' : 'records'}',
                style: const TextStyle(
                  color: AppColors.grey,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (records.isEmpty)
            _buildEmptyState()
          else
            for (final entry in records) _buildRecordCard(entry),
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value, double labelWidth) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              softWrap: true,
              style: const TextStyle(
                color: AppColors.black,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // ARCHIVED RECORD DROPDOWN
  // Collapsed: icon, title, module, archived date and dropdown arrow.
  // Expanded: all saved details, optional reason, one Restore action.
  // ============================================================

  Widget _buildRecordCard(_ArchivedEntry entry) {
    final record = entry.record;
    final details = _recordDetails(entry);
    final isRestoring = _restoring.contains(entry.key);
    final isDeleting = _deleting.contains(entry.key);
    final reason =
        (record['_archive_reason'] ?? record['archive_reason'])
            ?.toString()
            .trim() ??
        '';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.025),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey<String>('archived-${entry.key}'),
            initiallyExpanded: false,
            backgroundColor: AppColors.white,
            collapsedBackgroundColor: AppColors.white,
            iconColor: AppColors.grey,
            collapsedIconColor: AppColors.grey,
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            leading: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.red.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _moduleIcon(
                  entry.table,
                  kind: record['_site_profile_kind']?.toString(),
                ),
                color: AppColors.red,
                size: 22,
              ),
            ),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _titleFor(entry),
                        softWrap: true,
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.table == 'site_profile'
                            ? '${entry.module} · '
                                  '${record['_site_profile_kind'] == 'term' ? 'Committee Term' : 'Committee Member'}'
                            : entry.module,
                        softWrap: true,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_modules.containsKey(entry.table)) ...[
                        const SizedBox(height: 3),
                        Text(
                          record['_auto_archived'] == true
                              ? 'Automatically archived'
                              : 'Manually archived',
                          style: const TextStyle(
                            color: AppColors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        record['_auto_archived'] == true ||
                                entry.table == 'site_profile'
                            ? 'Archived From'
                            : 'Archived On',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _archiveDateLabel(record),
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            children: [
              const Divider(height: 1, color: AppColors.border),
              const SizedBox(height: 14),
              if (details.isNotEmpty)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final labelWidth = constraints.maxWidth < 440
                        ? 106.0
                        : 156.0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final detail in details)
                          _detailLine(detail.key, detail.value, labelWidth),
                      ],
                    );
                  },
                )
              else
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'No additional details available.',
                    style: TextStyle(color: AppColors.grey, fontSize: 12),
                  ),
                ),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.table == 'site_profile' &&
                                record['_site_profile_kind'] == 'member'
                            ? 'REASON FOR REMOVAL'
                            : 'ARCHIVE REASON',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        reason,
                        softWrap: true,
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Divider(height: 22, color: AppColors.border),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (entry.table == 'site_profile')
                      TextButton.icon(
                        onPressed: isRestoring
                            ? null
                            : () => _manageSiteProfile(entry),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: isRestoring
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.red,
                                ),
                              )
                            : const Icon(Icons.open_in_new, size: 18),
                        label: Text(
                          isRestoring ? 'Opening...' : 'Manage in Site Profile',
                        ),
                      )
                    else ...[
                      TextButton.icon(
                        onPressed: isRestoring || isDeleting
                            ? null
                            : () {
                                if (entry.table == 'service_providers') {
                                  _manageServiceProvider(entry);
                                } else if (entry.table == 'licences_regulatory') {
                                  if (_licenceRequiresRenewal(entry.record)) {
                                    _manageLicence(entry);
                                  } else {
                                    _restore(entry);
                                  }
                                } else if (entry.table == 'insurance_policies' ||
                                    entry.table == 'insurance_claims' ||
                                    entry.table == 'compliance_best_practices') {
                                  _manageArchivedModule(entry);
                                } else {
                                  _restore(entry);
                                }
                              },
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: isRestoring
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.red,
                                ),
                              )
                            : const Icon(Icons.restore, size: 18),
                        label: Text(
                          isRestoring
                              ? 'Opening...'
                              : entry.table == 'service_providers'
                              ? entry.record['_auto_archived'] == true
                                    ? entry.record['_auto_archive_cause'] ==
                                              'Terminated'
                                          ? 'Reactivate in Service Providers'
                                          : 'Renew in Service Providers'
                                    : 'Restore in Service Providers'
                              : entry.table == 'licences_regulatory' &&
                                    _licenceRequiresRenewal(entry.record)
                              ? entry.record['_auto_archive_cause'] ==
                                        'Terminated'
                                    ? 'Reactivate in Licences & Regulatory'
                                    : 'Renew in Licences & Regulatory'
                              : entry.table == 'insurance_policies'
                              ? entry.record['_auto_archived'] == true
                                    ? entry.record['_auto_archive_cause'] ==
                                              'Terminated'
                                          ? 'Reactivate in Insurance Policies'
                                          : 'Renew in Insurance Policies'
                                    : 'Restore in Insurance Policies'
                              : entry.table == 'insurance_claims'
                              ? entry.record['_auto_archived'] == true
                                    ? 'Reopen in Insurance Claims'
                                    : 'Restore in Insurance Claims'
                              : entry.table == 'compliance_best_practices'
                              ? 'Restore in Compliance & Best Practices'
                              : 'Restore',
                        ),
                      ),
                      // Delete button for all archived modules.
                      TextButton.icon(
                        onPressed: isRestoring || isDeleting
                            ? null
                            : () => _deleteArchivedEntry(entry),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                        ),
                        label: Text(
                          isDeleting ? 'Deleting...' : 'Delete',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}