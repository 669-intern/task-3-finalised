import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

/// Property-wide Defaulters register shown in the selected monthly report.
/// This Month / History and historical status are read from
/// public.finance_defaulters_monthly; the underlying debts are not duplicated.
class FinanceDefaulters extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceDefaulters({super.key, required this.report});

  @override
  State<FinanceDefaulters> createState() => _FinanceDefaultersState();
}

class _FinanceDefaultersState extends State<FinanceDefaulters> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _records = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _statusFilter;
  int _requestSerial = 0;

  String? get _reportId => _nonEmpty(widget.report['id']);
  String? get _siteId => _nonEmpty(widget.report['site_id']);

  DateTime? get _reportMonth => _parseDate(
        widget.report['report_month'] ??
            widget.report['month'] ??
            widget.report['report_date'],
      );

  static String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void didUpdateWidget(covariant FinanceDefaulters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['id']?.toString() != widget.report['id']?.toString() ||
        oldWidget.report['site_id']?.toString() !=
            widget.report['site_id']?.toString()) {
      _searchController.clear();
      _records = [];
      _statusFilter = null;
      _loadRecords();
    }
  }

  @override
  void dispose() {
    _requestSerial++;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    final requestedReportId = _reportId;
    final request = ++_requestSerial;
    if (requestedReportId == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No monthly report ID was provided.';
      });
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final data = await _supabase
          .from('finance_defaulters_monthly')
          .select(
            'report_id, report_month, defaulter_id, original_report_id, '
            'site_id, unit_no, name, due_date, action_taken, '
            'original_total_due, amount_paid, total_due, status, '
            'record_section, completed_date',
          )
          .eq('report_id', requestedReportId)
          .order('total_due', ascending: false)
          .order('unit_no');

      final loaded = data.map((row) => Map<String, dynamic>.from(row)).toList();
      final month = _reportMonth;
      if (loaded.isNotEmpty && month != null) {
        // A newer dated balance becomes this report month's displayed Due Date.
        // Preserve the original Due Date in Supabase so earlier months still
        // include the debt and retain their own historical balances.
        final monthEnd = DateTime(month.year, month.month + 1, 0);
        final ids = loaded
            .map((row) => row['defaulter_id']?.toString())
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();
        if (ids.isNotEmpty) {
          final balanceDates = await _supabase
              .from('finance_defaulter_balance_snapshots')
              .select('defaulter_id, balance_date')
              .inFilter('defaulter_id', ids)
              .lte('balance_date', _isoDate(monthEnd))
              .order('balance_date', ascending: false);
          final latestDates = <String, DateTime>{};
          for (final item in balanceDates) {
            final id = item['defaulter_id']?.toString();
            final date = _parseDate(item['balance_date']);
            if (id != null && date != null) {
              final existing = latestDates[id];
              if (existing == null || date.isAfter(existing)) {
                latestDates[id] = date;
              }
            }
          }
          for (final row in loaded) {
            final effectiveDate = latestDates[row['defaulter_id']?.toString()];
            if (effectiveDate != null) {
              row['display_due_date'] = _isoDate(effectiveDate);
            }
          }
        }
      }

      if (!mounted || request != _requestSerial || _reportId != requestedReportId) {
        return;
      }
      setState(() {
        _records = loaded;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _requestSerial || _reportId != requestedReportId) {
        return;
      }
      setState(() {
        _error = _defaulterError(error);
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _thisMonthRecords => _records
      .where((record) => record['record_section'] == 'This Month')
      .toList();

  List<Map<String, dynamic>> get _historyRecords => _records
      .where((record) => record['record_section'] == 'History')
      .toList();

  bool _matchesSearch(Map<String, dynamic> record) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final searchable = [
      record['unit_no'],
      record['name'],
      record['due_date'],
      record['status'],
      record['action_taken'],
      record['total_due'],
    ].where((value) => value != null).join(' ').toLowerCase();
    return searchable.contains(query);
  }

  Future<Map<String, dynamic>> _fetchOriginal(
    Map<String, dynamic> monthlyRow,
  ) async {
    final id = monthlyRow['defaulter_id']?.toString();
    if (id == null || id.isEmpty) throw StateError('Defaulter ID is missing.');

    var query = _supabase
        .from('finance_defaulters')
        .select('id, report_id, site_id, unit_no, name, total_due, '
            'due_date, initial_balance_date, action_taken')
        .eq('id', id);
    final site = _siteId;
    if (site != null) query = query.eq('site_id', site);
    final original = await query.single();
    return Map<String, dynamic>.from(original);
  }

  Future<void> _openForm([Map<String, dynamic>? monthlyRow]) async {
    if (_busy || _reportId == null) return;
    Map<String, dynamic>? original;
    if (monthlyRow != null) {
      try {
        original = await _fetchOriginal(monthlyRow);
      } catch (error) {
        if (mounted) _showMessage(_defaulterError(error), isError: true);
        return;
      }
    }
    if (!mounted) return;

    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DefaulterFormDialog(
        existing: original,
        reportMonth: _reportMonth,
      ),
    );
    if (!mounted || values == null) return;

    setState(() => _busy = true);
    try {
      final reportId = _reportId!;
      final site = _siteId;
      if (original == null) {
        // A debt is property-wide; do not create the same unit again merely
        // because the user opened a different monthly report.
        if (site != null) {
          final duplicates = await _supabase
              .from('finance_defaulters')
              .select('id')
              .eq('site_id', site)
              .eq('unit_no', values['unit_no'] as String)
              .neq('status', 'Completed')
              .limit(1);
          if (duplicates.isNotEmpty) {
            throw StateError(
              'This unit already has an unresolved Defaulters record for '
              'this property. Open that record and use Update Progress instead.',
            );
          }
        }
        final inserted = await _supabase
            .from('finance_defaulters')
            .insert({...values, 'report_id': reportId})
            .select('id');
        if (inserted.isEmpty) {
          throw StateError('Unable to confirm the new record was saved.');
        }
      } else {
        final changed = await _supabase
            .from('finance_defaulters')
            .update(values)
            .eq('id', original['id'].toString())
            .eq('report_id', original['report_id'].toString())
            .select('id');
        if (changed.isEmpty) {
          throw StateError('Unable to confirm the record was updated.');
        }
      }
      await _loadRecords();
      if (!mounted) return;
      _showMessage(original == null
          ? 'Defaulter record added.'
          : 'Defaulter record updated.');
    } catch (error) {
      if (mounted) _showMessage(_defaulterError(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProgress(Map<String, dynamic> monthlyRow) async {
    if (_busy) return;
    Map<String, dynamic> original;
    try {
      original = await _fetchOriginal(monthlyRow);
    } catch (error) {
      if (mounted) _showMessage(_defaulterError(error), isError: true);
      return;
    }
    if (!mounted) return;

    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DefaulterProgressDialog(record: original),
    );
    if (changed == true && mounted) await _loadRecords();
  }

  Future<void> _confirmDelete(Map<String, dynamic> monthlyRow) async {
    if (_busy) return;
    final originalId = _nonEmpty(monthlyRow['defaulter_id']);
    final originalReportId = _nonEmpty(monthlyRow['original_report_id']);
    if (originalId == null || originalReportId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete defaulter?'),
        content: Text(
          'Delete Unit ${monthlyRow['unit_no']} from this property? '
          'This also removes its balances and payments from all report '
          'months and cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() => _busy = true);
    try {
      final deleted = await _supabase
          .from('finance_defaulters')
          .delete()
          .eq('id', originalId)
          .eq('report_id', originalReportId)
          .select('id');
      if (deleted.isEmpty) throw StateError('Unable to confirm deletion.');
      await _loadRecords();
      if (mounted) _showMessage('Defaulter record deleted.');
    } catch (error) {
      if (mounted) _showMessage(_defaulterError(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.red.shade700 : null,
    ));
  }

  Widget _buildHeader() {
    final month = _reportMonth;
    final label = month == null
        ? 'Monthly report'
        : '${_monthName(month.month)} ${month.year}';
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
          const Text('FINANCE', style: TextStyle(
            color: AppColors.red,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          )),
          const SizedBox(height: 8),
          const Text('Defaulters', style: TextStyle(
            color: Colors.white,
            fontSize: 25,
            fontWeight: FontWeight.w800,
          )),
          const SizedBox(height: 8),
          Text(
            '$label • Report ID: ${_reportId ?? 'Unavailable'}',
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(
    String label,
    String value,
    IconData icon,
    Color color, {
    bool wide = false,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: wide ? 88 : 90),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? color : AppColors.border,
              width: selected ? 1.6 : 1,
            ),
            color: selected ? color.withValues(alpha: 0.04) : null,
          ),
          child: Row(
            children: [
              Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(label, style: const TextStyle(
                      color: AppColors.grey, fontSize: 12,
                    )),
                    const SizedBox(height: 4),
                    Text(value, style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
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

  void _toggleStatusFilter(String status) {
    setState(() {
      _statusFilter = _statusFilter == status ? null : status;
    });
  }

  Widget _buildSummaries() {
    final open = _thisMonthRecords;
    final total = open.fold<double>(
      0, (sum, record) => sum + _amount(record['total_due']),
    );
    final outstanding = open.where((r) => r['status'] == 'Outstanding').length;
    final partial = open.where((r) => r['status'] == 'Partially Paid').length;
    final complete = _historyRecords.length;

    return Column(
      children: [
        _summaryCard('Total Outstanding Amount',
            _ringgit(total), Icons.account_balance_wallet_outlined,
            AppColors.red, wide: true),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _summaryCard('Outstanding', '$outstanding',
              Icons.pending_actions_outlined, Colors.red.shade700,
              selected: _statusFilter == 'Outstanding',
              onTap: () => _toggleStatusFilter('Outstanding'))),
          const SizedBox(width: 10),
          Expanded(child: _summaryCard('Partially Paid', '$partial',
              Icons.payments_outlined, const Color(0xFFC58A14),
              selected: _statusFilter == 'Partially Paid',
              onTap: () => _toggleStatusFilter('Partially Paid'))),
          const SizedBox(width: 10),
          Expanded(child: _summaryCard('Completed', '$complete',
              Icons.check_circle_outline, const Color(0xFF178250),
              selected: _statusFilter == 'Completed',
              onTap: () => _toggleStatusFilter('Completed'))),
        ]),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search unit, name, status or action taken...',
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyPanel(String message) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(message, style: const TextStyle(color: AppColors.grey)),
      );

  Color _statusColor(String status) {
    switch (status) {
      case 'Outstanding': return Colors.red.shade700;
      case 'Partially Paid': return const Color(0xFFC58A14);
      case 'Completed': return const Color(0xFF178250);
      default: return AppColors.grey;
    }
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 212,
            child: Text(label, style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.grey,
            )),
          ),
          Expanded(child: Text(value, style: const TextStyle(
            fontSize: 13, color: AppColors.black,
          ))),
        ],
      ),
    );
  }

  String _actionLabel(dynamic value) {
    final text = _nonEmpty(value);
    if (text == null) return '-';

    final match = RegExp(
      r'^\d{4}-\d{2}-\d{2}\s*\|\s*(.*?)\s*\|\s*Remarks:\s*.*$',
      dotAll: true,
    ).firstMatch(text);

    return match?.group(1)?.trim() ?? text;
  }

  Widget _recordCard(int number, Map<String, dynamic> record) {
    final status = record['status']?.toString() ?? 'Outstanding';
    final statusColor = _statusColor(status);
    final date = _parseDate(record['display_due_date'] ?? record['due_date']);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              height: 43,
              width: 43,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.red.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('$number', style: const TextStyle(
                color: AppColors.red, fontSize: 16, fontWeight: FontWeight.bold,
              )),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(record['name']?.toString() ?? '',
                    style: const TextStyle(fontSize: 15,
                        fontWeight: FontWeight.bold, color: AppColors.black)),
                const SizedBox(height: 4),
                Text('Unit ${record['unit_no'] ?? ''}',
                    style: const TextStyle(fontSize: 12, color: AppColors.grey)),
              ],
            )),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(status, style: TextStyle(
                color: statusColor, fontSize: 12, fontWeight: FontWeight.w600,
              )),
            ),
          ]),
          const SizedBox(height: 20),
          _detailRow('Total Due (RM)', _ringgit(_amount(record['total_due']))),
          _detailRow('Due Date', _formatDate(date)),
          _detailRow('Action Taken', _actionLabel(record['action_taken'])),
          if (status == 'Partially Paid')
            _detailRow('Amount Paid', _ringgit(_amount(record['amount_paid']))),
          if (status == 'Completed')
            _detailRow('Completion Date',
                _formatDate(_parseDate(record['completed_date']))),
          const Divider(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              onPressed: _busy ? null : () => _openProgress(record),
              icon: const Icon(Icons.update, size: 17),
              label: const Text('Update Progress'),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _busy ? null : () => _confirmDelete(record),
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text('Delete'),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _recordsCards(List<Map<String, dynamic>> records) {
    if (records.isEmpty) return _emptyPanel('No defaulter records found.');
    return Column(children: [
      for (var i = 0; i < records.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _recordCard(i + 1, records[i]),
        ),
    ]);
  }

  Widget _buildHistory(List<Map<String, dynamic>> history) {
    if (history.isEmpty) return _emptyPanel('No completed defaulters.');
    final byMonth = <DateTime, List<Map<String, dynamic>>>{};
    for (final row in history) {
      final date = _parseDate(row['completed_date']) ?? _reportMonth ?? DateTime.now();
      final month = DateTime(date.year, date.month);
      byMonth.putIfAbsent(month, () => []).add(row);
    }
    final keys = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
    return Column(children: [
      for (final date in keys)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: ExpansionTile(
              key: PageStorageKey<String>('defaulter-history-${date.year}-${date.month}'),
              title: Text('${_monthName(date.month)} ${date.year}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${byMonth[date]!.length} completed '
                  'record${byMonth[date]!.length == 1 ? '' : 's'}'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: _recordsCards(byMonth[date]!),
                ),
              ],
            ),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final monthRows = _thisMonthRecords.where((row) =>
        _matchesSearch(row) &&
        (_statusFilter == null || row['status'] == _statusFilter)).toList();
    final historyRows = _historyRecords.where((row) =>
        _matchesSearch(row) &&
        (_statusFilter == null || row['status'] == _statusFilter)).toList();

    return Stack(children: [
      RefreshIndicator(
        onRefresh: _loadRecords,
        child: ListView(
          padding: const EdgeInsets.all(24),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(38),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Column(children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _loadRecords,
                  child: const Text('Retry'),
                ),
              ])
            else ...[
              _buildSummaries(),
              const SizedBox(height: 18),
              _buildControls(),
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('This Month', style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.bold,
                  color: AppColors.black,
                )),
                Text('${monthRows.length} record${monthRows.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12, color: AppColors.grey)),
              ]),
              const SizedBox(height: 12),
              monthRows.isEmpty
                  ? _emptyPanel('No outstanding or partially paid defaulters for this month.')
                  : _recordsCards(monthRows),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('History', style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.bold,
                  color: AppColors.black,
                )),
                Text('${historyRows.length} record${historyRows.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12, color: AppColors.grey)),
              ]),
              const SizedBox(height: 12),
              _buildHistory(historyRows),
            ],
            const SizedBox(height: 96),
          ],
        ),
      ),
      Positioned(
        right: 24,
        bottom: 18,
        child: ElevatedButton.icon(
          onPressed: _busy || _reportId == null ? null : () => _openForm(),
          icon: const Icon(Icons.add, size: 21),
          label: const Text('Add Defaulter', style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
          )),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.red,
            foregroundColor: Colors.white,
            minimumSize: const Size(148, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
            elevation: 3,
          ),
        ),
      ),
    ]);
  }

}

