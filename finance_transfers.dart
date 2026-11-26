import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../widgets/styles.dart';
import 'finance_helpers.dart';

enum _TransferSortColumn { date, amount }

class FinanceTransfers extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceTransfers({super.key, required this.report});

  @override
  State<FinanceTransfers> createState() => _FinanceTransfersState();
}

class _FinanceTransfersState extends State<FinanceTransfers> {
  final TextEditingController _searchController = TextEditingController();
  static final NumberFormat _transferAmountFormat = NumberFormat('#,##0.00');

  _TransferSortColumn _sortColumn = _TransferSortColumn.date;
  bool _sortAscending = false; // Default: newest transfer date first.

  List<Map<String, dynamic>> _transfers = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _historyNotice;

  String? get _reportId => widget.report['id']?.toString();

  String? get _siteId {
    final value = widget.report['site_id']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  DateTime? get _reportMonth {
    final raw = widget.report['report_month'] ??
        widget.report['month'] ??
        widget.report['report_date'];
    final date = DateTime.tryParse(raw?.toString() ?? '');
    return date == null ? null : DateTime(date.year, date.month);
  }

  DateTime? _transferMonth(Map<String, dynamic> row) {
    final date = DateTime.tryParse(row['transfer_date']?.toString() ?? '');
    return date == null ? null : DateTime(date.year, date.month);
  }

  int? _compareToSelectedMonth(Map<String, dynamic> row) {
    final month = _transferMonth(row);
    final selected = _reportMonth;
    if (month == null || selected == null) return null;
    return month.compareTo(selected).sign;
  }

  // A transfer is a dated transaction, not an unfinished task.
  // Its transfer_date decides the month, independently of report_id.
  // Newest dates must always appear first, even after editing a transfer.
  int _compareLatestTransferFirst(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final aDate = DateTime.tryParse(a['transfer_date']?.toString() ?? '');
    final bDate = DateTime.tryParse(b['transfer_date']?.toString() ?? '');
    if (aDate == null && bDate != null) return 1;
    if (aDate != null && bDate == null) return -1;
    if (aDate != null && bDate != null) {
      final byDate = bDate.compareTo(aDate);
      if (byDate != 0) return byDate;
    }
    // A stable, newest-first tie-breaker for transfers on the same day.
    final aCreated = a['created_at']?.toString() ?? '';
    final bCreated = b['created_at']?.toString() ?? '';
    final byCreated = bCreated.compareTo(aCreated);
    if (byCreated != 0) return byCreated;
    return (b['id']?.toString() ?? '').compareTo(a['id']?.toString() ?? '');
  }

  // Clicking either column header toggles direction. Switching columns
  // starts in descending order; reopening the page defaults to Date DESC.
  void _changeSort(_TransferSortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = false;
      }
    });
  }

  List<Map<String, dynamic>> _sortVisibleTransfers(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final sorted = rows.toList();
    sorted.sort((a, b) {
      if (_sortColumn == _TransferSortColumn.amount) {
        final comparison = FinanceHelpers.moneyValue(a['amount']).compareTo(
          FinanceHelpers.moneyValue(b['amount']),
        );
        if (comparison != 0) {
          return _sortAscending ? comparison : -comparison;
        }
        return _compareLatestTransferFirst(a, b);
      }

      final aDate = DateTime.tryParse(a['transfer_date']?.toString() ?? '');
      final bDate = DateTime.tryParse(b['transfer_date']?.toString() ?? '');
      // Undated legacy rows stay last in either direction.
      if (aDate == null && bDate != null) return 1;
      if (aDate != null && bDate == null) return -1;
      if (aDate != null && bDate != null) {
        final comparison = aDate.compareTo(bDate);
        if (comparison != 0) {
          return _sortAscending ? comparison : -comparison;
        }
      }
      return _compareLatestTransferFirst(a, b);
    });
    return sorted;
  }

  List<Map<String, dynamic>> get _thisMonthTransfers => _transfers
      .where((row) => _compareToSelectedMonth(row) == 0)
      .toList()
    ..sort(_compareLatestTransferFirst);

  List<Map<String, dynamic>> get _historicalTransfers => _transfers
      .where((row) {
        final difference = _compareToSelectedMonth(row);
        return difference == null || difference < 0;
      })
      .toList()
    ..sort(_compareLatestTransferFirst);

  double _sum(Iterable<Map<String, dynamic>> rows) => rows.fold<double>(
        0,
        (total, row) =>
            total + FinanceHelpers.moneyValue(row['amount']),
      );

  double get _totalTransferred => _sum(_thisMonthTransfers);

  // Includes all dated transfers through the selected report month.
  double get _cumulativeTransferred => _sum([
        ..._thisMonthTransfers,
        ..._historicalTransfers,
      ]);

  double get _collectedSinkingFund => FinanceHelpers.moneyValue(
        widget.report['collection_sinking_fund'],
      );

  String get _monthTitle {
    final month = _reportMonth;
    return month == null
        ? 'Monthly report'
        : '${_monthName(month.month)} ${month.year}';
  }

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static String _monthName(int month) => _months[month - 1];

  String _formatDate(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return 'Not recorded';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  static String _dateForDatabase(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  bool _matchesSearch(Map<String, dynamic> row) {
    final search = _searchController.text.trim().toLowerCase();
    if (search.isEmpty) return true;
    final searchable = [
      row['id'],
      row['amount'],
      row['notes'],
      row['transfer_date'],
      _formatDate(row['transfer_date']),
    ].where((part) => part != null).join(' ').toLowerCase();
    return searchable.contains(search);
  }

  @override
  void initState() {
    super.initState();
    _loadTransfers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTransfers() async {
    final currentId = _reportId;
    if (currentId == null || currentId.isEmpty) {
      if (mounted) {
        setState(() {
          _error = 'No monthly report ID was provided.';
          _loading = false;
        });
      }
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Load transfers for the same property across reports. This also lets a
      // backdated transfer entered in a later report appear in its actual month.
      final reportIds = <String>{currentId};
      String? notice;
      if (_siteId == null) {
        notice = 'Property ID is missing. Only transfers linked to this '
            'report could be retrieved.';
      } else {
        try {
          final reports = await FinanceHelpers.supabase
              .from('monthly_reports')
              .select('id')
              .eq('site_id', _siteId!);
          for (final report in reports) {
            final id = report['id']?.toString();
            if (id != null && id.isNotEmpty) reportIds.add(id);
          }
        } catch (e) {
          notice = 'Other monthly reports could not be loaded: $e';
        }
      }

      final data = await FinanceHelpers.supabase
          .from('finance_sinking_fund_transfers')
          .select()
          .inFilter('report_id', reportIds.toList())
          .order('transfer_date', ascending: false);

      final distinct = <String, Map<String, dynamic>>{};
      for (final raw in data) {
        final row = Map<String, dynamic>.from(raw);
        final id = row['id']?.toString();
        if (id != null) distinct[id] = row;
      }

      if (!mounted) return;
      setState(() {
        _transfers = distinct.values.toList()
          ..sort(_compareLatestTransferFirst);
        _historyNotice = notice;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load transfers: $e';
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool> _saveTransfer({
    required Map<String, dynamic>? existing,
    required DateTime date,
    required double amount,
    required String notes,
  }) async {
    if (_saving) return false;
    final ownerReportId = existing?['report_id']?.toString() ?? _reportId;
    if (ownerReportId == null || ownerReportId.isEmpty) {
      _showMessage('Cannot identify the monthly report for this transfer.');
      return false;
    }

    setState(() => _saving = true);
    try {
      final values = <String, dynamic>{
        'transfer_date': _dateForDatabase(date),
        'amount': amount,
        'notes': notes.trim().isEmpty ? null : notes.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      if (existing == null) {
        await FinanceHelpers.supabase
            .from('finance_sinking_fund_transfers')
            .insert({...values, 'report_id': ownerReportId});
      } else {
        // Keep the original report_id on historical edits.
        final updated = await FinanceHelpers.supabase
            .from('finance_sinking_fund_transfers')
            .update(values)
            .eq('id', existing['id'].toString())
            .eq('report_id', ownerReportId)
            .select('id');
        if (updated.isEmpty) {
          throw Exception('No record updated. Check Supabase permissions.');
        }
      }

      if (!mounted) return true;
      _showMessage(existing == null
          ? 'Transfer added successfully.'
          : 'Transfer updated successfully.');
      await _loadTransfers();
      return true;
    } catch (e) {
      if (mounted) _showMessage('Unable to save transfer: $e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openTransferForm({Map<String, dynamic>? existing}) async {
    if (_saving) return;

    final formKey = GlobalKey<FormState>();
    final amountController = TextEditingController(
      text: existing == null ? '' :
          FinanceHelpers.moneyValue(existing['amount']).toStringAsFixed(2),
    );
    final notesController = TextEditingController(
      text: existing?['notes']?.toString() ?? '',
    );
    DateTime date = DateTime.tryParse(
          existing?['transfer_date']?.toString() ?? '',
        ) ?? _reportMonth ?? DateTime.now();
    bool submitting = false;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: AppColors.white,
            surfaceTintColor: Colors.transparent,
            title: Text(
              existing == null ? 'Add Transfer' : 'Edit Transfer',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TRANSFER DETAILS',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.red,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: submitting ? null : () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null && dialogContext.mounted) {
                            setDialogState(() => date = picked);
                          }
                        },
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: Text('Transfer Date: ${_formatDate(date)}'),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: amountController,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Transfer Amount (RM) *',
                          prefixText: 'RM ',
                        ),
                        validator: (value) {
                          final amount = double.tryParse(
                            (value ?? '').trim().replaceAll(',', ''),
                          );
                          if (amount == null ||
                              !amount.isFinite || amount <= 0) {
                            return 'Enter a valid amount greater than zero.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: notesController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Notes (optional)',
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                onPressed: submitting ? null : () async {
                  if (!formKey.currentState!.validate()) return;
                  final amount = double.parse(
                    amountController.text.trim().replaceAll(',', ''),
                  );
                  setDialogState(() => submitting = true);
                  final saved = await _saveTransfer(
                    existing: existing,
                    date: date,
                    amount: amount,
                    notes: notesController.text,
                  );
                  if (!dialogContext.mounted) return;
                  if (saved) {
                    Navigator.pop(dialogContext);
                  } else {
                    setDialogState(() => submitting = false);
                  }
                },
                child: Text(existing == null ? 'Add Transfer' : 'Save Changes'),
              ),
            ],
          ),
        ),
      );
    } finally {
      amountController.dispose();
      notesController.dispose();
    }
  }

  Future<void> _deleteTransfer(Map<String, dynamic> transfer) async {
    if (_saving) return;
    final id = transfer['id']?.toString();
    final ownerId = transfer['report_id']?.toString();
    if (id == null || ownerId == null) {
      _showMessage('Unable to identify this transfer.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete Transfer?'),
        content: const Text('This transfer will be permanently deleted.'),
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

    setState(() => _saving = true);
    try {
      final deleted = await FinanceHelpers.supabase
          .from('finance_sinking_fund_transfers')
          .delete()
          .eq('id', id)
          .eq('report_id', ownerId)
          .select('id');
      if (deleted.isEmpty) {
        throw Exception('No record deleted. Check Supabase permissions.');
      }
      if (!mounted) return;
      _showMessage('Transfer deleted successfully.');
      await _loadTransfers();
    } catch (e) {
      if (mounted) _showMessage('Unable to delete transfer: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildHeader() {
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
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Sinking Fund Transfers',
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w800,
              color: AppColors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_monthTitle • Report ID: ${_reportId ?? 'Unavailable'}',
            style: const TextStyle(
              color: Color(0xFFE0E0E0), fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(
    String label,
    double amount,
    IconData icon, {
    Color accent = AppColors.red,
  }) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 100),
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
            child: Icon(icon, color: accent, size: 23),
          ),
          const SizedBox(width: 12),
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
                  FinanceHelpers.money(amount),
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: AppColors.black,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    final balance = _collectedSinkingFund - _totalTransferred;
    return Column(
      children: [
        _summaryCard(
          'Transfers This Month',
          _totalTransferred,
          Icons.swap_horiz,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = [
              _summaryCard(
                'Sinking Fund Collection',
                _collectedSinkingFund,
                Icons.account_balance_wallet_outlined,
                accent: Colors.blueGrey,
              ),
              _summaryCard(
                'Collection Less Transfers',
                balance,
                Icons.account_balance_outlined,
                accent: balance < 0
                    ? const Color(0xFFB45309)
                    : const Color(0xFF22683D),
              ),
            ];
            if (constraints.maxWidth < 560) {
              return Column(
                children: [
                  cards[0],
                  const SizedBox(height: 12),
                  cards[1],
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 12),
                Expanded(child: cards[1]),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _summaryCard(
          'Cumulative Transfers to Date',
          _cumulativeTransferred,
          Icons.history,
          accent: Colors.blueGrey,
        ),
      ],
    );
  }

  // A single compact register combines the selected month and history.
  // Dates and amounts can be sorted; notes have their own column on desktop.
  Widget _transferActions(Map<String, dynamic> transfer) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Edit transfer',
          onPressed: _saving
              ? null
              : () => _openTransferForm(existing: transfer),
          icon: const Icon(Icons.edit_outlined, size: 18),
          color: AppColors.black,
          constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
          padding: const EdgeInsets.all(6),
        ),
        IconButton(
          tooltip: 'Delete transfer',
          onPressed: _saving ? null : () => _deleteTransfer(transfer),
          icon: const Icon(Icons.delete_outline, size: 18),
          color: AppColors.red,
          constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
          padding: const EdgeInsets.all(6),
        ),
      ],
    );
  }

  Widget _tableCell(
    Widget child, {
    AlignmentGeometry alignment = Alignment.centerLeft,
    bool isHeader = false,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: isHeader ? 9 : 8,
      ),
      child: Align(alignment: alignment, child: child),
    );
  }

  Widget _sortHeader(
    String label,
    _TransferSortColumn column, {
    bool alignRight = false,
  }) {
    final active = _sortColumn == column;
    final arrow = !active
        ? Icons.unfold_more
        : _sortAscending
            ? Icons.arrow_upward
            : Icons.arrow_downward;
    return Tooltip(
      message: 'Sort $label ${active && !_sortAscending ? 'ascending' : 'descending'}',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _changeSort(column),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment:
                alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.grey,
                ),
              ),
              const SizedBox(width: 4),
              Icon(arrow, size: 15, color: active ? AppColors.red : AppColors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notesCell(Map<String, dynamic> transfer) {
    final notes = transfer['notes']?.toString().trim() ?? '';
    if (notes.isEmpty) {
      return const Text('-', style: TextStyle(color: AppColors.grey, fontSize: 13));
    }
    return Tooltip(
      message: notes,
      child: Text(
        notes,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: AppColors.black),
      ),
    );
  }

  Widget _transferTable(List<Map<String, dynamic>> transfers) {
    final divider = AppColors.border;
    const headerStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: AppColors.grey,
    );

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  color: const Color(0xFFF7F8FA),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _sortHeader('Transfer Date', _TransferSortColumn.date),
                        ),
                      ),
                      _sortHeader('Amount (RM)', _TransferSortColumn.amount),
                    ],
                  ),
                ),
                if (transfers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('No matching transfer records.',
                        style: TextStyle(color: AppColors.grey)),
                  ),
                for (var i = 0; i < transfers.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: divider),
                  _mobileTransferRow(transfers[i], i + 1),
                ],
              ],
            );
          }

          return Table(
            columnWidths: const {
              0: FixedColumnWidth(56),
              1: FlexColumnWidth(1.65),
              2: FlexColumnWidth(1.55),
              3: FlexColumnWidth(2.45),
              4: FixedColumnWidth(112),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFF7F8FA)),
                children: [
                  _tableCell(const Text('No.', style: headerStyle), isHeader: true),
                  _tableCell(
                    _sortHeader('Transfer Date', _TransferSortColumn.date),
                    isHeader: true,
                  ),
                  _tableCell(
                    _sortHeader('Amount (RM)', _TransferSortColumn.amount,
                        alignRight: true),
                    alignment: Alignment.centerLeft,
                    isHeader: true,
                  ),
                  _tableCell(const Text('Notes', style: headerStyle), isHeader: true),
                  _tableCell(
                    const Text('', style: headerStyle),
                    alignment: Alignment.centerRight,
                    isHeader: true,
                  ),
                ],
              ),
              for (var i = 0; i < transfers.length; i++)
                TableRow(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: divider)),
                  ),
                  children: [
                    _tableCell(
                      Text('${i + 1}',
                          style: const TextStyle(color: AppColors.grey, fontSize: 13)),
                    ),
                    _tableCell(Text(
                      _formatDate(transfers[i]['transfer_date']),
                      style: const TextStyle(fontSize: 13, color: AppColors.black),
                    )),
                    _tableCell(
                      Text(
                        _transferAmountFormat.format(
                          FinanceHelpers.moneyValue(transfers[i]['amount']),
                        ),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.black,
                        ),
                      ),
                      alignment: Alignment.centerLeft,
                    ),
                    _tableCell(_notesCell(transfers[i])),
                    _tableCell(
                      _transferActions(transfers[i]),
                      alignment: Alignment.centerRight,
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _mobileTransferRow(Map<String, dynamic> transfer, int number) {
    final notes = transfer['notes']?.toString().trim() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: AppColors.red,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatDate(transfer['transfer_date']),
                        style: const TextStyle(fontSize: 13, color: AppColors.black),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _transferAmountFormat.format(
                        FinanceHelpers.moneyValue(transfer['amount']),
                      ),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  _notesCell(transfer),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: _transferActions(transfer),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecords() {
    // Only show transfers up to and including the selected report month,
    // preserving the existing report-month cutoff for historical reports.
    final allRecords = [
      ..._thisMonthTransfers,
      ..._historicalTransfers,
    ];
    final filtered = _sortVisibleTransfers(allRecords.where(_matchesSearch));
    final searchActive = _searchController.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Total Records',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: AppColors.black,
                ),
              ),
            ),
            Text('${allRecords.length} records',
                style: const TextStyle(color: AppColors.grey, fontSize: 12)),
          ],
        ),
        if (searchActive) ...[
          const SizedBox(height: 4),
          Text('${filtered.length} matching transfers',
              style: const TextStyle(color: AppColors.grey, fontSize: 12)),
        ],
        const SizedBox(height: 12),
        _transferTable(filtered),
      ],
    );
  }

  Widget _buildSearchBar() {
    return TextField(
      controller: _searchController,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'Search transfer date, amount or notes...',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _searchController.clear();
                  setState(() {});
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          color: AppColors.red,
          onRefresh: _loadTransfers,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 110),
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(_error!, style: const TextStyle(color: AppColors.red)),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: _loadTransfers,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              else ...[
                _buildSummaryCards(),
                const SizedBox(height: 22),
                if (_historyNotice != null) ...[
                  Text(_historyNotice!,
                      style: const TextStyle(color: Color(0xFFB45309))),
                  const SizedBox(height: 12),
                ],
                _buildSearchBar(),
                const SizedBox(height: 22),
                _buildRecords(),
              ],
            ],
          ),
        ),
        Positioned(
          right: 20,
          bottom: 20,
          child: FloatingActionButton.extended(
            heroTag: 'add_sinking_fund_transfer',
            onPressed: _loading || _saving
                ? null
                : () => _openTransferForm(),
            backgroundColor: AppColors.red,
            foregroundColor: AppColors.white,
            icon: const Icon(Icons.add),
            label: const Text('Add Transfer'),
          ),
        ),
      ],
    );
  }
}