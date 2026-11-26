import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class InsuranceClaimsPage extends StatefulWidget {
  // Pass the selected monthly report for the correct month and Report ID.
  // Optional to preserve existing navigation that constructs this page.
  final Map<String, dynamic>? report;

  const InsuranceClaimsPage({super.key, this.report});

  @override
  State<InsuranceClaimsPage> createState() => _InsuranceClaimsPageState();
}

class _InsuranceClaimsPageState extends State<InsuranceClaimsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  static const List<String> _statuses = [
    'Submitted',
    'Under Review',
    'Approved',
    'Rejected',
    'Paid',
    'Closed',
  ];

  List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _archivedRecords = [];
  List<Map<String, dynamic>> _policies = [];

  bool _loading = true;
  bool _saving = false;

  String? _error;
  String? _policyError;
  final Set<String> _selectedStatuses = <String>{};

  DateTime get _selectedReportMonth {
    final raw = widget.report?['report_month'] ?? widget.report?['month'];
    DateTime? date;
    if (raw is DateTime) {
      date = raw;
    } else if (raw != null) {
      date = DateTime.tryParse(raw.toString());
    }
    date ??= DateTime.now();
    return DateTime(date.year, date.month, 1);
  }

  String get _selectedReportId =>
      widget.report?['id']?.toString() ?? 'Not provided';

  // Use the selected monthly report as the source of truth for the property.
  Future<String> _selectedPropertyId() async {
    final reportId = widget.report?['id']?.toString().trim() ?? '';

    if (reportId.isNotEmpty) {
      final report = await _supabase
          .from('monthly_reports')
          .select('site_id')
          .eq('id', reportId)
          .maybeSingle();

      final siteId = report?['site_id']?.toString().trim() ?? '';
      if (siteId.isEmpty) {
        throw StateError('The selected monthly report has no property assigned.');
      }
      final passedSiteId = widget.report?['site_id']?.toString().trim() ?? '';
      if (passedSiteId.isNotEmpty && passedSiteId != siteId) {
        throw StateError('The selected property does not match this report.');
      }
      return siteId;
    }

    // Supports existing navigation that passes a property without a report ID.
    final siteId = widget.report?['site_id']?.toString().trim() ?? '';
    if (siteId.isNotEmpty) return siteId;

    throw StateError('Open Insurance Claims from a selected property report.');
  }

  static DateTime _firstOfMonth(DateTime date) =>
      DateTime(date.year, date.month, 1);

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

  static String _monthHeading(DateTime date) =>
      '${_monthNames[date.month - 1]} ${date.year}';

  // Submission Date starts the claim; Incident Date is the legacy fallback.
  DateTime? _claimStartDate(Map<String, dynamic> record) {
    final source = _sourceRecord(record);
    return _parseDate(source['submitted_date']) ??
        _parseDate(source['incident_date']);
  }

  Map<String, dynamic> _sourceRecord(Map<String, dynamic> record) {
    final source = record['_source_record'];
    return source is Map<String, dynamic> ? source : record;
  }

  // Use the selected month's final day for past and future reports.
  // Only the current calendar month is limited to today's actual date.
  DateTime _claimMonthCutoff(DateTime month) {
    final lastDay = DateTime(month.year, month.month + 1, 0);
    final today = DateUtils.dateOnly(DateTime.now());
    return month.year == today.year && month.month == today.month
        ? today
        : lastDay;
  }

  // These events are written on status, paid-amount and approval changes.
  // Older months are snapshots rather than copies of the current claim row.
  Map<String, dynamic> _claimSnapshotAt(
    Map<String, dynamic> record,
    DateTime cutoff,
  ) {
    final source = _sourceRecord(record);
    final snapshot = Map<String, dynamic>.from(source);
    final rawEvents = source['status_history'];
    Map<String, dynamic>? latest;
    if (rawEvents is List) {
      for (final rawEvent in rawEvents) {
        if (rawEvent is! Map) continue;
        final event = Map<String, dynamic>.from(rawEvent);
        final date = _parseDate(event['date']);
        if (date == null || date.isAfter(cutoff)) continue;
        // Events are appended when changes are saved. A later correction
        // takes precedence even when its effective date was backdated.
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
    snapshot['_source_record'] = source;
    return snapshot;
  }

  // Keep the existing card presentation and status counts. The dated
  // status_history is used when evaluating whether closure had taken effect
  // in the selected reporting month.
  Map<String, dynamic> _claimSnapshotForSelectedMonth(
    Map<String, dynamic> record,
  ) => Map<String, dynamic>.from(_sourceRecord(record));

  static num? _amountFromRecord(Map<String, dynamic> record, String field) {
    return num.tryParse(record[field]?.toString() ?? '');
  }

  // Only a formally Closed claim is automatically archived, beginning the
  // calendar day AFTER its actual Closure Date. The status as-of the report
  // cutoff comes from status_history when dated events are available.
  DateTime? _automaticArchiveFrom(Map<String, dynamic> record) {
    final snapshot = _claimSnapshotAt(
      record,
      _claimMonthCutoff(_selectedReportMonth),
    );
    if (snapshot['status']?.toString() != 'Closed') return null;
    final closed = _parseDate(snapshot['closure_date']);
    if (closed == null) return null;
    return DateTime(closed.year, closed.month, closed.day + 1);
  }

  // Manual archive dates retain their original timestamps in Supabase.
  // A legacy manual archive with no timestamp stays archived with no
  // invented month.
  DateTime? _manualArchiveDate(Map<String, dynamic> record) {
    final source = _sourceRecord(record);
    if (source['is_archived'] != true) return null;
    final archivedAt = _parseDate(source['archived_at']);
    return archivedAt == null ? null : DateUtils.dateOnly(archivedAt.toLocal());
  }

  bool _manualArchiveAsOf(Map<String, dynamic> record) {
    if (_sourceRecord(record)['is_archived'] != true) return false;
    final date = _manualArchiveDate(record);
    return date == null ||
        !date.isAfter(_claimMonthCutoff(_selectedReportMonth));
  }

  // Use whichever dated archive reason took effect first. Manual archives
  // without a date are grouped as 'Date Not Set', never backdated.
  DateTime? _archiveEffectiveDate(Map<String, dynamic> record) {
    if (_manualArchiveAsOf(record) && _manualArchiveDate(record) == null) {
      return null;
    }
    final automatic = _automaticArchiveFrom(record);
    final manual = _manualArchiveAsOf(record)
        ? _manualArchiveDate(record)
        : null;
    if (manual == null) return automatic;
    if (automatic == null || manual.isBefore(automatic)) return manual;
    return automatic;
  }

  bool _isArchivedAsOf(Map<String, dynamic> record) {
    if (_manualArchiveAsOf(record)) return true;
    final date = _automaticArchiveFrom(record);
    return date != null &&
        !date.isAfter(_claimMonthCutoff(_selectedReportMonth));
  }

  // Claims not Closed or manually archived stay in This Month and carry
  // forward, including fully Paid and Rejected claims.
  bool _isThisMonth(Map<String, dynamic> record) {
    final start = _claimStartDate(record);
    final cutoff = _claimMonthCutoff(_selectedReportMonth);
    if (start == null || DateUtils.dateOnly(start).isAfter(cutoff)) {
      return false;
    }
    return !_isArchivedAsOf(record);
  }

  bool _isCarriedForward(Map<String, dynamic> record) {
    final start = _claimStartDate(record);
    return start != null &&
        _firstOfMonth(start).isBefore(_selectedReportMonth) &&
        _isThisMonth(record);
  }

  // Manually archived claims also need to be loaded here: they may still
  // have been active in an earlier selected reporting month.
  List<Map<String, dynamic>> get _allClaims =>
      [..._records, ..._archivedRecords];

  List<Map<String, dynamic>> get _thisMonthRecords => _allClaims
      .where(_isThisMonth)
      .map(_claimSnapshotForSelectedMonth)
      .toList();

  // The same filters apply to current and archived claims.
  bool _matchesFilters(Map<String, dynamic> record) {
    final status = record['status']?.toString() ?? 'Submitted';
    if (_selectedStatuses.isNotEmpty && !_selectedStatuses.contains(status)) {
      return false;
    }
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final searchable = [
      record['claim_number'],
      record['claim_type'],
      record['incident_description'],
      record['remarks'],
      record['archive_reason'],
      record['status'],
      record['amount_claimed'],
      record['amount_approved'],
      record['amount_paid'],
      _policyNameForId(record['policy_id']?.toString()),
    ].where((value) => value != null).join(' ').toLowerCase();
    return searchable.contains(query);
  }

  List<Map<String, dynamic>> get _filteredRecords => _allClaims
      .map(_claimSnapshotForSelectedMonth)
      .where(_matchesFilters)
      .toList();

  // Each archived claim appears only in Archived Records, grouped
  // by the date its archive became effective.
  List<Map<String, dynamic>> get _archivedClaims => _filteredRecords.where((r) {
        final start = _claimStartDate(r);
        if (start != null &&
            DateUtils.dateOnly(start).isAfter(
              _claimMonthCutoff(_selectedReportMonth),
            )) {
          return false;
        }
        return _isArchivedAsOf(r);
      }).toList();

  DateTime? _archiveMonthFor(Map<String, dynamic> record) {
    final date = _archiveEffectiveDate(record);
    return date == null ? null : _firstOfMonth(date);
  }

  Map<DateTime, List<Map<String, dynamic>>> _groupArchivedClaims(
      List<Map<String, dynamic>> records) {
    final groups = <DateTime, List<Map<String, dynamic>>>{};
    for (final record in records) {
      final month = _archiveMonthFor(record);
      if (month != null) (groups[month] ??= <Map<String, dynamic>>[]).add(record);
    }
    return groups;
  }

  int _countStatus(String status) => _thisMonthRecords
      .where(
        (record) => (record['status']?.toString() ?? 'Submitted') == status,
      )
      .length;

  void _toggleStatus(String status) {
    setState(() {
      if (!_selectedStatuses.add(status)) _selectedStatuses.remove(status);
    });
  }

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

  // ---------------------------------------------------------------------------
  // LOAD CLAIMS AND POLICIES
  // ---------------------------------------------------------------------------

  Future<void> _loadRecords() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
      _policyError = null;
    });

    try {
      final selectedSiteId = await _selectedPropertyId();
      final claimResult = await _supabase
          .from('insurance_claims')
          .select()
          .eq('site_id', selectedSiteId)
          .eq('is_archived', false)
          .order('incident_date', ascending: false, nullsFirst: false);
      final archivedResult = await _supabase
          .from('insurance_claims')
          .select()
          .eq('site_id', selectedSiteId)
          .eq('is_archived', true)
          .order('incident_date', ascending: false, nullsFirst: false);

      List<Map<String, dynamic>> policies = [];
      String? policyLoadError;

      // A policy-loading failure should not prevent claims from displaying.
      try {
        final policyResult = await _supabase
            .from('insurance_policies')
            .select('id, site_id, policy_name, insurer, policy_number, is_archived')
            .eq('site_id', selectedSiteId)
            .order('policy_name');

        policies = List<Map<String, dynamic>>.from(policyResult);
      } catch (e) {
        policyLoadError = e.toString();
      }

      if (!mounted) return;

      setState(() {
        _records = List<Map<String, dynamic>>.from(claimResult);
        _archivedRecords = List<Map<String, dynamic>>.from(archivedResult);
        _policies = policies;
        _policyError = policyLoadError;
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

  // ---------------------------------------------------------------------------
  // POLICY HELPERS
  // ---------------------------------------------------------------------------

  Map<String, dynamic>? _policyForId(String? policyId) {
    if (policyId == null || policyId.isEmpty) return null;

    for (final policy in _policies) {
      if (policy['id']?.toString() == policyId) {
        return policy;
      }
    }

    return null;
  }

  String _policyNameForId(String? policyId) {
    final policy = _policyForId(policyId);

    if (policy == null) {
      return policyId == null ? 'No linked policy' : 'Linked policy';
    }

    return policy['policy_name']?.toString() ?? 'Unnamed policy';
  }

  String _policyLabel(Map<String, dynamic> policy) {
    final parts = <String>[];

    final name = policy['policy_name']?.toString().trim() ?? '';
    final insurer = policy['insurer']?.toString().trim() ?? '';
    final number = policy['policy_number']?.toString().trim() ?? '';

    if (name.isNotEmpty) parts.add(name);
    if (insurer.isNotEmpty) parts.add(insurer);
    if (number.isNotEmpty) parts.add('No. $number');

    var label = parts.isEmpty ? 'Unnamed policy' : parts.join(' · ');

    if (policy['is_archived'] == true) {
      label += ' (Archived)';
    }

    return label;
  }

  List<Map<String, dynamic>> _policyOptions(String? selectedPolicyId) {
    // New claims can only select active policies.
    final options = _policies
        .where((policy) => policy['is_archived'] != true)
        .toList();

    // Preserve an already-linked archived policy when editing.
    if (selectedPolicyId != null &&
        !options.any(
          (policy) => policy['id']?.toString() == selectedPolicyId,
        )) {
      final existing = _policyForId(selectedPolicyId);

      if (existing != null) {
        options.add(existing);
      } else {
        // Preserve the existing foreign key if policy details cannot be loaded.
        options.add({
          'id': selectedPolicyId,
          'policy_name': 'Linked policy (details unavailable)',
          'insurer': null,
          'policy_number': null,
          'is_archived': true,
        });
      }
    }

    return options;
  }

  // ---------------------------------------------------------------------------
  // ADD / EDIT
  // ---------------------------------------------------------------------------

  Future<void> _openForm({Map<String, dynamic>? record}) async {
    if (_saving) return;
    if (record != null) record = _sourceRecord(record);

    final isEditing = record != null;
    final formKey = GlobalKey<FormState>();

    final claimNumberController = TextEditingController(
      text: record?['claim_number']?.toString() ?? '',
    );
    final claimTypeController = TextEditingController(
      text: record?['claim_type']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: record?['incident_description']?.toString() ?? '',
    );
    final claimAmountController = TextEditingController(
      text: record?['amount_claimed']?.toString() ?? '',
    );
    final approvedAmountController = TextEditingController(
      text: record?['amount_approved']?.toString() ?? '',
    );
    final paidAmountController = TextEditingController(
      text: record?['amount_paid']?.toString() ?? '',
    );
    final remarksController = TextEditingController(
      text: record?['remarks']?.toString() ?? '',
    );
    final archiveReasonController = TextEditingController();
    bool archiveSelected = false;

    DateTime? incidentDate = _parseDate(record?['incident_date']);
    DateTime? submittedDate = _parseDate(record?['submitted_date']);
    DateTime? closureDate = _parseDate(record?['closure_date']);

    String? selectedPolicyId = record?['policy_id']?.toString();

    String status = record?['status']?.toString() ?? 'Submitted';
    if (!_statuses.contains(status)) status = 'Submitted';

    final availablePolicies = _policyOptions(selectedPolicyId);

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.white,
              surfaceTintColor: Colors.transparent,
              title: Text(
                isEditing ? 'Edit Insurance Claim' : 'Add Insurance Claim',
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
                        _sectionHeading('LINKED INSURANCE POLICY'),
                        const SizedBox(height: 14),

                        DropdownButtonFormField<String?>(
                          initialValue: selectedPolicyId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Insurance Policy',
                            helperText:
                                'Optional. Archived policies are unavailable '
                                'for new claims.',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('No linked policy'),
                            ),
                            ...availablePolicies.map((policy) {
                              return DropdownMenuItem<String?>(
                                value: policy['id'].toString(),
                                child: Text(
                                  _policyLabel(policy),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (value) {
                            setDialogState(() {
                              selectedPolicyId = value;
                            });
                          },
                        ),

                        if (_policyError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Policies could not be loaded. An existing '
                            'policy link will be preserved unless changed.',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                            ),
                          ),
                        ],

                        const SizedBox(height: 22),
                        _sectionHeading('CLAIM DETAILS'),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: claimNumberController,
                          decoration: const InputDecoration(
                            labelText: 'Claim Number',
                            hintText: 'Optional claim reference',
                          ),
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: claimTypeController,
                          decoration: const InputDecoration(
                            labelText: 'Claim Type',
                            hintText: 'e.g. Property Damage',
                          ),
                        ),
                        const SizedBox(height: 14),

                        _dateField(
                          context: context,
                          label: 'Incident Date',
                          value: incidentDate,
                          allowClear: false,
                          onChanged: (value) {
                            setDialogState(() => incidentDate = value);
                          },
                        ),
                        const SizedBox(height: 14),

                        _dateField(
                          context: context,
                          label: 'Submission Date (Optional)',
                          value: submittedDate,
                          onChanged: (value) {
                            setDialogState(() => submittedDate = value);
                          },
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: descriptionController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Incident Description *',
                            hintText: 'Describe the incident and claim',
                            alignLabelWithHint: true,
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter an incident description.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: remarksController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Remarks',
                            hintText: 'Enter claim remarks',
                            alignLabelWithHint: true,
                          ),
                        ),

                        const SizedBox(height: 22),
                        const Divider(),
                        const SizedBox(height: 12),
                        _sectionHeading('FINANCIAL DETAILS'),
                        const SizedBox(height: 14),

                        _amountField(
                          controller: claimAmountController,
                          label: 'Claim Amount (RM) *',
                          required: true,
                        ),
                        const SizedBox(height: 14),

                        _amountField(
                          controller: approvedAmountController,
                          label: 'Approved Amount (RM)',
                          hint: 'Leave blank if not yet approved',
                        ),
                        const SizedBox(height: 14),

                        _amountField(
                          controller: paidAmountController,
                          label: 'Amount Paid (RM)',
                          hint: 'Leave blank if no payment has been made',
                        ),

                        const SizedBox(height: 22),
                        const Divider(),
                        const SizedBox(height: 12),
                        _sectionHeading('CLAIM STATUS'),
                        const SizedBox(height: 14),

                        DropdownButtonFormField<String>(
                          initialValue: status,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Status *',
                          ),
                          items: _statuses.map((value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            );
                          }).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => status = value);
                            }
                          },
                        ),
                        const SizedBox(height: 14),

                        _dateField(
                          context: context,
                          label: 'Closure Date',
                          value: closureDate,
                          onChanged: (value) {
                            setDialogState(() => closureDate = value);
                          },
                        ),
                        if (isEditing) ...[
                          const SizedBox(height: 22),
                          const Divider(),
                          const SizedBox(height: 12),
                          _sectionHeading('RECORD MANAGEMENT'),
                          const SizedBox(height: 8),
                          if (record!['is_archived'] == true)
                            const Text(
                              'This claim is archived. Use Restore in '
                              'Archived Records to return it to the active register.',
                              style: TextStyle(
                                color: AppColors.grey,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            )
                          else ...[
                            InkWell(
                              onTap: () => setDialogState(
                                () => archiveSelected = !archiveSelected,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Checkbox(
                                    value: archiveSelected,
                                    onChanged: (value) => setDialogState(
                                      () => archiveSelected = value ?? false,
                                    ),
                                    activeColor: AppColors.red,
                                    shape: const CircleBorder(),
                                    side: const BorderSide(
                                      color: AppColors.grey,
                                      width: 1.5,
                                    ),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('Archive'),
                                ],
                              ),
                            ),
                            if (archiveSelected) ...[
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: archiveReasonController,
                                minLines: 2,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                  labelText: 'Reason for Archiving *',
                                  hintText: 'Enter the reason for archiving',
                                  alignLabelWithHint: true,
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
                    if (incidentDate == null) {
                      _showMessage('Select an Incident Date for the claim.');
                      return;
                    }

                    final claim = _parseAmount(claimAmountController.text);
                    final approvedText = approvedAmountController.text.trim();
                    final approved = _parseAmount(approvedText);
                    final paidText = paidAmountController.text.trim();
                    final paid = _parseAmount(paidText);

                    if (claim == null || claim < 0) {
                      _showMessage('Enter a valid non-negative claim amount.');
                      return;
                    }

                    if (approvedText.isNotEmpty &&
                        (approved == null || approved < 0)) {
                      _showMessage(
                        'Enter a valid non-negative approved amount.',
                      );
                      return;
                    }

                    if (paidText.isNotEmpty && (paid == null || paid < 0)) {
                      _showMessage('Enter a valid non-negative paid amount.');
                      return;
                    }

                    if (approved != null && approved > claim) {
                      _showMessage(
                        'Approved amount cannot exceed the claim amount.',
                      );
                      return;
                    }

                    if (paid != null && approved != null && paid > approved) {
                      _showMessage(
                        'Amount paid cannot exceed the approved amount.',
                      );
                      return;
                    }

                    if (status == 'Paid' && (paid == null || paid <= 0)) {
                      _showMessage('Enter the amount paid for a paid claim.');
                      return;
                    }

                    if (status == 'Closed' && closureDate == null) {
                      _showMessage('Select a closure date for a closed claim.');
                      return;
                    }

                    if (status == 'Closed' &&
                        closureDate != null &&
                        submittedDate != null &&
                        closureDate!.isBefore(submittedDate!)) {
                      _showMessage(
                        'Closure Date cannot be before Submission Date.',
                      );
                      return;
                    }

                    Navigator.of(dialogContext).pop(true);
                  },
                  child: Text(archiveSelected ? 'Archive Claim' : (isEditing ? 'Save Changes' : 'Add Claim')),
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
        policyId: selectedPolicyId,
        claimNumber: claimNumberController.text,
        claimType: claimTypeController.text,
        incidentDate: incidentDate,
        submittedDate: submittedDate,
        description: descriptionController.text,
        remarks: remarksController.text,
        claimAmount: claimAmountController.text,
        approvedAmount: approvedAmountController.text,
        paidAmount: paidAmountController.text,
        status: status,
        closureDate: closureDate,
        archive: archiveSelected,
        archiveReason: archiveReasonController.text,
      );
    }

    claimNumberController.dispose();
    claimTypeController.dispose();
    descriptionController.dispose();
    claimAmountController.dispose();
    approvedAmountController.dispose();
    paidAmountController.dispose();
    remarksController.dispose();
    archiveReasonController.dispose();
  }

  Widget _sectionHeading(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: AppColors.red,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _amountField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool required = false,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, hintText: hint),
      validator: (value) {
        final text = value?.trim() ?? '';

        if (required && text.isEmpty) {
          return 'This amount is required.';
        }

        if (text.isEmpty) return null;

        final amount = num.tryParse(text);
        if (amount == null || !amount.isFinite || amount < 0) {
          return 'Enter a valid non-negative amount.';
        }

        return null;
      },
    );
  }

  // Persist a compact dated status/settlement timeline in the claim itself.
  // Existing table RLS stays in force; no second table or duplicate claims.
  Map<String, dynamic> _statusEvent({
    required DateTime date,
    required String status,
    required num? approved,
    required num? paid,
    required DateTime? closureDate,
  }) => {
    'date': _dateForDatabase(date),
    'status': status,
    'amount_approved': approved,
    'amount_paid': paid,
    'closure_date': _dateForDatabase(closureDate),
  };

  DateTime _effectiveStatusDate(String status, DateTime? closureDate) {
    final today = DateUtils.dateOnly(DateTime.now());
    if (status == 'Closed' &&
        closureDate != null &&
        !closureDate.isAfter(today)) {
      return DateUtils.dateOnly(closureDate);
    }
    return today;
  }

  List<Map<String, dynamic>> _updatedStatusHistory({
    required Map<String, dynamic>? previous,
    required DateTime startDate,
    required String status,
    required num? approved,
    required num? paid,
    required DateTime? closureDate,
  }) {
    final history = <Map<String, dynamic>>[];
    final existing = previous?['status_history'];
    if (existing is List) {
      for (final item in existing) {
        if (item is Map) history.add(Map<String, dynamic>.from(item));
      }
    }
    if (previous == null) {
      history.add(_statusEvent(
        date: startDate,
        status: status,
        approved: approved,
        paid: paid,
        closureDate: closureDate,
      ));
      return history;
    }

    // Do not invent an earlier status event for legacy claims without
    // status_history. Only actual changes from now on are dated and recorded.

    final wasStatus = previous['status']?.toString() ?? 'Submitted';
    final wasApproved = _amountFromRecord(previous, 'amount_approved');
    final wasPaid = _amountFromRecord(previous, 'amount_paid');
    final wasClosure = _dateForDatabase(_parseDate(previous['closure_date']));
    final nowClosure = _dateForDatabase(closureDate);
    if (wasStatus != status ||
        wasApproved != approved ||
        wasPaid != paid ||
        wasClosure != nowClosure) {
      final requestedDate = _effectiveStatusDate(status, closureDate);
      final date = requestedDate.isBefore(startDate)
          ? DateUtils.dateOnly(startDate)
          : requestedDate;
      history.add(_statusEvent(
        date: date,
        status: status,
        approved: approved,
        paid: paid,
        closureDate: closureDate,
      ));
    }
    return history;
  }

  Future<void> _saveRecord({
    required Map<String, dynamic>? record,
    required String? policyId,
    required String claimNumber,
    required String claimType,
    required DateTime? incidentDate,
    required DateTime? submittedDate,
    required String description,
    required String remarks,
    required String claimAmount,
    required String approvedAmount,
    required String paidAmount,
    required String status,
    required DateTime? closureDate,
    bool archive = false,
    String archiveReason = '',
  }) async {
    if (incidentDate == null) {
      _showMessage('Select an Incident Date for the claim.');
      return;
    }
    final claim = _parseAmount(claimAmount);
    final approvedText = approvedAmount.trim();
    final approved = _parseAmount(approvedText);
    final paidText = paidAmount.trim();
    final paid = _parseAmount(paidText);

    if (claim == null || claim < 0) {
      _showMessage('Enter a valid claim amount.');
      return;
    }

    if (approvedText.isNotEmpty && (approved == null || approved < 0)) {
      _showMessage('Enter a valid approved amount.');
      return;
    }

    if (paidText.isNotEmpty && (paid == null || paid < 0)) {
      _showMessage('Enter a valid paid amount.');
      return;
    }

    if (approved != null && approved > claim) {
      _showMessage('Approved amount cannot exceed the claim amount.');
      return;
    }

    if (paid != null && approved != null && paid > approved) {
      _showMessage('Amount paid cannot exceed the approved amount.');
      return;
    }

    if (status == 'Paid' && (paid == null || paid <= 0)) {
      _showMessage('Enter the amount paid for a paid claim.');
      return;
    }

    if (status == 'Closed' && closureDate == null) {
      _showMessage('Select a closure date for a closed claim.');
      return;
    }
    if (status == 'Closed' &&
        closureDate != null &&
        submittedDate != null &&
        closureDate.isBefore(submittedDate)) {
      _showMessage('Closure Date cannot be before Submission Date.');
      return;
    }

    final data = <String, dynamic>{
      'policy_id': policyId,
      'claim_number': _nullIfEmpty(claimNumber),
      'claim_type': _nullIfEmpty(claimType),
      'incident_date': _dateForDatabase(incidentDate),
      'submitted_date': _dateForDatabase(submittedDate),
      'incident_description': description.trim(),
      'remarks': _nullIfEmpty(remarks),
      'amount_claimed': claim,
      'amount_approved': approved,
      'amount_paid': paid,
      'status': status,
      'closure_date': _dateForDatabase(closureDate),
      'status_history': _updatedStatusHistory(
        previous: record,
        startDate: submittedDate ?? incidentDate,
        status: status,
        approved: approved,
        paid: paid,
        closureDate: closureDate,
      ),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      if (record == null) 'is_archived': false,
      if (archive) ...{
        'is_archived': true,
        'archived_at': DateTime.now().toUtc().toIso8601String(),
        'archive_reason': archiveReason.trim(),
      },
    };

    if (archive && (record == null || archiveReason.trim().isEmpty)) {
      _showMessage('An existing claim and a reason are required to archive.');
      return;
    }

    setState(() => _saving = true);

    try {
      final selectedSiteId = await _selectedPropertyId();
      if (record == null) {
        // New claims always belong to the selected property's report.
        data['site_id'] = selectedSiteId;
      } else {
        final existingSiteId = record['site_id']?.toString().trim() ?? '';
        if (existingSiteId != selectedSiteId) {
          throw StateError(
            'This insurance claim is not assigned to the selected property.',
          );
        }
      }

      if (record != null) {
        await _supabase
            .from('insurance_claims')
            .update(data)
            .eq('id', record['id'].toString());
      } else {
        await _supabase.from('insurance_claims').insert(data);
      }

      if (!mounted) return;

      await _loadRecords();

      if (!mounted) return;

      _showMessage(
        archive
            ? 'Insurance claim archived successfully.'
            : record == null
                ? 'Insurance claim added successfully.'
                : 'Insurance claim updated successfully.', 
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not save the insurance claim: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // DELETE (current and archived claim records)
  // ---------------------------------------------------------------------------

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    if (_saving) return;
    final id = record['id']?.toString();
    if (id == null || id.isEmpty) {
      _showMessage('Unable to delete: claim has no valid ID.');
      return;
    }
    final description =
        record['claim_number']?.toString() ??
        record['incident_description']?.toString() ??
        'this claim';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Insurance Claim?'),
        content: Text(
          'Permanently delete "$description"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final deleted = await _supabase
          .from('insurance_claims')
          .delete()
          .eq('id', id)
          .select('id');
      if (deleted.isEmpty) {
        throw Exception(
          'No row was deleted. Check your Supabase DELETE and SELECT permissions.',
        );
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _showMessage('Insurance claim deleted.');
    } catch (e) {
      if (mounted) _showMessage('Could not delete the claim: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // A past claim stays a single record: Restore updates that record rather
  // than creating a second copy. Reopening a closed claim is an explicit step.
  Future<void> _restoreRecord(Map<String, dynamic> record) async {
    if (_saving || !mounted) return;
    record = _sourceRecord(record);
    final id = record['id']?.toString();
    if (id == null || id.isEmpty) {
      _showMessage('Unable to restore: claim has no valid ID.');
      return;
    }
    final closureDate = _parseDate(record['closure_date']);
    final today = DateUtils.dateOnly(DateTime.now());
    final automaticFrom = closureDate == null
        ? null
        : DateTime(closureDate.year, closureDate.month, closureDate.day + 1);
    final shouldReopen = record['status'] == 'Closed' &&
        automaticFrom != null &&
        !automaticFrom.isAfter(today);
    // A claim can be displayed in a previous month's Archive even if it has
    // already been reopened since then. Do not change an already-active row.
    if (!shouldReopen && record['is_archived'] != true) {
      _showMessage('This claim is already active in the current register.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(shouldReopen ? 'Reopen Insurance Claim?' : 'Restore Insurance Claim?'),
        content: Text(
          shouldReopen
              ? 'Reopen this Closed claim? Its Closure Date will be cleared '
                'and status changed to Under Review. The dated status history, '
                'submission date, financial amounts, and other details will be kept.'
              : 'Restore this manually archived claim? Its existing '
                'submission date, status, and financial information will be kept.',
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
            child: Text(shouldReopen ? 'Reopen Claim' : 'Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final data = <String, dynamic>{
        'is_archived': false,
        'archived_at': null,
        'archive_reason': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        if (shouldReopen) 'closure_date': null,
        if (shouldReopen) ...{
          'status': 'Under Review',
          'status_history': _updatedStatusHistory(
            previous: record,
            startDate: _claimStartDate(record) ?? DateTime.now(),
            status: 'Under Review',
            approved: _amountFromRecord(record, 'amount_approved'),
            paid: _amountFromRecord(record, 'amount_paid'),
            closureDate: null,
          ),
        },
      };
      final restored = await _supabase
          .from('insurance_claims')
          .update(data)
          .eq('id', id)
          .select('id');
      if (restored.isEmpty) {
        throw Exception('No claim was updated. Check your database permissions.');
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) {
        _showMessage(shouldReopen
            ? 'Insurance claim reopened successfully.'
            : 'Insurance claim restored successfully.');
      }
    } catch (e) {
      if (mounted) _showMessage('Unable to restore the claim: $e');
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
    bool allowClear = true,
  }) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final initial = value ?? DateTime(now.year, now.month, now.day);

        final selected = await showDatePicker(
          context: context,
          initialDate: initial,
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
              if (allowClear && value != null)
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
        title: const Text('Insurance Claims'),
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
        label: const Text('Add Claim'),
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
                'Unable to load insurance claims.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SelectableText(_error!),
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

    final current = _filteredRecords.where(_isThisMonth).toList();
    final archived = _archivedClaims;
    final groups = _groupArchivedClaims(archived);
    final undated = archived.where((r) => _archiveMonthFor(r) == null).toList();
    final months = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return RefreshIndicator(
      onRefresh: _loadRecords,
      color: AppColors.red,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSummary(),
          const SizedBox(height: 22),
          _buildSearchAndFilters(),
          const SizedBox(height: 26),
          _sectionTitle(
            'This Month',
            '${current.length} record${current.length == 1 ? '' : 's'}',
          ),
          const SizedBox(height: 12),
          if (current.isEmpty)
            _buildEmptyState('No claims match this month or the selected filters.')
          else
            ...current.asMap().entries.map(
              (entry) => _buildRecordCard(
                entry.value,
                entry.key + 1,
                carriedForward: _isCarriedForward(entry.value),
              ),
            ),
          const SizedBox(height: 24),
          _sectionTitle(
            'Archived Records',
            '${archived.length} record${archived.length == 1 ? '' : 's'}',
          ),
          const SizedBox(height: 14),
          if (archived.isEmpty)
            _buildEmptyState('No archived insurance claims.')
          else ...[
            for (final month in months)
              _archivedMonthCard(
                keyValue: '${month.year}-${month.month}',
                title: _monthHeading(month),
                records: groups[month]!,
              ),
            if (undated.isNotEmpty)
              _archivedMonthCard(
                keyValue: 'undated',
                title: 'Date Not Set',
                records: undated,
              ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, String count) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            color: AppColors.black,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      Text(
        count,
        style: const TextStyle(
          color: AppColors.grey,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget _archivedMonthCard({
    required String keyValue,
    required String title,
    required List<Map<String, dynamic>> records,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>(
          'claims-archive-$keyValue',
        ),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        title: Text(
          title,
          style: const TextStyle(
            color: AppColors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          '${records.length} claim record${records.length == 1 ? '' : 's'}',
          style: const TextStyle(color: AppColors.grey, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        children: [
          for (final entry in records.asMap().entries)
            _buildRecordCard(
              entry.value,
              entry.key + 1,
              archivedView: true,
            ),
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
            'Insurance Claims',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthHeading(_selectedReportMonth)} · Report ID: $_selectedReportId',
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
        final cards = <Widget>[
          _statusCard(
            'Submitted',
            _countStatus('Submitted'),
            Icons.outgoing_mail,
            const Color(0xFF966400),
          ),
          _statusCard(
            'Under Review',
            _countStatus('Under Review'),
            Icons.manage_search_outlined,
            const Color(0xFF245C9C),
          ),
          _statusCard(
            'Approved',
            _countStatus('Approved'),
            Icons.verified_outlined,
            const Color(0xFF22683D),
          ),
          _statusCard(
            'Rejected',
            _countStatus('Rejected'),
            Icons.highlight_off_outlined,
            AppColors.red,
          ),
          _statusCard(
            'Paid',
            _countStatus('Paid'),
            Icons.payments_outlined,
            const Color(0xFF22683D),
          ),
          _statusCard(
            'Closed',
            _countStatus('Closed'),
            Icons.task_alt_outlined,
            AppColors.grey,
          ),
        ];
        return Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: _summaryCard(
                'Total Claims',
                _thisMonthRecords.length,
                Icons.description_outlined,
                AppColors.red,
                onTap: () => setState(() => _selectedStatuses.clear()),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final card in cards) SizedBox(width: width, child: card),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _statusCard(String status, int count, IconData icon, Color color) =>
      _summaryCard(
        status,
        count,
        icon,
        color,
        onTap: () => _toggleStatus(status),
      );

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
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Container(
                height: 46,
                width: 46,
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

  Widget _buildSearchAndFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search claims, policy, description, amount...',
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
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text(
              'Showing:',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
            if (_selectedStatuses.isEmpty)
              const Text(
                'All statuses',
                style: TextStyle(color: AppColors.black, fontSize: 12),
              )
            else ...[
              for (final status in _statuses)
                if (_selectedStatuses.contains(status))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFD8B5B0),
                        width: 1.2,
                      ),
                    ),
                    child: Text(
                      status,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 12,
                      ),
                    ),
                  ),
              TextButton.icon(
                onPressed: () => setState(() => _selectedStatuses.clear()),
                icon: const Icon(Icons.close, size: 14),
                label: const Text('Clear filter'),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState(String message) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Text(
      message,
      style: const TextStyle(color: AppColors.grey),
      textAlign: TextAlign.center,
    ),
  );

  Widget _buildRecordCard(
    Map<String, dynamic> record,
    int number, {
    bool carriedForward = false,
    bool archivedView = false,
  }) {
    final status = record['status']?.toString() ?? 'Submitted';
    final accent = _statusColor(status);
    final claimType = record['claim_type']?.toString().trim() ?? '';
    final claimNumber = record['claim_number']?.toString() ?? '';
    final policyId = record['policy_id']?.toString();
    final policyName = _policyNameForId(policyId);
    final displayName = claimType.isNotEmpty
        ? claimType
        : claimNumber.trim().isNotEmpty
            ? 'Insurance Claim'
            : 'Untitled Claim';
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
                      displayName,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_hasText(claimNumber)) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Claim No.: $claimNumber',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Policy: $policyName',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                      softWrap: true,
                    ),
                    if (carriedForward) ...[
                      const SizedBox(height: 5),
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
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _dateBox('Incident Date', record['incident_date']),
              _dateBox('Submission Date', record['submitted_date']),
              if (_hasText(record['closure_date']))
                _dateBox('Closure Date', record['closure_date']),
            ],
          ),
          const SizedBox(height: 15),
          if (_hasText(record['incident_description'])) ...[
            _detailRow('Incident Description', record['incident_description']),
            const SizedBox(height: 10),
          ],
          if (_hasText(record['remarks'])) ...[
            _detailRow('Remarks', record['remarks']),
            const SizedBox(height: 10),
          ],
          _detailRow('Claim Amount (RM)', _formatMoney(record['amount_claimed'])),
          const SizedBox(height: 9),
          _detailRow('Approved (RM)', _formatMoney(record['amount_approved'])),
          const SizedBox(height: 9),
          _detailRow('Paid (RM)', _formatMoney(record['amount_paid'])),
          if (archivedView && record['is_archived'] == true) ...[
            if (_hasText(record['archived_at'])) ...[
              const SizedBox(height: 10),
              _detailRow('Date Archived', _displayDate(record['archived_at'])),
            ],
            if (_hasText(record['archive_reason'])) ...[
              const SizedBox(height: 10),
              _detailRow('Archive Reason', record['archive_reason']),
            ],
          ],
          const Divider(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (archivedView)
                  TextButton.icon(
                    onPressed: _saving ? null : () => _restoreRecord(record),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.red,
                    ),
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('Restore'),
                  )
                else ...[
                  TextButton.icon(
                    onPressed: _saving ? null : () => _openForm(record: record),
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

  Widget _dateBox(String label, dynamic value) {
    return Container(
      width: 148,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
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
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 5),
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

  Widget _detailRow(String label, dynamic value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 146,
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 530),
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
      ],
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

    final amount = num.tryParse(value.trim());
    if (amount == null || !amount.isFinite) return null;

    return amount;
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
      case 'Approved':
      case 'Paid':
        return const Color(0xFF22683D);
      case 'Submitted':
        return const Color(0xFF966400);
      case 'Under Review':
        return const Color(0xFF245C9C);
      case 'Rejected':
        return AppColors.red;
      case 'Closed':
        return AppColors.grey;
      default:
        return AppColors.black;
    }
  }
}