class _DefaulterFormDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final DateTime? reportMonth;

  const _DefaulterFormDialog({this.existing, this.reportMonth});

  @override
  State<_DefaulterFormDialog> createState() => _DefaulterFormDialogState();
}

class _DefaulterFormDialogState extends State<_DefaulterFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _unitController;
  late final TextEditingController _nameController;
  late final TextEditingController _totalDueController;
  late final TextEditingController _actionController;
  late DateTime _dueDate;

  @override
  void initState() {
    super.initState();
    final record = widget.existing;
    final month = widget.reportMonth ?? DateTime.now();
    final defaultDate = DateTime(month.year, month.month + 1, 0);
    _dueDate = _parseDate(record?['due_date']) ?? defaultDate;
    _unitController = TextEditingController(text: record?['unit_no']?.toString() ?? '');
    _nameController = TextEditingController(text: record?['name']?.toString() ?? '');
    final amount = _amount(record?['total_due']);
    _totalDueController = TextEditingController(
      text: record == null ? '' : amount.toStringAsFixed(2),
    );
    _actionController = TextEditingController(
      text: record?['action_taken']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _unitController.dispose();
    _nameController.dispose();
    _totalDueController.dispose();
    _actionController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() => _dueDate = selected);
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final amount = _parseMoney(_totalDueController.text)!;
    Navigator.pop(context, <String, dynamic>{
      'unit_no': _unitController.text.trim(),
      'name': _nameController.text.trim(),
      'total_due': amount,
      'action_taken': _actionController.text.trim(),
      'due_date': _isoDate(_dueDate),
      'initial_balance_date': _isoDate(_dueDate),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'Add Defaulter' : 'Edit Defaulter'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _unitController,
              decoration: const InputDecoration(
                labelText: 'Unit No. *', hintText: 'e.g. 06-16',
                border: OutlineInputBorder(),
              ),
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Enter the unit number.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name *', border: OutlineInputBorder(),
              ),
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Enter the name.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _totalDueController,
              decoration: const InputDecoration(
                labelText: 'Total Due (RM) *',
                hintText: '0.00', border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              validator: (v) => _validateMoney(v, allowZero: true),
            ),
            const SizedBox(height: 12),
            _dateInput(context, 'Due Date *', _dueDate, _pickDate),
            const SizedBox(height: 12),
            TextFormField(
              controller: _actionController,
              decoration: const InputDecoration(
                labelText: 'Action Taken',
                hintText: 'e.g. Reminder Letter, Form 20',
                border: OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
            ),
          ]),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('Cancel')),
      FilledButton(
        onPressed: _save,
        style: FilledButton.styleFrom(backgroundColor: AppColors.red),
        child: const Text('Save'),
      ),
    ],
  );
}

