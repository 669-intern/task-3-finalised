import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'property_sites_service.dart';
import 'widgets/app_common_app_bar.dart';
import 'widgets/styles.dart';

class SiteProfilePage extends StatefulWidget {
  final String siteId;
  final String? siteName;
  final DateTime? reportMonth;
  final String? reportId;

  const SiteProfilePage({
    super.key,
    required this.siteId,
    this.siteName,
    this.reportMonth,
    this.reportId,
  });

  @override
  State<SiteProfilePage> createState() => _SiteProfilePageState();
}

class _SiteProfilePageState extends State<SiteProfilePage> {
  static const List<String> _frequencies = [
    'Monthly',
    'Quarterly',
    'Half-yearly',
    'Annually',
  ];

  static const String _totalUnitsHelp =
      'Enter the total number of units across the entire property, '
      'Provide the overall total as a whole number.';

  final _formKey = GlobalKey<FormState>();

  final Map<String, TextEditingController> _controllers = {
    for (final key in const [
      'total_units',
      'registration_address',
      'email',
      'contact_number',
      'service_charge_per_share_unit',
      'service_charge_per_sqft',
      'sinking_fund_per_share_unit',
      'sinking_fund_per_sqft',
      'total_monthly_billing',
      'total_aggregate_share_unit',
      'annual_billing',
    ])
      key: TextEditingController(),
  };

  // Dated committee records are authoritative. The legacy property-site JSON
  // is retained only to save unrelated Site Profile fields safely.
  List<Map<String, dynamic>> _committeeHistory = [];
  List<Map<String, dynamic>> _committeeTerms = [];
  List<Map<String, dynamic>> _originalCommitteeJson = [];
  // Member edits use the Edit dialog; keep a transient draft by membership ID.
  final Map<String, Map<String, dynamic>> _committeeDraftEdits = {};

  Map<String, dynamic> _originalInfo = {};
  SiteProfilePermissions _permissions = const SiteProfilePermissions(
    canView: false,
    canAdd: false,
    canEdit: false,
    canDelete: false,
  );

  String _siteName = '';
  String _serviceFrequency = 'Quarterly';
  String _fundFrequency = 'Quarterly';
  bool _serviceFrequencyTouched = false;
  bool _fundFrequencyTouched = false;

  late DateTime _viewMonth;
  // The live committee lifecycle is independent of the selected report month.
  late DateTime _committeeCurrentMonth;
  bool _loading = true;
  bool _saving = false;
  bool _accessDenied = false;
  String? _loadError;
  String? _saveError;
  String? _message;
  String? _resolvedReportId;
  Timer? _successTimer;

  @override
  void initState() {
    super.initState();
    _siteName = widget.siteName ?? '';
    final selected = widget.reportMonth ?? DateTime.now();
    _viewMonth = DateTime(selected.year, selected.month);
    _resolvedReportId = widget.reportId;
    _load();
  }

