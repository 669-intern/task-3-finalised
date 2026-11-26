import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Adjust the path if finance_calc.dart lives in another folder.
import 'finance/finance_calc.dart';
import 'property_sites_service.dart';

// Fixed deposit classification at the report cutoff (see fdCutoff).
enum _FdClass { active, matured, notYetPlaced, unclassified }

class ExportPdfPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const ExportPdfPage({super.key, required this.report});

  @override
  State<ExportPdfPage> createState() => _ExportPdfPageState();
}

class _ExportPdfPageState extends State<ExportPdfPage> {
  final supabase = Supabase.instance.client;

  // Live source data is loaded for the current preview and refreshed on generation.
  bool loading = false;
  String? error;

  static const _versionBucket = 'monthly-report-versions';
  bool _loadingVersions = true;
  bool _loadingSavedFiles = false;
  bool _generatingVersion = false;
  bool _versionActionBusy = false;
  bool _isAdmin = false;
  bool _canGenerateVersion = false;
  String? _versionError;
  String? _generatingUserName;
  List<Map<String, dynamic>> _savedVersions = [];
  Map<String, dynamic>? _selectedVersion;
  Map<String, dynamic>? _savedSnapshot;
  Uint8List? _savedPdfBytes;

  // The right-hand panel is an independent preview of the CURRENT report.
  // It never reads saved-version bytes and never writes a version to storage.
  bool _loadingLivePreview = false;
  Uint8List? _livePdfBytes;
  DateTime? _livePreviewUpdatedAt;
  String? _livePreviewError;
  int _livePreviewRevision = 0;
  Map<String, dynamic> _currentReportRecord = {};

  bool financeExpanded = true;
  bool operationsExpanded = false;
  bool occupancyUnitExpanded = false;
  bool contractsComplianceExpanded = false;

  // Finance
  Map<String, dynamic>? billing;
  Map<String, dynamic>? arrears;
  Map<String, dynamic>? utilities;

  // Previous month's closing arrears. Only used when this report has no saved
  // arrears row yet (mirrors what the Arrears screen shows in that case).
  double? carriedOpening;

  List<Map<String, dynamic>> transfers = [];
  List<Map<String, dynamic>> fixedDeposits = [];

  // Latest approved FD allocation saved for this site on or before the
  // selected report month. Null means no allocation was provided.
  double? approvedFdAllocation;
  List<Map<String, dynamic>> expenditures = [];

  // Section 5.2: dated Defaulters comparison.
  List<Map<String, dynamic>> defaulterPdfRows = [];
  List<DateTime> defaulterPdfBalanceDates = [];
  String? defaulterPdfError;

  // Report-specific Operations
  List<Map<String, dynamic>> maintenanceWorks = [];
  List<Map<String, dynamic>> pendingMaintenanceWorks = [];
  List<Map<String, dynamic>> maintenanceDashboardWorks = [];
  List<Map<String, dynamic>> complaints = [];
  List<Map<String, dynamic>> resolutions = [];
  List<Map<String, dynamic>> liftIncidents = [];
  // Section 7.3 only: selected-month rows and historical Mantrap incidents.
  List<Map<String, dynamic>> monthlyLiftSummary = [];
  List<Map<String, dynamic>> mantrapHistory = [];
  List<Map<String, dynamic>> assetConditions = [];

  // Property-wide Operations
  List<Map<String, dynamic>> assets = [];
  List<Map<String, dynamic>> serviceHistory = [];

  // Occupancy & Unit Management
  int? propertyTotalUnits;
  List<Map<String, dynamic>> occupancyRecords = [];
  List<Map<String, dynamic>> unitMovements = [];
  List<Map<String, dynamic>> renovationWorks = [];
  List<Map<String, dynamic>> subSalesUnits = [];

  // Contracts & Compliance
  List<Map<String, dynamic>> serviceProviders = [];
  List<Map<String, dynamic>> staffReportProviders = [];
  final Map<String, Map<String, dynamic>> staffByProviderId = {};
  List<Map<String, dynamic>> licencesRegulatory = [];
  List<Map<String, dynamic>> compliancePractices = [];
  List<Map<String, dynamic>> insurancePolicies = [];
  List<Map<String, dynamic>> insuranceClaims = [];
  // Section 9.3 is a per-report summary, separate from individual policies.
  Map<String, dynamic>? insuranceCoverageSummary;

  // Optional tables whose query failed (shown on the checklist instead of
  // being indistinguishable from an empty register).
  final Set<String> failedTables = {};

  // Existing unassigned records cannot be exported to an arbitrary property.
  // Flag these separately from Supabase query failures.
  final Set<String> unscopedTables = {};

  // Site + year-to-date data (for 5.1 / 5.2 financial comparisons only)
  Map<String, dynamic>? siteRow;
  // Same dated committee records and terms used by the Site Profile screen.
  List<Map<String, dynamic>> committeeHistory = [];
  List<Map<String, dynamic>> committeeTerms = [];
  List<Map<String, dynamic>> ytdReports = [];
  List<Map<String, dynamic>> ytdTransfers = [];
  List<Map<String, dynamic>> ytdLifts = [];
  List<Map<String, dynamic>> allMaintenanceWorks = [];
  final Map<int, Map<String, dynamic>> ytdBillingByMonth = {};
  final Map<int, Map<String, dynamic>> ytdUtilitiesByMonth = {};
  final Map<String, int> reportMonthById = {};
  DateTime? maintenanceSince;

  String get reportId => widget.report['id'].toString();

  String get siteId =>
      (_currentReportRecord['site_id'] ?? widget.report['site_id'])?.toString() ?? '';

  DateTime get reportMonth {
    final value = _currentReportRecord['report_month'] ?? widget.report['report_month'];

    if (value == null) {
      final now = DateTime.now();
      return DateTime(now.year, now.month);
    }

    final date = DateTime.parse(value.toString());
    return DateTime(date.year, date.month);
  }

  DateTime get monthEnd => DateTime(reportMonth.year, reportMonth.month + 1, 0);

  // PDF export scope: selected calendar month (inclusive).
  // 5.1 and 5.2 intentionally retain their twelve-month comparisons.
  bool isInReportMonth(dynamic value) {
    final d = calendarDate(value);
    return d != null &&
        d.year == reportMonth.year &&
        d.month == reportMonth.month;
  }

  // For a report-linked record, reject a dated item from another month.
  // Records without that date remain tied to their selected report_id.
  bool isSelectedReportItem(Map<String, dynamic> row, String dateKey) {
    final d = row[dateKey];
    return !hasValue(d) || isInReportMonth(d);
  }

  // Monthly registers may be linked to a report, or have an event date.
  // Avoid classifying older property-wide entries as new monthly records.
  bool isMonthlyRegisterRow(
    Map<String, dynamic> row,
    List<String> dateKeys, {
    bool allowMissingDateForReport = true,
  }) {
    final owner = row['report_id']?.toString();
    if (owner != null && owner.isNotEmpty && owner != reportId) return false;
    for (final key in dateKeys) {
      if (hasValue(row[key])) return isInReportMonth(row[key]);
    }
    return allowMissingDateForReport && owner == reportId;
  }

  String get monthLabel => DateFormat('MMMM yyyy').format(reportMonth);

  double number(dynamic value) => double.tryParse(value?.toString() ?? '') ?? 0;

  String money(dynamic value) =>
      'RM ${NumberFormat('#,##0.00').format(number(value))}';

  bool hasValue(dynamic value) =>
      value != null && value.toString().trim().isNotEmpty;

  DateTime? parseDate(dynamic value) {
    if (value == null) return null;

    try {
      return DateTime.parse(value.toString());
    } catch (_) {
      return null;
    }
  }

  String dateLabel(dynamic value) {
    final date = parseDate(value);
    return date == null ? '-' : DateFormat('dd/MM/yyyy').format(date);
  }

  String textValue(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) {
      return '-';
    }