/// Update Progress uses the two dated child tables and the existing
/// finance_defaulters.action_taken column. No action-history table is used.
class _DefaulterProgressDialog extends StatefulWidget {
  final Map<String, dynamic> record;

  const _DefaulterProgressDialog({required this.record});

  @override
  State<_DefaulterProgressDialog> createState() => _DefaulterProgressDialogState();
}

class _DefaulterProgressDialogState extends State<_DefaulterProgressDialog> {
  final _supabase = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();
  final _actionController = TextEditingController();
  final _remarksController = TextEditingController();

  List<Map<String, dynamic>> _snapshots = [];
  List<Map<String, dynamic>> _payments = [];
  String _category = 'balance';
  String? _editingId;
  String? _editingSource;
  DateTime _date = DateTime.now();
  bool _loading = true;
  bool _saving = false;
  bool _changed = false;
  String? _error;
  String? _notice;
  bool _noticeIsError = false;

  String get _defaulterId => widget.record['id'].toString();

  @override
  void initState() {
    super.initState();
    _prefillAction();
    _loadProgress();
  }

  void _prefillAction() {
    final existing = widget.record['action_taken']?.toString() ?? '';
    // Newly edited actions use a consistent format. Older free-text actions
    // remain editable as a single description.
    final pattern = RegExp(r'^(\d{4}-\d{2}-\d{2}) \| (.*?) \| Remarks: (.*)$',
        dotAll: true);
    final match = pattern.firstMatch(existing);
    if (match == null) {
      _actionController.text = existing;
      return;
    }
    _actionController.text = match.group(2) ?? '';
    _remarksController.text = match.group(3) ?? '';
    _date = _parseDate(match.group(1)) ?? _date;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    _actionController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _loadProgress() async {
    try {
      final snapshots = await _supabase
          .from('finance_defaulter_balance_snapshots')
          .select('id, defaulter_id, balance_date, balance_amount, reason, source')
          .eq('defaulter_id', _defaulterId)
          .order('balance_date', ascending: false);
      final payments = await _supabase
          .from('finance_defaulter_payments')
          .select('id, defaulter_id, payment_date, amount')
          .eq('defaulter_id', _defaulterId)
          .order('payment_date', ascending: false);
      if (!mounted) return;
      setState(() {
        _snapshots = snapshots.map((r) => Map<String, dynamic>.from(r)).toList();
        _payments = payments.map((r) => Map<String, dynamic>.from(r)).toList();
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _defaulterError(error);
      });
    }
  }

  void _selectCategory(String next) {
    if (_saving) return;
    setState(() {
      _category = next;
      _notice = null;
      _editingId = null;
      _editingSource = null;
      _amountController.clear();
      _reasonController.clear();
      _date = next == 'action'
          ? (_parseDate(RegExp(r'^\d{4}-\d{2}-\d{2}')
                  .firstMatch(widget.record['action_taken']?.toString() ?? '')
                  ?.group(0)) ?? DateTime.now())
          : DateTime.now();
    });
  }

  void _editSnapshot(Map<String, dynamic> row) {
    if (_saving) return;
    setState(() {
      _category = 'balance';
      _notice = null;
      _editingId = row['id'].toString();
      _editingSource = row['source']?.toString();
      _date = _parseDate(row['balance_date']) ?? DateTime.now();
      _amountController.text = _amount(row['balance_amount']).toStringAsFixed(2);
      _reasonController.text = row['reason']?.toString() ?? '';
    });
  }

  void _editPayment(Map<String, dynamic> row) {
    if (_saving) return;
    setState(() {
      _category = 'payment';
      _notice = null;
      _editingId = row['id'].toString();
      _editingSource = null;
      _date = _parseDate(row['payment_date']) ?? DateTime.now();
      _amountController.text = _amount(row['amount']).toStringAsFixed(2);
      _reasonController.clear();
    });
  }

  Future<void> _chooseDate() async {
    final result = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (result != null && mounted) setState(() => _date = result);
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _noticeIsError = error;
    });
  }

  Future<void> _saveProgress() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      if (_category == 'balance') {
        final values = <String, dynamic>{
          'balance_date': _isoDate(_date),
          'balance_amount': _parseMoney(_amountController.text)!,
          'reason': _reasonController.text.trim().isEmpty
              ? null
              : _reasonController.text.trim(),
        };
        if (_editingId == null) {
          final saved = await _supabase
              .from('finance_defaulter_balance_snapshots')
              .insert({...values, 'defaulter_id': _defaulterId,
                'source': 'Update Balance'})
              .select('id');
          if (saved.isEmpty) throw StateError('Balance update was not saved.');
        } else if (_editingSource == 'Opening Balance') {
          // The opening snapshot is maintained by the parent table trigger.
          // Editing the parent updates the opening amount and date together.
          final saved = await _supabase
              .from('finance_defaulters')
              .update({
                'total_due': values['balance_amount'],
                'due_date': values['balance_date'],
                'initial_balance_date': values['balance_date'],
              })
              .eq('id', _defaulterId)
              .eq('report_id', widget.record['report_id'].toString())
              .select('id');
          if (saved.isEmpty) throw StateError('Opening balance was not saved.');

          final amended = await _supabase
              .from('finance_defaulter_balance_snapshots')
              .update({'reason': values['reason']})
              .eq('defaulter_id', _defaulterId)
              .eq('source', 'Opening Balance')
              .eq('balance_date', values['balance_date']!)
              .select('id');
          if (amended.isEmpty) {
            throw StateError('Unable to save the opening balance reason.');
          }
        } else {
          final saved = await _supabase
              .from('finance_defaulter_balance_snapshots')
              .update(values)
              .eq('id', _editingId!)
              .eq('defaulter_id', _defaulterId)
              .eq('source', 'Update Balance')
              .select('id');
          if (saved.isEmpty) throw StateError('Balance update was not saved.');
        }
      } else if (_category == 'payment') {
        final values = <String, dynamic>{
          'payment_date': _isoDate(_date),
          'amount': _parseMoney(_amountController.text)!,
        };
        if (_editingId == null) {
          final saved = await _supabase
              .from('finance_defaulter_payments')
              .insert({...values, 'defaulter_id': _defaulterId})
              .select('id');
          if (saved.isEmpty) throw StateError('Payment was not saved.');
        } else {
          final saved = await _supabase
              .from('finance_defaulter_payments')
              .update(values)
              .eq('id', _editingId!)
              .eq('defaulter_id', _defaulterId)
              .select('id');
          if (saved.isEmpty) throw StateError('Payment update was not saved.');
        }
      } else {
        // Only the latest action is kept, as requested: no actions table.
        final action = '${_isoDate(_date)} | '
            '${_actionController.text.trim()} | '
            'Remarks: ${_remarksController.text.trim()}';
        final saved = await _supabase
            .from('finance_defaulters')
            .update({'action_taken': action})
            .eq('id', _defaulterId)
            .eq('report_id', widget.record['report_id'].toString())
            .select('id');
        if (saved.isEmpty) throw StateError('Action Taken was not saved.');
        widget.record['action_taken'] = action;
      }

      _changed = true;
      if (!mounted) return;
      _toast(_category == 'payment' ? 'Payment saved.' :
          _category == 'balance' ? 'Balance saved.' : 'Action Taken updated.');
      _editingId = null;
      _editingSource = null;
      _amountController.clear();
      _reasonController.clear();
      await _loadProgress();
    } catch (error) {
      if (mounted) _toast(_defaulterError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = <String, String>{
      'balance': 'Update Balance',
      'payment': 'Record Payment',
      'action': 'Action Taken',
    };
    final accent = _category == 'balance'
        ? AppColors.red
        : _category == 'payment'
            ? const Color(0xFF168A57)
            : const Color(0xFFB96D04);
    final background = _category == 'balance'
        ? const Color(0xFFFCE8E9)
        : _category == 'payment'
            ? const Color(0xFFEAF7EF)
            : const Color(0xFFFFF4E7);
    return AlertDialog(
      backgroundColor: background,
      title: const Text('Update Progress'),
      content: SizedBox(
        width: 590,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Unit ${widget.record['unit_no']} • '
                    '${widget.record['name']}',
                  style: const TextStyle(color: AppColors.grey)),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final category in categories.entries)
                  ChoiceChip(
                    label: Text(category.value),
                    selected: _category == category.key,
                    selectedColor: accent.withValues(alpha: 0.13),
                    backgroundColor: Colors.white,
                    checkmarkColor: accent,
                    side: BorderSide(
                      color: _category == category.key ? accent : AppColors.border,
                    ),
                    labelStyle: TextStyle(
                      color: _category == category.key ? accent : AppColors.black,
                    ),
                    onSelected: _saving ? null : (_) => _selectCategory(category.key),
                  ),
              ]),
              const SizedBox(height: 14),
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _dateInput(context,
                      _category == 'balance' ? 'Balance As At *' :
                      _category == 'payment' ? 'Payment Date *' : 'Action Date *',
                      _date, _chooseDate),
                    const SizedBox(height: 12),
                    if (_category == 'balance' || _category == 'payment') ...[
                      TextFormField(
                        controller: _amountController,
                        decoration: InputDecoration(
                          labelText: _category == 'balance'
                              ? 'New Total Due (RM) *' : 'Amount Received (RM) *',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                        ],
                        validator: (v) => _validateMoney(v,
                            allowZero: _category == 'balance'),
                      ),
                      if (_category == 'balance') ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _reasonController,
                          decoration: const InputDecoration(
                            labelText: 'Reason for Update',
                            border: OutlineInputBorder(),
                          ),
                          minLines: 1,
                          maxLines: 3,
                        ),
                      ],
                    ] else ...[
                      TextFormField(
                        controller: _actionController,
                        decoration: const InputDecoration(
                          labelText: 'Action Description *',
                          hintText: 'e.g. Reminder Letter, Form 20',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Enter the action taken.' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _remarksController,
                        decoration: const InputDecoration(
                          labelText: 'Remarks *', border: OutlineInputBorder(),
                        ),
                        minLines: 1,
                        maxLines: 3,
                      ),
                    ],
                  ],
                ),
              ),
              if (_notice != null) ...[
                const SizedBox(height: 10),
                Text(_notice!, style: TextStyle(
                  color: _noticeIsError ? Colors.red.shade700
                      : const Color(0xFF178250),
                  fontSize: 13,
                )),
              ],
              if (_category != 'action') ...[
                const SizedBox(height: 16),
                const Divider(),
                Text(_category == 'balance' ? 'Balance History' : 'Payment History',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_error != null)
                  Text(_error!, style: const TextStyle(color: Colors.red))
                else if (_category == 'balance')
                  _historyList(_snapshots, isBalance: true)
                else
                  _historyList(_payments, isBalance: false),
              ],
              const SizedBox(height: 8),
              if (_editingId != null)
                TextButton.icon(
                  onPressed: _saving ? null : () => _selectCategory(_category),
                  icon: const Icon(Icons.close),
                  label: const Text('Cancel editing this entry'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, _changed),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _saving ? null : _saveProgress,
          style: FilledButton.styleFrom(backgroundColor: accent),
          child: Text(_saving ? 'Saving...' :
              _editingId == null ? 'Save Progress' : 'Save Changes'),
        ),
      ],
    );
  }

  Widget _historyList(List<Map<String, dynamic>> rows,
      {required bool isBalance}) {
    if (rows.isEmpty) {
      return const Text('No previous entries.',
          style: TextStyle(color: AppColors.grey));
    }
    return Column(children: [
      for (final row in rows)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            '${_formatDate(_parseDate(row[isBalance ? 'balance_date' : 'payment_date']))} '
            '• ${_ringgit(_amount(row[isBalance ? 'balance_amount' : 'amount']))}',
          ),
          subtitle: isBalance
              ? Text('${row['source'] == 'Opening Balance' ? 'Opening Balance' : 'Update Balance'} '
                  '• ${row['reason'] ?? ''}')
              : const Text('Payment received'),
          trailing: IconButton(
            tooltip: 'Edit this entry',
            onPressed: _saving ? null : () => isBalance
                ? _editSnapshot(row)
                : _editPayment(row),
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
        ),
    ]);
  }
}