  @override
  void didUpdateWidget(covariant SiteProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldMonth = oldWidget.reportMonth;
    final newMonth = widget.reportMonth;
    if (widget.siteId != oldWidget.siteId ||
        widget.reportId != oldWidget.reportId ||
        oldMonth?.year != newMonth?.year ||
        oldMonth?.month != newMonth?.month) {
      final month = widget.reportMonth ?? DateTime.now();
      _viewMonth = DateTime(month.year, month.month);
      _resolvedReportId = widget.reportId;
      _load();
    }
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    _successTimer?.cancel();
    setState(() {
      _message = message;
      _saveError = null;
    });
    _successTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _message = null);
    });
  }

  // Report ID is always the existing monthly_reports.id, never a generated ID.
  // Use the supplied route value first, then look up the selected site/month.
  Future<String?> _findExistingReportId() async {
    final supplied = widget.reportId?.trim();
    if (supplied != null && supplied.isNotEmpty) return supplied;
    try {
      final row = await Supabase.instance.client
          .from('monthly_reports')
          .select('id')
          .eq('site_id', widget.siteId)
          .eq('report_month', _committeeMonthKey(_viewMonth))
          .maybeSingle();
      return row?['id']?.toString();
    } catch (_) {
      // Site Profile remains usable if report lookup is unavailable.
      return null;
    }
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }

    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _accessDenied = false;
      _permissions = const SiteProfilePermissions(
        canView: false,
        canAdd: false,
        canEdit: false,
        canDelete: false,
      );
    });

    try {
      final result = await PropertySitesService.getSiteProfileAuthenticated(
        siteId: widget.siteId,
      );
      final details = result.site;
      _permissions = result.permissions;

      // Fail visibly if the new historical API has not been deployed: using
      // the legacy JSON would silently show removed members as current.
      final history =
          await PropertySitesService.getCommitteeHistoryAuthenticated(
            siteId: widget.siteId,
          );
      final termResponse = await _committeeTermRequest(
        'get_committee_terms_authenticated',
        {'report_month': _committeeMonthKey(_viewMonth)},
      );
      final reportId = await _findExistingReportId();
      if (!mounted) return;
      _applyCommitteeTermResponse(termResponse);
      _resolvedReportId = reportId;
      _committeeHistory = history;
      _committeeDraftEdits.clear();
      final existingJson = details['management_committee'];
      _originalCommitteeJson = existingJson is List
          ? existingJson
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : [];

      final info = Map<String, dynamic>.from(
        details['site_information'] is Map
            ? details['site_information'] as Map
            : <String, dynamic>{},
      );

      _originalInfo = info;
      _siteName = details['site_name']?.toString() ?? _siteName;

      final totalUnits = details['total_units'] ?? info['total_units'] ?? '';
      _controllers['total_units']!.text = totalUnits.toString();

      for (final entry in _controllers.entries) {
        if (entry.key == 'total_units') continue;
        entry.value.text = info[entry.key]?.toString() ?? '';
      }

      final service = info['service_billing_frequency']?.toString() ?? '';
      final fund = info['fund_billing_frequency']?.toString() ?? '';

      _serviceFrequency = service.isEmpty ? 'Quarterly' : service;
      _fundFrequency = fund.isEmpty ? 'Quarterly' : fund;
      _serviceFrequencyTouched = false;
      _fundFrequencyTouched = false;
    } on PropertyAccessDeniedException {
      _accessDenied = true;
    } on AuthRequiredException catch (e) {
      _loadError = e.message;
    } catch (e) {
      _loadError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_permissions.canSave || !_permissions.canView) return;
    if (!_formKey.currentState!.validate()) return;

    final parsedTotalUnits = int.tryParse(
      _controllers['total_units']!.text.trim(),
    );

    if (parsedTotalUnits == null || parsedTotalUnits <= 0) {
      setState(() {
        _saveError = 'Total Units must be a whole number greater than zero.';
      });
      return;
    }

    if (_siteName.trim().isEmpty) {
      setState(() {
        _saveError = 'The site name is missing. Reload the page and try again.';
      });
      return;
    }

    final changedMembers = _committeeHistory
        .where(_committeeDraftChanged)
        .toList();
    if (changedMembers.isNotEmpty && !_permissions.canEdit) {
      setState(
        () => _saveError =
            'Edit permission is required to change committee members.',
      );
      return;
    }
    for (final member in changedMembers) {
      final draft = _committeeDraftFor(member);
      final name = (draft['name'] as String).trim();
      final designation = (draft['designation'] as String).trim();
      final start = draft['start'] as DateTime?;
      final removed = draft['removed'] as DateTime?;
      if (name.isEmpty ||
          designation.isEmpty ||
          name.length > 250 ||
          designation.length > 250 ||
          start == null ||
          (removed != null && !removed.isAfter(start))) {
        setState(
          () => _saveError =
              'Enter a valid name, designation and effective date range for '
              '${member['member_name'] ?? 'the committee member'}.',
        );
        return;
      }
      if ((member['updated_at']?.toString() ?? '').isEmpty) {
        setState(
          () => _saveError =
              'Committee member timestamp missing. Reload and try again.',
        );
        return;
      }
    }

    // Start from what is already saved so that any other keys in
    // site_information are preserved, then overlay the edited values.
    final updatedInformation = <String, dynamic>{..._originalInfo}
      ..remove('total_units');

    for (final entry in _controllers.entries) {
      if (entry.key == 'total_units') continue;
      updatedInformation[entry.key] = entry.value.text.trim();
    }

    // A missing frequency defaults visually to Quarterly. Avoid having a
    // partially permitted Staff account add the default when saving an
    // unrelated field. Preserve the full-access Admin save behavior.
    if (_originalInfo['service_billing_frequency']?.toString().isNotEmpty ==
            true ||
        _serviceFrequencyTouched ||
        (_permissions.canAdd &&
            _permissions.canEdit &&
            _permissions.canDelete)) {
      updatedInformation['service_billing_frequency'] = _serviceFrequency;
    }
    if (_originalInfo['fund_billing_frequency']?.toString().isNotEmpty ==
            true ||
        _fundFrequencyTouched ||
        (_permissions.canAdd &&
            _permissions.canEdit &&
            _permissions.canDelete)) {
      updatedInformation['fund_billing_frequency'] = _fundFrequency;
    }

    _successTimer?.cancel();
    setState(() {
      _saving = true;
      _saveError = null;
      _message = null;
    });

    var savedMemberCount = 0;
    try {
      // Apply only changed member cards. The existing Edge Function's edit
      // action validates permissions and protects membership date ranges.
      for (final member in changedMembers) {
        final draft = _committeeDraftFor(member);
        await PropertySitesService.editCommitteeMemberAuthenticated(
          siteId: widget.siteId,
          membershipId: member['id'].toString(),
          name: (draft['name'] as String).trim(),
          designation: (draft['designation'] as String).trim(),
          effectiveFrom: draft['start'] as DateTime,
          removedFrom: draft['removed'] as DateTime?,
          expectedUpdatedAt: member['updated_at'].toString(),
        );
        savedMemberCount++;
        _committeeDraftEdits.remove(member['id'].toString());
      }

      await PropertySitesService.updateSiteProfileAuthenticated(
        siteId: widget.siteId,
        siteName: _siteName.trim(),
        totalUnits: parsedTotalUnits,
        siteInformation: updatedInformation,
        // Ordinary profile fields do not overwrite dated committee history.
        managementCommittee: _originalCommitteeJson,
      );

      if (!mounted) return;
      await _load();
      if (mounted) _showSuccess('Site Profile saved successfully.');
    } on PropertyAccessDeniedException catch (e) {
      if (mounted) {
        setState(
          () => _saveError = savedMemberCount > 0
              ? 'Some committee changes were saved. Reload to review. ${e.message}'
              : e.message,
        );
      }
    } on AuthRequiredException catch (e) {
      if (mounted) {
        setState(
          () => _saveError = savedMemberCount > 0
              ? 'Some committee changes were saved. Reload to review. ${e.message}'
              : e.message,
        );
      }
    } catch (e) {
      if (mounted) {
        final detail = e.toString().replaceFirst('Exception: ', '');
        setState(
          () => _saveError = savedMemberCount > 0
              ? 'Some committee changes were saved. Reload to review. $detail'
              : detail,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // COMMITTEE TERM MANAGEMENT (new dated committee-term API)
  // ---------------------------------------------------------------------------

  String _committeeMonthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-01';

  List<Map<String, dynamic>> _parseCommitteeTerms(
    Map<String, dynamic> response,
  ) {
    final value = response['terms'];
    if (value is! List) {
      throw Exception('Invalid committee terms returned by the server.');
    }
    return value
        .whereType<Map>()
        .map((term) => Map<String, dynamic>.from(term))
        .toList();
  }

  void _applyCommitteeTermResponse(Map<String, dynamic> response) {
    final terms = _parseCommitteeTerms(response);
    final currentMonth = _parseMonth(response['current_month']);
    const allowedStatuses = <String>{
      'current',
      'upcoming',
      'closed',
      'restored',
      'needs_review',
    };
    if (currentMonth == null ||
        !response.containsKey('report_term_id') ||
        terms.any((term) => !allowedStatuses.contains(term['status']))) {
      throw Exception(
        'The committee service is missing lifecycle information. '
        'Refresh after the property-sites Edge Function is updated.',
      );
    }
    _committeeCurrentMonth = currentMonth;
    _committeeTerms = terms;
  }

  // Keep this request within site_profile.dart: other screens can continue
  // using PropertySitesService unchanged. The Edge Function verifies the
  // signed-in user and the per-site permissions on every call.
  Future<Map<String, dynamic>> _committeeTermRequest(
    String action,
    Map<String, dynamic> fields,
  ) async {
    final client = Supabase.instance.client;
    var session = client.auth.currentSession;
    if (session == null) throw const AuthRequiredException();
    if (session.isExpired) {
      try {
        session = (await client.auth.refreshSession()).session;
      } catch (_) {
        throw const AuthRequiredException();
      }
      if (session == null) throw const AuthRequiredException();
    }
    final jwt = session.accessToken;
    if (jwt.isEmpty) throw const AuthRequiredException();

    try {
      final response = await client.functions.invoke(
        'property-sites',
        body: {'action': action, 'site_id': widget.siteId, ...fields},
        headers: {'Authorization': 'Bearer $jwt'},
      );
      final data = response.data;
      if (data is! Map) {
        throw Exception('The property service returned an invalid response.');
      }
      return Map<String, dynamic>.from(data);
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map && details['error'] != null) {
        throw Exception(details['error'].toString());
      }
      throw Exception('Committee service request failed: $error');
    }
  }

  bool _termIsEffective(Map<String, dynamic> term) =>
      _termStatus(term) == 'Current';

  bool _termIsArchived(Map<String, dynamic> term) =>
      term['is_closed'] == true || term['status'] == 'closed';

  bool _memberWasArchived(Map<String, dynamic> member) =>
      (member['removal_reason']?.toString().trim() ?? '').isNotEmpty;

  bool _memberArchivedInView(Map<String, dynamic> member) {
    if (!_memberWasArchived(member)) return false;
    final removed = _parseMonth(member['removed_from']);
    if (removed == null || _committeeCurrentMonth.isBefore(removed)) {
      return false;
    }
    final terms = _committeeTerms.where(
      (term) => term['id']?.toString() == member['term_id']?.toString(),
    );
    // Closed and restored historical terms already show the entire roster.
    if (terms.isEmpty ||
        _termIsArchived(terms.first) ||
        _termStatus(terms.first) == 'Restored') {
      return false;
    }
    final identity = member['member_id']?.toString();
    if (identity == null) return false;
    // If restored, the newest active version replaces the archived card.
    return !_committeeHistory.any(
      (other) =>
          other['id']?.toString() != member['id']?.toString() &&
          other['member_id']?.toString() == identity &&
          other['term_id']?.toString() == member['term_id']?.toString() &&
          _isCurrentMember(other),
    );
  }

  String _termStatus(Map<String, dynamic> term) {
    if (_termIsArchived(term)) return 'Closed';
    switch (term['status']) {
      case 'current':
        return 'Current';
      case 'upcoming':
        return 'Upcoming';
      case 'restored':
        return 'Restored';
      default:
        return 'Review Dates';
    }
  }

  bool _canCloseTerm(Map<String, dynamic> term) =>
      _permissions.canEdit &&
      !_termIsArchived(term) &&
      term['can_close'] == true;

  bool _canRestoreTerm(Map<String, dynamic> term) =>
      _permissions.canEdit &&
      _termIsArchived(term) &&
      term['can_restore'] == true;

  // Only the closed outgoing term may share its final month with a successor.
  // Supabase repeats this validation under a property-specific lock.
  String? _newTermConflict(DateTime start, DateTime end) {
    for (final term in _committeeTerms) {
      final existingStart = _parseMonth(term['effective_from']);
      final existingEnd = _parseMonth(term['effective_until']);
      if (existingStart == null || term['needs_date_review'] == true) {
        return 'Confirm the dates of existing committee terms before adding another term.';
      }
      final overlaps =
          !end.isBefore(existingStart) &&
          (existingEnd == null || !start.isAfter(existingEnd));
      if (!overlaps) continue;
      final sameMonthHandover =
          existingStart.isBefore(start) &&
          _sameCommitteeMonth(existingEnd, start) &&
          term['is_closed'] == true;
      if (sameMonthHandover) continue;
      if (existingStart.isBefore(start) &&
          _sameCommitteeMonth(existingEnd, start)) {
        return 'Close ${term['term_name']} before creating a successor in the same month.';
      }
      return 'The new term overlaps ${term['term_name']}. '
          'Only a closed outgoing term may share its final month with a successor.';
    }
    return null;
  }

  DateTime _nextMonth(DateTime date) => DateTime(date.year, date.month + 1);

  Future<void> _runTermAction(
    Future<void> Function() operation,
    String successMessage,
  ) async {
    if (_saving) return;
    _successTimer?.cancel();
    setState(() {
      _saving = true;
      _saveError = null;
      _message = null;
    });
    var wasSaved = false;
    try {
      await operation();
      wasSaved = true;
      final termsResponse = await _committeeTermRequest(
        'get_committee_terms_authenticated',
        {'report_month': _committeeMonthKey(_viewMonth)},
      );
      final history =
          await PropertySitesService.getCommitteeHistoryAuthenticated(
            siteId: widget.siteId,
          );
      if (!mounted) return;
      setState(() {
        _applyCommitteeTermResponse(termsResponse);
        _committeeHistory = history;
        _committeeDraftEdits.clear();
      });
      _showSuccess(successMessage);
    } on PropertyAccessDeniedException catch (error) {
      if (mounted) {
        setState(
          () => _saveError = wasSaved
              ? 'Term saved, but the list could not refresh: ${error.message}'
              : error.message,
        );
      }
    } on AuthRequiredException catch (error) {
      if (mounted) {
        setState(
          () => _saveError = wasSaved
              ? 'Term saved, but the list could not refresh: ${error.message}'
              : error.message,
        );
      }
    } catch (error) {
      if (mounted) {
        final detail = error.toString().replaceFirst('Exception: ', '');
        setState(
          () => _saveError = wasSaved
              ? 'Term saved, but the list could not refresh: $detail'
              : detail,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Suggest the successor's start and end, but keep both editable.
  // Closed terms retain their original historical dates.
  Future<void> _createCommitteeTerm() async {
    if (_saving || !_permissions.canAdd) return;
    final ordered = List<Map<String, dynamic>>.from(_committeeTerms);
    ordered.sort(
      (a, b) => (a['effective_from']?.toString() ?? '').compareTo(
        b['effective_from']?.toString() ?? '',
      ),
    );
    final latest = ordered.isEmpty ? null : ordered.last;
    final latestStart = latest == null
        ? null
        : _parseMonth(latest['effective_from']);
    final latestEnd = latest == null
        ? null
        : _parseMonth(latest['effective_until']);

    // Default to the same handover month after closure, or the next
    // non-overlapping month if the previous term is still open.
    var from = _committeeCurrentMonth;
    if (latestEnd != null && latest != null) {
      from = _termIsArchived(latest) ? latestEnd : _nextMonth(latestEnd);
    } else if (latestStart != null) {
      from = DateTime(latestStart.year + 1, latestStart.month);
    }
    var until = DateTime(from.year + 1, from.month);
    var termName = 'Committee Term ${from.year}/${from.year + 1}';
    final formKey = GlobalKey<FormState>();

    final draft = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: const Text('Create New Committee Term'),
          content: SizedBox(
            width: 440,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      initialValue: termName,
                      maxLength: 250,
                      decoration: _decoration(
                        'Committee Term',
                        Icons.groups_outlined,
                      ),
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? 'Enter a term name'
                          : null,
                      onChanged: (value) => termName = value,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text('Effective From: ${_showMonth(from)}'),
                      onPressed: () async {
                        final picked = await _pickCommitteeMonth(
                          title: 'Effective From',
                          initial: from,
                        );
                        if (picked != null && dialogContext.mounted) {
                          refresh(() {
                            from = picked;
                            if (until.isBefore(from)) {
                              until = DateTime(from.year + 1, from.month);
                            }
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.event_available_outlined),
                      label: Text('Effective Until: ${_showMonth(until)}'),
                      onPressed: () async {
                        final picked = await _pickCommitteeMonth(
                          title: 'Effective Until',
                          initial: until,
                        );
                        if (picked != null && dialogContext.mounted) {
                          refresh(() => until = picked);
                        }
                      },
                    ),
                    if (until.isBefore(from) ||
                        _newTermConflict(from, until) != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          until.isBefore(from)
                              ? 'End month cannot precede the start month.'
                              : _newTermConflict(from, until)!,
                          style: const TextStyle(color: AppColors.red),
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
              onPressed:
                  until.isBefore(from) || _newTermConflict(from, until) != null
                  ? null
                  : () {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      Navigator.pop(dialogContext, {
                        'term_name': termName.trim(),
                        'from': from,
                        'until': until,
                      });
                    },
              child: const Text('Create Term'),
            ),
          ],
        ),
      ),
    );
    if (draft == null || !mounted) return;

    final start = draft['from'] as DateTime;
    final end = draft['until'] as DateTime;
    final conflict = _newTermConflict(start, end);
    if (conflict != null) {
      setState(() => _saveError = conflict);
      return;
    }

    // The database validates the boundary month and serializes creation.
    // Do not implicitly shorten or edit the preceding term.
    await _runTermAction(() async {
      await _committeeTermRequest('create_committee_term_authenticated', {
        'term_name': draft['term_name'],
        'effective_from': _committeeMonthKey(start),
        'effective_until': _committeeMonthKey(end),
      });
    }, 'Committee term created. Add members to its list below.');
  }

  Future<void> _editCommitteeTerm(Map<String, dynamic> term) async {
    if (_saving || !_permissions.canEdit || _termIsArchived(term)) return;
    var termName = term['term_name']?.toString() ?? '';
    final formKey = GlobalKey<FormState>();
    DateTime? from = _parseMonth(term['effective_from']);
    DateTime? until = _parseMonth(term['effective_until']);
    final needsReview = term['needs_date_review'] == true;

    final draft = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) {
          final valid =
              from != null && until != null && !until!.isBefore(from!);
          return AlertDialog(
            title: const Text('Edit Committee Term'),
            content: SizedBox(
              width: 440,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        initialValue: termName,
                        maxLength: 250,
                        decoration: _decoration(
                          'Committee Term',
                          Icons.groups_outlined,
                        ),
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? 'Enter a term name'
                            : null,
                        onChanged: (value) => termName = value,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: Text('Effective From: ${_showMonth(from)}'),
                        onPressed: () async {
                          final picked = await _pickCommitteeMonth(
                            title: 'Effective From',
                            initial: from ?? _viewMonth,
                          );
                          if (picked != null && dialogContext.mounted) {
                            refresh(() => from = picked);
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.event_available_outlined),
                        label: Text('Effective Until: ${_showMonth(until)}'),
                        onPressed: () async {
                          final picked = await _pickCommitteeMonth(
                            title: 'Effective Until',
                            initial: until ?? from ?? _viewMonth,
                          );
                          if (picked != null && dialogContext.mounted) {
                            refresh(() => until = picked);
                          }
                        },
                      ),
                      if (needsReview)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'Imported dates may be provisional. Check the actual '
                            'committee term before saving to confirm them.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.grey,
                            ),
                          ),
                        ),
                      if (!valid)
                        const Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: Text(
                            'Select valid start and end months.',
                            style: TextStyle(color: AppColors.red),
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
                onPressed: !valid
                    ? null
                    : () {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        Navigator.pop(dialogContext, {
                          'term_name': termName.trim(),
                          'from': from!,
                          'until': until!,
                        });
                      },
                child: Text(
                  needsReview ? 'Confirm Dates & Save' : 'Save Changes',
                ),
              ),
            ],
          );
        },
      ),
    );
    if (draft == null || !mounted) return;
    await _runTermAction(() async {
      await _committeeTermRequest('edit_committee_term_authenticated', {
        'term_id': term['id'],
        'term_name': draft['term_name'],
        'effective_from': _committeeMonthKey(draft['from'] as DateTime),
        'effective_until': _committeeMonthKey(draft['until'] as DateTime),
        'expected_updated_at': term['updated_at'],
        'confirm_dates': true,
      });
    }, 'Committee term updated. Membership history remains available.');
  }

  Future<void> _closeCommitteeTerm(Map<String, dynamic> term) async {
    if (_saving || !_canCloseTerm(term)) return;
    final start = _parseMonth(term['effective_from']);
    final until = _parseMonth(term['effective_until']);
    if (start == null || until == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close Committee Term'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Term: ${term['term_name']}'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _committeeDateBox(
                      'Effective From',
                      _showMonth(start),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _committeeDateBox(
                      'Effective Until',
                      _showMonth(until),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Closing this term moves it and its members to Archived Records. '
                'The saved effective dates and earlier monthly reports are preserved.',
                style: TextStyle(fontSize: 12, color: AppColors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Close Term'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runTermAction(() async {
      await _committeeTermRequest('close_committee_term_authenticated', {
        'term_id': term['id'],
        'expected_updated_at': term['updated_at'],
      });
    }, 'Committee term closed and moved to Archived Records.');
  }

  Future<void> _restoreCommitteeTerm(Map<String, dynamic> term) async {
    if (_saving || !_canRestoreTerm(term)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore Committee Term'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Term: ${term['term_name']}'),
              const SizedBox(height: 12),
              const Text(
                'Restore this term without changing its original effective '
                'dates or historical membership records. If its dates have expired '
                'or a successor overlaps, it returns as Restored history, not as '
                'a second current term.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore Term'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runTermAction(() async {
      await _committeeTermRequest('restore_committee_term_authenticated', {
        'term_id': term['id'],
        'expected_updated_at': term['updated_at'],
      });
    }, 'Committee term restored. Original dates are preserved.');
  }

  bool _termCanBeDeletedPermanently(Map<String, dynamic> term) {
    if (_termIsArchived(term) || _termStatus(term) == 'Restored') {
      return false;
    }
    final start = _parseMonth(term['effective_from']);
    final until = _parseMonth(term['effective_until']);
    // The database also rejects deletion of records used in completed reports.
    return start != null &&
        (until == null || !until.isBefore(_committeeCurrentMonth));
  }

  Future<void> _deleteCommitteeTerm(Map<String, dynamic> term) async {
    if (_saving ||
        !_permissions.canDelete ||
        !_termCanBeDeletedPermanently(term)) {
      return;
    }
    final termId = term['id']?.toString();
    final timestamp = term['updated_at']?.toString();
    if (termId == null ||
        termId.isEmpty ||
        timestamp == null ||
        timestamp.isEmpty) {
      setState(
        () => _saveError = 'Term details are incomplete. Refresh and retry.',
      );
      return;
    }
    final memberVersionCount = _committeeHistory
        .where((member) => member['term_id']?.toString() == termId)
        .length;
    final termName = term['term_name']?.toString() ?? 'Committee Term';
    final confirmationController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: const Text('Delete Committee Term Permanently?'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Term: $termName'),
                const SizedBox(height: 12),
                Text(
                  'This permanently deletes the term and all '
                  '$memberVersionCount associated committee membership '
                  'record(s). Historical monthly reports and PDF exports '
                  'will no longer include these records when regenerated. '
                  'This cannot be undone.',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: confirmationController,
                  decoration: const InputDecoration(
                    labelText: 'Type the term name to confirm',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => refresh(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton.icon(
              onPressed: confirmationController.text.trim() == termName.trim()
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete'),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
            ),
          ],
        ),
      ),
    );
    confirmationController.dispose();
    if (confirmed != true || !mounted) return;
    await _runTermAction(() async {
      await _committeeTermRequest('delete_committee_term_authenticated', {
        'term_id': termId,
        'expected_updated_at': timestamp,
      });
    }, 'Committee term and its membership records permanently deleted.');
  }

  // A finished term is historical, not deleted. Its dates remain unchanged.
  // The backend determines the governing term for a shared report month.

  Widget _committeeTermCard(
    Map<String, dynamic> term, {
    required bool expanded,
    bool archived = false,
  }) {
    final status = _termStatus(term);
    final statusColor = status == 'Current'
        ? const Color(0xFF22683D)
        : (status == 'Closed' || status == 'Review Dates')
        ? AppColors.red
        : AppColors.grey;
    final start = _parseMonth(term['effective_from']);
    final until = _parseMonth(term['effective_until']);
    final termId = term['id']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        key: PageStorageKey(
          'committee-term-$termId-${archived ? 'closed' : 'open'}',
        ),
        initiallyExpanded: expanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
        title: Text(
          term['term_name']?.toString() ?? 'Committee Term',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '${_showMonth(start)} - ${_showMonth(until)}',
            style: const TextStyle(color: AppColors.grey, fontSize: 12),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: status == 'Upcoming'
                    ? AppColors.white
                    : statusColor.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                status,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.expand_more),
          ],
        ),
        children: [
          if (term['needs_date_review'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'The original term dates have not yet been confirmed. '
                'Use Edit Term to verify them before creating the next term.',
                style: TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            ),
          if (archived)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                'Original effective dates and membership records are preserved. '
                'In a shared handover month, the successor takes priority in monthly reports.',
                style: const TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            ),
          if (archived && _permissions.canEdit)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message: _canRestoreTerm(term)
                      ? 'Restore this committee term'
                      : 'Restore requires permission and confirmed term dates.',
                  child: TextButton.icon(
                    onPressed: _saving || !_canRestoreTerm(term)
                        ? null
                        : () => _restoreCommitteeTerm(term),
                    icon: const Icon(Icons.restore_outlined, size: 18),
                    label: const Text('Restore'),
                  ),
                ),
              ),
            ),
          if (!archived &&
              (_permissions.canEdit ||
                  (_permissions.canDelete &&
                      _termCanBeDeletedPermanently(term))))
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (_permissions.canEdit)
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _editCommitteeTerm(term),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit'),
                      ),
                    if (_permissions.canEdit &&
                        (_termIsEffective(term) || _termStatus(term) == 'Restored'))
                      Tooltip(
                        message: _canCloseTerm(term)
                            ? 'Close committee term'
                            : 'Close is currently unavailable.',
                        child: TextButton.icon(
                          onPressed: _saving || !_canCloseTerm(term)
                              ? null
                              : () => _closeCommitteeTerm(term),
                          icon: const Icon(Icons.archive_outlined, size: 18),
                          label: const Text('Close'),
                        ),
                      ),
                    if (_permissions.canDelete &&
                        _termCanBeDeletedPermanently(term))
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _deleteCommitteeTerm(term),
                        icon: const Icon(
                          Icons.delete_forever_outlined,
                          size: 18,
                        ),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 20),
          ..._committeeHistoryWidgets(term, readOnlyTerm: archived),
        ],
      ),
    );
  }

  List<Widget> _committeeTermWidgets() {
    final review = _committeeTerms
        .where((term) => _termStatus(term) == 'Review Dates')
        .toList();
    final current = _committeeTerms.where(_termIsEffective).toList();
    final upcoming = _committeeTerms
        .where((term) => _termStatus(term) == 'Upcoming')
        .toList();
    final archived = _committeeTerms.where(_termIsArchived).toList()
      ..sort((a, b) {
        final byEnd = (b['effective_until']?.toString() ?? '').compareTo(
          a['effective_until']?.toString() ?? '',
        );
        if (byEnd != 0) return byEnd;
        return (b['effective_from']?.toString() ?? '').compareTo(
          a['effective_from']?.toString() ?? '',
        );
      });

    final items = <Widget>[
      if (_permissions.canAdd)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _createCommitteeTerm,
              icon: const Icon(Icons.add),
              label: const Text('Create New Term'),
            ),
          ),
        ),
    ];
    if (_committeeTerms.isEmpty) {
      items.add(const Text('No committee terms have been recorded.'));
      return items;
    }

    if (current.isEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'No current committee term in ${_showMonth(_committeeCurrentMonth)}.',
          ),
        ),
      );
    }
    for (final term in current) {
      items.add(_committeeTermCard(term, expanded: true));
    }

    final restored = _committeeTerms
        .where((term) => _termStatus(term) == 'Restored')
        .toList();

    for (final term in restored) {
      items.add(_committeeTermCard(term, expanded: false));
    }

    if (upcoming.isNotEmpty) {
      items.add(
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 12),
          child: Text(
            'Upcoming Committee Terms',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
      );
      for (final term in upcoming) {
        items.add(_committeeTermCard(term, expanded: false));
      }
    }
    if (review.isNotEmpty) {
      items.add(
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 12),
          child: Text(
            'Committee Terms Requiring Date Review',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
      );
      for (final term in review) {
        items.add(_committeeTermCard(term, expanded: false));
      }
    }
    final archivedMembers = _committeeHistory
        .where(_memberArchivedInView)
        .toList();
    archivedMembers.sort((a, b) {
      final ac = DateTime.tryParse(a['created_at']?.toString() ?? '');
      final bc = DateTime.tryParse(b['created_at']?.toString() ?? '');
      if (ac != null && bc != null) return ac.compareTo(bc);
      return (a['member_name']?.toString() ?? '').compareTo(
        b['member_name']?.toString() ?? '',
      );
    });
    if (archived.isNotEmpty || archivedMembers.isNotEmpty) {
      items.add(
        const Padding(
          padding: EdgeInsets.only(top: 16, bottom: 12),
          child: Row(
            children: [
              Icon(Icons.archive_outlined, size: 19, color: AppColors.grey),
              SizedBox(width: 8),
              Text(
                'Archived Records',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
      for (final term in archived) {
        items.add(_committeeTermCard(term, expanded: false, archived: true));
      }
      if (archivedMembers.isNotEmpty) {
        items.add(
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 10),
            child: Text(
              'Archived Committee Members',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        );
        for (var i = 0; i < archivedMembers.length; i++) {
          items.add(
            _committeeHistoryCard(
              archivedMembers[i],
              i,
              active: false,
              readOnly: true,
              archivedMember: true,
            ),
          );
        }
      }
    }
    return items;
  }

  // ---------------------------------------------------------------------------
  // DATED COMMITTEE ACTIONS
  // ---------------------------------------------------------------------------

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

  DateTime? _parseMonth(dynamic raw) {
    final date = raw == null ? null : DateTime.tryParse(raw.toString());
    return date == null ? null : DateTime(date.year, date.month);
  }

  String _showMonth(DateTime? date) =>
      date == null ? 'Not set' : '${_monthNames[date.month - 1]} ${date.year}';

  bool _isCurrentMember(Map<String, dynamic> member) =>
      _isMemberEffectiveInMonth(member, _committeeCurrentMonth);

  bool _isMemberEffectiveInMonth(Map<String, dynamic> member, DateTime month) {
    final start = _parseMonth(member['effective_from']);
    // removed_from is the FIRST inactive month, so the month before it
    // (Effective Until) is still part of the member's active period.
    final removed = _parseMonth(member['removed_from']);
    final effectiveUntil = removed == null
        ? null
        : DateTime(removed.year, removed.month - 1);
    return start != null &&
        !month.isBefore(start) &&
        (effectiveUntil == null || !month.isAfter(effectiveUntil));
  }

  Map<String, dynamic> _committeeDraftFor(Map<String, dynamic> member) {
    final id = member['id'].toString();
    return _committeeDraftEdits.putIfAbsent(
      id,
      () => <String, dynamic>{
        'name': member['member_name']?.toString() ?? '',
        'designation': member['designation']?.toString() ?? '',
        'start': _parseMonth(member['effective_from']),
        'removed': _parseMonth(member['removed_from']),
      },
    );
  }

  bool _sameCommitteeMonth(DateTime? a, DateTime? b) =>
      (a == null && b == null) ||
      (a != null && b != null && a.year == b.year && a.month == b.month);

  bool _committeeDraftChanged(Map<String, dynamic> member) {
    final draft = _committeeDraftEdits[member['id'].toString()];
    if (draft == null) return false;
    final start = draft['start'] as DateTime?;
    final removed = draft['removed'] as DateTime?;
    final originalStart = _parseMonth(member['effective_from']);
    final originalRemoved = _parseMonth(member['removed_from']);
    return (draft['name'] as String).trim() !=
            (member['member_name']?.toString() ?? '') ||
        (draft['designation'] as String).trim() !=
            (member['designation']?.toString() ?? '') ||
        !_sameCommitteeMonth(start, originalStart) ||
        !_sameCommitteeMonth(removed, originalRemoved);
  }

  /// Custom month/year picker avoids accidentally saving a random day.
  Future<DateTime?> _pickCommitteeMonth({
    required String title,
    required DateTime initial,
  }) {
    var year = initial.year.clamp(1950, 2100).toInt();
    var month = initial.month;
    return showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 340,
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<int>(
                    initialValue: month,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Month'),
                    items: List.generate(
                      12,
                      (i) => DropdownMenuItem<int>(
                        value: i + 1,
                        child: Text(_monthNames[i]),
                      ),
                    ),
                    onChanged: (value) {
                      if (value != null) refresh(() => month = value);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<int>(
                    initialValue: year,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Year'),
                    items: List.generate(
                      151,
                      (i) => DropdownMenuItem<int>(
                        value: i + 1950,
                        child: Text('${i + 1950}'),
                      ),
                    ),
                    onChanged: (value) {
                      if (value != null) refresh(() => year = value);
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, DateTime(year, month)),
              child: const Text('Select Month'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _memberEffectiveMonthButton({
    required String label,
    required String value,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.calendar_month_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.grey,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
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

  Future<void> _runCommitteeAction(
    Future<void> Function() operation,
    String successMessage,
  ) async {
    if (_saving) return;
    _successTimer?.cancel();
    setState(() {
      _saving = true;
      _saveError = null;
      _message = null;
    });
    var changeSaved = false;
    try {
      await operation();
      changeSaved = true;
      if (!mounted) return;
      // Only refresh committee history. Do not discard unsaved Property
      // Details, Billing Rates, or Committee Term edits elsewhere on the form.
      final history =
          await PropertySitesService.getCommitteeHistoryAuthenticated(
            siteId: widget.siteId,
          );
      if (!mounted) return;
      setState(() {
        final refreshedById = {
          for (final row in history)
            if (row['id'] != null) row['id'].toString(): row,
        };
        for (final old in _committeeHistory) {
          final id = old['id']?.toString();
          if (id == null) continue;
          final latest = refreshedById[id];
          if (latest == null || latest['updated_at'] != old['updated_at']) {
            _committeeDraftEdits.remove(id);
          }
        }
        _committeeHistory = history;
      });
      _showSuccess(successMessage);
    } on PropertyAccessDeniedException catch (e) {
      if (mounted) {
        setState(
          () => _saveError = changeSaved
              ? 'Membership saved, but the list could not refresh: ${e.message}'
              : e.message,
        );
      }
    } on AuthRequiredException catch (e) {
      if (mounted) {
        setState(
          () => _saveError = changeSaved
              ? 'Membership saved, but the list could not refresh: ${e.message}'
              : e.message,
        );
      }
    } catch (e) {
      if (mounted) {
        // Refresh after an ambiguous network failure so the visible list
        // reflects any committed membership operation.
        try {
          final latest =
              await PropertySitesService.getCommitteeHistoryAuthenticated(
                siteId: widget.siteId,
              );
          if (mounted) {
            setState(() {
              _committeeHistory = latest;
              _committeeDraftEdits.clear();
            });
          }
        } catch (_) {
          // Keep the original error; the user can use Refresh if needed.
        }
        if (mounted) {
          final detail = e.toString().replaceFirst('Exception: ', '');
          setState(
            () => _saveError = changeSaved
                ? 'Membership saved, but the list could not refresh: $detail'
                : detail,
          );
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addCommitteeMember(Map<String, dynamic> term) async {
    if (_saving ||
        !_permissions.canAdd ||
        _termIsArchived(term) ||
        term['needs_date_review'] == true) {
      return;
    }
    final termStart = _parseMonth(term['effective_from']);
    final termEnd = _parseMonth(term['effective_until']);
    if (termStart == null || termEnd == null) return;
    final formKey = GlobalKey<FormState>();
    var name = '';
    var designation = '';
    // Inherit both boundaries from the chosen term, not the report month.
    // The manager may still customize either boundary before saving.
    var startMonth = termStart;
    var untilMonth = termEnd;

    final draft = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) {
          final valid =
              !startMonth.isBefore(termStart) &&
              !untilMonth.isBefore(startMonth) &&
              !untilMonth.isAfter(termEnd);
          return AlertDialog(
            title: const Text('Add Committee Member'),
            content: SizedBox(
              width: 410,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        decoration: _decoration('Name', Icons.person_outline),
                        maxLength: 250,
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? 'Enter the name'
                            : null,
                        onChanged: (value) => name = value,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        decoration: _decoration(
                          'Designation',
                          Icons.badge_outlined,
                        ),
                        maxLength: 250,
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? 'Enter the designation'
                            : null,
                        onChanged: (value) => designation = value,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _memberEffectiveMonthButton(
                              label: 'Effective From',
                              value: _showMonth(startMonth),
                              onPressed: () async {
                                final selected = await _pickCommitteeMonth(
                                  title: 'Effective From',
                                  initial: startMonth,
                                );
                                if (selected != null && dialogContext.mounted) {
                                  refresh(() {
                                    startMonth = selected;
                                    if (untilMonth.isBefore(startMonth)) {
                                      untilMonth = startMonth;
                                    }
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _memberEffectiveMonthButton(
                              label: 'Effective Until',
                              value: _showMonth(untilMonth),
                              onPressed: () async {
                                final selected = await _pickCommitteeMonth(
                                  title: 'Effective Until',
                                  initial: untilMonth,
                                );
                                if (selected != null && dialogContext.mounted) {
                                  refresh(() => untilMonth = selected);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      if (!valid)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Member effective dates must fall within this term.',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                            ),
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
                onPressed: !valid
                    ? null
                    : () {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        Navigator.pop(dialogContext, {
                          'name': name.trim(),
                          'designation': designation.trim(),
                          'start': startMonth,
                          'until': untilMonth,
                        });
                      },
                child: const Text('Add Member'),
              ),
            ],
          );
        },
      ),
    );
    if (draft == null || !mounted) return;
    final effectiveFrom = draft['start'] as DateTime;
    final effectiveUntil = draft['until'] as DateTime;
    // Both dates are saved together; no follow-up edit or partial insert.
    await _runCommitteeAction(() async {
      await _committeeTermRequest('add_committee_member_authenticated', {
        'term_id': term['id'],
        'name': draft['name'],
        'designation': draft['designation'],
        'effective_from': _committeeMonthKey(effectiveFrom),
        'effective_until': _committeeMonthKey(effectiveUntil),
      });
    }, 'Committee member added to ${term['term_name']}.');
  }

  bool _memberParentIsClosed(Map<String, dynamic> member) {
    final terms = _committeeTerms.where(
      (term) => term['id']?.toString() == member['term_id']?.toString(),
    );
    return terms.isEmpty || _termIsArchived(terms.first);
  }

  bool _memberIsExplicitlyArchived(Map<String, dynamic> member) {
    final removed = _parseMonth(member['removed_from']);
    return _memberWasArchived(member) &&
        removed != null &&
        !_committeeCurrentMonth.isBefore(removed);
  }

  Future<void> _removeCommitteeMember(Map<String, dynamic> member) async {
    if (_saving ||
        !_permissions.canDelete ||
        _memberParentIsClosed(member) ||
        _memberIsExplicitlyArchived(member)) {
      return;
    }
    final start = _parseMonth(member['effective_from']);
    if (start == null) return;
    final originalRemoval = _parseMonth(member['removed_from']);
    final memberTerm = _committeeTerms.where(
      (term) => term['id']?.toString() == member['term_id']?.toString(),
    );
    final termEnd = memberTerm.isEmpty
        ? null
        : _parseMonth(memberTerm.first['effective_until']);
    final firstInactive = termEnd == null ? null : _nextMonth(termEnd);
    var removalMonth = originalRemoval ?? _committeeCurrentMonth;
    if (!removalMonth.isAfter(start)) {
      removalMonth = DateTime(start.year, start.month + 1);
    }
    var reason = '';
    final formKey = GlobalKey<FormState>();
    final name = member['member_name']?.toString() ?? 'this member';
    final decision = await showDialog<({DateTime from, String reason})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: Text(
            originalRemoval == null
                ? 'Remove $name'
                : 'Confirm removal month for $name',
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'The member will be archived from the selected '
                      'month. Earlier monthly reports remain unchanged.',
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_month_outlined),
                      label: Text('Remove From: ${_showMonth(removalMonth)}'),
                      onPressed: () async {
                        final selected = await _pickCommitteeMonth(
                          title: 'First month not shown',
                          initial: removalMonth,
                        );
                        if (selected != null && dialogContext.mounted) {
                          refresh(() => removalMonth = selected);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      decoration: _decoration(
                        'Reason for Removal',
                        Icons.notes_outlined,
                      ),
                      maxLength: 500,
                      maxLines: 3,
                      onChanged: (value) => reason = value,
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? 'Please enter a reason for removal'
                          : null,
                    ),
                    if (!removalMonth.isAfter(start) ||
                        (firstInactive != null &&
                            removalMonth.isAfter(firstInactive)))
                      Text(
                        'Removal must be after ${_showMonth(start)} and no later '
                        'than ${_showMonth(firstInactive)}.',
                        style: const TextStyle(
                          color: AppColors.red,
                          fontSize: 12,
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
              onPressed:
                  !removalMonth.isAfter(start) ||
                      (firstInactive != null &&
                          removalMonth.isAfter(firstInactive))
                  ? null
                  : () {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      Navigator.pop(dialogContext, (
                        from: removalMonth,
                        reason: reason.trim(),
                      ));
                    },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
    if (decision == null || !mounted) return;
    await _runCommitteeAction(
      () async {
        await _committeeTermRequest('remove_committee_member_authenticated', {
          'membership_id': member['id'].toString(),
          'removed_from': _committeeMonthKey(decision.from),
          'reason': decision.reason,
        });
      },
      '$name archived from ${_showMonth(decision.from)}. '
      'Earlier monthly reports remain intact.',
    );
  }

  Future<void> _editPreviousMember(Map<String, dynamic> member) async {
    if (_saving ||
        !_permissions.canEdit ||
        _memberParentIsClosed(member) ||
        _memberIsExplicitlyArchived(member)) {
      return;
    }
    final originalStart = _parseMonth(member['effective_from']);
    if (originalStart == null) return;
    final originalRemoval = _parseMonth(member['removed_from']);
    final memberTerm = _committeeTerms.where(
      (term) => term['id']?.toString() == member['term_id']?.toString(),
    );
    if (memberTerm.isEmpty) return;
    final termStart = _parseMonth(memberTerm.first['effective_from']);
    final termEnd = _parseMonth(memberTerm.first['effective_until']);
    final originalName = member['member_name']?.toString() ?? '';
    final originalDesignation = member['designation']?.toString() ?? '';
    final cardDraft = _committeeDraftFor(member);
    final expectedUpdatedAt = member['updated_at']?.toString() ?? '';
    if (expectedUpdatedAt.isEmpty) {
      setState(
        () => _saveError = 'Member timestamp missing. Reload and try again.',
      );
      return;
    }

    final formKey = GlobalKey<FormState>();
    var name = cardDraft['name'] as String;
    var designation = cardDraft['designation'] as String;
    var start = cardDraft['start'] as DateTime? ?? originalStart;
    final draftRemoval = cardDraft['removed'] as DateTime?;
    DateTime? lastActive = draftRemoval == null
        ? termEnd
        : DateTime(draftRemoval.year, draftRemoval.month - 1);
    var splitDetails = true;
    var splitMonth = DateTime(originalStart.year, originalStart.month + 1);

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) {
          final changedDetails =
              name.trim() != originalName ||
              designation.trim() != originalDesignation;
          final removedFrom = lastActive == null
              ? null
              : DateTime(lastActive!.year, lastActive!.month + 1);
          final changedDates =
              !start.isAtSameMomentAs(originalStart) ||
              (originalRemoval == null) != (removedFrom == null) ||
              (originalRemoval != null &&
                  removedFrom != null &&
                  !originalRemoval.isAtSameMomentAs(removedFrom));
          final validRange =
              (removedFrom == null || removedFrom.isAfter(start)) &&
              (termStart == null || !start.isBefore(termStart)) &&
              (termEnd == null ||
                  (lastActive != null && !lastActive!.isAfter(termEnd)));
          final splitValid =
              splitMonth.isAfter(originalStart) &&
              (originalRemoval == null ||
                  splitMonth.isBefore(originalRemoval)) &&
              (termStart == null || !splitMonth.isBefore(termStart)) &&
              (termEnd == null || !splitMonth.isAfter(termEnd));
          final splitConflict =
              changedDetails && splitDetails && (changedDates || !splitValid);
          final changed = changedDetails || changedDates;

          return AlertDialog(
            title: const Text('Edit Committee Member'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        initialValue: name,
                        decoration: _decoration(
                          'Member name',
                          Icons.person_outline,
                        ),
                        maxLength: 250,
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? 'Enter a member name'
                            : null,
                        onChanged: (value) => refresh(() => name = value),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: designation,
                        decoration: _decoration(
                          'Designation',
                          Icons.badge_outlined,
                        ),
                        maxLength: 250,
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? 'Enter a designation'
                            : null,
                        onChanged: (value) =>
                            refresh(() => designation = value),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _memberEffectiveMonthButton(
                              label: 'Effective From',
                              value: _showMonth(start),
                              onPressed: () async {
                                final month = await _pickCommitteeMonth(
                                  title: 'Effective From',
                                  initial: start,
                                );
                                if (month != null && dialogContext.mounted) {
                                  refresh(() => start = month);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _memberEffectiveMonthButton(
                              label: 'Effective Until',
                              value: lastActive == null
                                  ? 'Ongoing'
                                  : _showMonth(lastActive),
                              onPressed: () async {
                                final month = await _pickCommitteeMonth(
                                  title: 'Effective Until',
                                  initial: lastActive ?? termEnd ?? start,
                                );
                                if (month != null && dialogContext.mounted) {
                                  refresh(() => lastActive = month);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      if (termEnd == null && lastActive != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => refresh(() => lastActive = null),
                            child: const Text('Set Ongoing'),
                          ),
                        ),
                      if (!validRange)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Membership Effective From / Until must be inside '
                            'the committee term dates.',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (changedDetails) ...[
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: splitDetails,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            'Preserve earlier names and designations',
                          ),
                          subtitle: const Text(
                            'Create a new version from a chosen month. '
                            'Uncheck only to correct an existing historical record.',
                          ),
                          onChanged: (checked) =>
                              refresh(() => splitDetails = checked ?? false),
                        ),
                        if (splitDetails)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.edit_calendar_outlined),
                            label: Text(
                              'Change details from: ${_showMonth(splitMonth)}',
                            ),
                            onPressed: () async {
                              final month = await _pickCommitteeMonth(
                                title: 'First month with updated details',
                                initial: splitMonth,
                              );
                              if (month != null && dialogContext.mounted) {
                                refresh(() => splitMonth = month);
                              }
                            },
                          ),
                        if (splitConflict)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'To preserve earlier months, keep the existing period '
                              'dates and choose a change month strictly inside it. '
                              'Alternatively uncheck preservation to correct this record.',
                              style: TextStyle(
                                color: AppColors.red,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        if (!splitDetails)
                          const Text(
                            'Correction: changed details will apply to this entire '
                            'recorded period, including earlier reports.',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                            ),
                          ),
                      ],
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
                onPressed: !changed || !validRange || splitConflict
                    ? null
                    : () {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        Navigator.pop(dialogContext, <String, dynamic>{
                          'name': name.trim(),
                          'designation': designation.trim(),
                          'start': start,
                          'removed': removedFrom,
                          'split': changedDetails && splitDetails
                              ? splitMonth
                              : null,
                        });
                      },
                child: const Text('Save Changes'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    final split = result['split'] as DateTime?;
    await _runCommitteeAction(
      () => PropertySitesService.editCommitteeMemberAuthenticated(
        siteId: widget.siteId,
        membershipId: member['id'].toString(),
        name: result['name'] as String,
        designation: result['designation'] as String,
        effectiveFrom: result['start'] as DateTime,
        removedFrom: result['removed'] as DateTime?,
        splitFrom: split,
        expectedUpdatedAt: expectedUpdatedAt,
      ),
      split == null
          ? 'Committee membership corrected.'
          : 'New membership version effective ${_showMonth(split)}. Earlier months are preserved.',
    );
  }

  Future<void> _deleteCommitteeMemberVersion(
    Map<String, dynamic> member,
  ) async {
    if (_saving ||
        !_permissions.canDelete ||
        _memberParentIsClosed(member) ||
        _memberIsExplicitlyArchived(member)) {
      return;
    }
    final membershipId = member['id']?.toString();
    final timestamp = member['updated_at']?.toString();
    if (membershipId == null ||
        membershipId.isEmpty ||
        timestamp == null ||
        timestamp.isEmpty) {
      setState(
        () => _saveError = 'Member details are incomplete. Refresh and retry.',
      );
      return;
    }
    final name = member['member_name']?.toString() ?? 'this member';
    final start = _showMonth(_parseMonth(member['effective_from']));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Member Record Permanently?'),
        content: Text(
          'Permanently delete the $start membership record for $name? '
          'Other membership versions will remain, but this record will '
          'disappear from historical monthly reports and cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete'),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runCommitteeAction(() async {
      await _committeeTermRequest(
        'delete_committee_membership_version_authenticated',
        {'membership_id': membershipId, 'expected_updated_at': timestamp},
      );
    }, 'Committee member record permanently deleted.');
  }

  String? _restoreUnavailableReason(Map<String, dynamic> member) {
    final removal = _parseMonth(member['removed_from']);
    final start = _parseMonth(member['effective_from']);
    final memberId = member['member_id']?.toString();
    if (removal == null || memberId == null || start == null) {
      return 'This membership does not have a completed historical period to restore.';
    }
    final newer =
        _committeeHistory
            .where(
              (other) =>
                  other['member_id']?.toString() == memberId &&
                  other['id']?.toString() != member['id']?.toString() &&
                  (_parseMonth(other['effective_from'])?.isAfter(start) ??
                      false),
            )
            .toList()
          ..sort(
            (a, b) => (a['effective_from']?.toString() ?? '').compareTo(
              b['effective_from']?.toString() ?? '',
            ),
          );
    if (newer.isNotEmpty) {
      final latest = newer.last;
      return 'A newer membership (${latest['designation'] ?? 'member'}) '
          'already exists from ${_showMonth(_parseMonth(latest['effective_from']))}. '
          'Edit that record instead of restoring this earlier version.';
    }
    if (removal.isAfter(_committeeCurrentMonth)) {
      return 'This membership has not ended yet.';
    }
    final originalTerm = _committeeTerms.where(
      (term) => term['id']?.toString() == member['term_id']?.toString(),
    );
    if (originalTerm.isEmpty || !_termIsEffective(originalTerm.first)) {
      return 'The original committee term is not currently effective. '
          'Restore the term first if eligible, or create a new membership.';
    }
    return null;
  }

  bool _canRestoreMember(Map<String, dynamic> member) =>
      _restoreUnavailableReason(member) == null;

  Future<void> _restoreCommitteeMember(Map<String, dynamic> member) async {
    if (_saving || !_permissions.canAdd) return;
    final unavailable = _restoreUnavailableReason(member);
    if (unavailable != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(unavailable),
          backgroundColor: AppColors.charcoal,
        ),
      );
      return;
    }
    final removed = _parseMonth(member['removed_from']);
    if (removed == null) return;
    var restoreMonth = _committeeCurrentMonth.isAfter(removed)
        ? _committeeCurrentMonth
        : removed;
    final term = _committeeTerms.firstWhere(
      (term) => term['id']?.toString() == member['term_id']?.toString(),
    );
    final termEnd = _parseMonth(term['effective_until']);
    final name = member['member_name']?.toString() ?? 'Member';
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: Text('Restore $name'),
          content: SizedBox(
            width: 410,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Restoring creates a new membership period. '
                  'Months when this person was previously absent will stay unchanged.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text('Effective From: ${_showMonth(restoreMonth)}'),
                  onPressed: () async {
                    final month = await _pickCommitteeMonth(
                      title: 'Restoration month',
                      initial: restoreMonth,
                    );
                    if (month != null && dialogContext.mounted) {
                      refresh(() => restoreMonth = month);
                    }
                  },
                ),
                if (restoreMonth.isBefore(removed) ||
                    (termEnd != null && restoreMonth.isAfter(termEnd)))
                  Text(
                    'Restoration must be on or after ${_showMonth(removed)} '
                    'and within the original committee term.',
                    style: const TextStyle(color: AppColors.red, fontSize: 12),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  restoreMonth.isBefore(removed) ||
                      (termEnd != null && restoreMonth.isAfter(termEnd))
                  ? null
                  : () => Navigator.pop(dialogContext, restoreMonth),
              child: const Text('Restore Member'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _runCommitteeAction(
      () => PropertySitesService.restoreCommitteeMemberAuthenticated(
        siteId: widget.siteId,
        membershipId: member['id'].toString(),
        effectiveFrom: selected,
      ),
      '$name restored from ${_showMonth(selected)}. Earlier months are preserved.',
    );
  }

  Widget _committeeDateBox(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.grey, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(color: AppColors.black, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _committeeReadOnlyField(String label, String value, IconData icon) {
    return InputDecorator(
      decoration: _decoration(label, icon),
      isEmpty: value.isEmpty,
      child: Text(
        value,
        style: const TextStyle(color: AppColors.black, fontSize: 16),
      ),
    );
  }

  Widget _committeeHistoryCard(
    Map<String, dynamic> member,
    int index, {
    required bool active,
    bool readOnly = false,
    bool archivedMember = false,
  }) {
    final draft = _committeeDraftFor(member);
    final name = draft['name'] as String;
    final designation = draft['designation'] as String;
    final start = draft['start'] as DateTime?;
    final removed = draft['removed'] as DateTime?;
    final lastActive = removed == null
        ? null
        : DateTime(removed.year, removed.month - 1);
    final memberId = member['id'].toString();

    return Container(
      key: ValueKey('committee-member-$memberId'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E5E5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Member ${index + 1}',
            style: const TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          _committeeReadOnlyField('Member name', name, Icons.person_outline),
          const SizedBox(height: 12),
          _committeeReadOnlyField(
            'Designation',
            designation,
            Icons.badge_outlined,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _committeeDateBox('Effective From', _showMonth(start)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _committeeDateBox(
                  'Effective Until',
                  lastActive == null ? 'Ongoing' : _showMonth(lastActive),
                ),
              ),
            ],
          ),
          if (archivedMember) ...[
            const SizedBox(height: 12),
            _committeeReadOnlyField(
              'Reason for Removal',
              member['removal_reason']?.toString() ?? '',
              Icons.notes_outlined,
            ),
            if (_permissions.canAdd)
              Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message:
                      _restoreUnavailableReason(member) ??
                      'Restore committee member',
                  child: OutlinedButton.icon(
                    onPressed: _saving || !_canRestoreMember(member)
                        ? null
                        : () => _restoreCommitteeMember(member),
                    icon: const Icon(Icons.restore_outlined, size: 18),
                    label: const Text('Restore'),
                  ),
                ),
              ),
          ],
          if (!readOnly &&
              !archivedMember &&
              (_permissions.canEdit || _permissions.canDelete))
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_permissions.canEdit)
                    IconButton(
                      tooltip: 'Edit committee member',
                      onPressed: _saving
                          ? null
                          : () => _editPreviousMember(member),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      icon: const Icon(
                        Icons.edit_outlined,
                        color: AppColors.red,
                        size: 20,
                      ),
                    ),
                  if (active && _permissions.canDelete)
                    IconButton(
                      tooltip: 'Remove committee member',
                      onPressed: _saving
                          ? null
                          : () => _removeCommitteeMember(member),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: AppColors.red,
                        size: 20,
                      ),
                    ),
                  if (!active && _permissions.canDelete)
                    IconButton(
                      tooltip: 'Delete this member record permanently',
                      onPressed: _saving
                          ? null
                          : () => _deleteCommitteeMemberVersion(member),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      icon: const Icon(
                        Icons.delete_forever_outlined,
                        color: AppColors.red,
                        size: 20,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _committeeHistoryWidgets(
    Map<String, dynamic> term, {
    bool readOnlyTerm = false,
  }) {
    final termId = term['id']?.toString();
    final members = _committeeHistory
        .where((member) => member['term_id']?.toString() == termId)
        .toList();

    // Keep each person's original position even if they have multiple dated
    // membership versions. A newly added person goes after older members,
    // regardless of their Effective From month or a duplicated display_order.
    // Rows imported together have the same created_at; use their original
    // display_order as the tie-breaker to preserve the existing list order.
    final firstCreatedByMember = <String, DateTime>{};
    for (final member in members) {
      final identity =
          member['member_id']?.toString() ?? member['id']?.toString() ?? '';
      final created = DateTime.tryParse(member['created_at']?.toString() ?? '');
      if (created == null) continue;
      final earliest = firstCreatedByMember[identity];
      if (earliest == null || created.isBefore(earliest)) {
        firstCreatedByMember[identity] = created;
      }
    }
    members.sort((a, b) {
      final aIdentity = a['member_id']?.toString() ?? a['id']?.toString() ?? '';
      final bIdentity = b['member_id']?.toString() ?? b['id']?.toString() ?? '';
      final aCreated = firstCreatedByMember[aIdentity];
      final bCreated = firstCreatedByMember[bIdentity];
      if (aCreated != null && bCreated != null) {
        final compared = aCreated.compareTo(bCreated);
        if (compared != 0) return compared;
      } else if (aCreated != null) {
        return -1;
      } else if (bCreated != null) {
        return 1;
      }
      final aOrder = int.tryParse(a['display_order']?.toString() ?? '') ?? 0;
      final bOrder = int.tryParse(b['display_order']?.toString() ?? '') ?? 0;
      if (aOrder != bOrder) return aOrder.compareTo(bOrder);
      final byIdentity = aIdentity.compareTo(bIdentity);
      if (byIdentity != 0) return byIdentity;
      return (a['effective_from']?.toString() ?? '').compareTo(
        b['effective_from']?.toString() ?? '',
      );
    });

    final viewingThisTerm = _termIsEffective(term);
    final termStart = _parseMonth(term['effective_from']);
    final isUpcoming = _termStatus(term) == 'Upcoming';
    final active = members.where(_isCurrentMember).toList();

    // Archived terms are fully read-only, including their member cards.
    // Show the full recorded list there even though no member is current now.
    if (readOnlyTerm) {
      return [
        if (members.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('No committee members were recorded for this term.'),
          ),
        ...List.generate(
          members.length,
          (i) => _committeeHistoryCard(
            members[i],
            i,
            active: false,
            readOnly: true,
          ),
        ),
      ];
    }

    // Upcoming terms can be prepared ahead of their effective date.
    // Their members must not appear as current in earlier report months.
    final visible = viewingThisTerm
        ? active
        : ((isUpcoming || _termStatus(term) == 'Restored')
            ? members
            : <Map<String, dynamic>>[]);
    final other = members.where((member) {
      if (visible.contains(member)) return false;
      // Keep restored historical periods available under their term, but do
      // not duplicate individually archived members in two sections.
      return !_memberArchivedInView(member);
    }).toList();
    return [
      if (members.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('No committee members have been recorded for this term.'),
        ),
      if (viewingThisTerm && members.isNotEmpty && active.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('No committee members for the current month.'),
        ),
      ...List.generate(
        visible.length,
        (i) => _committeeHistoryCard(
          visible[i],
          i,
          active: viewingThisTerm,
          readOnly: _memberIsExplicitlyArchived(visible[i]) ||
              _termStatus(term) == 'Restored',
        ),
      ),
      if (_permissions.canAdd &&
          _termStatus(term) != 'Restored' &&
          term['needs_date_review'] != true &&
          termStart != null && _parseMonth(term['effective_until']) != null)
        OutlinedButton.icon(
          onPressed: _saving ? null : () => _addCommitteeMember(term),
          icon: const Icon(Icons.add),
          label: const Text('Add Committee Member'),
        ),
      if (other.isNotEmpty) ...[
        const SizedBox(height: 12),
        ExpansionTile(
          key: PageStorageKey('committee-term-members-$termId'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            viewingThisTerm
                ? 'Previous / Upcoming Members (${other.length})'
                : 'Recorded Members (${other.length})',
          ),
          children: List.generate(other.length, (i) {
            final member = other[i];
            final memberStart = _parseMonth(member['effective_from']);
            final future =
                memberStart != null &&
                memberStart.isAfter(_committeeCurrentMonth);
            return _committeeHistoryCard(
              member,
              visible.length + i,
              active: false,
              // Permit corrections to unconfirmed imported appointments.
              // Confirmed historical versions remain read-only.
              readOnly:
                  _memberIsExplicitlyArchived(member) ||
                  (!future && _termStatus(term) != 'Review Dates'),
            );
          }),
        ),
      ],
    ];
  }

  // ---------------------------------------------------------------------------
  // UI helpers
  // ---------------------------------------------------------------------------

  OutlineInputBorder _border({
    Color color = AppColors.border,
    double width = 1,
  }) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  InputDecoration _decoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: AppColors.red, size: 20),
      filled: true,
      fillColor: AppColors.white,
      labelStyle: const TextStyle(color: AppColors.grey, fontSize: 14),
      floatingLabelStyle: const TextStyle(color: AppColors.red),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: _border(),
      enabledBorder: _border(),
      focusedBorder: _border(color: AppColors.red, width: 1.5),
      errorBorder: _border(color: AppColors.red),
      focusedErrorBorder: _border(color: AppColors.red, width: 1.5),
    );
  }

  // Fields containing saved values require Edit to modify or Delete to
  // clear. Empty fields require Add. Total Units can only be edited.
  bool _canEditText(String key) {
    if (_saving || !_permissions.canView) return false;
    if (key == 'total_units') return _permissions.canEdit;
    final original = _originalInfo[key]?.toString().trim() ?? '';
    return original.isEmpty ? _permissions.canAdd : _permissions.canEdit;
  }

  bool _canClearText(String key) {
    if (_saving || !_permissions.canDelete || key == 'total_units') {
      return false;
    }
    return (_originalInfo[key]?.toString().trim() ?? '').isNotEmpty;
  }

  Widget _textField(
    String key,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    final canType = _canEditText(key);
    final canClear = _canClearText(key);
    return TextFormField(
      controller: _controllers[key],
      readOnly: !canType,
      keyboardType: keyboardType,
      maxLines: maxLines,
      inputFormatters: inputFormatters,
      decoration: _decoration(label, icon).copyWith(
        suffixIcon: canClear && !canType
            ? IconButton(
                tooltip: 'Clear $label',
                icon: const Icon(Icons.clear, color: AppColors.red),
                onPressed: () => setState(() {
                  _controllers[key]!.clear();
                  _message = null;
                }),
              )
            : null,
      ),
      validator: validator,
      onChanged: (_) {
        if (_message != null) setState(() => _message = null);
      },
    );
  }

  Widget _frequencyField({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final key = label.startsWith('Service')
        ? 'service_billing_frequency'
        : 'fund_billing_frequency';
    final saved = _originalInfo[key]?.toString().trim() ?? '';
    final canSelect =
        !_saving &&
        _permissions.canView &&
        (saved.isEmpty ? _permissions.canAdd : _permissions.canEdit);
    final canClear = !_saving && _permissions.canDelete && saved.isNotEmpty;
    final options = <String>[
      if (canClear || value.isEmpty) '',
      if (canSelect) ..._frequencies,
      if (!canSelect && value.isNotEmpty) value,
      if (canSelect && value.isNotEmpty && !_frequencies.contains(value)) value,
    ];

    return DropdownButtonFormField<String>(
      key: ValueKey('frequency-$key-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: _decoration(label, Icons.calendar_month_outlined),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option,
            child: Text(option.isEmpty ? 'Not set' : option),
          ),
      ],
      onChanged: canSelect || canClear
          ? (selected) {
              if (selected != null) {
                onChanged(selected);
                if (_message != null) setState(() => _message = null);
              }
            }
          : null,
    );
  }

  Widget _fieldGrid(List<Widget> fields) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 2 : 1;
        const spacing = 16.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: 16,
          children: [
            for (final field in fields) SizedBox(width: width, child: field),
          ],
        );
      },
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String description,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(22),
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.red, size: 23),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppColors.black,
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.grey,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }

  Widget _statusMessage({
    required IconData icon,
    required String message,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
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
            'SITE PROFILE',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Site Profile',
            style: const TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_showMonth(_viewMonth)} • Report ID: ${_resolvedReportId ?? 'Not available'}',
            style: TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.red),
      );
    }

    if (_accessDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _statusMessage(
            icon: Icons.lock_outline,
            message: 'You do not have Site Profile access to this property.',
            color: AppColors.red,
          ),
        ),
      );
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _statusMessage(
                icon: Icons.error_outline,
                message: 'Could not load the Site Profile: $_loadError',
                color: AppColors.red,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    return Form(
      key: _formKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pagePadding = constraints.maxWidth >= 900 ? 28.0 : 16.0;

          return ListView(
            padding: EdgeInsets.all(pagePadding),
            children: [
              _header(),
              if (!_permissions.canSave) ...[
                const SizedBox(height: 12),
                _statusMessage(
                  icon: Icons.visibility_outlined,
                  message:
                      'View-only access. You can read this Site Profile '
                      'but cannot add, edit, or delete its information.',
                  color: AppColors.grey,
                ),
              ],
              const SizedBox(height: 24),

              _sectionCard(
                icon: Icons.apartment_outlined,
                title: 'Property Details',
                description:
                    'Fixed information about the property. Save once and '
                    'update only when it changes.',
                children: [
                  _textField(
                    'total_units',
                    'Total Units',
                    Icons.domain_outlined,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) {
                      final units = int.tryParse((value ?? '').trim());
                      if (units == null || units <= 0) {
                        return 'Enter a whole number greater than zero';
                      }
                      return null;
                    },
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 8, bottom: 16),
                    child: Text(
                      _totalUnitsHelp,
                      style: TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                  _textField(
                    'registration_address',
                    'Registration Address',
                    Icons.location_on_outlined,
                    maxLines: 3,
                    validator: (value) {
                      if ((value ?? '').trim().isNotEmpty) return null;
                      final wasSet =
                          (_originalInfo['registration_address']
                                      ?.toString()
                                      .trim() ??
                                  '')
                              .isNotEmpty;
                      if (wasSet && _permissions.canDelete) return null;
                      return 'Registration Address is required';
                    },
                  ),
                  const SizedBox(height: 16),
                  _fieldGrid([
                    _textField(
                      'email',
                      'Email Address',
                      Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        final email = (value ?? '').trim();
                        if (email.isEmpty) return null;
                        return RegExp(
                              r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                            ).hasMatch(email)
                            ? null
                            : 'Enter a valid email address';
                      },
                    ),
                    _textField(
                      'contact_number',
                      'Contact Number',
                      Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                    ),
                  ]),
                ],
              ),

              const SizedBox(height: 20),

              _sectionCard(
                icon: Icons.payments_outlined,
                title: 'Billing Rates',
                description:
                    'Approved rates and billing figures. They stay the same '
                    'until deliberately changed.',
                children: [
                  _fieldGrid([
                    _textField(
                      'service_charge_per_share_unit',
                      'Service Charge per Share Unit (RM)',
                      Icons.payments_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    _textField(
                      'service_charge_per_sqft',
                      'Service Charge per Square Foot (RM)',
                      Icons.square_foot_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    _textField(
                      'sinking_fund_per_share_unit',
                      'Sinking Fund per Share Unit (RM)',
                      Icons.savings_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    _textField(
                      'sinking_fund_per_sqft',
                      'Sinking Fund per Square Foot (RM)',
                      Icons.square_foot_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    _frequencyField(
                      label: 'Service Charge Billing Frequency',
                      value: _serviceFrequency,
                      onChanged: (value) => setState(() {
                        _serviceFrequency = value;
                        _serviceFrequencyTouched = true;
                      }),
                    ),
                    _frequencyField(
                      label: 'Sinking Fund Billing Frequency',
                      value: _fundFrequency,
                      onChanged: (value) => setState(() {
                        _fundFrequency = value;
                        _fundFrequencyTouched = true;
                      }),
                    ),
                    _textField(
                      'total_monthly_billing',
                      'Total Monthly Billing (RM)',
                      Icons.receipt_long_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    _textField(
                      'total_aggregate_share_unit',
                      'Total Aggregate Share Unit',
                      Icons.numbers_outlined,
                      keyboardType: TextInputType.number,
                    ),
                    _textField(
                      'annual_billing',
                      'Annual Billing (RM)',
                      Icons.account_balance_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ]),
                ],
              ),

              const SizedBox(height: 20),

              _sectionCard(
                icon: Icons.groups_outlined,
                title: 'Management Committee',
                description: '',
                children: [..._committeeTermWidgets()],
              ),

              const SizedBox(height: 20),

              if (_saveError != null) ...[
                _statusMessage(
                  icon: Icons.error_outline,
                  message: _saveError!,
                  color: AppColors.red,
                ),
                const SizedBox(height: 12),
              ],

              if (_message != null) ...[
                _statusMessage(
                  icon: Icons.check_circle_outline,
                  message: _message!,
                  color: const Color(0xFF22683D),
                ),
                const SizedBox(height: 12),
              ],

              if (_permissions.canSave)
                Align(
                  alignment: Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 220,
                      maxWidth: 320,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.red,
                          foregroundColor: AppColors.white,
                          disabledBackgroundColor: AppColors.grey,
                          disabledForegroundColor: AppColors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.white,
                                ),
                              )
                            : const Icon(Icons.save_outlined),
                        label: Text(
                          _saving ? 'Saving...' : 'Save Site Profile',
                        ),
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppCommonAppBar(title: 'Site Profile', onRefresh: _load),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: _body(),
        ),
      ),
    );
  }
}