    return value.toString();
  }

  // ============================================================
  // CONTRACTS & COMPLIANCE HELPERS
  // ============================================================

  dynamic firstValue(Map<String, dynamic>? row, List<String> keys) {
    if (row == null) return null;

    for (final key in keys) {
      final value = row[key];

      if (value != null && value.toString().trim().isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  String firstText(Map<String, dynamic>? row, List<String> keys) {
    return textValue(firstValue(row, keys));
  }

  String firstDate(Map<String, dynamic>? row, List<String> keys) {
    return dateLabel(firstValue(row, keys));
  }

  String firstMoney(Map<String, dynamic>? row, List<String> keys) {
    final value = firstValue(row, keys);
    return value == null ? '-' : money(value);
  }

  bool isArchived(Map<String, dynamic> row) {
    final archived = row['is_archived'];

    if (archived is bool) return archived;

    if (archived != null) {
      final value = archived.toString().toLowerCase();
      if (value == 'true' || value == '1') return true;
    }

    return row['archived_at'] != null;
  }

  String expiryStatus(dynamic expiryValue, {String? storedStatus}) {
    final status = storedStatus?.trim();

    if (status != null && ['Terminated', 'Replaced'].contains(status)) {
      return status;
    }

    final expiry = parseDate(expiryValue);

    if (expiry == null) {
      return status == null || status.isEmpty ? 'Not set' : status;
    }

    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);

    final endDay = DateTime(monthEnd.year, monthEnd.month, monthEnd.day);

    if (expiryDay.isBefore(endDay)) {
      return 'Expired';
    }

    final renewalCutoff = endDay.add(const Duration(days: 30));

    if (!expiryDay.isAfter(renewalCutoff)) {
      return 'Renewal Due';
    }

    return 'Active';
  }

  // Treat expiry_date as the current contract's renewal / expiry boundary.
  // A newer expiry applies to historical PDFs only after its renewal was
  // confirmed by the selected month's end.
  dynamic providerExpiryForPdf(Map<String, dynamic> row) {
    final originalExpiry = calendarDate(firstValue(row, [
      'expiry_date',
      'expiry_renewal_date',
      'contract_expiry_date',
    ]));
    final confirmed = calendarDate(row['renewal_confirmed_at']);
    final nextExpiry = calendarDate(row['next_expiry_date']);
    if (confirmed != null &&
        !confirmed.isAfter(monthEnd) &&
        nextExpiry != null &&
        (originalExpiry == null || nextExpiry.isAfter(originalExpiry))) {
      return row['next_expiry_date'];
    }
    return firstValue(row, [
      'expiry_date',
      'expiry_renewal_date',
      'contract_expiry_date',
    ]);
  }

  // Section 8 only: automatically display a provider during the month
  // immediately before commencement. This does not activate its staff.
  // Do not use show_in_report_from to bring a contract into earlier months.
  bool providerIsUpcomingForMonth(Map<String, dynamic> row) {
    if (row['history_deleted_at'] != null || archivedByReportMonth(row)) {
      return false;
    }
    final commencement = calendarDate(
      firstValue(row, ['commencement_date', 'start_date', 'appointment_date']),
    );
    if (commencement == null) return false;
    final commencementMonth = DateTime(commencement.year, commencement.month);
    final nextMonth = DateTime(reportMonth.year, reportMonth.month + 1);
    if (!commencementMonth.isAtSameMomentAs(nextMonth)) return false;

    final expiry = calendarDate(providerExpiryForPdf(row));
    if (expiry != null && !expiry.isAfter(commencement)) return false;
    final stopped = calendarDate(row['lifecycle_date']);
    final status = row['status']?.toString().trim().toLowerCase() ?? '';
    if ((status == 'terminated' || status == 'no longer used') &&
        (stopped == null || !stopped.isAfter(commencement))) {
      return false;
    }
    return true;
  }

  // Section 8 status is calculated at this report's cutoff, not today.
  // The contract expiry is the boundary: an end date of 01/10/2027 makes
  // September 2027 its final visible month (unless renewed).
  String providerStatus(Map<String, dynamic> row) {
    if (providerIsUpcomingForMonth(row)) return 'Upcoming';
    final status = row['status']?.toString().trim().toLowerCase() ?? '';
    final stopped = calendarDate(row['lifecycle_date']);
    if ((status == 'terminated' || status == 'no longer used') &&
        (stopped == null || !stopped.isAfter(monthEnd))) {
      return 'No Longer Used';
    }

    final expiry = calendarDate(providerExpiryForPdf(row));
    if (expiry != null && !expiry.isAfter(reportMonthStart)) {
      return 'Expired';
    }

    // Preserve legacy renewal reminder dates for PDFs before November 2026;
    // from November onward, calculate reminders from the expiry date only.
    final legacyMonth = reportMonthStart.isBefore(DateTime(2026, 11));
    final reminderDate = legacyMonth
        ? calendarDate(row['renewal_date'])
        : expiry;
    if (reminderDate != null) {
      final reminderMonth = DateTime(reminderDate.year, reminderDate.month - 1);
      final confirmed = calendarDate(row['renewal_confirmed_at']);
      final renewed = confirmed != null && !confirmed.isAfter(monthEnd) &&
          !confirmed.isBefore(reminderMonth) &&
          calendarDate(row['next_expiry_date']) != null &&
          expiry == calendarDate(row['next_expiry_date']);
      if (!renewed && !reportMonthStart.isBefore(reminderMonth)) {
        return 'Renewal Due';
      }
    }
    return 'Active';
  }

  String licenceStatus(Map<String, dynamic> row) {
    final stored = firstText(row, ['status', 'licence_status']);
    final ended = calendarDate(row['lifecycle_date']);
    final futureEnded =
        (stored == 'Terminated' || stored == 'Replaced') &&
        ended != null &&
        ended.isAfter(monthEnd);
    return expiryStatus(
      firstValue(row, ['expiry_date', 'expiryDate']),
      storedStatus: futureEnded ? 'Active' : stored,
    );
  }

  String policyStatus(Map<String, dynamic> row) {
    return firstText(row, ['renewal_status', 'status']);
  }

  String policyLabelForClaim(dynamic policyId) {
    if (policyId == null) return 'No linked policy';

    final match = insurancePolicies.where(
      (policy) => policy['id']?.toString() == policyId.toString(),
    );

    if (match.isEmpty) {
      return 'Linked policy (details unavailable or archived)';
    }

    final policy = match.first;
    final name = firstText(policy, ['policy_name']);
    final policyNumber = firstText(policy, ['policy_number']);

    return policyNumber == '-' ? name : '$name (Policy No. $policyNumber)';
  }

  String pdfSafe(dynamic value) {
    if (value == null) return '-';

    return value
        .toString()
        .replaceAll('\u2014', '-')
        .replaceAll('\u2013', '-')
        .replaceAll('\u2212', '-')
        .replaceAll('\u2022', '-')
        .replaceAll('\u2026', '...')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u00A0', ' ');
  }

  List<Map<String, dynamic>> mapRows(dynamic response) {
    if (response is! List) return [];

    return response
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  // The monthly report uses the selected property's calendar-month scope.
  // Unlike one-time incidents, contracts and master registers can carry over
  // from previous months. Their dates must OVERLAP the month, not equal it.
  DateTime get reportMonthStart =>
      DateTime(reportMonth.year, reportMonth.month, 1);

  bool overlapsSelectedMonth(
    Map<String, dynamic> row, {
    required List<String> startKeys,
    required List<String> endKeys,
    List<String> stopKeys = const [],
  }) {
    final start = calendarDate(firstValue(row, startKeys));
    final end = calendarDate(firstValue(row, endKeys));
    final stop = calendarDate(firstValue(row, stopKeys));
    if (start != null && start.isAfter(monthEnd)) return false;
    if (end != null && end.isBefore(reportMonthStart)) return false;
    if (stop != null && stop.isBefore(reportMonthStart)) return false;
    return true;
  }

  // A register archived DURING or AFTER the selected month still belonged
  // to that month. Only archive dates before its first day remove it. An
  // archive without a date cannot safely be placed in an earlier period.
  bool archivedByReportMonth(Map<String, dynamic> row) {
    if (!isArchived(row)) return false;
    final archivedAt = calendarDate(row['archived_at']);
    return archivedAt == null || archivedAt.isBefore(reportMonthStart);
  }

  // A matching property id has priority; otherwise, a report id is usable
  // only if we verified that report belongs to this property. Never consider
  // a null report_id proof that a record belongs to every property.
  bool belongsToSelectedSite(
    Map<String, dynamic> row,
    Map<String, DateTime> siteReportMonths,
  ) {
    final ownerSite = row['site_id']?.toString().trim() ?? '';
    if (ownerSite.isNotEmpty) return ownerSite == siteId;
    final ownerReport = row['report_id']?.toString().trim() ?? '';
    return ownerReport.isNotEmpty && siteReportMonths.containsKey(ownerReport);
  }

  bool hasPropertyLink(Map<String, dynamic> row) =>
      hasValue(row['site_id']) || hasValue(row['report_id']);

  // Section 8: one contract per source_provider_id chain. Use the
  // newest report snapshot available at this month's cutoff; a snapshot
  // from the NEXT report month may be used only for an upcoming contract.
  // Never use later renewals to rewrite an earlier monthly PDF.
  List<Map<String, dynamic>> providersForMonth(
    List<Map<String, dynamic>> rows,
    Map<String, DateTime> siteReportMonths,
  ) {
    final byId = <String, Map<String, dynamic>>{
      for (final row in rows)
        if (hasValue(row['id'])) row['id'].toString(): row,
    };

    String originalId(Map<String, dynamic> row) {
      var id = row['id']?.toString() ?? '';
      final visited = <String>{};
      while (id.isNotEmpty && visited.add(id)) {
        final parent = byId[id]?['source_provider_id']?.toString() ?? '';
        if (parent.isEmpty || !byId.containsKey(parent)) break;
        id = parent;
      }
      return id;
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final id = row['report_id']?.toString() ?? '';
      if (!siteReportMonths.containsKey(id)) continue;
      (grouped[originalId(row)] ??= <Map<String, dynamic>>[]).add(row);
    }

    final chosen = <Map<String, dynamic>>[];
    final nextReportMonth = DateTime(reportMonth.year, reportMonth.month + 1);
    for (final snapshots in grouped.values) {
      snapshots.sort((a, b) {
        final aMonth =
            siteReportMonths[a['report_id']?.toString()] ?? DateTime(1900);
        final bMonth =
            siteReportMonths[b['report_id']?.toString()] ?? DateTime(1900);
        final byMonth = aMonth.compareTo(bMonth);
        return byMonth != 0
            ? byMonth
            : (a['updated_at']?.toString() ?? '').compareTo(
                b['updated_at']?.toString() ?? '',
              );
      });

      final past = snapshots.where((row) {
        final date = siteReportMonths[row['report_id']?.toString()];
        return date != null && !date.isAfter(reportMonthStart);
      }).toList();
      final upcoming = snapshots.where((row) {
        final date = siteReportMonths[row['report_id']?.toString()];
        // A future record cannot be imported into a historical PDF, except
        // the immediately following month's upcoming appointment.
        return date != null &&
            date.isAtSameMomentAs(nextReportMonth) &&
            providerIsUpcomingForMonth(row);
      }).toList();
      final candidates = <Map<String, dynamic>>[
        if (past.isNotEmpty) past.last,
        if (upcoming.isNotEmpty) upcoming.first,
      ];

      for (final row in candidates) {
        if (row['history_deleted_at'] != null || archivedByReportMonth(row)) {
          continue;
        }
        final commencement = calendarDate(
          firstValue(row, ['commencement_date', 'start_date', 'appointment_date']),
        );
        if (commencement != null &&
            commencement.isAfter(monthEnd) &&
            !providerIsUpcomingForMonth(row)) {
          continue;
        }

        // The first day of the renewal / expiry month is the boundary.
        // A mid-month expiry stays visible in its final partially active
        // month, so it is not removed before its last service day.
        final expiry = calendarDate(providerExpiryForPdf(row));
        if (expiry != null && !expiry.isAfter(reportMonthStart)) continue;

        final ended = calendarDate(row['lifecycle_date']);
        final status = row['status']?.toString().trim().toLowerCase() ?? '';
        if ((status == 'terminated' || status == 'no longer used') &&
            ended != null && ended.isBefore(reportMonthStart)) {
          continue;
        }
        final restored = calendarDate(row['restored_month']);
        if (restored != null && restored.isAfter(monthEnd)) continue;

        // Keep the original commencement date even when this report shows a
        // later monthly copy of the same provider; never inspect snapshots
        // belonging to months after the selected report (except this row,
        // which may be its upcoming appointment).
        final known = <Map<String, dynamic>>[
          ...past,
          if (!past.contains(row)) row,
        ];
        DateTime? firstCommencement;
        for (final snapshot in known) {
          final start = calendarDate(firstValue(snapshot, [
            'commencement_date', 'start_date', 'appointment_date',
          ]));
          if (start != null &&
              (firstCommencement == null || start.isBefore(firstCommencement))) {
            firstCommencement = start;
          }
        }
        final displayRow = Map<String, dynamic>.from(row);
        if (firstCommencement != null) {
          displayRow['_pdf_first_commencement'] =
              DateFormat('yyyy-MM-dd').format(firstCommencement);
        }
        chosen.add(displayRow);
        break; // A single logical contract never prints twice.
      }
    }
    return chosen;
  }

  bool licenceAppliesInMonth(Map<String, dynamic> row) {
    if (archivedByReportMonth(row)) return false;
    final endedStatus = row['status']?.toString();
    final stopped = endedStatus == 'Terminated' || endedStatus == 'Replaced'
        ? calendarDate(row['lifecycle_date'])
        : null;
    if (stopped != null && stopped.isBefore(reportMonthStart)) return false;
    return overlapsSelectedMonth(
      row,
      startKeys: ['issue_date', 'issued_date'],
      endKeys: ['expiry_date'],
    );
  }

  bool policyAppliesInMonth(Map<String, dynamic> row) =>
      !archivedByReportMonth(row) &&
      overlapsSelectedMonth(
        row,
        startKeys: ['start_date', 'effective_date', 'valid_from'],
        endKeys: ['end_date', 'expiry_date', 'valid_until'],
        stopKeys: ['termination_date', 'cancelled_at'],
      );

  // Compliance & Best Practices is a shared master register in the existing
  // ComplianceBestPracticesPage: saved records have report_id = null, and the
  // main list is not a month-specific snapshot. The Next Review Date is a
  // DISPLAY field in the PDF, never a filter for inclusion.
  // Explicitly archived records are still excluded like on the source page.
  bool isActiveComplianceRecord(Map<String, dynamic> row) {
    final archived = row['is_archived'];
    return archived != true && archived?.toString().toLowerCase() != 'true';
  }

  String complianceNextServiceDate(Map<String, dynamic> row) {
    final date = calendarDate(
      firstValue(row, ['next_review_date', 'next_service_date']),
    );
    return date == null ? '-' : DateFormat('dd MMMM yyyy').format(date);
  }

  String complianceStatusForPdf(Map<String, dynamic> row) {
    final status = firstText(row, ['status']);
    return status == 'Active' ? 'Renewed' : status;
  }

  // Section 9.4 is a cumulative insurance-claim register as at the selected
  // report month. Submission, closure, and archive dates do not remove claims.
  // Incident Date is the only date used for inclusion.
  bool claimAppliesInMonth(Map<String, dynamic> row) {
    final incident = calendarDate(row['incident_date']);
    return incident != null && !incident.isAfter(monthEnd);
  }

  String emptyRegisterLabel(String table) {
    if (failedTables.contains(table)) return 'Unable to load records';
    if (unscopedTables.contains(table)) {
      return 'Records need property assignment';
    }
    return 'No records';
  }

  // ============================================================
  // DATA LOADING
  // ============================================================

  @override
  void initState() {
    super.initState();
    // Load saved history AND render the current live PDF. Rendering the
    // preview does not create or change any saved report version.
    _initializeVersions();
    _refreshLivePdf();
  }

  Future<Uint8List?> _refreshLivePdf() async {
    if (_loadingLivePreview) return null;
    if (!mounted) return null;
    setState(() {
      _loadingLivePreview = true;
      loading = true;
      _livePreviewError = null;
      _livePdfBytes = null;
      error = null;
    });
    try {
      // Fetch the parent record as well, so the preview reflects status and
      // other monthly-report fields that may have changed since navigation.
      final latestReport = await supabase
          .from('monthly_reports')
          .select()
          .eq('id', reportId)
          .single();
      if (!mounted) return null;
      _currentReportRecord = Map<String, dynamic>.from(latestReport);
      await loadFinanceData();
      if (!mounted) return null;
      if (error != null) throw StateError(error!);
      final bytes = await buildPdf(PdfPageFormat.a4);
      if (!mounted) return null;
      setState(() {
        _livePdfBytes = bytes;
        // This is the time the PDF preview was updated, NOT a claim that
        // source records were edited at this exact instant.
        _livePreviewUpdatedAt = DateTime.now();
        _livePreviewRevision++;
      });
      return bytes;
    } catch (e) {
      debugPrint('Unable to refresh current report PDF preview: $e');
      if (mounted) {
        setState(() => _livePreviewError =
            'Could not load the latest report PDF: $e');
      }
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _loadingLivePreview = false;
          loading = false;
        });
      }
    }
  }

  Future<void> loadFinanceData() async {
    try {
      final results = await Future.wait<dynamic>([
        supabase
            .from('finance_billing_collection')
            .select()
            .eq('report_id', reportId)
            .maybeSingle(),
        supabase
            .from('finance_arrears_reconciliation')
            .select()
            .eq('report_id', reportId)
            .maybeSingle(),
        supabase
            .from('finance_sinking_fund_transfers')
            .select()
            .eq('report_id', reportId)
            .order('transfer_date'),
        supabase
            .from('finance_fixed_deposits')
            .select()
            .eq('site_id', siteId)
            .order('maturity_date'),
        supabase
            .from('finance_utilities')
            .select()
            .eq('report_id', reportId)
            .maybeSingle(),
      ]);

      billing = results[0] == null
          ? null
          : Map<String, dynamic>.from(results[0] as Map);

      arrears = results[1] == null
          ? null
          : Map<String, dynamic>.from(results[1] as Map);

      transfers = mapRows(results[2]);
      fixedDeposits = mapRows(results[3]);

      carriedOpening = null;
      if (arrears == null) {
        try {
          final carry = await FinanceCalc.arrearsCarryForward(
            reportId: reportId,
            reportMonth: reportMonth,
          );
          carriedOpening = carry.previousClosing;
        } catch (e) {
          debugPrint('Unable to derive carried-forward arrears: $e');
        }
      }

      utilities = results[4] == null
          ? null
          : Map<String, dynamic>.from(results[4] as Map);

      await loadApprovedFdAllocation();
      await loadExpenditures();
      await loadDefaultersPdfData();
      await loadOperationsData();
      await loadLiftSummaryData();
      await loadPendingMaintenanceWorks();
      await loadComplaintProgressData();
      await loadOccupancyUnitData();
      await loadCommitteeHistoryData();
      await loadContractsComplianceData();
      await loadYtdData();
    } catch (e) {
      error = 'Unable to load report data: $e';
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  // The allocation is stored on a monthly report, not on each deposit.
  // A later report inherits the last non-null allocation from the SAME site.
  Future<void> loadApprovedFdAllocation() async {
    approvedFdAllocation = null;
    if (siteId.isEmpty) return;

    try {
      final rows = mapRows(
        await supabase
            .from('monthly_reports')
            .select('id, report_month, fd_approved_allocation')
            .eq('site_id', siteId)
            .lte('report_month', DateFormat('yyyy-MM-dd').format(monthEnd))
            .order('report_month', ascending: false),
      );

      for (final row in rows) {
        final value = row['fd_approved_allocation'];
        if (value == null) continue;
        final parsed = double.tryParse(value.toString());
        if (parsed != null && parsed.isFinite && parsed >= 0) {
          approvedFdAllocation = parsed;
          break;
        }
      }
    } catch (e) {
      // Older deployments may not yet have the allocation column.
      // Do not silently present a zero balance as a real allocation.
      debugPrint('Unable to load FD allocation: $e');
    }
  }

  Future<void> loadExpenditures() async {
    if (siteId.isEmpty) return;

    final response = await supabase.functions.invoke(
      'finance-expenditures',
      body: {'action': 'list', 'site_id': siteId},
    );

    final dynamic payload = response.data;
    List<dynamic> rows = [];

    if (payload is List) {
      rows = payload;
    } else if (payload is Map) {
      final data = payload['data'] ?? payload['records'] ?? payload['items'];
      if (data is List) rows = data;
    }

    expenditures =
        rows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .where((row) {
              final date = parseDate(row['approval_date']);
              return date != null && !date.isAfter(monthEnd);
            })
            .toList()
          ..sort((a, b) {
            final dateA = parseDate(a['approval_date']) ?? DateTime(1900);
            final dateB = parseDate(b['approval_date']) ?? DateTime(1900);
            return dateA.compareTo(dateB);
          });
  }

  // Defaulters: the dated statement is authoritative at its own date.
  // Only payments AFTER that statement are deducted, so a newer statement
  // (which already reflects prior payments) is never charged twice.
  double? defaulterBalanceAt(
    List<Map<String, dynamic>> snapshots,
    List<Map<String, dynamic>> payments,
    DateTime asOf,
  ) {
    Map<String, dynamic>? latest;
    DateTime? latestDate;
    for (final snapshot in snapshots) {
      final date = calendarDate(snapshot['balance_date']);
      if (date == null || date.isAfter(asOf)) continue;
      if (latestDate == null ||
          date.isAfter(latestDate) ||
          (date.isAtSameMomentAs(latestDate) &&
              (snapshot['created_at']?.toString() ?? '')
                      .compareTo(latest?['created_at']?.toString() ?? '') >
                  0)) {
        latest = snapshot;
        latestDate = date;
      }
    }
    if (latest == null || latestDate == null) return null;

    var result = number(latest['balance_amount']);
    for (final payment in payments) {
      final date = calendarDate(payment['payment_date']);
      if (date != null && date.isAfter(latestDate) && !date.isAfter(asOf)) {
        result -= number(payment['amount']);
      }
    }
    return result < 0 ? 0 : result;
  }

  // Only the action description is shown in the PDF, not the saved
  // action date or the optional remarks from Update Progress.
  String defaulterActionLabel(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '-';
    final match = RegExp(
      r'^\d{4}-\d{2}-\d{2}\s*\|\s*(.*?)\s*\|\s*Remarks:\s*.*$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(raw);
    if (match != null) {
      final action = match.group(1)?.trim() ?? '';
      return action.isEmpty ? '-' : action;
    }
    final datedAction = RegExp(
      r'^\d{4}-\d{2}-\d{2}\s*\|\s*(.*)$',
      dotAll: true,
    ).firstMatch(raw);
    if (datedAction != null) {
      final action = datedAction.group(1)?.trim() ?? '';
      return action.isEmpty ? '-' : action;
    }
    return raw;
  }

  void sortDefaulterPdfRows() {
    defaulterPdfRows.sort((a, b) {
      final byAmount = number(b['balance_first'])
          .compareTo(number(a['balance_first']));
      if (byAmount != 0) return byAmount;
      final byUnit = (a['unit_no']?.toString() ?? '')
          .compareTo(b['unit_no']?.toString() ?? '');
      if (byUnit != 0) return byUnit;
      return (a['id']?.toString() ?? '')
          .compareTo(b['id']?.toString() ?? '');
    });
  }

  Future<void> loadDefaultersPdfData() async {
    defaulterPdfRows = [];
    defaulterPdfBalanceDates = [];
    defaulterPdfError = null;

    try {
      // Use the same property- and month-scoped view as finance_defaulters.dart.
      // It already applies the correct historical status and outstanding balance.
      final monthlyRows = <Map<String, dynamic>>[];
      const pageSize = 500;
      for (var offset = 0; ; offset += pageSize) {
        final page = mapRows(
          await supabase
              .from('finance_defaulters_monthly')
              .select(
                'report_id, report_month, defaulter_id, original_report_id, '
                'site_id, unit_no, name, due_date, action_taken, '
                'original_total_due, amount_paid, total_due, status, '
                'record_section, completed_date',
              )
              .eq('report_id', reportId)
              .order('total_due', ascending: false)
              .order('unit_no')
              .range(offset, offset + pageSize - 1),
        );
        monthlyRows.addAll(page);
        if (page.length < pageSize) break;
      }

      // Only debts still owing at the report month-end belong in this table.
      final openRows = monthlyRows.where((row) =>
          row['record_section'] == 'This Month' &&
          number(row['total_due']) > 0).toList();
      if (openRows.isEmpty) return;

      final byId = <String, Map<String, dynamic>>{
        for (final row in openRows)
          if (row['defaulter_id'] != null)
            row['defaulter_id'].toString(): row,
      };
      if (byId.isEmpty) return;

      // Fetch the histories used by the website's Update Progress dialog.
      final snapshots = <Map<String, dynamic>>[];
      final payments = <Map<String, dynamic>>[];
      final ids = byId.keys.toList();
      const batchSize = 60;
      for (var i = 0; i < ids.length; i += batchSize) {
        final batchIds = ids.skip(i).take(batchSize).toList();
        for (var offset = 0; ; offset += pageSize) {
          final page = mapRows(
            await supabase
                .from('finance_defaulter_balance_snapshots')
                .select('id, defaulter_id, balance_date, balance_amount, created_at')
                .inFilter('defaulter_id', batchIds)
                .order('id')
                .range(offset, offset + pageSize - 1),
          );
          snapshots.addAll(page);
          if (page.length < pageSize) break;
        }
        for (var offset = 0; ; offset += pageSize) {
          final page = mapRows(
            await supabase
                .from('finance_defaulter_payments')
                .select('id, defaulter_id, payment_date, amount')
                .inFilter('defaulter_id', batchIds)
                .order('id')
                .range(offset, offset + pageSize - 1),
          );
          payments.addAll(page);
          if (page.length < pageSize) break;
        }
      }

      final snapshotsById = <String, List<Map<String, dynamic>>>{};
      final paymentsById = <String, List<Map<String, dynamic>>>{};
      for (final snapshot in snapshots) {
        final id = snapshot['defaulter_id']?.toString();
        if (id != null && byId.containsKey(id)) {
          (snapshotsById[id] ??= <Map<String, dynamic>>[]).add(snapshot);
        }
      }
      for (final payment in payments) {
        final id = payment['defaulter_id']?.toString();
        if (id != null && byId.containsKey(id)) {
          (paymentsById[id] ??= <Map<String, dynamic>>[]).add(payment);
        }
      }

      // Use only the first displayed defaulter's Balance History as the date
      // reference; later updates to other units do not create new columns.
      // Retain the selected month and the two preceding calendar months.
      final windowStart = DateTime(reportMonth.year, reportMonth.month - 2, 1);
      final uniqueDates = <String, DateTime>{};
      final referenceId = byId.keys.first;
      final referenceHistory =
          snapshotsById[referenceId] ?? <Map<String, dynamic>>[];
      for (final snapshot in referenceHistory) {
        final date = calendarDate(snapshot['balance_date']);
        if (date == null ||
            date.isBefore(windowStart) ||
            date.isAfter(monthEnd)) {
          continue;
        }
        uniqueDates[DateFormat('yyyy-MM-dd').format(date)] = date;
      }
      defaulterPdfBalanceDates = uniqueDates.values.toList()
        ..sort((a, b) => a.compareTo(b));

      for (final entry in byId.entries) {
        final id = entry.key;
        final source = entry.value;
        final history = snapshotsById[id] ?? <Map<String, dynamic>>[];
        final paid = paymentsById[id] ?? <Map<String, dynamic>>[];
        final datedBalances = <String, double?>{
          for (final date in defaulterPdfBalanceDates)
            DateFormat('yyyy-MM-dd').format(date):
                defaulterBalanceAt(history, paid, date),
        };
        final firstDate = defaulterPdfBalanceDates.isEmpty
            ? null
            : DateFormat('yyyy-MM-dd').format(defaulterPdfBalanceDates.first);
        defaulterPdfRows.add({
          'id': id,
          'unit_no': source['unit_no'],
          'name': source['name'],
          'action_taken': source['action_taken'],
          'balance_first': firstDate == null ? null : datedBalances[firstDate],
          'balances_by_date': datedBalances,
        });
      }
      sortDefaulterPdfRows();
    } catch (e) {
      defaulterPdfError = 'Unable to load Defaulters records';
      debugPrint('PDF Defaulters query failed: $e');
    }
  }

  Future<void> loadOperationsData() async {
    final results = await Future.wait<dynamic>([
      supabase
          .from('maintenance_works')
          .select()
          .eq('report_id', reportId)
          .order('line_no'),
      supabase
          .from('complaints_resolution')
          .select()
          .eq('report_id', reportId)
          .order('line_no'),
      supabase
          .from('lift_incidents')
          .select()
          .eq('report_id', reportId)
          .order('line_no'),
      supabase
          .from('monthly_asset_conditions')
          .select()
          .eq('report_id', reportId),
    ]);

    maintenanceWorks = mapRows(results[0]);
    complaints = mapRows(
      results[1],
    ).where((row) => isSelectedReportItem(row, 'entry_date')).toList();
    liftIncidents = mapRows(
      results[2],
    ).where((row) => isSelectedReportItem(row, 'incident_date')).toList();
    assetConditions = mapRows(results[3]);
    await loadAgmResolutions();

    if (siteId.isEmpty) {
      assets = [];
      serviceHistory = [];
      return;
    }

    assets = mapRows(
      await supabase
          .from('asset_register')
          .select()
          .eq('site_id', siteId)
          .order('asset_id'),
    );

    final assetUuids = assets
        .map((asset) => asset['id'])
        .where((id) => id != null)
        .map((id) => id.toString())
        .toList();

    if (assetUuids.isEmpty) {
      serviceHistory = [];
      return;
    }

    serviceHistory = mapRows(
      await supabase
          .from('asset_service_history')
          .select()
          .inFilter('asset_uuid', assetUuids)
          .order('service_date', ascending: false),
    ).where((row) => isInReportMonth(row['service_date'])).toList();

    // Preserve the full property-wide Asset Register. Only the condition
    // column and Service History are limited to the selected report month.
  }

  // The AGM/EGM section is property-wide, not restricted to one report_id.
  // A resolution appears in each report from its Meeting Date onward.
  // Read the property from monthly_reports (like the AGM website does),
  // instead of relying only on possibly incomplete widget.report data.
  Future<void> loadAgmResolutions() async {
    resolutions = [];

    final selectedReport = await supabase
        .from('monthly_reports')
        .select('id, site_id, report_month')
        .eq('id', reportId)
        .maybeSingle();

    if (selectedReport == null) {
      throw StateError(
        'Could not find the selected monthly report for AGM export.',
      );
    }

    final selectedSiteId =
        selectedReport['site_id']?.toString().trim() ?? siteId;
    if (selectedSiteId.isEmpty) {
      throw StateError(
        'The selected monthly report has no property (site_id).',
      );
    }

    final selectedDate = calendarDate(selectedReport['report_month']);
    if (selectedDate == null) {
      throw StateError(
        'The selected monthly report has no valid report_month.',
      );
    }

    final selectedMonthEnd = DateTime(
      selectedDate.year,
      selectedDate.month + 1,
      0,
    );
    final today = DateUtils.dateOnly(DateTime.now());
    final cutoff = selectedMonthEnd.isAfter(today) ? today : selectedMonthEnd;
    final upcomingMeetingCutoff = DateTime(
      selectedDate.year,
      selectedDate.month + 3,
      0,
    );

    final siteReports = mapRows(
      await supabase
          .from('monthly_reports')
          .select('id, report_month')
          .eq('site_id', selectedSiteId),
    );

    final monthsById = <String, DateTime>{};
    for (final report in siteReports) {
      final id = report['id']?.toString();
      final date = calendarDate(report['report_month']);
      if (id != null && date != null) {
        monthsById[id] = DateTime(date.year, date.month);
      }
    }
    monthsById.putIfAbsent(
      reportId,
      () => DateTime(selectedDate.year, selectedDate.month),
    );

    // Include original resolutions attached to ANY monthly report belonging
    // to this property, even if entered later with a backdated Meeting Date.
    final sourceRows = mapRows(
      await supabase
          .from('agm_egm_resolutions')
          .select()
          .inFilter('report_id', monthsById.keys.toList()),
    );

    debugPrint(
      'AGM PDF: report=$reportId site=$selectedSiteId '
      'sources=${sourceRows.length} cutoff=$cutoff',
    );
    if (sourceRows.isEmpty) return;

    final sourceIds = sourceRows
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();

    final progressByResolution = <String, List<Map<String, dynamic>>>{};
    final progressRows = mapRows(
      await supabase
          .from('agm_egm_progress_updates')
          .select(
            'id, resolution_id, report_id, progress_date, '
            'status, secondary_status, resolution, person_in_charge, '
            'deadline, created_at',
          )
          .inFilter('report_id', monthsById.keys.toList()),
    );
    for (final update in progressRows) {
      final id = update['resolution_id']?.toString();
      if (id != null && sourceIds.contains(id)) {
        progressByResolution.putIfAbsent(id, () => []).add(update);
      }
    }
    for (final updates in progressByResolution.values) {
      updates.sort((a, b) {
        final dateA = calendarDate(a['progress_date']) ?? DateTime(1900);
        final dateB = calendarDate(b['progress_date']) ?? DateTime(1900);
        final byDate = dateA.compareTo(dateB);
        if (byDate != 0) return byDate;
        final byCreated = (a['created_at']?.toString() ?? '').compareTo(
          b['created_at']?.toString() ?? '',
        );
        if (byCreated != 0) return byCreated;
        return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });
    }

    for (final source in sourceRows) {
      final original = monthsById[source['report_id']?.toString()];
      if (original == null) continue;

      final meetingDate = calendarDate(source['meeting_date']) ?? original;
      if (meetingDate.isAfter(upcomingMeetingCutoff)) continue;

      Map<String, dynamic>? latest;
      final updates = progressByResolution[source['id']?.toString()] ?? [];
      for (final update in updates) {
        final date = calendarDate(update['progress_date']);
        if (date == null || date.isBefore(meetingDate)) continue;
        if (!date.isAfter(cutoff)) latest = update;
      }

      final row = Map<String, dynamic>.from(source);
      row['_agm_source_month'] = original;
      row['status'] ??= 'Pending';
      if (latest != null) {
        for (final field in ['resolution', 'person_in_charge', 'deadline']) {
          row[field] = latest[field];
        }
        row['status'] = latest['status'] ?? source['status'] ?? 'Pending';
        row['secondary_status'] = latest['secondary_status'];
      }
      resolutions.add(row);
    }

    resolutions.sort((a, b) {
      final dateA =
          calendarDate(a['meeting_date']) ??
          (a['_agm_source_month'] as DateTime? ?? DateTime(1900));
      final dateB =
          calendarDate(b['meeting_date']) ??
          (b['_agm_source_month'] as DateTime? ?? DateTime(1900));
      final byDate = dateA.compareTo(dateB);
      if (byDate != 0) return byDate;
      final meetingA = a['meeting']?.toString() ?? '';
      final meetingB = b['meeting']?.toString() ?? '';
      final byMeeting = meetingA.compareTo(meetingB);
      if (byMeeting != 0) return byMeeting;
      final lineA = int.tryParse(a['line_no']?.toString() ?? '') ?? 0;
      final lineB = int.tryParse(b['line_no']?.toString() ?? '') ?? 0;
      return lineA.compareTo(lineB);
    });

    debugPrint('AGM PDF: visible resolutions=${resolutions.length}');
  }

  // SECTION 7.3 ONLY.
  // Both lift breakdowns include all earlier incidents at the report cutoff.
  // The Mantrap breakdown contains ALL prior incidents for this property,
  // up to the selected report's cutoff date. Dated progress changes override
  // source values only when their Progress Date applies to this report.
  Future<void> loadLiftSummaryData() async {
    monthlyLiftSummary = [];
    mantrapHistory = [];

    final reportRow = await supabase
        .from('monthly_reports')
        .select('site_id')
        .eq('id', reportId)
        .maybeSingle();
    final propertyId = reportRow?['site_id']?.toString() ?? siteId;
    if (propertyId.isEmpty) return;

    final propertyReports = mapRows(
      await supabase
          .from('monthly_reports')
          .select('id, report_month')
          .eq('site_id', propertyId),
    );

    final reportMonths = <String, DateTime>{};
    for (final row in propertyReports) {
      final id = row['id']?.toString();
      final date = calendarDate(row['report_month']);
      if (id != null && date != null) {
        reportMonths[id] = DateTime(date.year, date.month);
      }
    }
    if (reportMonths.isEmpty) return;

    final eligibleIds = reportMonths.entries
        .where((entry) => !entry.value.isAfter(reportMonthStart))
        .map((entry) => entry.key)
        .toList();
    if (eligibleIds.isEmpty) return;

    final sources = mapRows(
      await supabase
          .from('lift_incidents')
          .select()
          .inFilter('report_id', eligibleIds),
    );
    if (sources.isEmpty) return;

    final sourceIds = sources
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();

    // Updates may have been entered from another month's page. Use their
    // actual progress_date, not the report_id that saved the update.
    final events = mapRows(
      await supabase
          .from('lift_incident_progress_updates')
          .select(
            'id, incident_id, progress_date, status, mantrap, '
            'description, turnaround_hours, created_at',
          )
          .inFilter('report_id', reportMonths.keys.toList()),
    );
    final updatesByIncident = <String, List<Map<String, dynamic>>>{};
    for (final event in events) {
      final id = event['incident_id']?.toString();
      if (id != null && sourceIds.contains(id)) {
        updatesByIncident.putIfAbsent(id, () => []).add(event);
      }
    }
    for (final updates in updatesByIncident.values) {
      updates.sort((a, b) {
        final aDate = calendarDate(a['progress_date']) ?? DateTime(1900);
        final bDate = calendarDate(b['progress_date']) ?? DateTime(1900);
        final dateOrder = aDate.compareTo(bDate);
        if (dateOrder != 0) return dateOrder;
        final createdOrder = (a['created_at']?.toString() ?? '').compareTo(
          b['created_at']?.toString() ?? '',
        );
        if (createdOrder != 0) return createdOrder;
        return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });
    }

    final today = DateUtils.dateOnly(DateTime.now());
    final cutoff = monthEnd.isAfter(today) ? today : monthEnd;
    final latestRowsById = <String, Map<String, dynamic>>{};

    for (final source in sources) {
      final sourceId = source['id']?.toString();
      if (sourceId == null) continue;
      final incidentDate =
          calendarDate(source['incident_date']) ??
          reportMonths[source['report_id']?.toString()];
      if (incidentDate == null || incidentDate.isAfter(cutoff)) continue;

      final effective = Map<String, dynamic>.from(source);
      for (final event
          in updatesByIncident[sourceId] ?? const <Map<String, dynamic>>[]) {
        final progressDate = calendarDate(event['progress_date']);
        if (progressDate == null ||
            progressDate.isBefore(incidentDate) ||
            progressDate.isAfter(cutoff)) {
          continue;
        }
        // Most recent dated event supplies the status and narrative.
        for (final field in ['status', 'description', 'turnaround_hours']) {
          effective[field] = event[field];
        }
        // NULL means no Mantrap decision in an older progress event.
        if (event['mantrap'] != null) {
          effective['mantrap'] = event['mantrap'];
        }
      }
      latestRowsById[sourceId] = effective;
    }

    // Cumulative lift register, oldest Incident Date first.
    monthlyLiftSummary = latestRowsById.values.toList()
      ..sort((a, b) {
        final dateA = calendarDate(a['incident_date']) ?? DateTime(1900);
        final dateB = calendarDate(b['incident_date']) ?? DateTime(1900);
        final byDate = dateA.compareTo(dateB);
        if (byDate != 0) return byDate;
        final lineA = int.tryParse(a['line_no']?.toString() ?? '') ?? 0;
        final lineB = int.tryParse(b['line_no']?.toString() ?? '') ?? 0;
        final byLine = lineA.compareTo(lineB);
        return byLine != 0
            ? byLine
            : (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });

    mantrapHistory = latestRowsById.values.where(isMantrap).toList()
      ..sort((a, b) {
        final aDate = calendarDate(a['incident_date']) ?? DateTime(1900);
        final bDate = calendarDate(b['incident_date']) ?? DateTime(1900);
        final dateOrder = aDate.compareTo(bDate);
        if (dateOrder != 0) return dateOrder;
        final liftOrder = (a['lift_no']?.toString() ?? '').compareTo(
          b['lift_no']?.toString() ?? '',
        );
        if (liftOrder != 0) return liftOrder;
        return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });
  }

  Future<void> loadPendingMaintenanceWorks() async {
    pendingMaintenanceWorks = [];
    maintenanceDashboardWorks = [];

    if (siteId.isEmpty) return;

    final monthStart = DateTime(reportMonth.year, reportMonth.month);

    final today = DateUtils.dateOnly(DateTime.now());
    final cutoff =
        reportMonth.year == today.year && reportMonth.month == today.month
        ? today
        : monthEnd;

    // Fetch reports belonging to this property.
    final siteReports = mapRows(
      await supabase
          .from('monthly_reports')
          .select('id, report_month')
          .eq('site_id', siteId),
    );

    final monthsByReportId = <String, DateTime>{};

    for (final report in siteReports) {
      final id = report['id']?.toString();
      final date = calendarDate(report['report_month']);

      if (id != null && date != null) {
        monthsByReportId[id] = DateTime(date.year, date.month);
      }
    }

    // Include records from this month and earlier months.
    final eligibleReportIds = monthsByReportId.entries
        .where((entry) => !entry.value.isAfter(monthStart))
        .map((entry) => entry.key)
        .toList();

    if (eligibleReportIds.isEmpty) return;

    final sources = mapRows(
      await supabase
          .from('maintenance_works')
          .select()
          .inFilter('report_id', eligibleReportIds),
    );

    if (sources.isEmpty) return;

    final sourceIds = sources
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();

    // Fetch progress updates for this property's records.
    final progressByWork = <String, List<Map<String, dynamic>>>{};

    final events = mapRows(
      await supabase
          .from('maintenance_progress_updates')
          .select()
          .inFilter('report_id', monthsByReportId.keys.toList()),
    );

    for (final event in events) {
      final maintenanceId = event['maintenance_id']?.toString();

      if (maintenanceId != null && sourceIds.contains(maintenanceId)) {
        progressByWork
            .putIfAbsent(maintenanceId, () => <Map<String, dynamic>>[])
            .add(event);
      }
    }

    // Sort updates by effective date, then creation time.
    for (final updates in progressByWork.values) {
      updates.sort((a, b) {
        final dateA = calendarDate(a['progress_date']) ?? DateTime(1900);
        final dateB = calendarDate(b['progress_date']) ?? DateTime(1900);

        final dateOrder = dateA.compareTo(dateB);
        if (dateOrder != 0) return dateOrder;

        final createdOrder = (a['created_at']?.toString() ?? '').compareTo(
          b['created_at']?.toString() ?? '',
        );

        if (createdOrder != 0) return createdOrder;

        return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });
    }

    for (final source in sources) {
      final origin = monthsByReportId[source['report_id']?.toString()];

      if (origin == null || origin.isAfter(monthStart)) {
        continue;
      }

      final started = calendarDate(source['entry_date']) ?? origin;

      final startedMonth = DateTime(started.year, started.month);

      if (startedMonth.isAfter(monthStart)) continue;

      final updates =
          progressByWork[source['id']?.toString()] ?? <Map<String, dynamic>>[];

      Map<String, dynamic>? latest;
      for (final update in updates) {
        final date = calendarDate(update['progress_date']);
        if (date != null && !date.isAfter(cutoff)) {
          latest = update;
        }
      }

      // PDF maintenance is cumulative: previously completed records remain
      // reportable, with their status determined by this month's cutoff.

      // IMPORTANT:
      // Progress status takes priority over original status.
      var effectiveStatus = (latest?['status'] ?? source['status'] ?? 'Pending')
          .toString()
          .trim();

      // Match the Maintenance page's legacy behaviour.
      // Completion requires a dated progress update.
      if (effectiveStatus == 'Completed' && latest == null) {
        effectiveStatus = 'In Progress';
      }

      final row = Map<String, dynamic>.from(source);

      // Use the latest applicable progress details.
      if (latest != null) {
        for (final field in ['challenge', 'action_taken', 'deadline']) {
          row[field] = latest[field];
        }
        if ((latest['snapshot_version'] as num?) == 1) {
          for (final field in ['entry_date', 'work_activity']) {
            row[field] = latest[field];
          }
        }
      }

      final deadline = calendarDate(row['deadline']);
      final statusForSummary = effectiveStatus;

      if (effectiveStatus != 'Completed' &&
          deadline != null &&
          monthStart.isAfter(DateTime(deadline.year, deadline.month))) {
        effectiveStatus = 'Overdue';
      }

      row['status'] = effectiveStatus;
      row['_maintenance_summary_status'] = statusForSummary;
      row['_source_report_month'] = origin;

      maintenanceDashboardWorks.add(row);
      pendingMaintenanceWorks.add(row);
    }

    // Completed records first; otherwise sort by deadline ascending.
    pendingMaintenanceWorks.sort((a, b) {
      final aCompleted = a['status'] == 'Completed';
      final bCompleted = b['status'] == 'Completed';

      if (aCompleted != bCompleted) {
        return aCompleted ? -1 : 1;
      }

      if (!aCompleted) {
        final deadlineA = calendarDate(a['deadline']);
        final deadlineB = calendarDate(b['deadline']);

        if (deadlineA == null && deadlineB != null) return 1;
        if (deadlineA != null && deadlineB == null) return -1;

        if (deadlineA != null && deadlineB != null) {
          final deadlineOrder = deadlineA.compareTo(deadlineB);
          if (deadlineOrder != 0) return deadlineOrder;
        }
      }

      // Preserve the previous order when both items have equal priority.
      final originA = a['_source_report_month'] as DateTime? ?? DateTime(1900);
      final originB = b['_source_report_month'] as DateTime? ?? DateTime(1900);

      final originOrder = originA.compareTo(originB);
      if (originOrder != 0) return originOrder;

      final dateA = calendarDate(a['entry_date']) ?? DateTime(1900);
      final dateB = calendarDate(b['entry_date']) ?? DateTime(1900);

      final dateOrder = dateA.compareTo(dateB);
      if (dateOrder != 0) return dateOrder;

      final lineA = int.tryParse(a['line_no']?.toString() ?? '') ?? 0;
      final lineB = int.tryParse(b['line_no']?.toString() ?? '') ?? 0;

      final lineOrder = lineA.compareTo(lineB);
      if (lineOrder != 0) return lineOrder;

      return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
    });
  }

  Future<void> loadComplaintProgressData() async {
    complaints = [];
    if (siteId.isEmpty) return;

    final monthStart = DateTime(reportMonth.year, reportMonth.month);

    final today = DateUtils.dateOnly(DateTime.now());
    // Match the website: a future report month uses its month-end cutoff.
    final cutoff =
        reportMonth.year == today.year && reportMonth.month == today.month
        ? today
        : monthEnd;

    if (cutoff.isBefore(monthStart)) return;

    // Fetch reports belonging to the selected property.
    final siteReports = mapRows(
      await supabase
          .from('monthly_reports')
          .select('id, report_month')
          .eq('site_id', siteId),
    );

    final monthsByReportId = <String, DateTime>{};

    for (final report in siteReports) {
      final id = report['id']?.toString();
      final date = calendarDate(report['report_month']);

      if (id != null && date != null) {
        monthsByReportId[id] = DateTime(date.year, date.month);
      }
    }

    monthsByReportId.putIfAbsent(reportId, () => monthStart);

    final eligibleIds = monthsByReportId.entries
        .where((entry) => !entry.value.isAfter(monthStart))
        .map((entry) => entry.key)
        .toList();

    if (eligibleIds.isEmpty) return;

    // Load original complaints, including earlier months.
    final sources = mapRows(
      await supabase
          .from('complaints_resolution')
          .select()
          .inFilter('report_id', eligibleIds),
    );

    if (sources.isEmpty) return;

    final sourceIds = sources
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();

    final updatesByComplaint = <String, List<Map<String, dynamic>>>{};

    // Fetch progress updates for this property's reports.
    final updates = mapRows(
      await supabase
          .from('complaint_progress_updates')
          .select(
            'id, complaint_id, report_id, progress_date, '
            'status, description_location, action_taken, '
            'deadline, deadline_is_asap, entry_date, unit_complainant, '
            'snapshot_version, created_at',
          )
          .inFilter('report_id', monthsByReportId.keys.toList()),
    );

    for (final update in updates) {
      final complaintId = update['complaint_id']?.toString();

      if (complaintId != null && sourceIds.contains(complaintId)) {
        updatesByComplaint
            .putIfAbsent(complaintId, () => <Map<String, dynamic>>[])
            .add(update);
      }
    }

    // Order updates by progress date and creation time.
    for (final events in updatesByComplaint.values) {
      events.sort((a, b) {
        final aDate = calendarDate(a['progress_date']) ?? DateTime(1900);
        final bDate = calendarDate(b['progress_date']) ?? DateTime(1900);

        final byDate = aDate.compareTo(bDate);
        if (byDate != 0) return byDate;

        final byCreated = (a['created_at']?.toString() ?? '').compareTo(
          b['created_at']?.toString() ?? '',
        );

        if (byCreated != 0) return byCreated;

        return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
      });
    }

    for (final source in sources) {
      final origin = monthsByReportId[source['report_id']?.toString()];

      if (origin == null || origin.isAfter(monthStart)) {
        continue;
      }

      final started = calendarDate(source['entry_date']) ?? origin;

      final startedMonth = DateTime(started.year, started.month);

      if (startedMonth.year != monthStart.year ||
          startedMonth.month != monthStart.month) {
        continue;
      }

      Map<String, dynamic>? beforeMonth;
      Map<String, dynamic>? latest;
      bool changedThisMonth = false;

      for (final update
          in updatesByComplaint[source['id']?.toString()] ??
              const <Map<String, dynamic>>[]) {
        final date = calendarDate(update['progress_date']);

        if (date == null || date.isBefore(started)) {
          continue;
        }

        if (date.isBefore(monthStart)) {
          beforeMonth = update;
        }

        if (!date.isAfter(cutoff)) {
          latest = update;
        }

        if (!date.isBefore(monthStart) && !date.isAfter(cutoff)) {
          changedThisMonth = true;
        }
      }

      // Stop carrying forward a completed complaint,
      // unless it was reopened during the selected month.
      if (startedMonth.isBefore(monthStart) &&
          beforeMonth?['status']?.toString() == 'Completed' &&
          !changedThisMonth) {
        continue;
      }

      final row = Map<String, dynamic>.from(source);

      // Use the latest applicable progress details.
      if (latest != null) {
        for (final field in [
          'description_location',
          'action_taken',
          'deadline',
          'deadline_is_asap',
        ]) {
          row[field] = latest[field];
        }
        if ((latest['snapshot_version'] as num?) == 1) {
          for (final field in ['entry_date', 'unit_complainant']) {
            row[field] = latest[field];
          }
        }
      }

      // Progress status overrides original status.
      final rawStatus = (latest?['status'] ?? source['status'] ?? 'Pending')
          .toString();

      final datedCompletion = latest != null && rawStatus == 'Completed';

      var effectiveStatus = rawStatus == 'Completed' && !datedCompletion
          ? 'In Progress'
          : rawStatus;

      // Match overdue rules from the Complaints page.
      if (effectiveStatus != 'Completed') {
        final deadline = calendarDate(row['deadline']);

        if (deadline != null &&
            DateTime(deadline.year, deadline.month).isBefore(monthStart)) {
          effectiveStatus = 'Overdue';
        }
      }

      row['status'] = effectiveStatus;
      complaints.add(row);
    }

    // Sort by source report month and original row number.
    complaints.sort((a, b) {
      final am = monthsByReportId[a['report_id']?.toString()] ?? DateTime(1900);
      final bm = monthsByReportId[b['report_id']?.toString()] ?? DateTime(1900);

      final byMonth = am.compareTo(bm);
      if (byMonth != 0) return byMonth;

      final ai = int.tryParse(a['line_no']?.toString() ?? '') ?? 0;
      final bi = int.tryParse(b['line_no']?.toString() ?? '') ?? 0;

      final byLine = ai.compareTo(bi);

      return byLine != 0
          ? byLine
          : (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
    });
  }

  // Reproduce the website's month-end renovation snapshot without editing the
  // source record. Carry an unfinished renovation into subsequent reports;
  // a dated Completed event still appears in its completion month, then leaves
  // This Month in later reports. Later progress cannot rewrite an older PDF.
  Map<String, dynamic>? renovationForPdfMonth(Map<String, dynamic> source) {
    final started = calendarDate(source['start_date']) ??
        calendarDate(source['opened_month']);
    if (started == null || started.isAfter(monthEnd)) return null;

    dynamic rawHistory = source['progress_history'];
    if (rawHistory is String) {
      try {
        rawHistory = jsonDecode(rawHistory);
      } catch (_) {
        rawHistory = null;
      }
    }
    final history = <Map<String, dynamic>>[];
    if (rawHistory is List) {
      for (final event in rawHistory) {
        if (event is Map) history.add(Map<String, dynamic>.from(event));
      }
    }
    history.sort((a, b) {
      final aDate = calendarDate(a['progress_date']) ?? DateTime(2000);
      final bDate = calendarDate(b['progress_date']) ?? DateTime(2000);
      final byDate = aDate.compareTo(bDate);
      return byDate != 0
          ? byDate
          : (a['saved_at']?.toString() ?? '')
              .compareTo(b['saved_at']?.toString() ?? '');
    });

    // Match RenovationWorks._progressAsOfMonth and _effectiveStatus.
    final nextMonth = DateTime(reportMonth.year, reportMonth.month + 1);
    Map<String, dynamic>? latest;
    for (final event in history.reversed) {
      final date = calendarDate(event['progress_date']);
      if (date != null && date.isBefore(nextMonth)) {
        latest = event;
        break;
      }
    }

    final storedStatus =
        source['renovation_status']?.toString() ?? 'Pending';
    String effectiveStatus;
    if (latest != null) {
      effectiveStatus = latest['status']?.toString() ?? storedStatus;
    } else if (history.isNotEmpty) {
      final first = history.first;
      final previous = first['previous_status']?.toString();
      if (first['status'] == 'Completed' && previous == 'Completed') {
        effectiveStatus = 'In Progress';
      } else {
        effectiveStatus = previous ??
            (first['status']?.toString() == 'Completed'
                ? 'In Progress'
                : first['status']?.toString() ?? storedStatus);
      }
    } else {
      final legacyCompleted = calendarDate(source['completed_date']);
      effectiveStatus = storedStatus == 'Completed' &&
              legacyCompleted != null &&
              DateTime(legacyCompleted.year, legacyCompleted.month)
                  .isAfter(reportMonthStart)
          ? 'In Progress'
          : storedStatus;
    }

    DateTime? completed;
    if (effectiveStatus == 'Completed') {
      if (latest != null) {
        completed = calendarDate(latest['progress_date']);
      } else {
        final legacyCompleted = calendarDate(source['completed_date']);
        if (legacyCompleted != null &&
            !DateTime(legacyCompleted.year, legacyCompleted.month)
                .isAfter(reportMonthStart)) {
          completed = legacyCompleted;
        }
      }
    }
    if (completed != null &&
        DateTime(completed.year, completed.month)
            .isBefore(reportMonthStart)) {
      return null;
    }

    return <String, dynamic>{
      ...source,
      'renovation_status': effectiveStatus,
    };
  }

  Future<void> loadOccupancyUnitData() async {
    // The selected monthly report is authoritative for the property. A
    // movement's source report month is NOT its movement month.
    final selectedReport = await supabase
        .from('monthly_reports')
        .select('site_id')
        .eq('id', reportId)
        .maybeSingle();
    final selectedSiteId = selectedReport?['site_id']?.toString() ?? '';
    if (selectedSiteId.isEmpty) {
      throw StateError('Unable to identify the property for PDF export.');
    }

    final results = await Future.wait<dynamic>([
      supabase
          .from('occupancy_records')
          .select()
          .eq('report_id', reportId)
          .order('line_no'),
      supabase
          .from('renovation_works')
          .select()
          .eq('site_id', selectedSiteId)
          .order('line_no'),
      supabase
          .from('sub_sales_units')
          .select()
          .eq('site_id', selectedSiteId)
          .order('sale_month', ascending: true),
      supabase
          .from('monthly_reports')
          .select('id,report_month')
          .eq('site_id', selectedSiteId),
    ]);

    occupancyRecords = mapRows(results[0]);
    renovationWorks = mapRows(results[1])
        .map(renovationForPdfMonth)
        .whereType<Map<String, dynamic>>()
        .toList()
      ..sort((a, b) {
        final aDate = calendarDate(a['start_date']) ??
            calendarDate(a['opened_month']) ?? DateTime(2000);
        final bDate = calendarDate(b['start_date']) ??
            calendarDate(b['opened_month']) ?? DateTime(2000);
        final byDate = bDate.compareTo(aDate);
        if (byDate != 0) return byDate;
        return number(b['line_no']).compareTo(number(a['line_no']));
      });
    subSalesUnits = mapRows(results[2]);

    // Unit Movement's website fetches all source reports for the property and
    // groups records by movement_date. Apply the same rule to the PDF, even
    // when an October movement was entered via a September/November report.
    final siteReportMonths = <String, DateTime>{};
    for (final row in mapRows(results[3])) {
      final id = row['id']?.toString() ?? '';
      final date = calendarDate(row['report_month']);
      if (id.isNotEmpty && date != null) siteReportMonths[id] = date;
    }
    final siteReportIds = siteReportMonths.keys.toList();
    final allMovements = <Map<String, dynamic>>[];
    const batchSize = 80;
    const pageSize = 500;
    for (var i = 0; i < siteReportIds.length; i += batchSize) {
      final batch = siteReportIds.skip(i).take(batchSize).toList();
      for (var offset = 0; ; offset += pageSize) {
        final page = mapRows(await supabase
            .from('unit_movements')
            .select()
            .inFilter('report_id', batch)
            .order('report_id')
            .order('line_no')
            .range(offset, offset + pageSize - 1));
        allMovements.addAll(page);
        if (page.length < pageSize) break;
      }
    }
    unitMovements = allMovements.where((row) {
      final event = calendarDate(row['movement_date']) ??
          siteReportMonths[row['report_id']?.toString()];
      return event != null && isInReportMonth(event);
    }).toList()
      ..sort((a, b) {
        final aDate = calendarDate(a['movement_date']) ??
            siteReportMonths[a['report_id']?.toString()] ?? DateTime(2000);
        final bDate = calendarDate(b['movement_date']) ??
            siteReportMonths[b['report_id']?.toString()] ?? DateTime(2000);
        final byDate = aDate.compareTo(bDate);
        if (byDate != 0) return byDate;
        return (a['unit']?.toString() ?? '')
            .compareTo(b['unit']?.toString() ?? '');
      });

    final site = await supabase
        .from('property_sites')
        .select()
        .eq('id', selectedSiteId)
        .maybeSingle();

    siteRow = site == null ? null : Map<String, dynamic>.from(site);
    propertyTotalUnits = site == null
        ? null
        : int.tryParse(site['total_units']?.toString() ?? '');
  }

  // Committee history and terms must match the authenticated Site Profile
  // sources, never legacy management_committee / committee_term JSON.
  Future<void> loadCommitteeHistoryData() async {
    committeeHistory = [];
    committeeTerms = [];
    if (siteId.isEmpty) return;

    // If either request fails, show the report load error rather than
    // exporting members under an outdated or incorrectly dated term.
    committeeHistory =
        await PropertySitesService.getCommitteeHistoryAuthenticated(
          siteId: siteId,
        );

    var session = supabase.auth.currentSession;
    if (session == null) throw const AuthRequiredException();
    if (session.isExpired) {
      try {
        session = (await supabase.auth.refreshSession()).session;
      } catch (_) {
        throw const AuthRequiredException();
      }
      if (session == null) throw const AuthRequiredException();
    }
    final jwt = session.accessToken;
    if (jwt.isEmpty) throw const AuthRequiredException();

    final response = await supabase.functions.invoke(
      'property-sites',
      body: {
        'action': 'get_committee_terms_authenticated',
        'site_id': siteId,
        'report_month': DateFormat('yyyy-MM-dd').format(reportMonthStart),
      },
      headers: {'Authorization': 'Bearer $jwt'},
    );
    final data = response.data;
    if (data is! Map || data['terms'] is! List) {
      throw StateError('Invalid committee terms returned by the server.');
    }
    committeeTerms = mapRows(data['terms']);
  }

  // ============================================================
  // CONTRACTS & COMPLIANCE DATA LOADING
  // ============================================================

  // Section 4 reads the same monthly-effective staffing figures as the
  // website. Section 8 may show a provider a month early as Upcoming, but
  // this MUST NOT activate its staff before the actual commencement date.
  Future<void> loadStaffReportData(
    List<Map<String, dynamic>> providerRows,
    Map<String, DateTime> siteReportMonths,
  ) async {
    staffReportProviders = [];
    staffByProviderId.clear();
    if (providerRows.isEmpty) return;

    final current = providersForMonth(providerRows, siteReportMonths).where(
      (provider) {
        if (providerIsUpcomingForMonth(provider)) return false;
        final start = calendarDate(provider['commencement_date']);
        return start != null && !start.isAfter(monthEnd);
      },
    ).toList();
    if (current.isEmpty) return;

    final byId = <String, Map<String, dynamic>>{
      for (final provider in providerRows)
        if (provider['id'] != null) provider['id'].toString(): provider,
    };
    final providerIds = byId.keys.toList();
    final directStaffByProvider = <String, Map<String, dynamic>>{};

    // The view inherits only from this exact provider or its earlier copies.
    // It never reads a staffing change saved on a future provider copy.
    try {
      final currentIds = current
          .map((provider) => provider['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      for (var i = 0; i < currentIds.length; i += 80) {
        final ids = currentIds.skip(i).take(80).toList();
        final rows = mapRows(await supabase
            .from('staff_effective')
            .select(
              'service_provider_id,total_staff,day_shift_staff,'
              'day_shift_timing,night_shift_staff,night_shift_timing,'
              'frequency,include_in_staff',
            )
            .inFilter('service_provider_id', ids));
        for (final staff in rows) {
          final id = staff['service_provider_id']?.toString();
          if (id != null) staffByProviderId[id] = staff;
        }
      }
      // The direct staff table is used ONLY to detect an explicit opt-in
      // for nonstandard service categories, matching Staff Management.
      for (var i = 0; i < providerIds.length; i += 80) {
        final ids = providerIds.skip(i).take(80).toList();
        final rows = mapRows(await supabase
            .from('staff')
            .select('service_provider_id,include_in_staff')
            .inFilter('service_provider_id', ids));
        for (final staff in rows) {
          final id = staff['service_provider_id']?.toString();
          if (id != null) directStaffByProvider[id] = staff;
        }
      }
    } catch (e) {
      staffReportProviders = [];
      staffByProviderId.clear();
      failedTables.add('staff');
      debugPrint('Unable to load Staff Management PDF data: $e');
      return;
    }

    bool explicitlyIncluded(Map<String, dynamic> provider) {
      var cursor = provider['id']?.toString() ?? '';
      final seen = <String>{};
      while (cursor.isNotEmpty && seen.add(cursor)) {
        final direct = directStaffByProvider[cursor];
        if (direct != null) return direct['include_in_staff'] == true;
        final parent = byId[cursor]?['source_provider_id']?.toString();
        if (parent == null || !byId.containsKey(parent)) break;
        cursor = parent;
      }
      return false;
    }

    const regularCategories = <String>{'cleaning', 'landscaping', 'security'};
    for (final provider in current) {
      final id = provider['id']?.toString() ?? '';
      final staff = staffByProviderId[id];
      if (staff == null || staff['include_in_staff'] != true) continue;
      final service = provider['service']?.toString().trim().toLowerCase() ?? '';
      if (!regularCategories.contains(service) && !explicitlyIncluded(provider)) {
        continue;
      }
      if (staffTotalPaxForPdf(staff) == null) continue;
      staffReportProviders.add(provider);
    }
    staffReportProviders.sort((a, b) {
      final serviceA = a['service']?.toString().toLowerCase() ?? '';
      final serviceB = b['service']?.toString().toLowerCase() ?? '';
      final byService = serviceA.compareTo(serviceB);
      if (byService != 0) return byService;
      return (a['company_pic']?.toString().toLowerCase() ?? '').compareTo(
        b['company_pic']?.toString().toLowerCase() ?? '',
      );
    });
  }

  Future<void> loadContractsComplianceData() async {
    failedTables.clear();
    unscopedTables.clear();
    serviceProviders = [];
    staffReportProviders = [];
    staffByProviderId.clear();
    licencesRegulatory = [];
    compliancePractices = [];
    insurancePolicies = [];
    insuranceClaims = [];
    insuranceCoverageSummary = null;

    // Refuse to mix property-specific information when the selected report
    // has no property id. Supabase RLS is still the authorization boundary.
    if (siteId.isEmpty) {
      failedTables.addAll({
        'service_providers',
        'licences_regulatory',
        'compliance_best_practices',
        'insurance_policies',
        'insurance_claims',
        'insurance_coverage_summary',
      });
      debugPrint('PDF export: selected report has no site_id.');
      return;
    }

    try {
      // Match the website: the latest summary effective by this report's
      // month-end applies until its Valid To month, without reviving an older
      // summary after a newer one expires or is explicitly cleared.
      final coverageRows = mapRows(
        await supabase
            .from('monthly_reports')
            .select(
              'id, report_month, insurance_coverage_underwriter, '
              'insurance_coverage_valid_from, insurance_coverage_valid_to, '
              'insurance_coverage_renewal_notes, insurance_coverage_cost',
            )
            .eq('site_id', siteId)
            .order('report_month', ascending: false),
      );
      if (!coverageRows.any((row) => row['id']?.toString() == reportId)) {
        failedTables.add('insurance_coverage_summary');
      } else {
        const coverageFields = <String>[
          'insurance_coverage_underwriter',
          'insurance_coverage_valid_from',
          'insurance_coverage_valid_to',
          'insurance_coverage_renewal_notes',
          'insurance_coverage_cost',
        ];
        Map<String, dynamic>? effectiveSummary;
        DateTime? latestEffectiveStart;
        DateTime? latestSavedMonth;
        for (final row in coverageRows) {
          if (!coverageFields.any((field) => row[field] != null)) continue;
          final savedMonth = calendarDate(row['report_month']);
          final start =
              calendarDate(row['insurance_coverage_valid_from']) ?? savedMonth;
          if (start == null || start.isAfter(monthEnd)) continue;
          if (latestEffectiveStart == null ||
              start.isAfter(latestEffectiveStart) ||
              (start.isAtSameMomentAs(latestEffectiveStart) &&
                  savedMonth != null &&
                  (latestSavedMonth == null ||
                      savedMonth.isAfter(latestSavedMonth)))) {
            effectiveSummary = row;
            latestEffectiveStart = start;
            latestSavedMonth = savedMonth;
          }
        }
        final validTo = calendarDate(
          effectiveSummary?['insurance_coverage_valid_to'],
        );
        if (effectiveSummary != null &&
            (validTo == null || !validTo.isBefore(reportMonthStart))) {
          insuranceCoverageSummary = effectiveSummary;
        }
      }
    } catch (e) {
      // A missing migration or denied SELECT must not break other PDF sections.
      failedTables.add('insurance_coverage_summary');
      debugPrint('Unable to load monthly insurance coverage summary: $e');
    }

    final siteReportMonths = <String, DateTime>{};
    final providerReportMonths = <String, DateTime>{};
    try {
      final rows = mapRows(
        await supabase
            .from('monthly_reports')
            .select('id, report_month')
            .eq('site_id', siteId),
      );
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        final date = calendarDate(row['report_month']);
        if (id.isNotEmpty && date != null) {
          final month = DateTime(date.year, date.month, 1);
          providerReportMonths[id] = month;
          if (!month.isAfter(reportMonthStart)) {
            siteReportMonths[id] = month;
          }
        }
      }
    } catch (e) {
      debugPrint('Unable to verify property monthly reports: $e');
      failedTables.add('service_providers');
    }

    siteReportMonths[reportId] = reportMonthStart;
    providerReportMonths[reportId] = reportMonthStart;

    final providerRows = await loadOptionalTable(
      'service_providers',
      reportIds: providerReportMonths.keys.toList(),
    );
    serviceProviders = providersForMonth(providerRows, providerReportMonths);

    // Staff Management is linked to the provider row's exact ID. Fetch this
    // report's provider rows explicitly so a multi-month register cannot omit
    // the IDs used by the website's current-month Staff records.
    final staffProviderRows = List<Map<String, dynamic>>.from(providerRows);
    try {
      final currentProviderRows = mapRows(
        await supabase
            .from('service_providers')
            .select()
            .eq('report_id', reportId),
      );
      final loadedIds = staffProviderRows
          .map((row) => row['id']?.toString())
          .whereType<String>()
          .toSet();
      for (final row in currentProviderRows) {
        final id = row['id']?.toString();
        if (id != null && loadedIds.add(id)) staffProviderRows.add(row);
      }
    } catch (e) {
      debugPrint('Unable to verify current-month Staff provider IDs: $e');
    }
    await loadStaffReportData(staffProviderRows, providerReportMonths);

    // Licence records already have site_id and are property-wide.
    final licenceRows = await loadOptionalTable(
      'licences_regulatory',
      siteFilter: siteId,
    );
    licencesRegulatory = licenceRows.where(licenceAppliesInMonth).toList();

    final complianceRows = await loadOptionalTable(
      'compliance_best_practices',
      siteFilter: siteId,
    );
    compliancePractices = complianceRows.where(isActiveComplianceRecord).toList();

    final policyRows = await loadOptionalTable('insurance_policies');
    insurancePolicies = policyRows
        .where((row) => belongsToSelectedSite(row, siteReportMonths))
        .where(policyAppliesInMonth)
        .toList();

    if (policyRows.any(
      (row) => !hasPropertyLink(row) && policyAppliesInMonth(row),
    )) {
      unscopedTables.add('insurance_policies');
    }

    final propertyPolicyIds = policyRows
        .where((row) => belongsToSelectedSite(row, siteReportMonths))
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();

    final claimRows = await loadOptionalTable('insurance_claims');
    bool claimBelongsHere(Map<String, dynamic> row) {
      if (belongsToSelectedSite(row, siteReportMonths)) return true;
      // Legacy claims can also be linked to a policy already confirmed to
      // belong to the selected site. Do not assume unlinked claims do.
      if (hasPropertyLink(row)) return false;
      final policyId = row['policy_id']?.toString() ?? '';
      return policyId.isNotEmpty && propertyPolicyIds.contains(policyId);
    }

    insuranceClaims = claimRows
        .where(claimBelongsHere)
        .where(claimAppliesInMonth)
        .toList();
    if (claimRows.any(
      (row) =>
          !claimBelongsHere(row) &&
          !hasPropertyLink(row) &&
          claimAppliesInMonth(row),
    )) {
      unscopedTables.add('insurance_claims');
    }

    serviceProviders.sort(
      (a, b) => firstText(a, [
        'service',
        'company_pic',
      ]).compareTo(firstText(b, ['service', 'company_pic'])),
    );

    licencesRegulatory.sort((a, b) {
      final dateA = calendarDate(firstValue(a, ['issue_date', 'issued_date']));

      final dateB = calendarDate(firstValue(b, ['issue_date', 'issued_date']));

      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1;
      if (dateB == null) return -1;

      return dateA.compareTo(dateB);
    });

    // Ascending Next Service Date; records without a date appear last.
    compliancePractices.sort((a, b) {
      final dateA = calendarDate(
        firstValue(a, ['next_review_date', 'next_service_date']),
      );
      final dateB = calendarDate(
        firstValue(b, ['next_review_date', 'next_service_date']),
      );
      if (dateA == null && dateB != null) return 1;
      if (dateA != null && dateB == null) return -1;
      if (dateA != null && dateB != null) {
        final dateOrder = dateA.compareTo(dateB);
        if (dateOrder != 0) return dateOrder;
      }
      final nameOrder = firstText(a, ['name', 'item_practice'])
          .toLowerCase()
          .compareTo(firstText(b, ['name', 'item_practice']).toLowerCase());
      if (nameOrder != 0) return nameOrder;
      return firstText(a, ['id']).compareTo(firstText(b, ['id']));
    });
    insuranceClaims.sort((a, b) {
      final aDate = calendarDate(a['incident_date']) ?? DateTime(1900);
      final bDate = calendarDate(b['incident_date']) ?? DateTime(1900);
      return aDate.compareTo(bDate);
    });
    debugPrint(
      'PDF $monthLabel: providers=${serviceProviders.length}, '
      'licences=${licencesRegulatory.length}, '
      'compliance=${compliancePractices.length}, '
      'policies=${insurancePolicies.length}, claims=${insuranceClaims.length}, '
      'assets=${assets.length}; failed=$failedTables, unscoped=$unscopedTables',
    );
  }

  Future<List<Map<String, dynamic>>> loadOptionalTable(
    String table, {
    List<String>? reportIds,
    String? siteFilter,
  }) async {
    try {
      dynamic query = supabase.from(table).select();
      if (reportIds != null) {
        if (reportIds.isEmpty) return [];
        query = query.inFilter('report_id', reportIds);
      }
      if (siteFilter != null) query = query.eq('site_id', siteFilter);
      return mapRows(await query);
    } catch (e) {
      debugPrint('Unable to load optional table $table: $e');
      failedTables.add(table);
      return [];
    }
  }

  // ============================================================
  // YEAR-TO-DATE DATA (September-style trend sections)
  // ============================================================

  Future<void> loadYtdData() async {
    ytdReports = [];
    ytdTransfers = [];
    ytdLifts = [];
    allMaintenanceWorks = maintenanceWorks;
    ytdBillingByMonth.clear();
    ytdUtilitiesByMonth.clear();
    reportMonthById.clear();
    maintenanceSince = reportMonth;

    // Fallback so a failed query still yields the current month.
    void useCurrentMonthOnly() {
      reportMonthById[reportId] = reportMonth.month;
      ytdReports = [Map<String, dynamic>.from(_currentReportRecord.isEmpty ? widget.report : _currentReportRecord)];
      if (billing != null) {
        ytdBillingByMonth[reportMonth.month] = billing!;
      }

      if (utilities != null) {
        ytdUtilitiesByMonth[reportMonth.month] = utilities!;
      }

      ytdTransfers = transfers;
      ytdLifts = liftIncidents;
    }

    if (siteId.isEmpty) {
      useCurrentMonthOnly();
      return;
    }

    try {
      final siteReports = mapRows(
        await supabase
            .from('monthly_reports')
            .select()
            .eq('site_id', siteId)
            .lte('report_month', DateFormat('yyyy-MM-dd').format(monthEnd)),
      );

      if (!siteReports.any((r) => r['id']?.toString() == reportId)) {
        siteReports.add(Map<String, dynamic>.from(_currentReportRecord.isEmpty ? widget.report : _currentReportRecord));
      }

      DateTime? earliest;
      for (final r in siteReports) {
        final d = calendarDate(r['report_month']);
        if (d != null && (earliest == null || d.isBefore(earliest))) {
          earliest = d;
        }
      }
      maintenanceSince = earliest ?? reportMonth;

      ytdReports = siteReports.where((r) {
        final d = calendarDate(r['report_month']);
        return d != null && d.year == reportMonth.year;
      }).toList();

      for (final r in ytdReports) {
        reportMonthById[r['id'].toString()] = calendarDate(
          r['report_month'],
        )!.month;
      }

      final ytdIds = ytdReports.map((r) => r['id'].toString()).toList();
      final allIds = siteReports.map((r) => r['id'].toString()).toList();

      final results = await Future.wait<dynamic>([
        supabase
            .from('finance_billing_collection')
            .select()
            .inFilter('report_id', ytdIds),
        supabase
            .from('finance_utilities')
            .select()
            .inFilter('report_id', ytdIds),
        supabase
            .from('finance_sinking_fund_transfers')
            .select()
            .inFilter('report_id', ytdIds)
            .order('transfer_date'),
        supabase
            .from('lift_incidents')
            .select()
            .inFilter('report_id', ytdIds)
            .order('incident_date'),
        supabase
            .from('maintenance_works')
            .select()
            .inFilter('report_id', allIds),
      ]);

      for (final row in mapRows(results[0])) {
        final m = reportMonthById[row['report_id']?.toString()];
        if (m != null) ytdBillingByMonth[m] = row;
      }

      for (final row in mapRows(results[1])) {
        final m = reportMonthById[row['report_id']?.toString()];
        if (m != null) ytdUtilitiesByMonth[m] = row;
      }

      ytdTransfers = mapRows(results[2]);
      ytdLifts = mapRows(results[3]);
      allMaintenanceWorks = mapRows(results[4]);
    } catch (e) {
      debugPrint('Unable to load year-to-date data: $e');
      useCurrentMonthOnly();
    }
  }

  // ============================================================
  // FINANCE CALCULATIONS
  // ============================================================

  double get totalBilling {
    if (billing == null) return 0;

    return number(billing!['billing_service_charge']) +
        number(billing!['billing_sinking_fund']) +
        number(billing!['billing_other']);
  }

  double get totalCollection {
    if (billing == null) return 0;

    return number(billing!['collection_service_charge']) +
        number(billing!['collection_sinking_fund']) +
        number(billing!['collection_other']) +
        number(billing!['collection_open_credit']);
  }

  double get collectionRate =>
      totalBilling == 0 ? 0 : totalCollection / totalBilling * 100;

  // Saved opening when the arrears row exists (same as the Arrears screen),
  // otherwise the previous month's closing, otherwise zero.
  double get openingArrears => arrears != null
      ? number(arrears!['opening_arrears'])
      : (carriedOpening ?? 0);

  // Arrears reconciliation uses FinanceCalc. Open Credit is included
  // in Total Collection, not in Total Billing.

  double get arrearsBilled => FinanceCalc.billed(billing);

  double get arrearsCollected => FinanceCalc.collected(billing);

  double get closingArrears => FinanceCalc.closing(
    opening: openingArrears,
    billed: arrearsBilled,
    collected: arrearsCollected,
    adjustments: number(arrears?['adjustments']),
  );

  double get totalTransfers =>
      transfers.fold<double>(0, (total, row) => total + number(row['amount']));

  double get sinkingFundCollection =>
      number(billing?['collection_sinking_fund']);

  // Same scope as the 5.5 table

  // Section 5.5: January up to the selected report month.
  // Arrange approved expenditures by date, oldest first.
  List<Map<String, dynamic>> get yearExpenditures {
    final startOfYear = DateTime(reportMonth.year, 1, 1);

    final records = expenditures.where((row) {
      final date = calendarDate(row['approval_date']);

      return date != null &&
          !date.isBefore(startOfYear) &&
          !date.isAfter(monthEnd);
    }).toList();

    records.sort((a, b) {
      final dateA = calendarDate(a['approval_date'])!;
      final dateB = calendarDate(b['approval_date'])!;

      return dateA.compareTo(dateB);
    });

    return records;
  }

  // Groups raw status text into the report's four status rows.
  String expenditureBucket(dynamic status) {
    final s = status?.toString().trim().toLowerCase() ?? '';
    if (s.isEmpty) return 'Not set';
    if (s.contains('cancel')) return 'Cancelled';
    if (s.contains('complete')) return 'Completed (work/ delivery)';
    if (s.contains('progress')) return 'In progress';
    if (s.contains('pending') || s.contains('hold') || s.contains('kiv')) {
      return 'Pending (work/ delivery)';
    }
    return status.toString().trim();
  }

  double get activeExpenditureTotal {
    return yearExpenditures
        .where((row) => expenditureBucket(row['status']) != 'Cancelled')
        .fold<double>(
          0,
          (total, row) => total + number(row['approved_amount']),
        );
  }

  double get totalFixedDeposits => reportFixedDeposits.fold<double>(
    0,
    (total, row) => total + number(row['deposit_amount']),
  );

  // Not Yet Placed is an allocation balance, NOT deposits with placement
  // dates after the month-end. Use all confirmed placements for this site
  // through the selected month, including deposits from earlier months.
  double get cumulativePlacedFdPrincipal => fixedDeposits
      .where((row) {
        final placement = calendarDate(row['placement_date']);
        return placement != null && !placement.isAfter(monthEnd);
      })
      .fold<double>(0, (sum, row) => sum + number(row['deposit_amount']));

  double? get notYetPlacedPrincipal {
    final allocated = approvedFdAllocation;
    if (allocated == null) return null;
    final remainder = allocated - cumulativePlacedFdPrincipal;
    return remainder > 0 ? remainder : 0;
  }

  // ---- Fixed deposit classification (reporting cutoff = last day of the
  // selected report month; calendar-date comparisons only) ----

  // Reads the date exactly as written (yyyy-MM-dd prefix), so time-of-day
  // and timezone offsets cannot move a date across a day boundary.
  DateTime? calendarDate(dynamic value) {
    if (value == null) return null;

    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})',
    ).firstMatch(value.toString().trim());
    if (match == null) return null;

    final y = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final d = int.parse(match.group(3)!);

    final date = DateTime(y, m, d);
    if (date.year != y || date.month != m || date.day != d) return null;

    return date;
  }

  // Null when the selected report month is missing or invalid.
  // Deliberately does NOT fall back to the current date.
  DateTime? get fdCutoff {
    final start = calendarDate(_currentReportRecord['report_month'] ?? widget.report['report_month']);
    if (start == null) return null;
    return DateTime(start.year, start.month + 1, 0);
  }

  _FdClass classifyFixedDeposit(Map<String, dynamic> row, DateTime cutoff) {
    final placement = calendarDate(row['placement_date']);
    final maturity = calendarDate(row['maturity_date']);

    if (placement != null && placement.isAfter(cutoff)) {
      return _FdClass.notYetPlaced;
    }
    if (placement == null || maturity == null) return _FdClass.unclassified;
    // Matured on or before month-end (same rule as the Fixed Deposits page).
    // A maturity date AFTER month-end is a legitimate future maturity: the
    // deposit stays in the report as Active.
    if (!maturity.isAfter(cutoff)) return _FdClass.matured;
    return _FdClass.active; // maturity after the cutoff
  }

  // Include each placement from its placement month through the maturity
  // month, inclusive. Deposits with no recorded maturity remain unclassified.
  List<Map<String, dynamic>> get reportFixedDeposits {
    final cutoff = fdCutoff;
    if (cutoff == null) return [];

    final monthStart = DateTime(cutoff.year, cutoff.month, 1);
    return fixedDeposits.where((row) {
      final placement = calendarDate(row['placement_date']);
      final maturity = calendarDate(row['maturity_date']);
      return placement != null &&
          !placement.isAfter(cutoff) &&
          (maturity == null || !maturity.isBefore(monthStart));
    }).toList();
  }

  String fdStatusLabel(Map<String, dynamic> row) {
    final cutoff = fdCutoff;
    if (cutoff == null) return '-';

    final cls = classifyFixedDeposit(row, cutoff);
    if (cls == _FdClass.active) return 'Active';
    if (cls == _FdClass.matured) return 'Matured';
    if (cls == _FdClass.notYetPlaced) return 'Not yet placed';
    return 'Unclassified';
  }

  List<Map<String, dynamic>> fixedDepositsIn(_FdClass target) {
    final cutoff = fdCutoff;
    if (cutoff == null) return [];
    return reportFixedDeposits
        .where((row) => classifyFixedDeposit(row, cutoff) == target)
        .toList();
  }

  double fixedDepositPrincipal(_FdClass target) => fixedDepositsIn(
    target,
  ).fold<double>(0, (total, row) => total + number(row['deposit_amount']));

  double get activeFixedDeposits => fixedDepositPrincipal(_FdClass.active);
  double get maturedFixedDeposits => fixedDepositPrincipal(_FdClass.matured);
  double get notYetPlacedFixedDeposits =>
      fixedDepositPrincipal(_FdClass.notYetPlaced);
  double get unclassifiedFixedDeposits =>
      fixedDepositPrincipal(_FdClass.unclassified);
  int get unclassifiedFixedDepositCount =>
      fixedDepositsIn(_FdClass.unclassified).length;

  // Window: day after the cutoff through cutoff + 30 calendar days.
  double get maturingWithin30Days {
    final cutoff = fdCutoff;
    if (cutoff == null) return 0;

    final windowEnd = DateTime(cutoff.year, cutoff.month, cutoff.day + 30);

    return fixedDepositsIn(_FdClass.active)
        .where((row) {
          final maturity = calendarDate(row['maturity_date']);
          return maturity != null &&
              maturity.isAfter(cutoff) &&
              !maturity.isAfter(windowEnd);
        })
        .fold<double>(0, (total, row) => total + number(row['deposit_amount']));
  }

  bool get billingComplete {
    if (billing == null) return false;

    const fields = [
      'billing_service_charge',
      'billing_sinking_fund',
      'billing_other',
      'collection_service_charge',
      'collection_sinking_fund',
      'collection_other',
      'collection_open_credit',
    ];

    return fields.every((field) => hasValue(billing![field])) &&
        fields.any((field) => number(billing![field]) != 0);
  }

  bool get arrearsComplete {
    if (arrears == null) return false;

    return hasValue(arrears!['opening_arrears']) &&
        hasValue(arrears!['adjustments']) &&
        (number(arrears!['opening_arrears']) != 0 ||
            number(arrears!['adjustments']) != 0);
  }

  bool get utilitiesComplete {
    final row = utilities;
    if (row == null) return false;

    // The Utilities page saves only the monthly electricity and water
    // figures (report_id, report_month, electricity_kwh, water_m3); it never
    // writes period_start, period_end or days. When a row does not store
    // them, the period is the reporting month and the day count is the
    // number of days in it. Values that ARE stored are still validated.
    final start = hasValue(row['period_start'])
        ? parseDate(row['period_start'])
        : DateTime(reportMonth.year, reportMonth.month, 1);
    final end = hasValue(row['period_end'])
        ? parseDate(row['period_end'])
        : monthEnd;
    final days = hasValue(row['days'])
        ? double.tryParse(row['days'].toString())
        : monthEnd.day.toDouble();

    return start != null &&
        end != null &&
        !end.isBefore(start) &&
        days != null &&
        days > 0 &&
        hasValue(row['electricity_kwh']) &&
        hasValue(row['water_m3']);
  }

  List<MapEntry<String, bool>> get checklist => [
    MapEntry('Billing & Collection', billingComplete),
    MapEntry('Arrears Reconciliation', arrearsComplete),
    MapEntry('Sinking Fund Transfers', transfers.isNotEmpty),
    MapEntry('Approved Expenditure', siteId.isNotEmpty),
    MapEntry('Utilities', utilitiesComplete),
  ];

  List<MapEntry<String, bool>> get operationsChecklist => [
    MapEntry('Maintenance & Works', maintenanceWorks.isNotEmpty),
    MapEntry('Complaints & Resolution', complaints.isNotEmpty),
    MapEntry('AGM / EGM Resolutions', resolutions.isNotEmpty),
    MapEntry('Lift Incidents', liftIncidents.isNotEmpty),
    MapEntry('Asset Register', assets.isNotEmpty),
    MapEntry('Monthly Asset Conditions', assetConditions.isNotEmpty),
    MapEntry('Service History', serviceHistory.isNotEmpty),
  ];

  List<MapEntry<String, bool>> get occupancyUnitChecklist => [
    MapEntry(
      'Occupancy Records',
      occupancyRecords.isNotEmpty && (propertyTotalUnits ?? 0) > 0,
    ),
    MapEntry('Unit Movement', unitMovements.isNotEmpty),
    MapEntry('Renovation Works', renovationWorks.isNotEmpty),
    MapEntry('Sub-Sales Units', subSalesUnits.isNotEmpty),
  ];

  // Checklist labels whose source table failed to load.
  Set<String> get failedChecklistItems => {
    if (failedTables.contains('service_providers')) 'Service Providers',
    if (failedTables.contains('licences_regulatory')) 'Licences & Regulatory',
    if (failedTables.contains('compliance_best_practices'))
      'Compliance & Best Practices',
    if (failedTables.contains('insurance_policies')) 'Insurance Policies',
    if (failedTables.contains('insurance_claims')) 'Insurance Claims',
  };

  Set<String> get unscopedChecklistItems => {
    if (unscopedTables.contains('insurance_policies')) 'Insurance Policies',
    if (unscopedTables.contains('insurance_claims')) 'Insurance Claims',
  };

  String get missingInsuranceLinksWarning {
    final sections = <String>[
      if (unscopedTables.contains('insurance_policies')) 'insurance policies',
      if (unscopedTables.contains('insurance_claims')) 'insurance claims',
    ];
    if (sections.isEmpty) return '';
    return 'Some ${sections.join(' and ')} could not be assigned to this '
        'property and were excluded. Link them to the correct property or '
        'policy in Supabase, then refresh the PDF.';
  }

  List<MapEntry<String, bool>> get contractsComplianceChecklist => [
    MapEntry('Service Providers', serviceProviders.isNotEmpty),
    MapEntry('Licences & Regulatory', licencesRegulatory.isNotEmpty),
    MapEntry('Compliance & Best Practices', compliancePractices.isNotEmpty),
    MapEntry('Insurance Policies', insurancePolicies.isNotEmpty),
    MapEntry('Insurance Claims', insuranceClaims.isNotEmpty),
  ];

  // ============================================================
  // OCCUPANCY & UNIT MANAGEMENT CALCULATIONS
  // ============================================================

  int get totalVacantUnits => occupancyRecords.fold<int>(
    0,
    (total, row) => total + number(row['vacant']).toInt(),
  );

  int get totalOwnerOccupiedUnits => occupancyRecords.fold<int>(
    0,
    (total, row) => total + number(row['owner_occupied']).toInt(),
  );

  int get totalTenantOccupiedUnits => occupancyRecords.fold<int>(
    0,
    (total, row) => total + number(row['tenant_occupied']).toInt(),
  );

  int get totalCommercialUnits => occupancyRecords.fold<int>(
    0,
    (total, row) => total + number(row['commercial_units']).toInt(),
  );

  int get totalOccupiedUnits =>
      totalOwnerOccupiedUnits + totalTenantOccupiedUnits;

  int get commercialBalanceUnits {
    final units = propertyTotalUnits ?? 0;
    if (units <= 0) return 0;

    final recorded =
        totalOwnerOccupiedUnits + totalTenantOccupiedUnits + totalVacantUnits;
    return units > recorded ? units - recorded : 0;
  }

  int get accountedUnits =>
      totalOwnerOccupiedUnits +
      totalTenantOccupiedUnits +
      totalVacantUnits +
      commercialBalanceUnits;

  double get occupancyRate {
    final units = propertyTotalUnits ?? 0;
    return units <= 0 ? 0 : totalOccupiedUnits / units * 100;
  }

  int get moveInCount => unitMovements
      .where((row) => row['movement']?.toString() == 'Move In')
      .length;

  int get moveOutCount => unitMovements
      .where((row) => row['movement']?.toString() == 'Move Out')
      .length;

  int get renovationInProgressCount => renovationWorks
      .where((row) => row['renovation_status']?.toString() == 'In Progress')
      .length;

  int get renovationCompletedCount => renovationWorks
      .where((row) => row['renovation_status']?.toString() == 'Completed')
      .length;

  double get totalRenovationDeposits => renovationWorks.fold<double>(
    0,
    (total, row) => total + number(row['deposit_amount']),
  );

  String staffShiftForPdf(
    Map<String, dynamic>? staff,
    String timingKey,
    String paxKey,
  ) {
    final timing = staff?[timingKey]?.toString().trim() ?? '';
    final pax = staff?[paxKey];
    final parts = <String>[
      if (timing.isNotEmpty) timing,
      if (pax != null && pax.toString().trim().isNotEmpty)
        '${pax.toString()} pax',
    ];
    return parts.isEmpty ? '-' : parts.join('\n');
  }

  // Use the entered Total Staff, or derive Total Pax from the saved shifts.
  // Missing values remain unknown; never treat them as zero by default.
  int? staffTotalPaxForPdf(Map<String, dynamic>? staff) {
    if (staff == null) return null;

    int? readPax(dynamic value) {
      final raw = value?.toString().trim() ?? '';
      if (raw.isEmpty) return null;
      final parsed = num.tryParse(raw);
      if (parsed == null ||
          !parsed.isFinite ||
          parsed < 0 ||
          parsed != parsed.toInt()) {
        return null;
      }
      return parsed.toInt();
    }

    final total = readPax(staff['total_staff']);
    if (total != null) return total;

    final day = readPax(staff['day_shift_staff']);
    final night = readPax(staff['night_shift_staff']);
    if (day == null && night == null) return null;
    return (day ?? 0) + (night ?? 0);
  }

  // ============================================================
  // OPERATIONS HELPERS
  // ============================================================

  int countStatus(List<Map<String, dynamic>>? rows, String status) {
    final safeRows = rows ?? const <Map<String, dynamic>>[];

    return safeRows.where((row) {
      return (row['status']?.toString().trim().toLowerCase() ?? '') ==
          status.toLowerCase();
    }).length;
  }

  String statusSummary(List<Map<String, dynamic>>? rows) {
    final safeRows = rows ?? const <Map<String, dynamic>>[];

    return 'Total: ${safeRows.length} | '
        'Completed: ${countStatus(safeRows, 'Completed')} | '
        'In Progress: ${countStatus(safeRows, 'In Progress')} | '
        'Pending: ${countStatus(safeRows, 'Pending')} | '
        'Cancelled: ${countStatus(safeRows, 'Cancelled')} | '
        'On Hold: ${countStatus(safeRows, 'On Hold')}';
  }

  List<List<String>> operationRows(
    List<Map<String, dynamic>>? rows,
    List<String> fields,
  ) {
    final safeRows = rows ?? const <Map<String, dynamic>>[];

    if (safeRows.isEmpty) {
      return [
        List<String>.generate(
          fields.length,
          (index) => index == 0 ? 'No records' : '-',
        ),
      ];
    }

    return safeRows.map((row) {
      return fields.map((field) {
        final value = row[field];

        if (field.endsWith('_date') || field == 'deadline') {
          return dateLabel(value);
        }

        return textValue(value);
      }).toList();
    }).toList();
  }

  Map<String, dynamic> get assetsByUuid => {
    for (final asset in assets)
      if (asset['id'] != null) asset['id'].toString(): asset,
  };

  Map<String, dynamic> get conditionsByAssetUuid => {
    for (final condition in assetConditions)
      if (condition['asset_uuid'] != null)
        condition['asset_uuid'].toString(): condition,
  };

  String assetLabel(dynamic assetUuid) {
    if (assetUuid == null) return '-';

    final asset = assetsByUuid[assetUuid.toString()];
    if (asset == null) return assetUuid.toString();

    return '${textValue(asset['asset_id'])} - '
        '${textValue(asset['asset_item'])}';
  }

  int get recordedConditionCount {
    final recordedUuids = assetConditions
        .map((row) => row['asset_uuid']?.toString())
        .whereType<String>()
        .toSet();

    return assets
        .where((asset) => recordedUuids.contains(asset['id']?.toString()))
        .length;
  }

  int get pendingConditionCount =>
      (assets.length - recordedConditionCount).clamp(0, assets.length);

  int get activeAssetCount => assets.where((asset) {
    return (asset['status']?.toString().toLowerCase() ?? 'active') == 'active';
  }).length;

  int get retiredAssetCount => assets.where((asset) {
    return (asset['status']?.toString().toLowerCase() ?? '') == 'retired';
  }).length;

  // ============================================================
  // CHECKLIST UI
  // ============================================================

  Widget buildChecklistGroup({
    required String title,
    required IconData icon,
    required List<MapEntry<String, bool>> items,
    required bool expanded,
    required VoidCallback onToggle,
    required ThemeData theme,
  }) {
    final completed = items.where((item) => item.value).length;
    final progress = items.isEmpty ? 0.0 : completed / items.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('$completed of ${items.length} checks completed'),
            trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            onTap: onToggle,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: LinearProgressIndicator(value: progress),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            ...items.map(
              (item) => ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(
                  item.value ? Icons.check_circle : Icons.pending_outlined,
                  color: item.value ? Colors.green : Colors.orange,
                ),
                title: Text(item.key),
                subtitle: Text(
                  item.value
                      ? 'Data detected'
                      : failedChecklistItems.contains(item.key)
                      ? 'Could not load data - review required'
                      : unscopedChecklistItems.contains(item.key)
                      ? 'Unassigned property records - site_id needed'
                      : 'Review required',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // PDF STYLE (matches the September 2026 Apex Choice report)
  // ============================================================

  static const PdfColor _red = PdfColor.fromInt(0xFFC0504D);
  static const PdfColor _green = PdfColor.fromInt(0xFFD7E4BD);
  static const PdfColor _orange = PdfColor.fromInt(0xFFFAC090);
  static const PdfColor _blue = PdfColor.fromInt(0xFF4F81BD);
  static const PdfColor _lightGreen = PdfColor.fromInt(0xFF9BBB59);

  static const String _placeholder = '[ To be updated ]';

  // Set in buildPdf(). Null -> a placeholder box is drawn instead.
  pw.ImageProvider? _logo;

  String amt(dynamic value) => NumberFormat('#,##0.00').format(number(value));

  String qty(dynamic value) => NumberFormat('#,##0.##').format(number(value));

  String monthShort(int month) =>
      DateFormat('MMM-yy').format(DateTime(reportMonth.year, month));

  List<String> get yearMonthLabels => [
    for (var m = 1; m <= 12; m++) monthShort(m),
  ];

  String monthLong(int month) =>
      DateFormat('MMMM yyyy').format(DateTime(reportMonth.year, month));

  String get siteName {
    final name = firstText(siteRow, ['site_name', 'name', 'property_name']);
    return name == '-' ? 'PROPERTY NAME' : name;
  }

  // property_sites.site_information (jsonb) -> Map, or null if missing/invalid.
  Map<String, dynamic>? get siteInformation {
    final value = siteRow?['site_information'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  String get totalUnitsDisplay {
    final residences = int.tryParse(siteInfoValue('residential_units'));

    final commercial = int.tryParse(siteInfoValue('commercial_units'));

    if (residences != null &&
        commercial != null &&
        residences >= 0 &&
        commercial >= 0) {
      final total = residences + commercial;

      return '$residences (Residences) + '
          '$commercial (Commercial) = $total';
    }

    return propertyTotalUnits?.toString() ?? _placeholder;
  }

  // Use the committee term shown in Site Profile for this report month.
  // Term endpoints are inclusive; membership removed_from is exclusive.
  Map<String, dynamic>? get effectiveCommitteeTerm {
    final selectedMonth = reportMonthStart;
    for (final term in committeeTerms) {
      final from = calendarDate(term['effective_from']);
      final until = calendarDate(term['effective_until']);
      if (from == null ||
          (hasValue(term['effective_until']) && until == null)) {
        continue;
      }
      final startMonth = DateTime(from.year, from.month);
      final endMonth = until == null
          ? null
          : DateTime(until.year, until.month);
      if (!selectedMonth.isBefore(startMonth) &&
          (endMonth == null || !selectedMonth.isAfter(endMonth))) {
        return term;
      }
    }
    return null;
  }

  String get committeeTitle {
    final termName =
        effectiveCommitteeTerm?['term_name']?.toString().trim() ?? '';
    return termName.isEmpty ? 'Committee Members' : termName;
  }

  // Site Profile stores Effective From as the first ACTIVE month and
  // removed_from as the first INACTIVE month (Effective Until + 1 month).
  // Only show members of this term who are active in the PDF report month.
  List<Map<String, dynamic>> get committeeMembers {
    final selectedMonth = reportMonthStart;
    final termId = effectiveCommitteeTerm?['id']?.toString();
    if (termId == null || termId.isEmpty) return [];
    return committeeHistory.where((member) {
      if (member['term_id']?.toString() != termId) return false;
      final from = calendarDate(member['effective_from']);
      final removed = calendarDate(member['removed_from']);
      // Do not treat an invalid end date as an ongoing membership.
      if (from == null || (hasValue(member['removed_from']) && removed == null)) {
        return false;
      }
      final startMonth = DateTime(from.year, from.month);
      final removedMonth = removed == null
          ? null
          : DateTime(removed.year, removed.month);
      return !startMonth.isAfter(selectedMonth) &&
          (removedMonth == null || removedMonth.isAfter(selectedMonth));
    }).toList();
  }

  String committeeEffectiveFrom(Map<String, dynamic> member) {
    final from = calendarDate(member['effective_from']);
    return from == null ? _placeholder : DateFormat('MMMM yyyy').format(from);
  }

  String committeeEffectiveUntil(Map<String, dynamic> member) {
    if (!hasValue(member['removed_from'])) return 'Ongoing';
    final removed = calendarDate(member['removed_from']);
    if (removed == null) return _placeholder;
    // removed_from is the first inactive month, not the final active month.
    final lastActive = DateTime(removed.year, removed.month - 1);
    return DateFormat('MMMM yyyy').format(lastActive);
  }

  // Raw saved text from site_information[key] (trimmed, '' if missing).
  String siteInfoValue(String key) =>
      siteInformation?[key]?.toString().trim() ?? '';

  String siteInfoText(String key) {
    final value = siteInfoValue(key);
    return value.isEmpty ? _placeholder : value;
  }

  String _withRm(String value) =>
      value.toUpperCase().startsWith('RM') ? value : 'RM$value';

  // e.g. "RM3.71 per share unit / RM0.36 per square foot" (values as saved).
  String siteRate(String perShareKey, String perSqftKey) {
    final share = siteInfoValue(perShareKey);
    final sqft = siteInfoValue(perSqftKey);

    final parts = <String>[
      if (share.isNotEmpty) '${_withRm(share)} per share unit',
      if (sqft.isNotEmpty) '${_withRm(sqft)} per square foot',
    ];

    return parts.isEmpty ? _placeholder : parts.join(' / ');
  }

  // Saved amount formatted as RM 1,234.00; non-numeric text is shown as saved.
  String siteMoney(String key) {
    final value = siteInfoValue(key);
    if (value.isEmpty) return _placeholder;

    final parsed = double.tryParse(
      value
          .replaceAll(',', '')
          .replaceFirst(RegExp(r'^RM\s*', caseSensitive: false), ''),
    );

    return parsed == null
        ? value
        : 'RM ${NumberFormat('#,##0.00').format(parsed)}';
  }

  String committeeField(Map<String, dynamic> member, String key) {
    return hasValue(member[key]) ? member[key].toString().trim() : _placeholder;
  }

  String get preparedByName {
    // The generated PDF and its saved metadata use the same profile name.
    if (_generatingUserName != null && _generatingUserName!.trim().isNotEmpty) {
      return _generatingUserName!.trim();
    }
    final user = supabase.auth.currentUser;
    final meta = user?.userMetadata;
    final name = meta?['full_name'] ?? meta?['name'] ?? meta?['display_name'];

    if (name != null && name.toString().trim().isNotEmpty) {
      return name.toString().trim();
    }

    final email = user?.email;
    return email == null || email.isEmpty ? '-' : email;
  }

  pw.Widget pdfLogo({double width = 90, double height = 34}) {
    if (_logo != null) {
      return pw.SizedBox(
        width: width,
        height: height,
        child: pw.Image(_logo!, fit: pw.BoxFit.contain),
      );
    }

    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _red, width: 0.8),
      ),
      child: pw.Text(
        'APEX CHOICE\n[ logo placeholder ]',
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: height > 60 ? 16 : 6,
          fontWeight: pw.FontWeight.bold,
          color: _red,
        ),
      ),
    );
  }

  // Red section banner, e.g. "5. Financial Position"
  pw.Widget pdfBanner(String title) {
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: 10),
      padding: const pw.EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      decoration: pw.BoxDecoration(
        color: _red,
        border: pw.Border.all(color: PdfColors.black, width: 1.2),
      ),
      child: pw.Text(
        pdfSafe(title),
        style: pw.TextStyle(
          fontSize: 14,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
  }

  // Black sub-section bar, e.g. "5.1 Billing VS Collection"
  pw.Widget pdfBar(String title) {
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 12, bottom: 6),
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: PdfColors.black,
      child: pw.Text(
        pdfSafe(title),
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
  }

  // Underlined caption above a table or chart.
  pw.Widget pdfSub(String title) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 8, bottom: 4),
      child: pw.Text(
        pdfSafe(title),
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          decoration: pw.TextDecoration.underline,
        ),
      ),
    );
  }

  pw.Widget pdfNote(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4),
      child: pw.Text(
        pdfSafe(text),
        style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
      ),
    );
  }

  pw.Widget pdfTable(
    List<String> headers,
    List<List<String>> rows, {
    Map<int, pw.TableColumnWidth>? widths,
    bool highlightLast = false,
    Set<int> rightAlign = const {},
    Set<int> redRows = const {},
    double fontSize = 8,
  }) {
    pw.Widget cell(
      String text, {
      bool header = false,
      bool bold = false,
      bool red = false,
      int col = 0,
    }) {
      final right = !header && rightAlign.contains(col);

      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        alignment: header
            ? pw.Alignment.center
            : (right ? pw.Alignment.centerRight : pw.Alignment.centerLeft),
        child: pw.Text(
          pdfSafe(text),
          textAlign: header
              ? pw.TextAlign.center
              : (right ? pw.TextAlign.right : pw.TextAlign.left),
          style: pw.TextStyle(
            fontSize: fontSize,
            color: red ? const PdfColor.fromInt(0xFFB91C1C) : PdfColors.black,
            fontWeight: header || bold || red
                ? pw.FontWeight.bold
                : pw.FontWeight.normal,
          ),
        ),
      );
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
      columnWidths: widths,
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _green),
          children: [
            for (var c = 0; c < headers.length; c++)
              cell(headers[c], header: true, col: c),
          ],
        ),
        for (var r = 0; r < rows.length; r++)
          pw.TableRow(
            decoration: highlightLast && r == rows.length - 1
                ? const pw.BoxDecoration(color: _orange)
                : null,
            children: [
              for (var c = 0; c < headers.length; c++)
                cell(
                  c < rows[r].length ? rows[r][c] : '-',
                  bold: highlightLast && r == rows.length - 1,
                  red: redRows.contains(r),
                  col: c,
                ),
            ],
          ),
      ],
    );
  }

  // Two-column "label: value" table with a green title row.
  pw.Widget pdfKeyValueTable(String title, List<List<String>> rows) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            color: _green,
            border: pw.Border.all(color: PdfColors.black, width: 0.5),
          ),
          child: pw.Text(
            pdfSafe(title),
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(1),
            1: pw.FlexColumnWidth(1.6),
          },
          children: [
            for (final row in rows)
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(
                      pdfSafe(row[0]),
                      style: pw.TextStyle(
                        fontSize: 8.5,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(
                      pdfSafe(row[1]),
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  // Section 9.3: the summary saved on the selected monthly report.
  // The 3-column layout mirrors the reference: merged Underwriter, merged
  // Validity Period, separate From / To, followed by Cost and Notes rows.
  pw.Widget pdfInsuranceCoverageSummary() {
    final summary = insuranceCoverageSummary;
    final underwriter = firstText(summary, ['insurance_coverage_underwriter']);
    final fromDate = calendarDate(summary?['insurance_coverage_valid_from']);
    final toDate = calendarDate(summary?['insurance_coverage_valid_to']);
    final fromText = fromDate == null
        ? '-'
        : DateFormat('dd/MM/yyyy').format(fromDate);
    final toText = toDate == null
        ? '-'
        : DateFormat('dd/MM/yyyy').format(toDate);
    final costValue = firstValue(summary, ['insurance_coverage_cost']);
    final costText = costValue == null ? '-' : money(costValue);
    final notes = firstText(summary, ['insurance_coverage_renewal_notes']);

    const borderSide = pw.BorderSide(color: PdfColors.black, width: 0.5);
    const grey = PdfColor.fromInt(0xFFE7E7E7);
    const rowBorder = pw.TableBorder(
      left: borderSide,
      right: borderSide,
      bottom: borderSide,
      verticalInside: borderSide,
    );

    pw.Widget cell(
      String value, {
      bool label = false,
      bool greyBackground = false,
      bool centered = false,
    }) {
      return pw.Container(
        color: greyBackground ? grey : PdfColors.white,
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
        alignment: centered ? pw.Alignment.center : pw.Alignment.centerLeft,
        child: pw.Text(
          pdfSafe(value),
          textAlign: centered ? pw.TextAlign.center : pw.TextAlign.left,
          style: pw.TextStyle(
            fontSize: 8.5,
            fontWeight: label ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );
    }

    // The first 40% of each Cost / Notes row aligns with the two grey
    // label columns (27% + 13%) of the validity-period block above.
    pw.Widget detailRow(String label, String value) {
      return pw.Table(
        border: rowBorder,
        columnWidths: const {
          0: pw.FlexColumnWidth(4),
          1: pw.FlexColumnWidth(6),
        },
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
        children: [
          pw.TableRow(
            children: [
              cell(label, label: true, greyBackground: true, centered: true),
              cell(value),
            ],
          ),
        ],
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
          decoration: pw.BoxDecoration(
            color: grey,
            border: pw.Border.all(color: PdfColors.black, width: 0.5),
          ),
          child: pw.Text(
            pdfSafe('Underwriter: $underwriter'),
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.Table(
          border: rowBorder,
          columnWidths: const {
            0: pw.FlexColumnWidth(2.7),
            1: pw.FlexColumnWidth(7.3),
          },
          defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
          children: [
            pw.TableRow(
              children: [
                cell(
                  'Validity Period',
                  label: true,
                  greyBackground: true,
                  centered: true,
                ),
                pw.Table(
                  border: const pw.TableBorder(
                    horizontalInside: borderSide,
                    verticalInside: borderSide,
                  ),
                  columnWidths: const {
                    0: pw.FlexColumnWidth(1.3),
                    1: pw.FlexColumnWidth(6),
                  },
                  defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
                  children: [
                    pw.TableRow(
                      children: [
                        cell('From', label: true, greyBackground: true),
                        cell(fromText),
                      ],
                    ),
                    pw.TableRow(
                      children: [
                        cell('To', label: true, greyBackground: true),
                        cell(toText),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        detailRow('Cost (RM)', costText),
        detailRow('Notes', notes),
      ],
    );
  }

  // Simple bar chart drawn with plain widgets (no chart-package dependency).
  // Bar chart with one shared plot height and zero baseline.
  pw.Widget pdfBarChart({
    required List<String> labels,
    required List<List<double>> series,
    required List<PdfColor> colors,
    List<String>? legends,
    double height = 100,
    bool showValues = true,
    String? yAxisTitle,
    double? yAxisStep,
    double? yAxisMax,
    bool moneyYAxis = false,
  }) {
    final maxValue = series
        .expand((values) => values)
        .fold<double>(0, (max, value) => value > max ? value : max);
    final neededMax = math.max(maxValue, yAxisMax ?? 0.0);
    final step = yAxisStep != null && yAxisStep > 0 ? yAxisStep : null;
    final gridLineCount = step != null
        ? math.max(1, (neededMax / step).ceil())
        : 5;
    final topValue = step != null
        ? gridLineCount * step
        : (neededMax > 0 ? neededMax : 1.0);

    // The plotted data, horizontal grid lines and Y-axis labels all use
    // exactly `height` points. Padding is OUTSIDE that shared plot area.
    final scale = height / topValue;
    final topPadding = showValues ? 12.0 : 6.0;
    const bottomPadding = 6.0;
    const tickHeight = 10.0;
    final canvasHeight = topPadding + height + bottomPadding;
    final axisWidth = moneyYAxis ? 58.0 : 28.0;
    final barWidth = series.length > 1 ? 7.0 : 14.0;

    String fmt(double value) => value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);

    return pw.Container(
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            // Never bottom-align the Y axis with the X-axis text underneath.
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (yAxisTitle != null)
                pw.Container(
                  width: 18,
                  height: canvasHeight,
                  alignment: pw.Alignment.center,
                  child: pw.Transform.rotate(
                    angle: math.pi / 2,
                    child: pw.Text(
                      pdfSafe(yAxisTitle),
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                ),
              // Tick labels are CENTERED on precisely the same coordinates
              // used to position the horizontal grid lines.
              pw.SizedBox(
                width: axisWidth,
                height: canvasHeight,
                child: pw.Stack(
                  children: [
                    for (var g = 0; g <= gridLineCount; g++)
                      pw.Positioned(
                        right: 0,
                        bottom:
                            bottomPadding +
                            height * g / gridLineCount -
                            tickHeight / 2,
                        child: pw.Container(
                          width: axisWidth,
                          height: tickHeight,
                          alignment: pw.Alignment.centerRight,
                          child: pw.Text(
                            moneyYAxis
                                ? NumberFormat(
                                    '#,##0.00',
                                  ).format(topValue * g / gridLineCount)
                                : fmt(topValue * g / gridLineCount),
                            style: const pw.TextStyle(fontSize: 8),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              pw.SizedBox(width: 4),
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.SizedBox(
                      height: canvasHeight,
                      child: pw.Stack(
                        children: [
                          // Grid lines: 0, step, 2*step, ... max.
                          for (var g = 0; g <= gridLineCount; g++)
                            pw.Positioned(
                              left: 0,
                              right: 0,
                              bottom:
                                  bottomPadding + height * g / gridLineCount,
                              child: pw.Container(
                                height: 0.5,
                                color: g == 0
                                    ? PdfColors.grey500
                                    : PdfColors.grey300,
                              ),
                            ),
                          // Every bar starts on the SAME zero line as the grid.
                          pw.Positioned.fill(
                            child: pw.Row(
                              crossAxisAlignment: pw.CrossAxisAlignment.end,
                              children: [
                                for (var i = 0; i < labels.length; i++)
                                  pw.Expanded(
                                    child: pw.Container(
                                      height: canvasHeight,
                                      alignment: pw.Alignment.bottomCenter,
                                      child: pw.Padding(
                                        padding: const pw.EdgeInsets.only(
                                          bottom: bottomPadding,
                                        ),
                                        child: pw.Row(
                                          mainAxisSize: pw.MainAxisSize.min,
                                          crossAxisAlignment:
                                              pw.CrossAxisAlignment.end,
                                          children: [
                                            for (
                                              var s = 0;
                                              s < series.length;
                                              s++
                                            )
                                              pw.Column(
                                                mainAxisSize:
                                                    pw.MainAxisSize.min,
                                                children: [
                                                  if (showValues &&
                                                      series[s][i] > 0)
                                                    pw.Padding(
                                                      padding:
                                                          const pw.EdgeInsets.only(
                                                            bottom: 2,
                                                          ),
                                                      child: pw.Text(
                                                        fmt(series[s][i]),
                                                        style:
                                                            const pw.TextStyle(
                                                              fontSize: 6,
                                                            ),
                                                      ),
                                                    ),
                                                  pw.Container(
                                                    width: barWidth,
                                                    height:
                                                        math.max(
                                                          0.0,
                                                          series[s][i],
                                                        ) *
                                                        scale,
                                                    color: colors[s],
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < labels.length; i++)
                          pw.Expanded(
                            child: pw.Text(
                              pdfSafe(labels[i]),
                              textAlign: pw.TextAlign.center,
                              style: const pw.TextStyle(fontSize: 8),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (legends != null && legends.isNotEmpty) ...[
            pw.SizedBox(height: 5),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.center,
              children: [
                for (var s = 0; s < legends.length; s++) ...[
                  pw.Container(width: 7, height: 7, color: colors[s]),
                  pw.SizedBox(width: 3),
                  pw.Text(
                    pdfSafe(legends[s]),
                    style: const pw.TextStyle(fontSize: 7),
                  ),
                  pw.SizedBox(width: 12),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  // Line chart
  pw.Widget pdfLineChart({
    required List<String> labels,
    required List<List<double>> series,
    required List<PdfColor> colors,
    required List<String> legends,
    double height = 160,
    String xAxisTitle = 'Month',
    String yAxisTitle = 'Consumption (kWh)',
    bool showValues = false,
  }) {
    if (labels.isEmpty || series.isEmpty) {
      return pw.Text('No chart data available');
    }

    final allValues = series.expand((values) => values).toList();

    if (allValues.isEmpty) {
      return pw.Text('No chart data available');
    }

    final maxValue = allValues.reduce((a, b) => a > b ? a : b);

    final yMax = maxValue <= 0 ? 5.0 : maxValue * 1.2;

    final yTicks = List<double>.generate(6, (i) => yMax * i / 5);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 60,
              child: pw.Text(
                yAxisTitle,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),

            pw.Expanded(
              child: pw.SizedBox(
                height: height,
                child: pw.Chart(
                  grid: pw.CartesianGrid(
                    xAxis: pw.FixedAxis.fromStrings(
                      labels,
                      textStyle: const pw.TextStyle(fontSize: 7),
                    ),
                    yAxis: pw.FixedAxis<double>(
                      yTicks,
                      format: (value) => value.toStringAsFixed(0),
                      divisions: true,
                      textStyle: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                  datasets: [
                    for (int s = 0; s < series.length; s++)
                      pw.LineDataSet(
                        color: colors[s],
                        lineWidth: 2,
                        drawPoints: true,
                        pointSize: 3,
                        isCurved: false,
                        data: [
                          for (
                            int i = 0;
                            i < series[s].length && i < labels.length;
                            i++
                          )
                            pw.PointChartValue(i.toDouble(), series[s][i]),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),

        pw.SizedBox(height: 8),

        pw.Center(
          child: pw.Text(xAxisTitle, style: const pw.TextStyle(fontSize: 9)),
        ),

        pw.SizedBox(height: 8),

        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            for (int i = 0; i < legends.length && i < colors.length; i++) ...[
              pw.Container(width: 15, height: 3, color: colors[i]),
              pw.SizedBox(width: 5),
              pw.Text(legends[i], style: const pw.TextStyle(fontSize: 8)),
              pw.SizedBox(width: 12),
            ],
          ],
        ),
      ],
    );
  }

  pw.Widget pdfPie(
    List<MapEntry<String, double>> data,
    List<PdfColor> colors, {
    double width = 230,
    double height = 150,
    bool showPercentages = false,
    bool showLabels = true,
  }) {
    final active = <int>[
      for (var i = 0; i < data.length; i++)
        if (data[i].value > 0) i,
    ];

    if (active.isEmpty) {
      return pw.Text(
        'No records to chart.',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      );
    }

    String legendText(MapEntry<String, double> entry) => showPercentages
        ? '${entry.key} (${entry.value.toStringAsFixed(1)}%)'
        : '${entry.key} (${entry.value.toInt()})';

    return pw.SizedBox(
      width: width,
      height: height,
      child: pw.Chart(
        grid: pw.PieGrid(),
        datasets: [
          for (final i in active)
            pw.PieDataSet(
              legend: showLabels ? pdfSafe(legendText(data[i])) : null,
              value: data[i].value,
              color: colors[i],
              legendStyle: const pw.TextStyle(fontSize: 7),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // PDF SECTION BUILDERS
  // ============================================================

  List<pw.Widget> pdfCover() {
    return [
      pw.SizedBox(height: 50),
      pw.Center(child: pdfLogo(width: 240, height: 130)),
      pw.SizedBox(height: 50),
      pw.Center(
        child: pw.Text(
          'MONTHLY REPORT',
          style: pw.TextStyle(fontSize: 38, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.SizedBox(height: 6),
      pw.Center(
        child: pw.Text(
          pdfSafe(monthLabel.toUpperCase()),
          style: pw.TextStyle(fontSize: 38, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.SizedBox(height: 50),
      pw.Center(
        child: pw.Text(
          pdfSafe(siteName.toUpperCase()),
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.SizedBox(height: 24),
      pw.Center(
        child: pw.Text(
          'Report status: ${pdfSafe(_currentReportRecord['status'] ?? widget.report['status'] ?? 'Draft')}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
      ),
    ];
  }

  List<pw.Widget> pdfToc() {
    final categories = pdfAssetCategories;
    final entries = <List<dynamic>>[
      [0, '1. Site Information'],
      [0, '2. Committee Members'],
      [0, '4. Dashboard for The Month'],
      [0, '5. Financial Position'],
      [1, '5.1 Billing Vs Collection'],
      [1, '5.2 Collection and Arrears Report'],
      [1, '5.3 Sinking Fund Transfer'],
      [1, '5.4 Summary of Fixed Deposit Placement'],
      [1, '5.5 Approved Expenditure Summary'],
      [1, '5.6 Electricity Consumption Analysis'],
      [1, '5.7 Water Consumption Analysis'],
      [0, '6. AGM / EGM Resolution'],
      [0, '7. Property Management and Building Operations'],
      [1, '7.1 Weekly Maintenance Progress'],
      [1, '7.2 Complaints and Resolution Summary'],
      [1, '7.3 Lift Summary'],
      [1, '7.4 Occupancy Overview'],
      [1, '7.5 Renovation Works Overview'],
      [0, '8. Service Provider and Contract Management'],
      [0, '9. Licensing and Insurance Overview'],
      [1, '9.1 Licences and Regulatory Compliance'],
      [1, '9.2 Compliance & Best Practices'],
      [1, '9.3 Insurance Coverage Status'],
      [1, '9.4 Insurance Claims Update'],
      [0, '10. Asset Register'],
      if (categories.isEmpty) [1, '10.1 Asset Register (No Assets)'],
      for (var i = 0; i < categories.length; i++)
        [1, '10.${i + 1} ${categories[i]}'],
      [
        1,
        '10.${categories.isEmpty ? 2 : categories.length + 1} Service History',
      ],
    ];

    return [
      pdfBanner('TABLE OF CONTENT'),
      pw.SizedBox(height: 10),
      for (final entry in entries)
        pw.Padding(
          padding: pw.EdgeInsets.only(
            left: (entry[0] as int) * 28.0 + 12,
            top: (entry[0] as int) == 0 ? 6 : 3,
          ),
          child: pw.Text(
            pdfSafe(entry[1]),
            style: pw.TextStyle(
              fontSize: 10.5,
              fontWeight: (entry[0] as int) == 0
                  ? pw.FontWeight.bold
                  : pw.FontWeight.normal,
            ),
          ),
        ),
    ];
  }

  // 1-3. Placeholders: to be completed by the user.
  List<pw.Widget> pdfSiteAndCommittee() {
    final members = committeeMembers;

    return [
      pdfBanner('1. Site Information'),
      pdfKeyValueTable(siteName, [
        ['Site name:', siteName == 'PROPERTY NAME' ? _placeholder : siteName],
        ['Total units:', totalUnitsDisplay],
        ['Reg. address:', siteInfoText('registration_address')],
        ['Email address:', siteInfoText('email')],
        ['Contact number:', siteInfoText('contact_number')],
        [
          'Service charge rate:',
          siteRate('service_charge_per_share_unit', 'service_charge_per_sqft'),
        ],
        [
          'Sinking fund rate:',
          siteRate('sinking_fund_per_share_unit', 'sinking_fund_per_sqft'),
        ],
        ['Service monthly billing:', siteInfoText('service_billing_frequency')],
        ['Fund monthly billing:', siteInfoText('fund_billing_frequency')],
        ['Total monthly billing:', siteMoney('total_monthly_billing')],
        [
          'Total Aggregate Share Unit:',
          siteInfoText('total_aggregate_share_unit'),
        ],
        ['Annual Billing:', siteMoney('annual_billing')],
      ]),
      pw.SizedBox(height: 18),
      pdfBanner('2. Committee Members for the Term $committeeTitle'),
      pdfTable(
        ['No.', 'Name', 'Designation'],
        members.isEmpty
            ? [
                ['-', 'No committee members for this month', '-'],
              ]
            : [
                for (var i = 0; i < members.length; i++)
                  [
                    '${i + 1}',
                    committeeField(members[i], 'member_name'),
                    committeeField(members[i], 'designation'),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(30),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(1.3),
        },
        fontSize: 9,
      ),
    ];
  }

  // 4
  List<pw.Widget> pdfDashboard() {
    final works = maintenanceDashboardWorks;
    int maintenanceCount(String status) => works.where((row) {
      final value = row['_maintenance_summary_status'] ?? row['status'];
      return (value?.toString().trim().toLowerCase() ?? '') ==
          status.toLowerCase();
    }).length;

    final done = maintenanceCount('Completed');
    final inProgress = maintenanceCount('In Progress');
    final pending = maintenanceCount('Pending');
    final cancelledOnHold =
        maintenanceCount('Cancelled') + maintenanceCount('On Hold');

    DateTime? firstMaintenanceDate;

for (final work in works) {
  final start = calendarDate(work['entry_date']) ??
      (work['_source_report_month'] as DateTime?);

  if (start != null &&
      (firstMaintenanceDate == null ||
          start.isBefore(firstMaintenanceDate))) {
    firstMaintenanceDate = start;
  }
}

final cumulativePeriod = firstMaintenanceDate == null
    ? 'through $monthLabel'
    : '${DateFormat('MMMM yyyy').format(firstMaintenanceDate)} - $monthLabel';

    // Lift breakdown from January up to the selected report month.
    final liftByMonth = List<double>.filled(12, 0);
    final liftByLift = <String, int>{};
    final liftOrder = <String, int>{};

    for (final row in ytdLifts) {
      final incidentDate = calendarDate(row['incident_date']);

      // Only count incidents from the selected reporting year.
      if (incidentDate != null && incidentDate.year != reportMonth.year) {
        continue;
      }

      // Use the original report month if Incident Date is missing.
      final incidentMonth =
          incidentDate?.month ?? reportMonthById[row['report_id']?.toString()];

      if (incidentMonth == null ||
          incidentMonth < 1 ||
          incidentMonth > reportMonth.month) {
        continue;
      }

      // Count breakdowns for each month.
      liftByMonth[incidentMonth - 1] += 1;

      // Count breakdowns for each individual lift.
      final label =
          '${textValue(row['tower'])} (Lift ${textValue(row['lift_no'])})';

      liftByLift[label] = (liftByLift[label] ?? 0) + 1;

      liftOrder[label] = int.tryParse(row['lift_no']?.toString() ?? '') ?? 9999;
    }

    final liftKeys = liftByLift.keys.toList()
      ..sort((a, b) {
        final byNo = liftOrder[a]!.compareTo(liftOrder[b]!);
        return byNo != 0 ? byNo : a.compareTo(b);
      });

    // Complaint summary
    final cDone = countStatus(complaints, 'Completed');
    final cInProgress = countStatus(complaints, 'In Progress');
    final cKiv =
        countStatus(complaints, 'Pending') + countStatus(complaints, 'On Hold');

    // Occupancy
    final totalUnits = propertyTotalUnits ?? 0;
    String pct(int n) =>
        totalUnits > 0 ? (n / totalUnits * 100).toStringAsFixed(1) : '-';

    final occupancyCounts = <MapEntry<String, double>>[
      MapEntry('Owner-occupied', totalOwnerOccupiedUnits.toDouble()),
      MapEntry('Tenanted', totalTenantOccupiedUnits.toDouble()),
      MapEntry('Vacant', totalVacantUnits.toDouble()),
      if (commercialBalanceUnits > 0)
        MapEntry('Commercial / Other', commercialBalanceUnits.toDouble()),
    ];

    final occupancyPercentages = <MapEntry<String, double>>[
      for (final entry in occupancyCounts)
        MapEntry(
          entry.key,
          totalUnits > 0 ? entry.value / totalUnits * 100 : 0.0,
        ),
    ];

    final occupancyColors = <PdfColor>[
      _blue,
      _red,
      _lightGreen,
      PdfColors.grey500,
    ];

    // Dashboard totals come from Staff Management; Service Providers
    // determines which months are included in staffReportProviders.
    final staffCountsByService = <String, double>{
      'Landscaping': 0,
      'Cleaning': 0,
      'Security': 0,
    };
    bool hasEnteredStaff = false;

    for (final provider in staffReportProviders) {
      final staff = staffByProviderId[provider['id']?.toString()];
      final count = staffTotalPaxForPdf(staff);
      final service =
          provider['service']?.toString().trim().toLowerCase() ?? '';
      final String? category =
          service == 'landscaping' || service == 'landscape'
          ? 'Landscaping'
          : service == 'cleaning'
          ? 'Cleaning'
          : service == 'security'
          ? 'Security'
          : null;
      if (category == null || count == null) continue;

      hasEnteredStaff = true;
      staffCountsByService[category] =
          staffCountsByService[category]! + count.toDouble();
    }

    final staffPie =
        staffCountsByService.entries
            .where((entry) => entry.value > 0)
            .map((entry) => MapEntry(entry.key, entry.value))
            .toList()
          ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    final landscapingStaff = staffCountsByService['Landscaping']!.toInt();
    final cleaningStaff = staffCountsByService['Cleaning']!.toInt();
    final securityStaff = staffCountsByService['Security']!.toInt();
    final staffTotal = landscapingStaff + cleaningStaff + securityStaff;

    const staffPalette = <String, PdfColor>{
      'Cleaning': _blue,
      'Landscaping': _red,
      'Security': _lightGreen,
    };

    final staffColors = <PdfColor>[
      for (final entry in staffPie)
        staffPalette[entry.key] ?? PdfColors.grey500,
    ];

    final staffTotalLabel = failedTables.contains('staff')
        ? 'Unavailable'
        : hasEnteredStaff
        ? staffTotal.toString()
        : 'Not entered';

    return [
      pdfBanner('4. Dashboard for The Month'),
pdfSub('Status of maintenance / upgrading work (cumulative: $cumulativePeriod)'),      pw.Center(
        child: pdfPie(
          [
            MapEntry('Completed', done.toDouble()),
            MapEntry('In progress', inProgress.toDouble()),
            MapEntry('Pending', pending.toDouble()),
            MapEntry('Cancelled / On Hold', cancelledOnHold.toDouble()),
          ],
          [_blue, _red, _lightGreen, PdfColors.grey500],
        ),
      ),
      pw.SizedBox(height: 6),
      pdfTable(
        ['Status', 'No.'],
        [
          ['Completed', '$done'],
          ['In progress', '$inProgress'],
          ['Pending', '$pending'],
          ['Cancelled / On Hold', '$cancelledOnHold'],
        ],
        widths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
        fontSize: 9,
      ),
      pdfSub(
        'Frequency of Lift Breakdown as at ${DateFormat('MMMM yyyy').format(reportMonth)}',
      ),

      pdfBarChart(
        labels: yearMonthLabels.take(reportMonth.month).toList(),
        series: [liftByMonth.take(reportMonth.month).toList()],
        colors: [_blue],
        height: 110,
        yAxisStep: 2,
        yAxisMax: 8,
      ),
      pdfSub(
        'Breakdown reported based on lift as at ${DateFormat('MMMM yyyy').format(reportMonth)}',
      ),
      liftKeys.isEmpty
          ? pw.Text(
              'No lift incidents recorded.',
              style: const pw.TextStyle(fontSize: 8),
            )
          : pdfBarChart(
              labels: liftKeys,
              series: [
                [for (final k in liftKeys) liftByLift[k]!.toDouble()],
              ],
              colors: [_blue],
              height: 110,
              yAxisStep: 2,
              yAxisMax: 8,
            ),
      pw.NewPage(),
      pdfSub('Summary of complaint for $monthLabel'),
      pw.Center(
        child: pdfPie(
          [
            MapEntry('Completed', cDone.toDouble()),
            MapEntry('In progress', cInProgress.toDouble()),
            MapEntry('KIV', cKiv.toDouble()),
          ],
          [_blue, _red, _lightGreen],
        ),
      ),
      pw.SizedBox(height: 6),
      pdfTable(
        ['Status', 'No.'],
        [
          ['Completed', '$cDone'],
          ['In progress', '$cInProgress'],
          ['KIV (Pending / On Hold)', '$cKiv'],
        ],
        widths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
        fontSize: 9,
      ),
      pdfSub(
        'Occupancy Status as at ${dateLabel(monthEnd)}: '
        '${totalUnits > 0 ? '${occupancyRate.toStringAsFixed(1)}%' : 'N/A'}',
      ),
      pdfTable(
        ['', 'Owner-occupied', 'Tenanted', 'Vacant', 'Commercial', 'TOTAL'],
        [
          [
            'No.',
            '$totalOwnerOccupiedUnits',
            '$totalTenantOccupiedUnits',
            '$totalVacantUnits',
            '$totalCommercialUnits',
            totalUnits > 0 ? '$accountedUnits' : '-',
          ],
          [
            'Percentage',
            pct(totalOwnerOccupiedUnits),
            pct(totalTenantOccupiedUnits),
            pct(totalVacantUnits),
            pct(totalCommercialUnits),
            pct(accountedUnits),
          ],
        ],
        fontSize: 9,
      ),

      // Two occupancy pie charts
      pw.SizedBox(height: 16),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
        children: [
          pw.Column(
            children: [
              pw.Text(
                'No. of Units',
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 10),
              pdfPie(occupancyCounts, occupancyColors, width: 285, height: 220),
            ],
          ),
          pw.Column(
            children: [
              pw.Text(
                'Percentage (%)',
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 10),
              pdfPie(
                occupancyPercentages,
                occupancyColors,
                width: 285,
                height: 220,
                showPercentages: true,
              ),
            ],
          ),
        ],
      ),

      // Staff Management
      pw.NewPage(),
      pw.SizedBox(height: 12),
      pdfSub('Staff Management - Total Staff: $staffTotalLabel'),
      pw.SizedBox(height: 8),

      if (staffPie.isEmpty)
        pdfNote(
          failedTables.contains('staff')
              ? 'Unable to load staff figures for this report.'
              : hasEnteredStaff
              ? 'No staff counts recorded for this report month.'
              : 'No staff figures entered for this report month.',
        )
      else ...[
        pw.Center(
          child: pdfPie(
            staffPie,
            staffColors,
            width: 245,
            height: 195,
            showLabels: true,
          ),
        ),
      ],
      pw.SizedBox(height: 10),
      pdfTable(
        [
          'No.',
          'Category',
          'Company / PIC',
          'Day Shift',
          'Night Shift',
          'Total Pax',
          'Frequency',
        ],
        staffReportProviders.isEmpty
            ? [
                ['-', 'No records', '-', '-', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < staffReportProviders.length; i++)
                  [
                    '${i + 1}',
                    textValue(staffReportProviders[i]['service']),
                    textValue(staffReportProviders[i]['company_pic']),
                    staffShiftForPdf(
                      staffByProviderId[staffReportProviders[i]['id']
                          ?.toString()],
                      'day_shift_timing',
                      'day_shift_staff',
                    ),
                    staffShiftForPdf(
                      staffByProviderId[staffReportProviders[i]['id']
                          ?.toString()],
                      'night_shift_timing',
                      'night_shift_staff',
                    ),
                    staffTotalPaxForPdf(
                          staffByProviderId[staffReportProviders[i]['id']
                              ?.toString()],
                        )?.toString() ??
                        '-',
                    textValue(
                      staffByProviderId[staffReportProviders[i]['id']
                          ?.toString()]?['frequency'],
                    ),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(24),
          1: pw.FlexColumnWidth(1.2),
          2: pw.FlexColumnWidth(2.2),
          3: pw.FlexColumnWidth(1.3),
          4: pw.FlexColumnWidth(1.3),
          5: pw.FlexColumnWidth(0.8),
          6: pw.FlexColumnWidth(1.0),
        },
        fontSize: 7.2,
      ),
    ];
  }

  // Year-to-date billing rows (Jan-Dec of the report year).
  List<List<String>> ytdBillingRows() {
    final rows = <List<String>>[];
    double sc = 0, sf = 0, other = 0;

    for (var m = 1; m <= reportMonth.month; m++) {
      final b = ytdBillingByMonth[m];

      if (b == null) {
        rows.add([monthShort(m), '', '', '', '']);
        continue;
      }

      final a = number(b['billing_service_charge']);
      final f = number(b['billing_sinking_fund']);
      final o = number(b['billing_other']);
      sc += a;
      sf += f;
      other += o;

      rows.add([monthShort(m), amt(a), amt(f), amt(o), amt(a + f + o)]);
    }

    rows.add([
      'Total (RM)',
      amt(sc),
      amt(sf),
      amt(other),
      amt(sc + sf + other),
    ]);
    return rows;
  }

  List<List<String>> ytdCollectionRows() {
    final rows = <List<String>>[];
    double sc = 0, sf = 0, other = 0, credit = 0, billed = 0;

    for (var m = 1; m <= reportMonth.month; m++) {
      final b = ytdBillingByMonth[m];

      if (b == null) {
        rows.add([monthShort(m), '', '', '', '', '', '']);
        continue;
      }

      final a = number(b['collection_service_charge']);
      final f = number(b['collection_sinking_fund']);
      final o = number(b['collection_other']);
      final c = number(b['collection_open_credit']);
      final bill =
          number(b['billing_service_charge']) +
          number(b['billing_sinking_fund']) +
          number(b['billing_other']);
      final total = a + f + o + c;

      sc += a;
      sf += f;
      other += o;
      credit += c;
      billed += bill;

      rows.add([
        monthShort(m),
        amt(a),
        amt(f),
        amt(o),
        amt(c),
        amt(total),
        bill == 0 ? '-' : (total / bill * 100).toStringAsFixed(2),
      ]);
    }

    final grand = sc + sf + other + credit;

    rows.add([
      'Total (RM)',
      amt(sc),
      amt(sf),
      amt(other),
      amt(credit),
      amt(grand),
      billed == 0 ? '-' : (grand / billed * 100).toStringAsFixed(2),
    ]);

    return rows;
  }

  List<List<String>> ytdUtilityRows({required String valueField}) {
    final rows = <List<String>>[];
    final isWater = valueField == 'water_m3';

    for (var m = 1; m <= reportMonth.month; m++) {
      final u = ytdUtilitiesByMonth[m];

      if (u == null) {
        rows.add(['$m', monthShort(m), '', '', '', '', '']);
        continue;
      }

      final consumption = hasValue(u[valueField])
          ? number(u[valueField])
          : null;

      if (!isWater) {
        // Electricity: days in the reporting calendar month.
        final days = DateUtils.getDaysInMonth(reportMonth.year, m);

        rows.add([
          '$m',
          monthShort(m),
          consumption == null ? '-' : qty(consumption),
          '$days',
          consumption == null ? '-' : (consumption / days).toStringAsFixed(2),
          hasValue(u['electricity_bill_rm'])
              ? amt(u['electricity_bill_rm'])
              : '-',
          hasValue(u['electricity_total_bill_rm'])
              ? amt(u['electricity_total_bill_rm'])
              : '-',
        ]);
      } else {
        // Water: days calculated from the saved billing dates.
        final start = parseDate(u['water_period_start']);
        final end = parseDate(u['water_period_end']);

        int? days;

        if (start != null && end != null) {
          final startUtc = DateTime.utc(start.year, start.month, start.day);

          final endUtc = DateTime.utc(end.year, end.month, end.day);

          final calculatedDays = endUtc.difference(startUtc).inDays;

          if (calculatedDays > 0) {
            days = calculatedDays;
          }
        }

        rows.add([
          '$m',
          monthShort(m),
          consumption == null ? '-' : qty(consumption),
          start != null && end != null && days != null
              ? '${dateLabel(start)} - ${dateLabel(end)}'
              : '-',
          days?.toString() ?? '-',
          consumption == null || days == null
              ? '-'
              : (consumption / days).toStringAsFixed(2),
          hasValue(u['water_bill_rm']) ? amt(u['water_bill_rm']) : '-',
        ]);
      }
    }

    return rows;
  }

  List<double> ytdUtilitySeries({required String valueField}) {
    return [
      for (var m = 1; m <= reportMonth.month; m++)
        number(ytdUtilitiesByMonth[m]?[valueField]),
    ];
  }

  // Section 5.2: the Defaulters comparison follows Total Collection.
  pw.Widget pdfDefaultersTable() {
    final dates = defaulterPdfBalanceDates;
    final dateKeys = [
      for (final date in dates) DateFormat('yyyy-MM-dd').format(date),
    ];
    final compact = dates.length > 6;

    pw.Widget cell(
      String text, {
      bool header = false,
      bool total = false,
      bool amount = false,
    }) {
      return pw.Container(
        padding: pw.EdgeInsets.symmetric(
          vertical: 4,
          horizontal: compact ? 2 : 4,
        ),
        alignment: header
            ? pw.Alignment.center
            : amount
                ? pw.Alignment.centerRight
                : pw.Alignment.centerLeft,
        child: pw.Text(
          pdfSafe(text),
          textAlign: header
              ? pw.TextAlign.center
              : amount
                  ? pw.TextAlign.right
                  : pw.TextAlign.left,
          style: pw.TextStyle(
            fontSize: compact ? (header ? 6.1 : 6.0) : (header ? 7.3 : 7.2),
            fontWeight: header || total
                ? pw.FontWeight.bold
                : pw.FontWeight.normal,
          ),
        ),
      );
    }

    final rows = <pw.TableRow>[
      pw.TableRow(
        repeat: true,
        decoration: const pw.BoxDecoration(color: _green),
        children: [
          cell('No.', header: true),
          cell('Unit No.', header: true),
          cell('Name', header: true),
          for (final date in dates)
            cell('Total Due\n${dateLabel(date)}', header: true, amount: true),
          cell('Action Taken', header: true),
        ],
      ),
    ];

    if (defaulterPdfRows.isEmpty) {
      rows.add(pw.TableRow(children: [
        cell('-'),
        cell('-'),
        cell('No defaulters recorded'),
        for (var i = 0; i < dates.length; i++) cell('-', amount: true),
        cell('-'),
      ]));
    } else {
      for (var i = 0; i < defaulterPdfRows.length; i++) {
        final row = defaulterPdfRows[i];
        final balances = row['balances_by_date'] as Map<String, double?>;
        rows.add(pw.TableRow(children: [
          cell('${i + 1}'),
          cell(textValue(row['unit_no'])),
          cell(textValue(row['name'])),
          for (final key in dateKeys)
            cell(balances[key] == null ? '-' : amt(balances[key]), amount: true),
          cell(defaulterActionLabel(row['action_taken'])),
        ]));
      }
    }

    rows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: _orange),
      children: [
        cell('', total: true),
        cell('', total: true),
        cell('Total (RM)', total: true),
        for (final key in dateKeys)
          cell(
            amt(defaulterPdfRows.fold<double>(
              0,
              (sum, row) => sum +
                  number((row['balances_by_date'] as Map<String, double?>)[key]),
            )),
            total: true,
            amount: true,
          ),
        cell('', total: true),
      ],
    ));

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
      columnWidths: {
        0: const pw.FixedColumnWidth(26),
        1: const pw.FixedColumnWidth(48),
        2: const pw.FlexColumnWidth(2.4),
        for (var i = 0; i < dates.length; i++)
          i + 3: const pw.FlexColumnWidth(1.25),
        dates.length + 3: const pw.FlexColumnWidth(2.4),
      },
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: rows,
    );
  }

  List<pw.Widget> pdfFinance() {
    final billingSeries = <double>[];
    final collectionSeries = <double>[];

    for (var m = 1; m <= reportMonth.month; m++) {
      final b = ytdBillingByMonth[m];
      billingSeries.add(
        number(b?['billing_service_charge']) +
            number(b?['billing_sinking_fund']) +
            number(b?['billing_other']),
      );
      collectionSeries.add(
        number(b?['collection_service_charge']) +
            number(b?['collection_sinking_fund']) +
            number(b?['collection_other']) +
            number(b?['collection_open_credit']),
      );
    }

    final monthlyTransfers =
        ytdTransfers.where((row) {
          final date = calendarDate(row['transfer_date']);

          return date != null &&
              date.year == reportMonth.year &&
              !date.isAfter(monthEnd);
        }).toList()..sort((a, b) {
          final dateA = calendarDate(a['transfer_date'])!;
          final dateB = calendarDate(b['transfer_date'])!;
          return dateA.compareTo(dateB);
        });

    final transferTotal = monthlyTransfers.fold<double>(
      0,
      (total, row) => total + number(row['amount']),
    );

    final transferTableRows = <List<String>>[];
    final missingTransferRows = <int>{};

    var transferNo = 0;

    for (var m = 1; m <= reportMonth.month; m++) {
      final monthLabel = DateFormat(
        'MMMM yyyy',
      ).format(DateTime(reportMonth.year, m));

      final monthTransfers = monthlyTransfers.where((row) {
        final date = calendarDate(row['transfer_date']);

        return date != null && date.year == reportMonth.year && date.month == m;
      }).toList();

      monthTransfers.sort((a, b) {
        final dateA = calendarDate(a['transfer_date'])!;
        final dateB = calendarDate(b['transfer_date'])!;
        return dateA.compareTo(dateB);
      });

      if (monthTransfers.isEmpty) {
        missingTransferRows.add(transferTableRows.length);

        transferTableRows.add(['-', monthLabel, 'No transfer recorded', '-']);
      } else {
        for (final row in monthTransfers) {
          transferNo++;

          transferTableRows.add([
            '$transferNo',
            monthLabel,
            dateLabel(row['transfer_date']),
            amt(row['amount']),
          ]);
        }
      }
    }

    transferTableRows.add(['', 'Total Amount (RM)', '', amt(transferTotal)]);

    final expenditureStatusCounts = <String, int>{
      'Completed (work/ delivery)': 0,
      'In progress': 0,
      'Pending (work/ delivery)': 0,
      'Cancelled': 0,
    };
    for (final row in yearExpenditures) {
      final bucket = expenditureBucket(row['status']);
      expenditureStatusCounts[bucket] =
          (expenditureStatusCounts[bucket] ?? 0) + 1;
    }

    final Map<int, pw.TableColumnWidth> electricityWidths = const {
      0: pw.FixedColumnWidth(23),
      1: pw.FlexColumnWidth(1),
      2: pw.FlexColumnWidth(1.15),
      3: pw.FlexColumnWidth(0.85),
      4: pw.FlexColumnWidth(1.4),
      5: pw.FlexColumnWidth(1.3),
      6: pw.FlexColumnWidth(2.8),
    };

    final Map<int, pw.TableColumnWidth> waterWidths = const {
      0: pw.FixedColumnWidth(23),
      1: pw.FlexColumnWidth(1),
      2: pw.FlexColumnWidth(1.15),
      3: pw.FlexColumnWidth(2),
      4: pw.FlexColumnWidth(0.75),
      5: pw.FlexColumnWidth(1.45),
      6: pw.FlexColumnWidth(1.3),
    };

    final fdRows = reportFixedDeposits;

    return [
      pdfBanner('5. Financial Position'),

      // 5.1
      pdfBar('5.1 Billing VS Collection'),
      pdfBarChart(
        labels: yearMonthLabels.take(reportMonth.month).toList(),
        series: [billingSeries, collectionSeries],
        colors: [_blue, _red],
        legends: ['Total Billing (RM)', 'Total Collection (RM)'],
        height: 120,
        showValues: false,
        yAxisStep: 50000,
        yAxisMax: 300000,
        moneyYAxis: true,
      ),

      // 5.2
      pdfBar('5.2 Collection and Arrears Report'),
      pdfSub('Total Billing'),
      pdfTable(
        [
          'Month',
          'Service Charge (RM)',
          'Sinking Fund (RM)',
          'Other [LPI, Utilities, other income] (RM)',
          'Total Billing (RM)',
        ],
        ytdBillingRows(),
        highlightLast: true,
        rightAlign: const {1, 2, 3, 4},
      ),
      pdfSub('Total Collection'),
      pdfTable(
        [
          'Month',
          'Service Charge (RM)',
          'Sinking Fund (RM)',
          'Other [LPI, Utilities, other income] (RM)',
          'Open Credit (RM)',
          'Total Collection (RM)',
          '% of total collection',
        ],
        ytdCollectionRows(),
        highlightLast: true,
        rightAlign: const {1, 2, 3, 4, 5, 6},
        fontSize: 7.5,
      ),
      pdfSub('Defaulters'),
      if (defaulterPdfError != null)
        pdfNote(defaulterPdfError!)
      else
        pdfDefaultersTable(),
      pdfSub('Arrears Reconciliation - $monthLabel'),
      pdfTable(
        ['Item', 'Amount (RM)'],
        [
          ['Opening Arrears', amt(openingArrears)],
          ['Total Billing', amt(arrearsBilled)],
          ['Total Collection', amt(arrearsCollected)],
          ['Adjustments', amt(arrears?['adjustments'])],
          ['Closing Arrears', amt(closingArrears)],
        ],
        highlightLast: true,
        rightAlign: const {1},
        widths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1)},
      ),

      // 5.3 Sinking Fund Transfer
      pdfBar('5.3 Sinking Fund Transfer'),
      pdfTable(
        ['No', 'Month', 'Date of Transfer', 'Amount (RM)'],
        transferTableRows,
        highlightLast: true,
        redRows: missingTransferRows,
        rightAlign: const {3},
        widths: const {
          0: pw.FixedColumnWidth(30),
          1: pw.FlexColumnWidth(1.4),
          2: pw.FlexColumnWidth(2),
          3: pw.FlexColumnWidth(1.4),
        },
      ),

      // 5.4
      pdfBar('5.4 Summary of Fixed Deposit Placement'),
      pdfTable(
        [
          'No',
          'Bank',
          'FD Cert',
          'Placement Date',
          'Rate %',
          'Maturity Date',
          'Amount (RM)',
        ],
        fdCutoff == null
            ? [
                [
                  '-',
                  'Fixed deposit list unavailable: report month is missing '
                      'or invalid',
                  '-',
                  '-',
                  '-',
                  '-',
                  '-',
                ],
              ]
            : fdRows.isEmpty
            ? [
                ['-', 'No deposits recorded', '-', '-', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < fdRows.length; i++)
                  [
                    '${i + 1}',
                    textValue(fdRows[i]['bank_name']),
                    textValue(fdRows[i]['cert']),
                    dateLabel(fdRows[i]['placement_date']),
                    textValue(fdRows[i]['interest_rate']),
                    dateLabel(fdRows[i]['maturity_date']),
                    amt(fdRows[i]['deposit_amount']),
                  ],
              ],
        rightAlign: const {6},
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(1.6),
          2: pw.FlexColumnWidth(1.6),
          3: pw.FlexColumnWidth(1.4),
          4: pw.FlexColumnWidth(0.8),
          5: pw.FlexColumnWidth(1.4),
          6: pw.FlexColumnWidth(1.5),
        },
      ),
      pw.SizedBox(height: 6),
      pdfTable(
        ['Portfolio Metric', 'Amount (RM)'],
        fdCutoff == null
            ? [
                [
                  'Fixed deposit classification unavailable: '
                      'report month is missing or invalid',
                  '-',
                ],
              ]
            : [
                ['Total Portfolio Principal', amt(totalFixedDeposits)],
                ['Active Principal at Month-End', amt(activeFixedDeposits)],
                ['Matured Principal at Month-End', amt(maturedFixedDeposits)],
                ['Not Yet Placed Principal', amt(notYetPlacedPrincipal)],
                [
                  'Maturing Within 30 Days After Month-End',
                  amt(maturingWithin30Days),
                ],
                if (unclassifiedFixedDepositCount > 0)
                  [
                    'Unclassified (Missing/Invalid Dates)',
                    amt(unclassifiedFixedDeposits),
                  ],
              ],
        rightAlign: const {1},
        widths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1)},
      ),

      // 5.5
      pdfBar('5.5 Approved Expenditure Summary'),
      pdfTable(
        ['Date', 'AR No', 'Company Name', 'Details', 'Amount (RM)', 'Status'],
        yearExpenditures.isEmpty
            ? [
                ['-', '-', 'No records', '-', '-', '-'],
              ]
            : [
                for (final row in yearExpenditures)
                  [
                    dateLabel(row['approval_date']),
                    textValue(row['ar_number']),
                    textValue(row['expenditure_name']),
                    textValue(row['description'] ?? row['category']),
                    amt(row['approved_amount']),
                    textValue(row['status']),
                  ],
              ],
        rightAlign: const {4},
        fontSize: 7.5,
        widths: const {
          0: pw.FlexColumnWidth(1),
          1: pw.FlexColumnWidth(1.4),
          2: pw.FlexColumnWidth(1.5),
          3: pw.FlexColumnWidth(2.6),
          4: pw.FlexColumnWidth(1),
          5: pw.FlexColumnWidth(1),
        },
      ),
      pw.SizedBox(height: 6),

      pdfTable(
        ['Status', 'No.'],
        [
          for (final entry in expenditureStatusCounts.entries)
            if (entry.value > 0) [entry.key, '${entry.value}'],

          if (expenditureStatusCounts.values.every((count) => count == 0))
            ['No records', '0'],
        ],
        widths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1)},
      ),

      pw.SizedBox(height: 3),
      pw.Text(
        'Total Active Approved Amount as at $monthLabel (RM): ${amt(activeExpenditureTotal)}   |   '
        'Register cutoff: ${dateLabel(monthEnd)}',
        style: const pw.TextStyle(fontSize: 8),
      ),

      // 5.6
      pw.NewPage(),
      pdfBar('5.6 Electricity Consumption Analysis'),
      pdfSub('Landlord Meter'),
      pdfTable(
        [
          'No',
          'Month',
          'Total (kWh)',
          'Total Days',
          'Total Usage per Day (kWh)',
          'Total Bill (RM)',
          'Total Bill Including Maximum Demand, ICPT '
              '& Renewable Energy Fund (RM)',
        ],
        ytdUtilityRows(valueField: 'electricity_kwh'),
        rightAlign: const {2, 3, 4, 5, 6},
        widths: electricityWidths,
        fontSize: 6.8,
      ),
      pw.SizedBox(height: 6),

      pdfBarChart(
        labels: yearMonthLabels.take(reportMonth.month).toList(),
        series: [ytdUtilitySeries(valueField: 'electricity_kwh')],
        colors: [_red],
        legends: ['Total kWh'],
        height: 130,
        showValues: true,
        yAxisTitle: 'Total kWh',
        yAxisStep: 10000,
      ),

      // 5.7
      pdfBar('5.7 Water Consumption Analysis'),
      pdfTable(
        [
          'No',
          'Month',
          'Total (m³)',
          'Duration',
          'Total Days',
          'Total Usage per Day (m³)',
          'Total Bill (RM)',
        ],
        ytdUtilityRows(valueField: 'water_m3'),
        rightAlign: const {2, 4, 5, 6},
        widths: waterWidths,
        fontSize: 6.8,
      ),

      pw.SizedBox(height: 6),
      pdfBarChart(
        labels: yearMonthLabels.take(reportMonth.month).toList(),
        series: [ytdUtilitySeries(valueField: 'water_m3')],
        colors: [_red],
        legends: ['Total m³'],
        height: 130,
        showValues: true,
        yAxisTitle: 'Total m³',
        yAxisStep: 500,
      ),
      pdfNote(
        'Note: TNB reported that the PT fuse is faulty. It may be the '
        'reason why they are unable to obtain an accurate meter reading.'
        'Management is currently awaiting for a quotation from the '
        'contractor for the replacement of the faulty fuse.',
      ),
    ];
  }

  // Display two independently selected statuses in the original PDF column.
  String agmStatusForPdf(Map<String, dynamic> row) {
    const ordering = [
      'Approved',
      'Completed',
      'In Progress',
      'Pending',
      'Cancelled',
    ];
    final first = row['status']?.toString();
    final second = row['secondary_status']?.toString();
    final selected = [
      for (final value in ordering)
        if (value == first || value == second) value,
    ];
    if (selected.isEmpty) return textValue(first);
    if (selected.length == 1) return selected.first;
    return '${selected.first} and ${selected[1].toLowerCase()}';
  }

  List<pw.Widget> pdfAgm() {
    // Preserve the previously requested merged No / AGM / EGM columns.
    final groups = <String, List<Map<String, dynamic>>>{};

    for (final row in resolutions) {
      final key =
          '${textValue(row['meeting'])}|${dateLabel(row['meeting_date'])}';
      groups.putIfAbsent(key, () => []).add(row);
    }

    pw.Widget cell(String value, {bool header = false}) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        alignment: header ? pw.Alignment.center : pw.Alignment.topLeft,
        child: pw.Text(
          pdfSafe(value),
          textAlign: header ? pw.TextAlign.center : pw.TextAlign.left,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );
    }

    final groupedEntries = groups.entries.toList();
    return [
      pdfBanner('6. AGM / EGM Resolution'),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
        columnWidths: const {
          0: pw.FixedColumnWidth(28),
          1: pw.FlexColumnWidth(1.4),
          2: pw.FlexColumnWidth(3),
          3: pw.FlexColumnWidth(1.2),
        },
        children: [
          pw.TableRow(
            repeat: true,
            decoration: const pw.BoxDecoration(color: _green),
            children: [
              cell('No', header: true),
              cell('AGM / EGM', header: true),
              cell('Resolution', header: true),
              cell('Status', header: true),
            ],
          ),
          if (groupedEntries.isEmpty)
            pw.TableRow(
              children: [
                cell('-'),
                cell('No records'),
                cell('-'),
                cell('-'),
              ],
            ),
          for (var i = 0; i < groupedEntries.length; i++)
            pw.TableRow(
              verticalAlignment: pw.TableCellVerticalAlignment.top,
              children: [
                cell('${i + 1}'),
                cell(
                  '${textValue(groupedEntries[i].value.first['meeting'])}\n'
                  '${dateLabel(groupedEntries[i].value.first['meeting_date'])}',
                ),
                cell(groupedEntries[i].value
                    .map((row) => textValue(row['resolution']))
                    .join('\n')),
                cell(groupedEntries[i].value
                    .map(agmStatusForPdf)
                    .join('\n')),
              ],
            ),
        ],
      ),
    ];
  }

  String complaintDeadlineForPdf(Map<String, dynamic> row) {
    if (row['deadline_is_asap'] == true) {
      return 'ASAP';
    }

    final date = calendarDate(row['deadline']);
    return date == null ? '-' : dateLabel(date);
  }

  String complaintAgeing(Map<String, dynamic> row) {
    final status = textValue(row['status']).toLowerCase();
    final date = parseDate(row['entry_date']);

    if (date == null) return '-';
    if (status == 'completed' || status == 'cancelled') return '0';

    final days = monthEnd
        .difference(DateTime(date.year, date.month, date.day))
        .inDays;

    return days < 0 ? '0' : '$days';
  }

  bool isMantrap(Map<String, dynamic> row) => row['mantrap'] == true;

  // The first lift table uses the existing numeric Turnaround (Hours) and
  // Description, combined into the reference's Turnaround time column.
  String mantrapTurnaroundText(Map<String, dynamic> row) {
    final rawHours = row['turnaround_hours'];
    final hours = double.tryParse(rawHours?.toString() ?? '');
    final description = row['description']?.toString().trim() ?? '';

    String timing = '';
    if (hours != null) {
      if (hours == 0) {
        timing = 'Immediately';
      } else {
        final formatted = qty(hours);
        timing = '$formatted ${hours == 1 ? 'hour' : 'hours'}';
      }
    }

    if (timing.isEmpty) return description.isEmpty ? '-' : description;
    return description.isEmpty ? timing : '$timing\n$description';
  }

  String mantrapLabel(dynamic value) {
    if (value == true) return 'Yes';
    if (value == false) return 'No';
    return '-'; // Older incidents may not have been classified yet.
  }

  List<pw.Widget> pdfOperations() {
    final pendingWorks = pendingMaintenanceWorks;

    return [
      pdfBanner('7. Property Management and Building Operations'),

      // 7.1
      pdfBar('7.1 Weekly Maintenance Progress'),
      pdfTable(
        ['From weekly report', 'Completion by', 'Challenges', 'Action'],
        pendingWorks.isEmpty
            ? [
                ['No records', '-', '-', '-'],
              ]
            : [
                for (final row in pendingWorks)
                  [
                    textValue(row['work_activity']),
                    row['status'] == 'Completed'
                        ? 'Work completed'
                        : dateLabel(row['deadline']),
                    textValue(row['challenge']),
                    textValue(row['action_taken']),
                  ],
              ],
        widths: const {
          0: pw.FlexColumnWidth(1.6),
          1: pw.FlexColumnWidth(1),
          2: pw.FlexColumnWidth(2),
          3: pw.FlexColumnWidth(1.4),
        },
      ),

      // 7.2
      pdfBar('7.2 Complaints and Resolution'),
      pdfTable(
        [
          'No',
          'Date',
          'Unit No. & Name (Contact)',
          'Description & Location',
          'Action Taken',
          'Deadline',
          'Ageing',
        ],
        complaints.isEmpty
            ? [
                ['-', '-', 'No records', '-', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < complaints.length; i++)
                  [
                    '${i + 1}',
                    dateLabel(complaints[i]['entry_date']),
                    textValue(complaints[i]['unit_complainant']),
                    textValue(complaints[i]['description_location']),
                    textValue(complaints[i]['action_taken']),
                    complaintDeadlineForPdf(complaints[i]),
                    complaintAgeing(complaints[i]),
                  ],
              ],
        fontSize: 7.5,
        widths: const {
          0: pw.FixedColumnWidth(22),
          1: pw.FlexColumnWidth(1),
          2: pw.FlexColumnWidth(1.2),
          3: pw.FlexColumnWidth(1.8),
          4: pw.FlexColumnWidth(2),
          5: pw.FlexColumnWidth(1),
          6: pw.FixedColumnWidth(34),
        },
      ),

      // 7.3 - Cumulative Mantrap and lift summaries.
      pdfBar('7.3 Lift Summary'),
      pdfSub('Breakdown of Mantrap'),
      pdfTable(
        ['No.', 'Date', 'Lift', 'Turnaround time'],
        mantrapHistory.isEmpty
            ? [
                ['-', '-', '-', 'No records'],
              ]
            : [
                for (var i = 0; i < mantrapHistory.length; i++)
                  [
                    '${i + 1}',
                    calendarDate(mantrapHistory[i]['incident_date']) == null
                        ? '-'
                        : DateFormat('d MMMM yyyy').format(
                            calendarDate(mantrapHistory[i]['incident_date'])!,
                          ),
                    textValue(mantrapHistory[i]['lift_no']),
                    mantrapTurnaroundText(mantrapHistory[i]),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(1.5),
          2: pw.FixedColumnWidth(48),
          3: pw.FlexColumnWidth(4.2),
        },
        fontSize: 7.5,
      ),
      pw.SizedBox(height: 12),
      pdfSub('Breakdown According to Lifts - as at $monthLabel'),
      pdfTable(
        ['No.', 'Date', 'Tower', 'Lift No.', 'Mantrap', 'Status'],
        monthlyLiftSummary.isEmpty
            ? [
                ['-', '-', '-', '-', '-', 'No records'],
              ]
            : [
                for (var i = 0; i < monthlyLiftSummary.length; i++)
                  [
                    '${i + 1}',
                    dateLabel(monthlyLiftSummary[i]['incident_date']),
                    textValue(monthlyLiftSummary[i]['tower']),
                    textValue(monthlyLiftSummary[i]['lift_no']),
                    mantrapLabel(monthlyLiftSummary[i]['mantrap']),
                    textValue(monthlyLiftSummary[i]['status']),
                  ],
                [
                  '',
                  '',
                  '',
                  '',
                  'Total incidents',
                  '${monthlyLiftSummary.length}',
                ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(1.2),
          2: pw.FlexColumnWidth(1.3),
          3: pw.FlexColumnWidth(1),
          4: pw.FlexColumnWidth(1),
          5: pw.FlexColumnWidth(1.3),
        },
        fontSize: 7.5,
        highlightLast: monthlyLiftSummary.isNotEmpty,
      ),

      // 7.4
      pdfBar('7.4 Occupancy Overview'),
      pdfSub('Status of Occupancy as of ${dateLabel(monthEnd)}'),
      pdfTable(
        ['', 'Vacant', 'Owners', 'Tenants', 'Commercial', 'Occupancy Rate'],
        [
          [
            'Total',
            '$totalVacantUnits',
            '$totalOwnerOccupiedUnits',
            '$totalTenantOccupiedUnits',
            '$totalCommercialUnits',
            propertyTotalUnits != null && propertyTotalUnits! > 0
                ? '${occupancyRate.toStringAsFixed(1)}%'
                : 'Not available',
          ],
        ],
        fontSize: 9,
      ),
      pdfSub('Occupancy by Tower / Component'),
      pdfTable(
        ['Tower / Component', 'Vacant', 'Owner-Occupied', 'Tenant-Occupied', 'Commercial'],
        occupancyRecords.isEmpty
            ? [
                ['No occupancy records', '-', '-', '-', '-'],
              ]
            : [
                for (final row in occupancyRecords)
                  [
                    textValue(row['tower_component']),
                    number(row['vacant']).toInt().toString(),
                    number(row['owner_occupied']).toInt().toString(),
                    number(row['tenant_occupied']).toInt().toString(),
                    number(row['commercial_units']).toInt().toString(),
                  ],
              ],
      ),

      pdfSub('Unit Movement as of ${dateLabel(monthEnd)}'),
      pdfTable(
        ['No', 'Unit', 'Moving In / Out', 'Date', 'Remarks'],
        unitMovements.isEmpty
            ? [
                ['-', 'No records', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < unitMovements.length; i++)
                  [
                    textValue(i + 1),
                    textValue(unitMovements[i]['unit']),
                    textValue(
                      unitMovements[i]['movement'],
                    ).replaceAll('Move ', ''),
                    dateLabel(unitMovements[i]['movement_date']),
                    textValue(unitMovements[i]['remarks']),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(28),
          1: pw.FlexColumnWidth(1),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(1.2),
          4: pw.FlexColumnWidth(2),
        },
      ),

      // Sub-Sales Units
      pdfSub(
        'Sub-Sales Unit as at ${DateFormat('d MMMM yyyy').format(monthEnd)}',
      ),
      pdfTable(
        ['No', 'Unit', 'Sub-Sales', 'Date', 'Remark'],
        subSalesUnits.isEmpty
            ? [
                ['-', 'No records', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < subSalesUnits.length; i++)
                  [
                    '${i + 1}',
                    textValue(subSalesUnits[i]['unit']),
                    textValue(subSalesUnits[i]['status']),
                    calendarDate(subSalesUnits[i]['sale_month']) == null
                        ? '-'
                        : DateFormat('MMMM yyyy').format(
                            calendarDate(subSalesUnits[i]['sale_month'])!,
                          ),
                    textValue(subSalesUnits[i]['remarks']),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(28),
          1: pw.FlexColumnWidth(1.2),
          2: pw.FlexColumnWidth(1.4),
          3: pw.FlexColumnWidth(1.5),
          4: pw.FlexColumnWidth(2),
        },
        fontSize: 8,
      ),

      // 7.5
      pdfBar('7.5 Renovation Overview'),
      pdfSub('Status of Renovation as of ${dateLabel(monthEnd)}'),
      pdfTable(
        [
          'No.',
          'Unit No.',
          'Type of Renovation',
          'Duration of Renovation',
          'Deposit Amount (RM)',
          'Renovation Status',
          'Refund Status',
        ],
        renovationWorks.isEmpty
            ? [
                ['-', 'No records', '-', '-', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < renovationWorks.length; i++)
                  [
                    '${i + 1}',
                    textValue(renovationWorks[i]['unit']),
                    textValue(renovationWorks[i]['renovation_type']),
                    textValue(renovationWorks[i]['duration']),
                    amt(renovationWorks[i]['deposit_amount']),
                    textValue(renovationWorks[i]['renovation_status']),
                    textValue(renovationWorks[i]['refund_status']),
                  ],
              ],
        rightAlign: const {4},
        fontSize: 7.5,
      ),
    ];
  }

  List<pw.Widget> pdfServiceProviders() {
    pw.Widget plainCell(String value, {bool header = false}) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        alignment: header ? pw.Alignment.center : pw.Alignment.centerLeft,
        child: pw.Text(
          pdfSafe(value),
          textAlign: header ? pw.TextAlign.center : pw.TextAlign.left,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );
    }

    pw.Widget styledCell(List<pw.InlineSpan> spans) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        alignment: pw.Alignment.centerLeft,
        child: pw.RichText(
          text: pw.TextSpan(
            style: const pw.TextStyle(fontSize: 8),
            children: spans,
          ),
        ),
      );
    }

    final bodyRows = <pw.TableRow>[];
    for (var i = 0; i < serviceProviders.length; i++) {
      final provider = serviceProviders[i];
      final company = firstText(provider, ['company_pic']);
      final contact = firstText(provider, ['contact']);
      bodyRows.add(
        pw.TableRow(
          children: [
            plainCell('${i + 1}'),
            styledCell([
              pw.TextSpan(
                text: pdfSafe(firstText(provider, ['service'])),
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              if (company != '-')
                pw.TextSpan(text: '\nCompany / PIC: ${pdfSafe(company)}'),
              if (contact != '-')
                pw.TextSpan(text: '\nContact: ${pdfSafe(contact)}'),
            ]),
            plainCell(firstText(provider, ['schedule_staffing'])),
            styledCell([
              pw.TextSpan(
                text: 'Commencement Date:',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.TextSpan(
                text:
                    '\n${pdfSafe(firstDate(provider, ['_pdf_first_commencement', 'commencement_date']))}\n',
              ),
              pw.TextSpan(
                text: 'Next Renewal / Expiry Date:',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.TextSpan(
                text:
                    '\n${pdfSafe(dateLabel(providerExpiryForPdf(provider)))}\n',
              ),
              pw.TextSpan(
                text: 'Status:',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.TextSpan(text: ' ${pdfSafe(providerStatus(provider))}'),
            ]),
          ],
        ),
      );
    }

    return [
      pdfBanner('8. Service Provider and Contract Management'),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
        columnWidths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(2.4),
          2: pw.FlexColumnWidth(1.6),
          3: pw.FlexColumnWidth(1.6),
        },
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
        children: [
          pw.TableRow(
            repeat: true,
            decoration: const pw.BoxDecoration(color: _green),
            children: [
              plainCell('NO', header: true),
              plainCell('SERVICES', header: true),
              plainCell('SCHEDULE', header: true),
              plainCell('APPOINTMENT', header: true),
            ],
          ),
          if (bodyRows.isEmpty)
            pw.TableRow(
              children: [
                plainCell('-'),
                plainCell(emptyRegisterLabel('service_providers')),
                plainCell('-'),
                plainCell('-'),
              ],
            ),
          ...bodyRows,
        ],
      ),
    ];
  }

  List<pw.Widget> pdfLicensingInsurance() {
    return [
      pdfBanner('9. Licensing and Insurance Overview'),

      // 9.1
      pdfBar('9.1 Licences and Regulatory Compliance'),
      pdfTable(
        [
          'NO',
          'SERVICE RENDERED',
          'FROM',
          'TO',
          'RENEWAL FREQUENCY',
          'RENEWAL STATUS',
        ],
        licencesRegulatory.isEmpty
            ? [
                [
                  '-',
                  emptyRegisterLabel('licences_regulatory'),
                  '-',
                  '-',
                  '-',
                  '-',
                ],
              ]
            : [
                for (var i = 0; i < licencesRegulatory.length; i++)
                  [
                    '${i + 1}',
                    firstText(licencesRegulatory[i], [
                      'licence_name',
                      'license_name',
                      'name',
                    ]),
                    firstDate(licencesRegulatory[i], [
                      'issue_date',
                      'issued_date',
                    ]),
                    firstDate(licencesRegulatory[i], ['expiry_date']),
                    firstText(licencesRegulatory[i], ['renewal_frequency']),
                    licenceStatus(licencesRegulatory[i]) +
                        (firstDate(licencesRegulatory[i], [
                                  'replacement_date',
                                ]) ==
                                '-'
                            ? ''
                            : ' (replaced ${firstDate(licencesRegulatory[i], ['replacement_date'])})'),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(1),
          4: pw.FlexColumnWidth(1.3),
          5: pw.FlexColumnWidth(1.4),
        },
      ),

      // 9.2 - cumulative non-archived master register, including older records.
      // Ordered by Next Service Date, earliest first. Future service dates
      // never hide an otherwise eligible record.
      pdfBar('9.2 Compliance & Best Practices'),
      pdfTable(
        [
          'No',
          'Services',
          'Maintenance\nPeriod\n(Months)',
          'Status',
          'Next Service\nDate',
          'Justification*',
        ],
        compliancePractices.isEmpty
            ? [
                [
                  '-',
                  emptyRegisterLabel('compliance_best_practices'),
                  '-',
                  '-',
                  '-',
                  '-',
                ],
              ]
            : [
                for (var i = 0; i < compliancePractices.length; i++)
                  [
                    '${i + 1}',
                    firstText(compliancePractices[i], [
                      'name',
                      'item_practice',
                      'service',
                      'item',
                      'practice',
                    ]),
                    // Preserve what the user entered (e.g. 6, 12, Monthly).
                    firstText(compliancePractices[i], [
                      'review_frequency',
                      'maintenance_period',
                    ]),
                    complianceStatusForPdf(compliancePractices[i]),
                    complianceNextServiceDate(compliancePractices[i]),
                    firstText(compliancePractices[i], [
                      'action_remarks',
                      'justification',
                      'remarks',
                    ]),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(24),
          1: pw.FlexColumnWidth(2.25),
          2: pw.FlexColumnWidth(1.35),
          3: pw.FlexColumnWidth(1.0),
          4: pw.FlexColumnWidth(1.45),
          5: pw.FlexColumnWidth(3.45),
        },
        fontSize: 8,
      ),

      // 9.3
      pdfBar('9.3 Insurance Coverage Status'),
      pdfInsuranceCoverageSummary(),
      if (failedTables.contains('insurance_coverage_summary'))
        pdfNote(
          'Unable to load the insurance coverage summary. Check the selected '
          'monthly report and its insurance coverage fields.',
        ),
      pw.SizedBox(height: 6),
      pdfTable(
        ['No', 'Policy', 'Total Sum Insured (RM)', 'Renewal Status'],
        insurancePolicies.isEmpty
            ? [
                ['-', emptyRegisterLabel('insurance_policies'), '-', '-'],
              ]
            : [
                for (var i = 0; i < insurancePolicies.length; i++)
                  [
                    '${i + 1}',
                    firstText(insurancePolicies[i], ['policy_name']),
                    firstMoney(insurancePolicies[i], [
                      'sum_insured',
                      'sum_insured_amount',
                    ]),
                    policyStatus(insurancePolicies[i]),
                  ],
              ],
        rightAlign: const {2},
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(2.4),
          2: pw.FlexColumnWidth(1.4),
          3: pw.FlexColumnWidth(1.2),
        },
      ),

      // 9.4
      pdfBar('9.4 Insurance Claim Update'),
      pdfSub(
        'Insurance Claim as at ${DateFormat('MMMM yyyy').format(reportMonth)}',
      ),
      pdfTable(
        ['No', 'Incident Date', 'Descriptions', 'Total Cost (RM)', 'Remarks'],
        insuranceClaims.isEmpty
            ? [
                ['-', '-', emptyRegisterLabel('insurance_claims'), '-', '-'],
              ]
            : [
                for (var i = 0; i < insuranceClaims.length; i++)
                  [
                    '${i + 1}',
                    dateLabel(insuranceClaims[i]['incident_date']),
                    firstText(insuranceClaims[i], ['incident_description']),
                    insuranceClaims[i]['amount_claimed'] == null
                        ? 'TBA'
                        : amt(insuranceClaims[i]['amount_claimed']),
                    firstText(insuranceClaims[i], ['remarks', 'status']),
                  ],
              ],
        rightAlign: const {3},
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(1),
          2: pw.FlexColumnWidth(3),
          3: pw.FlexColumnWidth(1.1),
          4: pw.FlexColumnWidth(1.4),
        },
      ),
      pdfNote('Total Cost RM0.00 = Amount to be adjusted.'),
      if (unscopedTables.contains('insurance_policies') ||
          unscopedTables.contains('insurance_claims'))
        pdfNote(
          'Some insurance records are missing a property link and have '
          'been excluded until they can be assigned to the correct site.',
        ),
    ];
  }

  // Group legacy asset categories into the main categories used by the website.
  // This affects PDF display only; the original asset records are unchanged.
  String assetPdfCategory(Map<String, dynamic> asset) {
    final category = asset['category']?.toString().trim() ?? '';
    if (category.isEmpty) return 'Uncategorised';

    const legacyMainCategories = <String, String>{
      'air-conditioning equipment': 'Air-Conditioning Equipment',
      'aircond': 'Air-Conditioning Equipment',
      'air conditioning': 'Air-Conditioning Equipment',
      'air-conditioning': 'Air-Conditioning Equipment',
      'mechanical ventilation system': 'Mechanical Ventilation Systems',
      'mechanical ventilation systems': 'Mechanical Ventilation Systems',
      'pump equipment': 'Pump Equipment',
      'wet riser': 'Pump Equipment',
      'lr level': 'Pump Equipment',
      'sprinkler pump': 'Pump Equipment',
      'suction pump': 'Pump Equipment',
      'fire protection system': 'Fire Protection Systems',
      'fire protection systems': 'Fire Protection Systems',
      'co2': 'Fire Protection Systems',
      'fire alarm system': 'Fire Protection Systems',
      'fire damper': 'Fire Protection Systems',
      'fire extinguisher': 'Fire Protection Systems',
      'fireman intercom': 'Fire Protection Systems',
      'hose reel system': 'Fire Protection Systems',
      'hydrant system': 'Fire Protection Systems',
      'sprinkler system': 'Fire Protection Systems',
      'wet riser system': 'Fire Protection Systems',
    };

    return legacyMainCategories[category.toLowerCase()] ?? category;
  }

  // The saved subcategory takes priority. Legacy records may instead store
  // the subcategory name in their original category field.
  String assetPdfSubcategory(Map<String, dynamic> asset) {
    final saved = asset['subcategory']?.toString().trim() ?? '';
    if (saved.isNotEmpty) return saved;

    final original = asset['category']?.toString().trim() ?? '';
    final mainCategory = assetPdfCategory(asset);
    if (original.isNotEmpty &&
        original.toLowerCase() != mainCategory.toLowerCase()) {
      return original;
    }
    return 'Uncategorised';
  }

  // Arrange records by Asset ID first. The main categories and their
  // subcategories then appear in order of their first Asset ID.
  List<Map<String, dynamic>> _pdfAssetsById() {
    final ordered = List<Map<String, dynamic>>.from(assets);
    ordered.sort((a, b) {
      final aId = (a['asset_id']?.toString().trim() ?? '').toLowerCase();
      final bId = (b['asset_id']?.toString().trim() ?? '').toLowerCase();
      return aId.compareTo(bId);
    });
    return ordered;
  }

  List<String> get pdfAssetCategories =>
      _pdfAssetsById().map(assetPdfCategory).toSet().toList();

  List<String> pdfAssetSubcategories(
    String mainCategory,
    List<Map<String, dynamic>> orderedAssets,
  ) {
    return orderedAssets
        .where((asset) => assetPdfCategory(asset) == mainCategory)
        .map(assetPdfSubcategory)
        .toSet()
        .toList();
  }

  pw.Widget pdfAssetSubheading(String title) {
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 8, bottom: 4),
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 8),
      color: _green,
      child: pw.Text(
        pdfSafe(title),
        style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
      ),
    );
  }

  List<pw.Widget> pdfAssets() {
    final orderedAssets = _pdfAssetsById();
    final categories = orderedAssets.map(assetPdfCategory).toSet().toList();
    var rowNumber = 0;

    const assetHeaders = [
      'No',
      'Asset ID',
      'Asset Item',
      'Qty',
      'Location',
      'Brand / Model',
      'Capacity / Rating',
      'Status',
      'Monthly Condition',
    ];

    const assetWidths = <int, pw.TableColumnWidth>{
      0: pw.FixedColumnWidth(21),
      1: pw.FlexColumnWidth(1.05),
      2: pw.FlexColumnWidth(1.9),
      3: pw.FixedColumnWidth(25),
      4: pw.FlexColumnWidth(1.3),
      5: pw.FlexColumnWidth(1.25),
      6: pw.FlexColumnWidth(1.15),
      7: pw.FlexColumnWidth(0.85),
      8: pw.FlexColumnWidth(1.2),
    };

    return [
      pdfBanner('10. Asset Register'),

      pw.Text(
        'Total assets: ${assets.length}   |   '
        'Active: $activeAssetCount   |   '
        'Retired: $retiredAssetCount   |   '
        'Monthly conditions recorded: '
        '$recordedConditionCount of ${assets.length}',
        style: const pw.TextStyle(fontSize: 8),
      ),

      pw.SizedBox(height: 5),

      if (categories.isEmpty) ...[
        pdfBar('10.1 Asset Register (No Assets)'),
        pdfTable(
          assetHeaders,
          [
            ['-', '-', 'No assets recorded', '-', '-', '-', '-', '-', '-'],
          ],
          fontSize: 7,
          widths: assetWidths,
        ),
      ] else ...[
        for (var i = 0; i < categories.length; i++) ...[
          pdfBar('10.${i + 1} ${categories[i]}'),

          for (final subcategory in pdfAssetSubcategories(
            categories[i],
            orderedAssets,
          )) ...[
            pdfAssetSubheading(subcategory),

            pdfTable(
              assetHeaders,
              [
                for (final asset in orderedAssets.where(
                  (row) =>
                      assetPdfCategory(row) == categories[i] &&
                      assetPdfSubcategory(row) == subcategory,
                ))
                  [
                    '${++rowNumber}',
                    textValue(asset['asset_id']),
                    textValue(asset['asset_item']),
                    textValue(asset['qty']),
                    textValue(asset['location']),
                    textValue(asset['brand_model']),
                    textValue(asset['capacity_rating']),
                    textValue(asset['status'] ?? 'Active'),
                    textValue(
                      conditionsByAssetUuid[asset['id']
                          ?.toString()]?['condition'],
                    ),
                  ],
              ],
              fontSize: 7,
              widths: assetWidths,
            ),
          ],
        ],
      ],

      pdfBar(
        '10.${categories.isEmpty ? 2 : categories.length + 1} '
        'Service History',
      ),

      pdfTable(
        ['No', 'Asset', 'Service Date', 'Condition', 'Remarks'],
        serviceHistory.isEmpty
            ? [
                ['-', 'No service history recorded', '-', '-', '-'],
              ]
            : [
                for (var i = 0; i < serviceHistory.length; i++)
                  [
                    '${i + 1}',
                    assetLabel(serviceHistory[i]['asset_uuid']),
                    dateLabel(serviceHistory[i]['service_date']),
                    textValue(
                      conditionsByAssetUuid[serviceHistory[i]['asset_uuid']
                              ?.toString()]?['condition'] ??
                          'Not Recorded',
                    ),
                    textValue(serviceHistory[i]['remarks']),
                  ],
              ],
        widths: const {
          0: pw.FixedColumnWidth(26),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(1.2),
          4: pw.FlexColumnWidth(2),
        },
      ),
    ];
  }

  // ============================================================
  // BUILD PDF
  // ============================================================

  Future<Uint8List> buildPdf(PdfPageFormat format) async {
    // The current data has already been loaded for a live preview or a
    // confirmed one-click version generation. No queries during rendering.
    final regularFontData = await rootBundle.load(
      'assets/fonts/Roboto-Regular.ttf',
    );
    final boldFontData = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');

    final regularFont = pw.Font.ttf(regularFontData);
    final boldFont = pw.Font.ttf(boldFontData);

    // Optional logo. Drop the file at this path and register it in
    // pubspec.yaml; until then a placeholder box is drawn.
    _logo = null;
    try {
      final logoData = await rootBundle.load(
        'assets/images/apex_choice_logo.png',
      );
      _logo = pw.MemoryImage(logoData.buffer.asUint8List());
    } catch (_) {
      _logo = null;
    }

    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );

    pdf.addPage(
      pw.MultiPage(
        // Always A4 portrait to match the September report.
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(36, 20, 36, 20),
        header: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(bottom: 8),
          child: pdfLogo(width: 100, height: 38),
        ),
        footer: (context) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.black, width: 0.8),
          ),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(3),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        pdfSafe('PREPARED BY'),
                        style: pw.TextStyle(
                          fontSize: 7,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        pdfSafe(
                          'BUILDING MANAGER: ${preparedByName.toUpperCase()}',
                        ),
                        style: pw.TextStyle(
                          fontSize: 7,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        pdfSafe(
                          'MONTHLY REPORT ${monthLabel.toUpperCase()} '
                          '(DUE DATE BY 7TH EACH)',
                        ),
                        style: const pw.TextStyle(fontSize: 7),
                      ),
                    ],
                  ),
                ),
              ),
              pw.Container(width: 0.8, height: 30, color: PdfColors.black),
              pw.Expanded(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(3),
                  child: pw.Align(
                    alignment: pw.Alignment.topRight,
                    child: pw.Text(
                      'PAGE ${context.pageNumber}',
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        build: (context) => [
          ...pdfCover(),
          pw.NewPage(),
          ...pdfToc(),
          pw.NewPage(),
          ...pdfSiteAndCommittee(),
          pw.NewPage(),
          ...pdfDashboard(),
          pw.NewPage(),
          ...pdfFinance(),
          pw.NewPage(),
          ...pdfAgm(),
          pw.SizedBox(height: 14),
          ...pdfOperations(),
          pw.NewPage(),
          ...pdfServiceProviders(),
          pw.NewPage(),
          ...pdfLicensingInsurance(),
          pw.NewPage(),
          ...pdfAssets(),
        ],
      ),
    );

    return pdf.save();
  }

  // ============================================================
  // PAGE UI
  // ============================================================

  // ============================================================
  // SAVED VERSION CONTROL (the PDF sections above are unchanged)
  // ============================================================

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is List && value.length == 1 && value.first is Map) {
      return Map<String, dynamic>.from(value.first as Map);
    }
    throw StateError('Unexpected monthly report version response.');
  }

  Future<void> _initializeVersions() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) throw StateError('Please sign in to view saved reports.');
      final profile = await supabase
          .from('user_profiles')
          .select('full_name, role, account_status')
          .eq('id', user.id)
          .maybeSingle();
      final active = profile?['account_status']?.toString() == 'active';
      final admin = active && profile?['role']?.toString() == 'admin';
      final allowed = await supabase.rpc(
        'can_generate_report_version',
        params: {'p_report_id': reportId},
      );
      if (!mounted) return;
      setState(() {
        _isAdmin = admin;
        _canGenerateVersion = allowed == true;
        _generatingUserName = profile?['full_name']?.toString().trim();
      });
      await _refreshVersions();
    } catch (e) {
      if (mounted) {
        setState(() {
          _versionError = 'Unable to open saved report versions: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingVersions = false);
    }
  }

  Future<void> _refreshVersions({String? preferredId}) async {
    final data = await supabase
        .from('monthly_report_versions')
        .select(
          'id, report_id, version_number, status, pdf_storage_path, '
          'snapshot_storage_path, generated_by_name, generated_at, '
          'is_locked, locked_at, deletion_reason',
        )
        .eq('report_id', reportId)
        .order('version_number', ascending: false);
    final rows = mapRows(data);
    final ready = rows.where((row) => row['status'] == 'ready').toList();
    final currentId = preferredId ?? _selectedVersion?['id']?.toString();
    Map<String, dynamic>? chosen;
    for (final row in ready) {
      if (row['id']?.toString() == currentId) {
        chosen = row;
        break;
      }
    }
    if (chosen == null && ready.isNotEmpty) chosen = ready.first;
    if (!mounted) return;
    if (chosen == null) ++_savedDownloadSequence;
    setState(() {
      _savedVersions = rows;
      _versionError = null;
      if (chosen == null) {
        _selectedVersion = null;
        _savedPdfBytes = null;
        _savedSnapshot = null;
      }
    });
    if (chosen != null) await _loadSavedVersion(chosen);
  }

  Future<void> _loadSavedVersion(Map<String, dynamic> version) async {
    final requestId = ++_savedDownloadSequence;
    if (mounted) {
      setState(() {
        _loadingSavedFiles = true;
        _selectedVersion = version;
        _savedPdfBytes = null;
        _savedSnapshot = null;
        _versionError = null;
      });
    }
    try {
      final paths = [
        version['pdf_storage_path'].toString(),
        version['snapshot_storage_path'].toString(),
      ];
      final files = await Future.wait<Uint8List>([
        supabase.storage.from(_versionBucket).download(paths[0]),
        supabase.storage.from(_versionBucket).download(paths[1]),
      ]);
      final parsedSnapshot = _asMap(jsonDecode(utf8.decode(files[1])));
      if (!mounted || requestId != _savedDownloadSequence) return;
      setState(() {
        _savedPdfBytes = files[0];
        _savedSnapshot = parsedSnapshot;
      });
    } catch (e) {
      if (mounted && requestId == _savedDownloadSequence) {
        setState(() => _versionError = 'Could not load this saved version: $e');
      }
    } finally {
      if (mounted && requestId == _savedDownloadSequence) {
        setState(() => _loadingSavedFiles = false);
      }
    }
  }

  int _savedDownloadSequence = 0;

  // Make the source data JSON-safe. A snapshot is an archival copy, not a
  // reference to live Supabase tables. PDF bytes are archived separately.
  dynamic _jsonValue(dynamic value) {
    if (value is DateTime) return value.toIso8601String();
    if (value is Map) {
      // The site SELECT includes passcode_hash. Never archive credentials or
      // tokens as part of a monthly report data snapshot.
      const excluded = <String>{
        'passcode_hash', 'password', 'password_hash', 'access_token',
        'refresh_token', 'service_role_key', 'api_key', 'authorization',
      };
      return {
        for (final entry in value.entries)
          if (!excluded.contains(entry.key.toString().toLowerCase()))
            entry.key.toString(): _jsonValue(entry.value),
      };
    }
    if (value is Iterable) return value.map(_jsonValue).toList();
    if (value is num || value is String || value is bool || value == null) {
      return value;
    }
    return value.toString();
  }

  List<Map<String, dynamic>> _checklistSnapshot(List<MapEntry<String, bool>> items) {
    return [
      for (final item in items) {'label': item.key, 'complete': item.value},
    ];
  }

  Map<String, dynamic> _captureReportSnapshot() {
    final snapshot = <String, dynamic>{
      'snapshot_schema_version': 1,
      'report_id': reportId,
      'site_id': siteId,
      'report_month': DateFormat('yyyy-MM-dd').format(reportMonthStart),
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'generated_by_name': preparedByName,
      'report': _currentReportRecord.isEmpty ? widget.report : _currentReportRecord,
      'checklists': {
        'Finance': _checklistSnapshot(checklist),
        'Operations': _checklistSnapshot(operationsChecklist),
        'Occupancy & Unit Management': _checklistSnapshot(occupancyUnitChecklist),
        'Contracts & Compliance': _checklistSnapshot(contractsComplianceChecklist),
      },
      'failed_tables': failedTables.toList(),
      'unscoped_tables': unscopedTables.toList(),
      'sections': {
        'Site & Committee': {
          'Property': siteRow,
          'Committee terms': committeeTerms,
          'Committee history': committeeHistory,
          'Members shown for report month': committeeMembers,
        },
        'Finance': {
          'Billing & Collection': billing,
          'Arrears Reconciliation': arrears,
          'Carried opening arrears': carriedOpening,
          'Sinking Fund Transfers': transfers,
          'Fixed Deposits': fixedDeposits,
          'Approved FD allocation': approvedFdAllocation,
          'Approved Expenditures': expenditures,
          'Defaulters PDF rows': defaulterPdfRows,
          'Defaulters comparison dates': defaulterPdfBalanceDates,
          'Defaulters query error': defaulterPdfError,
          'Utilities': utilities,
        },
        'Operations': {
          'Maintenance Works': maintenanceWorks,
          'Maintenance Progress': pendingMaintenanceWorks,
          'Maintenance Dashboard': maintenanceDashboardWorks,
          'Complaints': complaints,
          'AGM / EGM Resolutions': resolutions,
          'Lift Incidents': liftIncidents,
          'Cumulative Lift Summary': monthlyLiftSummary,
          'Mantrap History': mantrapHistory,
          'Asset Conditions': assetConditions,
          'Assets': assets,
          'Asset Service History': serviceHistory,
        },
        'Occupancy & Unit Management': {
          'Total Property Units': propertyTotalUnits,
          'Occupancy Records': occupancyRecords,
          'Unit Movements': unitMovements,
          'Renovation Works': renovationWorks,
          'Sub-Sales Units': subSalesUnits,
        },
        'Contracts & Compliance': {
          'Service Providers': serviceProviders,
          'Staff Providers for Report': staffReportProviders,
          'Staff by Provider ID': staffByProviderId,
          'Licences & Regulatory': licencesRegulatory,
          'Compliance & Best Practices': compliancePractices,
          'Insurance Policies': insurancePolicies,
          'Insurance Claims': insuranceClaims,
          'Insurance Coverage Summary': insuranceCoverageSummary,
        },
        'Year-to-date & History': {
          'YTD Reports': ytdReports,
          'YTD Transfers': ytdTransfers,
          'YTD Lifts': ytdLifts,
          'All Maintenance Works': allMaintenanceWorks,
          'YTD Billing by Month': ytdBillingByMonth,
          'YTD Utilities by Month': ytdUtilitiesByMonth,
          'Report Month by ID': reportMonthById,
          'Maintenance Since': maintenanceSince,
        },
      },
    };
    return _asMap(_jsonValue(snapshot));
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _generateVersion() async {
    // One click creates the next version immediately; no confirmation dialog.
    if (_generatingVersion || _loadingLivePreview || !_canGenerateVersion) return;
    setState(() {
      _generatingVersion = true;
      loading = true;
      error = null;
    });
    Map<String, dynamic>? reserved;
    try {
      // Always refresh current source data immediately before generating.
      // This same PDF is displayed in the right-hand preview and archived as
      // a new, immutable version together with its matching data snapshot.
      final pdfBytes = await _refreshLivePdf();
      if (pdfBytes == null) {
        throw StateError(_livePreviewError ?? 'Latest PDF preview unavailable');
      }
      final snapshotBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(_captureReportSnapshot())),
      );
      reserved = _asMap(await supabase.rpc(
        'reserve_report_version',
        params: {'p_report_id': reportId},
      ));
      final storage = supabase.storage.from(_versionBucket);
      await storage.uploadBinary(
        reserved['pdf_storage_path'].toString(),
        pdfBytes,
        fileOptions: const FileOptions(contentType: 'application/pdf', upsert: false),
      );
      await storage.uploadBinary(
        reserved['snapshot_storage_path'].toString(),
        snapshotBytes,
        fileOptions: const FileOptions(contentType: 'application/json', upsert: false),
      );
      await supabase.rpc(
        'finalize_report_version',
        params: {'p_version_id': reserved['id']},
      );
      await _refreshVersions(preferredId: reserved['id']?.toString());
      _notice('Version ${reserved['version_number']} was generated and saved.');
    } catch (e) {
      // If finalization succeeded but its response was lost, never delete the
      // now-permanent saved files. Check DB status first.
      var completed = false;
      if (reserved != null) {
        try {
          final status = await supabase
              .from('monthly_report_versions')
              .select('status')
              .eq('id', reserved['id'])
              .maybeSingle();
          completed = status?['status'] == 'ready';
        } catch (_) {}
        if (!completed) {
          try {
            await supabase.storage.from(_versionBucket).remove([
              reserved['pdf_storage_path'].toString(),
              reserved['snapshot_storage_path'].toString(),
            ]);
            await supabase.rpc(
              'abort_report_version',
              params: {'p_version_id': reserved['id']},
            );
          } catch (cleanupError) {
            debugPrint('Version upload cleanup requires attention: $cleanupError');
          }
        }
      }
      if (completed) {
        await _refreshVersions(preferredId: reserved!['id']?.toString());
        _notice('Report saved successfully.');
      } else {
        _notice('Report generation was not saved: $e');
      }
    } finally {
      if (mounted) setState(() => _generatingVersion = false);
    }
  }

  Future<void> _changeVersionLock(Map<String, dynamic> version) async {
    if (!_isAdmin || _versionActionBusy) return;
    final lock = version['is_locked'] != true;
    setState(() => _versionActionBusy = true);
    try {
      await supabase.rpc('set_report_version_lock', params: {
        'p_version_id': version['id'],
        'p_locked': lock,
      });
      await _refreshVersions(preferredId: version['id']?.toString());
      _notice(lock ? 'Version locked.' : 'Version unlocked.');
    } catch (e) {
      _notice('Unable to change version lock: $e');
    } finally {
      if (mounted) setState(() => _versionActionBusy = false);
    }
  }

  Future<void> _deleteVersion(Map<String, dynamic> version) async {
    if (!_isAdmin || _versionActionBusy) return;
    final resuming = version['status'] == 'deleting';
    // Admin deletion is immediate. No confirmation or reason is requested.
    if (!resuming && version['is_locked'] == true) return;
    setState(() => _versionActionBusy = true);
    try {
      if (!resuming) {
        version = _asMap(await supabase.rpc('begin_delete_report_version', params: {
          'p_version_id': version['id'],
          'p_reason': null,
        }));
      }
      // Storage objects must be removed through the Storage API, never by
      // deleting their SQL metadata (which leaves orphaned physical objects).
      await supabase.storage.from(_versionBucket).remove([
        version['pdf_storage_path'].toString(),
        version['snapshot_storage_path'].toString(),
      ]);
      await supabase.rpc('finish_delete_report_version', params: {
        'p_version_id': version['id'],
      });
      await _refreshVersions();
      _notice('Version ${version['version_number']} permanently deleted.');
    } catch (e) {
      _notice('Deletion could not finish: $e. Admin can resume it from Version History.');
      try { await _refreshVersions(); } catch (_) {}
    } finally {
      if (mounted) setState(() => _versionActionBusy = false);
    }
  }

  List<MapEntry<String, bool>> _savedChecklist(String title) {
    final groups = _savedSnapshot?['checklists'];
    if (groups is! Map || groups[title] is! List) return [];
    return [
      for (final record in groups[title] as List)
        if (record is Map)
          MapEntry(
            record['label']?.toString() ?? '-',
            record['complete'] == true,
          ),
    ];
  }

  String _versionDate(dynamic value) {
    if (value == null) return 'Generation in progress';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return '-';
    return DateFormat('dd MMM yyyy, hh:mm a').format(parsed.toLocal());
  }

  Widget _versionControls(ThemeData theme) {
    final ready = _savedVersions.where((row) => row['status'] == 'ready').toList();
    final deleting = _savedVersions.where((row) => row['status'] == 'deleting').toList();
    final version = _selectedVersion;
    final selectedId = version?['id']?.toString();
    final latest = ready.isNotEmpty && ready.first['id']?.toString() == selectedId;
    final locked = version?['is_locked'] == true;
    final actionsBusy = _versionActionBusy || _generatingVersion ||
        _loadingSavedFiles || _loadingLivePreview;
    final border = theme.dividerColor.withValues(alpha: 0.55);
    final red = const Color(0xFFE11D2E);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.layers_outlined, size: 21),
                const SizedBox(width: 8),
                Expanded(child: Text('Report Versions', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                if (ready.isNotEmpty)
                  Chip(label: Text('${ready.length} saved'), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 10),
            if (ready.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No saved versions yet. Generate the first report to create a saved PDF.'),
              )
            else ...[
              if (ready.length > 1) ...[
                DropdownButtonFormField<String>(
                  initialValue: selectedId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    isDense: true,
                  ),
                  items: [
                    for (final row in ready)
                      DropdownMenuItem<String>(
                        value: row['id']?.toString(),
                        child: Text('Version ${row['version_number']}${row['is_locked'] == true ? '  •  Locked' : ''}', overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: actionsBusy ? null : (id) {
                    if (id == null) return;
                    for (final row in ready) {
                      if (row['id']?.toString() == id) {
                        _loadSavedVersion(row);
                        break;
                      }
                    }
                  },
                ),
                const SizedBox(height: 10),
              ],
              if (version != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Text('Version ${version['version_number']}', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          if (latest) const Chip(label: Text('Latest'), visualDensity: VisualDensity.compact),
                          Chip(
                            avatar: Icon(locked ? Icons.lock_outline : Icons.lock_open_outlined, size: 15),
                            label: Text(locked ? 'Locked' : 'Unlocked'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(children: [
                        const Icon(Icons.person_outline, size: 16),
                        const SizedBox(width: 6),
                        Expanded(child: Text(version['generated_by_name']?.toString() ?? '-', style: theme.textTheme.bodyMedium)),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        const Icon(Icons.calendar_today_outlined, size: 15),
                        const SizedBox(width: 7),
                        Expanded(child: Text('Generated at: ${_versionDate(version['generated_at'])}', style: theme.textTheme.bodySmall)),
                      ]),
                      const SizedBox(height: 10),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          OutlinedButton.icon(
                            onPressed: actionsBusy || _savedPdfBytes == null ? null : () => _showPdfPreview(),
                            icon: const Icon(Icons.picture_as_pdf_outlined, size: 17),
                            label: const Text('View PDF'),
                          ),
                          if (_isAdmin)
                            OutlinedButton.icon(
                              onPressed: actionsBusy ? null : () => _changeVersionLock(version),
                              icon: Icon(locked ? Icons.lock_open_outlined : Icons.lock_outline, size: 17),
                              label: Text(locked ? 'Unlock' : 'Lock'),
                            ),
                          if (_isAdmin)
                            Tooltip(
                              message: locked ? 'Unlock this version before deleting it' : 'Permanently delete this version immediately',
                              child: OutlinedButton.icon(
                                onPressed: actionsBusy || locked ? null : () => _deleteVersion(version),
                                style: OutlinedButton.styleFrom(foregroundColor: red, side: BorderSide(color: locked ? border : red.withValues(alpha: 0.65))),
                                icon: const Icon(Icons.delete_forever_outlined, size: 17),
                                label: const Text('Delete'),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: red, padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13)),
              onPressed: _canGenerateVersion && !actionsBusy ? _generateVersion : null,
              icon: const Icon(Icons.post_add_outlined, size: 20),
              label: Text(ready.isEmpty ? 'Generate New Version' : 'Regenerate as New Version'),
            ),
            if (_generatingVersion) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              const Text('Generating PDF and saving report version...'),
            ],
            if (_isAdmin && deleting.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(),
              Text('Incomplete deletions', style: theme.textTheme.titleSmall),
              for (final row in deleting)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Version ${row['version_number']} • Deletion in progress'),
                  trailing: TextButton(
                    onPressed: actionsBusy ? null : () => _deleteVersion(row),
                    child: const Text('Resume'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPdfPreview() {
    // Full-screen preview uses the stored bytes, never live source data.
    final pdfBytes = _savedPdfBytes;
    if (pdfBytes == null) return;
    final versionNo = _selectedVersion?['version_number'];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (previewContext) => Scaffold(
          appBar: AppBar(title: Text('Saved Report - Version $versionNo')),
          body: PdfPreview(
            build: (format) async => pdfBytes,
            canChangeOrientation: false,
            canChangePageFormat: false,
            allowPrinting: true,
            allowSharing: true,
            pdfFileName: 'Property_Report_${DateFormat('yyyy_MM').format(reportMonth)}_v$versionNo.pdf',
          ),
        ),
      ),
    );
  }

  Widget _compactSavedProgress(ThemeData theme) {
    final groups = <MapEntry<String, List<MapEntry<String, bool>>>>[
      MapEntry('Finance', _savedChecklist('Finance')),
      MapEntry('Operations', _savedChecklist('Operations')),
      MapEntry('Occupancy & Unit Management', _savedChecklist('Occupancy & Unit Management')),
      MapEntry('Contracts & Compliance', _savedChecklist('Contracts & Compliance')),
    ];
    final total = groups.fold<int>(0, (sum, group) => sum + group.value.length);
    final done = groups.fold<int>(0, (sum, group) => sum + group.value.where((x) => x.value).length);
    final percent = total == 0 ? 0.0 : done / total;
    final border = theme.dividerColor.withValues(alpha: 0.55);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: border)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: const Icon(Icons.fact_check_outlined),
        title: const Text('Saved Report Progress', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            Text('$done / $total checks completed · ${(percent * 100).round()}%', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: percent, minHeight: 6, color: const Color(0xFFE11D2E)),
            ),
            const SizedBox(height: 6),
          ],
        ),
        children: [
          const Divider(height: 1),
          for (final group in groups)
            ExpansionTile(
              key: PageStorageKey('saved-checklist-${group.key}'),
              tilePadding: const EdgeInsets.symmetric(horizontal: 18),
              title: Text(group.key, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text('${group.value.where((item) => item.value).length} / ${group.value.length} completed'),
              children: [
                for (final item in group.value)
                  ListTile(
                    dense: true,
                    leading: Icon(item.value ? Icons.check_circle_outline : Icons.pending_outlined,
                        size: 19, color: item.value ? Colors.green : Colors.orange),
                    title: Text(item.key, style: const TextStyle(fontSize: 13)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ============================================================
  // PAGE UI -- saved versions on the left, live PDF preview on the right
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final savedReady = _savedVersions.any((row) => row['status'] == 'ready');
    final snapshotReady = _savedSnapshot != null;

    return Scaffold(
      appBar: AppBar(title: Text('Export PDF - $monthLabel')),
      body: _loadingVersions
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final isPhone =
                    (theme.platform == TargetPlatform.android ||
                        theme.platform == TargetPlatform.iOS) &&
                    MediaQuery.sizeOf(context).shortestSide < 600;
                final sideBySide = !isPhone && constraints.maxWidth >= 900;

                final progressPanel = SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _versionControls(theme),
                      if (_versionError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SelectableText(
                            _versionError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      if (snapshotReady) _compactSavedProgress(theme),
                      if (!savedReady)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('No saved report exists for this month. Generate a new version when needed.'),
                        ),
                    ],
                  ),
                );

                // The right panel ALWAYS represents current Supabase data,
                // never the saved-version selection in the left panel.
                final Widget previewPanel;
                if (_loadingLivePreview) {
                  previewPanel = const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Building current PDF preview from latest data...'),
                      ],
                    ),
                  );
                } else if (_livePdfBytes != null) {
                  final pdfBytes = _livePdfBytes!;
                  previewPanel = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        child: Row(
                          children: [
                            const Icon(Icons.picture_as_pdf_outlined, size: 19),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Current Report - Live PDF Preview',
                                      style: theme.textTheme.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w700)),
                                  Text(
                                    'Last updated at: ${_versionDate(_livePreviewUpdatedAt?.toIso8601String())} (PDF preview)',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh PDF with latest report changes',
                              onPressed: _generatingVersion || _versionActionBusy
                                  ? null
                                  : () { _refreshLivePdf(); },
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: PdfPreview(
                          key: ValueKey('live-pdf-$_livePreviewRevision'),
                          build: (format) async => pdfBytes,
                          canChangeOrientation: false,
                          canChangePageFormat: false,
                          allowPrinting: false,
                          allowSharing: false,
                          pdfFileName: 'Current_Property_Report_${DateFormat('yyyy_MM').format(reportMonth)}.pdf',
                          loadingWidget: const Center(
                              child: CircularProgressIndicator()),
                        ),
                      ),
                    ],
                  );
                } else {
                  previewPanel = Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.picture_as_pdf_outlined, size: 34),
                          const SizedBox(height: 10),
                          Text(
                            _livePreviewError ??
                                'The current report PDF preview is not available.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () { _refreshLivePdf(); },
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry PDF Preview'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                if (sideBySide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 4, child: progressPanel),
                      const VerticalDivider(width: 1, thickness: 1),
                      Expanded(flex: 6, child: previewPanel),
                    ],
                  );
                }
                return Column(
                  children: [
                    Flexible(
                      flex: 0,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.48),
                        child: progressPanel,
                      ),
                    ),
                    Expanded(child: previewPanel),
                  ],
                );
              },
            ),
    );
  }
}