// Utilities are local to this file; no other Dart file needs to be changed.
DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  final date = DateTime.tryParse(value.toString());
  return date == null ? null : DateTime(date.year, date.month, date.day);
}

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _formatDate(DateTime? date) {
  if (date == null) return '-';
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/'
      '${date.year.toString().padLeft(4, '0')}';
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
String _monthName(int month) => _monthNames[month - 1];

double _amount(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _ringgit(double amount) {
  final negative = amount < 0;
  final parts = amount.abs().toStringAsFixed(2).split('.');
  final integerPart = parts.first;
  final buffer = StringBuffer();
  for (var i = 0; i < integerPart.length; i++) {
    if (i > 0 && (integerPart.length - i) % 3 == 0) buffer.write(',');
    buffer.write(integerPart[i]);
  }
  return 'RM ${negative ? '-' : ''}$buffer.${parts.last}';
}

double? _parseMoney(String value) {
  final normalized = value.trim().replaceAll(',', '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(normalized)) return null;
  final amount = double.tryParse(normalized);
  if (amount == null || !amount.isFinite || amount > 999999999999.99) {
    return null;
  }
  return double.parse(amount.toStringAsFixed(2));
}

String? _validateMoney(String? value, {required bool allowZero}) {
  final amount = _parseMoney(value ?? '');
  if (amount == null || amount < 0 || (!allowZero && amount <= 0)) {
    return allowZero
        ? 'Enter a valid amount with up to two decimals.'
        : 'Enter an amount greater than zero (up to two decimals).';
  }
  return null;
}

Widget _dateInput(
  BuildContext context,
  String label,
  DateTime value,
  VoidCallback onTap,
) => InkWell(
  onTap: onTap,
  child: InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: const Icon(Icons.calendar_month_outlined),
      border: const OutlineInputBorder(),
    ),
    child: Text(_formatDate(value)),
  ),
);

String _defaulterError(Object error) {
  if (error is PostgrestException) {
    if (error.code == '23505') {
      return 'There is already a balance record for that date or a duplicate unit. '
          'Edit the existing entry instead.';
    }
    return error.message;
  }
  if (error is StateError) return error.message;
  return error.toString().replaceFirst(RegExp(r'^Exception: '), '');
}