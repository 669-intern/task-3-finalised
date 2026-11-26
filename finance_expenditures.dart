import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';
import 'finance_helpers.dart';

class FinanceExpenditures extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceExpenditures({super.key, required this.report});

  @override
  State<FinanceExpenditures> createState() => _FinanceExpendituresState();
}

class _FinanceExpendituresState extends State<FinanceExpenditures> {
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _records = [];
  bool _loading = true;
  String? _error;
  final Set<String> _selectedStatusFilters = <String>{};

  // Keep the existing four statuses and add only the three requested ones.
  static const _statuses = [
    'Approved',
    'Partially Spent',
    'Fully Spent',
    'Cancelled',
    'Completed',
    'Pending Delivery',
    'In Progress',
  ];

  static const _openStatuses = <String>{
    'Approved',
    'Partially Spent',
    'Pending Delivery',
    'In Progress',
  };

  String? get _reportId => widget.report['id']?.toString();

  DateTime? get _reportMonth {
    final raw =
        widget.report['report_month'] ??
        widget.report['month'] ??
        widget.report['report_date'];

    if (raw == null) return null;

    final parsed = DateTime.tryParse(raw.toString());
    if (parsed == null) return null;

    return DateTime(parsed.year, parsed.month);
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadRecords();
      }
    });
  }

  @override
  void didUpdateWidget(covariant FinanceExpenditures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['site_id']?.toString() !=
            widget.report['site_id']?.toString() ||
        oldWidget.report['id']?.toString() != widget.report['id']?.toString()) {
      // Never show a previous property's records if the parent swaps reports.
      _records = [];
      _loading = true;
      _error = null;
      _selectedStatusFilters.clear();
      _searchController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadRecords();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Map<String, dynamic> _responseMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;

    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }

    throw Exception('Unexpected response from the finance server.');
  }

  String _errorMessage(Object error) {
    // Supabase Flutter 2.x exposes the Edge Function's JSON error body here.
    // Show its useful message instead of a long FunctionsHttpException string.
    if (error is FunctionsHttpException) {
      final details = error.details;
      if (details is Map) {
        final reason =
            details['error']?.toString() ?? details['message']?.toString();
        final code = details['code']?.toString();
        final requestId = details['request_id']?.toString();
        if (reason != null && reason.isNotEmpty) {
          return '$reason'
              '${code == null || code.isEmpty ? '' : ' (Code: $code)'}'
              '${requestId == null || requestId.isEmpty ? '' : ' [Ref: $requestId]'}';
        }
      }
      return 'Finance server returned HTTP ${error.status}. '
          'Please check the finance-expenditures Logs.';
    }

    final message = error.toString();
    if (message.toLowerCase().contains('failed to fetch') ||
        message.toLowerCase().contains('socketexception')) {
      return 'Could not connect to the server. Check your internet connection.';
    }
    return message;
  }

  Future<Map<String, dynamic>> _invokeFinance(
    String action, {
    Map<String, dynamic> payload = const {},
  }) async {
    final response = await FinanceHelpers.supabase.functions.invoke(
      'finance-expenditures',
      body: {'action': action, ...payload},
    );

    final data = _responseMap(response.data);
    final error = data['error'];
    if (error != null) {
      throw Exception(error.toString());
    }
    return data;
  }

  // Unlike the initial load, a post-save refresh must be allowed to throw.
  // Otherwise a failed refresh could incorrectly be shown as a successful save.
  Future<void> _fetchRecords({bool showLoading = true}) async {
    if (mounted && showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final siteId = widget.report['site_id']?.toString();
    if (siteId == null || siteId.isEmpty) {
      throw Exception('Residence ID is missing from the report.');
    }

    final data = await _invokeFinance('list', payload: {'site_id': siteId});
    final result = data['records'];
    if (result is! List) {
      throw Exception('The server returned an invalid records list.');
    }

    final loaded = result
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    if (!mounted || widget.report['site_id']?.toString() != siteId) return;
    setState(() {
      _records = loaded;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _loadRecords() async {
    final requestedSite = widget.report['site_id']?.toString();
    try {
      await _fetchRecords();
    } catch (e) {
      if (!mounted || widget.report['site_id']?.toString() != requestedSite) {
        return;
      }
      setState(() {
        _error = _errorMessage(e);
        _loading = false;
      });
    }
  }

  // Normalize manual serials (e.g. /0005 -> /005) to match the DB trigger.
  // Keep the original string if it is not in a recognizable AR format; the
  // server will return the appropriate validation error instead.
  String _normalizeArNumber(String value) {
    final parts = value.trim().toUpperCase().split('/');
    if (parts.length == 5 && RegExp(r'^\d+$').hasMatch(parts.last)) {
      final n = int.tryParse(parts.last);
      if (n != null && n > 0) {
        parts[4] = n.toString().padLeft(3, '0');
      }
    }
    return parts.join('/');
  }

  String _dateOnly(dynamic value) {
    final raw = value?.toString() ?? '';
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  String? _optionalText(dynamic value) {
    final result = value?.toString().trim();
    return result == null || result.isEmpty ? null : result;
  }

  // Confirm that the server returned every edited value as actually stored.
  bool _recordMatchesPayload(
    Map<String, dynamic> saved,
    Map<String, dynamic> payload,
  ) {
    if (saved['id'] == null) return false;
    if (saved['expenditure_name']?.toString().trim() !=
        payload['expenditure_name']?.toString().trim()) {
      return false;
    }
    if (saved['category']?.toString().trim() !=
        payload['category']?.toString().trim()) {
      return false;
    }
    if (_optionalText(saved['description']) !=
        _optionalText(payload['description'])) {
      return false;
    }
    if (saved['approved_amount'] == null ||
        (_number(saved['approved_amount']) -
                    _number(payload['approved_amount']))
                .abs() >
            0.00001) {
      return false;
    }
    if (saved['status']?.toString() != payload['status']?.toString()) {
      return false;
    }
    if (_dateOnly(saved['approval_date']) !=
        _dateOnly(payload['approval_date'])) {
      return false;
    }
    if (payload.containsKey('ar_number') &&
        saved['ar_number']?.toString().trim() !=
            payload['ar_number']?.toString().trim()) {
      return false;
    }
    if (payload.containsKey('original_report_month') &&
        _dateOnly(saved['original_report_month']) !=
            _dateOnly(payload['original_report_month'])) {
      return false;
    }
    if (payload.containsKey('site_id') &&
        saved['site_id']?.toString().toLowerCase() !=
            payload['site_id']?.toString().toLowerCase()) {
      return false;
    }
    return true;
  }

  double _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _money(dynamic value) => 'RM ${_number(value).toStringAsFixed(2)}';

  String _formatDate(dynamic value) {
    if (value == null) return '-';

    final date = DateTime.tryParse(value.toString());
    if (date == null) return value.toString();

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
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

  Widget _buildHeader() {
    final reportMonth = _reportMonth;

    final monthLabel = reportMonth == null
        ? 'Monthly report'
        : '${_monthName(reportMonth.month)} ${reportMonth.year}';

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
            'FINANCE',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Approved Expenditure',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$monthLabel • Report ID: ${_reportId ?? 'Unavailable'}',
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 13),
          ),
        ],
      ),
    );
  }

  // An expenditure belongs to its Approval Date month, regardless of when
  // it was entered into the property-wide register.
  DateTime? _recordedMonth(Map<String, dynamic> record) {
    final raw = record['approval_date'];
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month);
  }

  /// -1 = recorded in an earlier month, 0 = this month,
  /// 1 = recorded after this report's month, null = unknown.
  int? _periodOf(Map<String, dynamic> record) {
    final recorded = _recordedMonth(record);
    final current = _reportMonth;

    if (recorded == null || current == null) return null;

    final diff =
        (recorded.year - current.year) * 12 + (recorded.month - current.month);

    return diff.sign;
  }

  // Sort by AR number, interpreting trailing numeric portions as numbers.
  // Month tokens are compared chronologically rather than alphabetically.
  int _compareArValues(String a, String b) {
    final aParts = a.toUpperCase().split('/');
    final bParts = b.toUpperCase().split('/');
    const monthTokens = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    final limit = aParts.length < bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < limit; i++) {
      final left = aParts[i];
      final right = bParts[i];
      final ln = int.tryParse(left);
      final rn = int.tryParse(right);
      int order;
      if (ln != null && rn != null) {
        order = ln.compareTo(rn);
      } else if (monthTokens.contains(left) && monthTokens.contains(right)) {
        order = monthTokens.indexOf(left).compareTo(monthTokens.indexOf(right));
      } else {
        order = left.compareTo(right);
      }
      if (order != 0) return order;
    }
    return aParts.length.compareTo(bParts.length);
  }

  List<Map<String, dynamic>> _sortByAr(List<Map<String, dynamic>> records) {
    records.sort((a, b) {
      final order = _compareArValues(
        a['ar_number']?.toString() ?? '',
        b['ar_number']?.toString() ?? '',
      );
      if (order != 0) return order;
      return _number(a['id']).compareTo(_number(b['id']));
    });
    return records;
  }

  // Carry forward only an unresolved approval from an EARLIER month.
  // A finished/cancelled record remains in its original month's register.
  bool _isCarryForward(Map<String, dynamic> record) =>
      _periodOf(record) == -1 &&
      _openStatuses.contains(record['status']?.toString());

  // Show carried-forward records under the existing "This Month" heading.
  // The original database record is never duplicated or moved.
  List<Map<String, dynamic>> get _thisMonthExpenditures => _sortByAr(
    _records
        .where((record) => _periodOf(record) == 0 || _isCarryForward(record))
        .toList(),
  );

  // Keep earlier closed/undated records in History. Carried-forward records
  // are excluded here so that each appears only once on the page.
  List<Map<String, dynamic>> get _historicalExpenditures => _sortByAr(
    _records.where((record) {
      final period = _periodOf(record);
      return (period == -1 && !_isCarryForward(record)) || period == null;
    }).toList(),
  );

  int _count(String status) =>
      _thisMonthExpenditures.where((r) => r['status'] == status).length;

  // Financial amount is NEW approvals in the selected month only. The
  // carried-forward amounts are visible but are NOT counted again.
  double get _totalAmount => _thisMonthExpenditures
      .where((r) => _periodOf(r) == 0 && r['status'] != 'Cancelled')
      .fold<double>(0, (sum, r) => sum + _number(r['approved_amount']));

  void _toggleStatusFilter(String? status) {
    setState(() {
      if (status == null) {
        _selectedStatusFilters.clear();
      } else if (!_selectedStatusFilters.add(status)) {
        _selectedStatusFilters.remove(status);
      }
    });
  }

  bool _matchesStatus(Map<String, dynamic> record) =>
      _selectedStatusFilters.isEmpty ||
      _selectedStatusFilters.contains(record['status']?.toString());

  bool _matchesSearch(Map<String, dynamic> record) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      record['ar_number'],
      record['expenditure_name'],
      record['category'],
      record['description'],
      record['status'],
      record['approved_amount'],
    ].where((v) => v != null).join(' ').toLowerCase().contains(query);
  }

  List<Map<String, dynamic>> get _filteredRecords => _thisMonthExpenditures
      .where((r) => _matchesStatus(r) && _matchesSearch(r))
      .toList();

  List<Map<String, dynamic>> get _filteredHistory =>
      _historicalExpenditures.where(_matchesSearch).toList();

  String _monthLabel(DateTime date) => '${_monthName(date.month)} ${date.year}';

  Widget _emptyPanel(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.white,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.grey)),
  );

  Color _statusColor(String status) {
    switch (status) {
      case 'Approved':
        return Colors.blue;
      case 'Partially Spent':
        return Colors.orange;
      case 'Fully Spent':
        return Colors.green;
      case 'Completed':
        return const Color(0xFF168A57);
      case 'Pending Delivery':
        return const Color(0xFFC17B13);
      case 'In Progress':
        return const Color(0xFF8250C8);
      case 'Cancelled':
        return AppColors.grey;
      default:
        return AppColors.black;
    }
  }

  Future<void> _editRecord({Map<String, dynamic>? record}) async {
    final formKey = GlobalKey<FormState>();

    final arNumberController = TextEditingController(
      text: record?['ar_number']?.toString() ?? '',
    );

    final nameController = TextEditingController(
      text: record?['expenditure_name'] ?? '',
    );

    final categoryController = TextEditingController(
      text: record?['category'] ?? '',
    );

    final detailsController = TextEditingController(
      text: record?['description'] ?? '',
    );

    final amountController = TextEditingController(
      text: record == null
          ? ''
          : _number(record['approved_amount']).toStringAsFixed(2),
    );

    String status = record?['status']?.toString() ?? 'Approved';
    if (!_statuses.contains(status)) status = 'Approved';
    bool isSaving = false;

    // New records default to the selected monthly report, not today's month.
    // The user can still choose any date using the existing date picker.
    DateTime approvalDate = record != null
        ? (DateTime.tryParse(record['approval_date']?.toString() ?? '') ??
              DateTime.now())
        : (_reportMonth ?? DateTime.now());

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(
              record == null ? 'Add Expenditure' : 'Edit Expenditure',
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (record == null) ...[
                        TextFormField(
                          controller: arNumberController,
                          decoration: const InputDecoration(
                            labelText: 'AR Number (optional)',
                            hintText: 'Leave blank to generate automatically',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (record != null) ...[
                        TextFormField(
                          controller: arNumberController,
                          decoration: const InputDecoration(
                            labelText: 'AR Number *',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Enter an AR Number'
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Company Name *',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Enter a company name'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: categoryController,
                        decoration: const InputDecoration(
                          labelText: 'Category *',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: detailsController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Expenditure Details',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Approved Amount (RM) *',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          final amount = double.tryParse(v?.trim() ?? '');

                          if (amount == null ||
                              !amount.isFinite ||
                              amount < 0) {
                            return 'Enter a valid non-negative amount';
                          }

                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: approvalDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );

                          if (picked != null) {
                            setDialogState(() => approvalDate = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Approval Date',
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(Icons.calendar_month_outlined),
                          ),
                          child: Text(
                            _formatDate(approvalDate.toIso8601String()),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: status,
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                        ),
                        items: _statuses
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => status = v);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                onPressed: isSaving
                    ? null
                    : () async {
                        if (!formKey.currentState!.validate()) return;

                        final siteId = widget.report['site_id']?.toString();
                        if (siteId == null || siteId.isEmpty) {
                          _showMessage(
                            'Cannot save expenditure: residence information is missing.',
                          );
                          return;
                        }

                        setDialogState(() => isSaving = true);
                        final amount = double.parse(
                          amountController.text.trim(),
                        );
                        final newDate =
                            '${approvalDate.year}-'
                            '${approvalDate.month.toString().padLeft(2, '0')}-'
                            '${approvalDate.day.toString().padLeft(2, '0')}';

                        final payload = <String, dynamic>{
                          'site_id': siteId,
                          'expenditure_name': nameController.text.trim(),
                          'category': categoryController.text.trim(),
                          'description': _optionalText(detailsController.text),
                          'approved_amount': amount,
                          'status': status,
                          'approval_date': newDate,
                        };

                        if (record == null) {
                          payload['original_report_month'] =
                              '${approvalDate.year}-'
                              '${approvalDate.month.toString().padLeft(2, '0')}-01';
                          // AR number is optional for creation; otherwise the
                          // database auto-generates the next available serial.
                          final requestedAr = _normalizeArNumber(
                            arNumberController.text,
                          );
                          if (requestedAr.isNotEmpty) {
                            payload['ar_number'] = requestedAr;
                          }
                        } else {
                          payload['id'] = record['id'];
                          final editedArNumber = _normalizeArNumber(
                            arNumberController.text,
                          );
                          if (editedArNumber !=
                              (record['ar_number']?.toString().trim() ?? '')) {
                            payload['ar_number'] = editedArNumber;
                          }
                          final oldMonth = _recordedMonth(record);
                          if (oldMonth == null ||
                              oldMonth.year != approvalDate.year ||
                              oldMonth.month != approvalDate.month) {
                            payload['original_report_month'] =
                                '${approvalDate.year}-'
                                '${approvalDate.month.toString().padLeft(2, '0')}-01';
                          }
                        }

                        late final Map<String, dynamic> savedRecord;
                        try {
                          final response = await _invokeFinance(
                            record == null ? 'create' : 'update',
                            payload: payload,
                          );
                          final saved = response['record'];
                          if (saved is! Map) {
                            throw Exception(
                              'The server did not return the saved expenditure.',
                            );
                          }
                          savedRecord = Map<String, dynamic>.from(saved);
                          if (!_recordMatchesPayload(savedRecord, payload)) {
                            throw Exception(
                              'The server response does not match your changes.',
                            );
                          }
                          if (record != null &&
                              savedRecord['id']?.toString() !=
                                  record['id']?.toString()) {
                            throw Exception(
                              'The server returned another record.',
                            );
                          }
                        } catch (e) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() => isSaving = false);
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Could not confirm save: ${_errorMessage(e)}',
                              ),
                            ),
                          );
                          return;
                        }

                        if (!dialogContext.mounted) return;
                        Navigator.pop(dialogContext);

                        // A real database record has been returned. Only display
                        // normal success after the list refresh also confirms it.
                        try {
                          await _fetchRecords(showLoading: false);
                          if (!mounted) return;
                          final matching = _records.where(
                            (r) =>
                                r['id']?.toString() ==
                                savedRecord['id']?.toString(),
                          );
                          if (matching.isEmpty ||
                              !_recordMatchesPayload(matching.first, payload)) {
                            _showMessage(
                              'Saved in the database, but the list has not '
                              'refreshed correctly. Please refresh the page.',
                            );
                          } else {
                            _showMessage(
                              record == null
                                  ? 'Expenditure added'
                                  : 'Expenditure updated',
                            );
                          }
                        } catch (e) {
                          if (!mounted) return;
                          _showMessage(
                            'Saved in the database, but the list could not '
                            'refresh: ${_errorMessage(e)}',
                          );
                        }
                      },
                child: Text(isSaving ? 'Saving...' : 'Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      arNumberController.dispose();
      nameController.dispose();
      categoryController.dispose();
      detailsController.dispose();
      amountController.dispose();
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete expenditure?'),
        content: Text(
          'Delete ${record['ar_number'] ?? 'this expenditure'}? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final siteId = widget.report['site_id']?.toString();
      if (siteId == null || siteId.isEmpty) {
        throw Exception('Residence ID is missing from the report.');
      }
      final response = await _invokeFinance(
        'delete',
        payload: {'id': record['id'], 'site_id': siteId},
      );
      if (response['success'] != true) {
        throw Exception('The server did not confirm deletion.');
      }

      try {
        await _fetchRecords(showLoading: false);
        if (!mounted) return;
        _showMessage('Expenditure deleted');
      } catch (e) {
        if (!mounted) return;
        _showMessage(
          'Expenditure deleted, but the list could not refresh: '
          '${_errorMessage(e)}',
        );
      }
    } catch (e) {
      if (!mounted) return;

      _showMessage('Delete failed: ${_errorMessage(e)}');
    }
  }

  Widget _summary(
    String title,
    String value,
    IconData icon,
    Color accent, {
    VoidCallback? onTap,
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
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    value,
                    style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
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

  Widget _buildSummary() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: _summary(
            'Total Active Amount (This Month)',
            _money(_totalAmount),
            Icons.account_balance_wallet_outlined,
            AppColors.red,
            onTap: () => _toggleStatusFilter(null),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _summary(
                'Approved',
                '${_count('Approved')}',
                Icons.check_circle_outline,
                const Color(0xFF246B46),
                onTap: () => _toggleStatusFilter('Approved'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summary(
                'Partially Spent',
                '${_count('Partially Spent')}',
                Icons.pending_actions,
                const Color(0xFF946200),
                onTap: () => _toggleStatusFilter('Partially Spent'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _summary(
                'Fully Spent',
                '${_count('Fully Spent')}',
                Icons.task_alt,
                const Color(0xFF22683D),
                onTap: () => _toggleStatusFilter('Fully Spent'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summary(
                'Cancelled',
                '${_count('Cancelled')}',
                Icons.cancel_outlined,
                AppColors.grey,
                onTap: () => _toggleStatusFilter('Cancelled'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _summary(
                'Completed',
                '${_count('Completed')}',
                Icons.check_circle_outline,
                const Color(0xFF168A57),
                onTap: () => _toggleStatusFilter('Completed'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summary(
                'Pending Delivery',
                '${_count('Pending Delivery')}',
                Icons.local_shipping_outlined,
                const Color(0xFFC17B13),
                onTap: () => _toggleStatusFilter('Pending Delivery'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _summary(
                'In Progress',
                '${_count('In Progress')}',
                Icons.pending_actions,
                const Color(0xFF8250C8),
                onTap: () => _toggleStatusFilter('In Progress'),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: SizedBox()),
          ],
        ),
      ],
    );
  }

  Widget _recordCard(Map<String, dynamic> record, {required int number}) {
    final status = record['status']?.toString() ?? 'Approved';
    final color = _statusColor(status);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
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
                  children: [
                    Text(
                      record['expenditure_name']?.toString() ??
                          'Unnamed company',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      record['ar_number']?.toString() ?? 'AR number pending',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                    if (_isCarryForward(record)) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.red.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text(
                          'Carry Forward',
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
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _financeDetail('Category', record['category']?.toString() ?? '-'),
          if (record['description']?.toString().trim().isNotEmpty ?? false) ...[
            const SizedBox(height: 9),
            _financeDetail(
              'Expenditure Details',
              record['description'].toString(),
            ),
          ],
          const SizedBox(height: 10),
          _financeDetail('Approved Amount', _money(record['approved_amount'])),
          const SizedBox(height: 9),
          _financeDetail('Approval Date', _formatDate(record['approval_date'])),
          const Divider(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 5,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => _editRecord(record: record),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
                TextButton.icon(
                  onPressed: () => _deleteRecord(record),
                  icon: const Icon(Icons.delete_outline, size: 18),
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

  Widget _financeDetail(String label, String value) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelWidth = constraints.maxWidth < 460
            ? constraints.maxWidth * 0.38
            : 200.0;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: labelWidth,
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(color: AppColors.black, height: 1.4),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHistory(List<Map<String, dynamic>> history) {
    final grouped = <DateTime, List<Map<String, dynamic>>>{};
    for (final record in history) {
      final month = _recordedMonth(record) ?? DateTime(1900);
      grouped.putIfAbsent(month, () => []).add(record);
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
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
            ),
            Text(
              '${history.length} records',
              style: const TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (months.isEmpty)
          _emptyPanel('No earlier expenditures by Approval Date.')
        else
          for (final month in months)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ExpansionTile(
                key: PageStorageKey(
                  'expenditure-history-${month.year}-${month.month}',
                ),
                initiallyExpanded: false,
                title: Text(
                  month.year == 1900 ? 'Undated' : _monthLabel(month),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${grouped[month]!.length} expenditure record(s)',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  for (var i = 0; i < grouped[month]!.length; i++)
                    _recordCard(grouped[month]![i], number: i + 1),
                ],
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _filteredRecords;
    final history = _filteredHistory;
    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : () => _editRecord(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Expenditure'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadRecords,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          children: [
            _buildHeader(),
            const SizedBox(height: 18),
            if (_loading && _records.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && _records.isEmpty)
              Column(
                children: [
                  Text('Unable to load expenditures: $_error'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _loadRecords,
                    child: const Text('Retry'),
                  ),
                ],
              )
            else ...[
              _buildSummary(),
              const SizedBox(height: 20),
              TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search AR number, company, category or details...',
                  prefixIcon: const Icon(Icons.search, color: AppColors.grey),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () => setState(_searchController.clear),
                          icon: const Icon(Icons.clear),
                        ),
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: AppColors.white,
                ),
              ),
              const SizedBox(height: 9),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
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
                    for (final status in _statuses.where(
                      _selectedStatusFilters.contains,
                    ))
                      Chip(
                        label: Text(status),
                        visualDensity: VisualDensity.compact,
                        onDeleted: () => _toggleStatusFilter(status),
                      ),
                    if (_selectedStatusFilters.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => _toggleStatusFilter(null),
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('Clear filter'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'This Month',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: AppColors.black,
                      ),
                    ),
                  ),
                  Text(
                    '${_thisMonthExpenditures.length} records',
                    style: const TextStyle(color: AppColors.grey, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (current.isEmpty)
                _emptyPanel('No matching expenditure records for this month.')
              else
                for (var i = 0; i < current.length; i++)
                  _recordCard(current[i], number: i + 1),
              const SizedBox(height: 22),
              _buildHistory(history),
            ],
          ],
        ),
      ),
    );
  }
}
