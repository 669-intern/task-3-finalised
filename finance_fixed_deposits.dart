import 'package:flutter/material.dart';
import 'finance_helpers.dart';
import 'finance_record_history.dart';
import '../widgets/styles.dart';

class FinanceFixedDeposits extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceFixedDeposits({super.key, required this.report});

  @override
  State<FinanceFixedDeposits> createState() => _FinanceFixedDepositsState();
}

class _FinanceFixedDepositsState extends State<FinanceFixedDeposits> {
  final _formKey = GlobalKey<FormState>();
  final _bankController = TextEditingController();
  final _amountController = TextEditingController();
  final _rateController = TextEditingController();
  final _certController = TextEditingController();
  final _allocationController = TextEditingController();
  final _searchController = TextEditingController();
  String? _selectedStatus; // Tapping the status badge filters records.
  final Set<String> _expandedHistoryMonths = <String>{};

  // Deposits for THIS property that were entered in this report's month or
  // earlier (earlier ones are "carried forward").
  List<Map<String, dynamic>> _deposits = [];

  // Deposits entered in a LATER reporting month than the one being viewed.
  int _hiddenLaterCount = 0;

  DateTime _placementDate = DateTime.now();
  DateTime _maturityDate = DateTime.now().add(const Duration(days: 365));

  String? _editingId;
  String? _error;

  bool _loading = true;
  bool _saving = false;
  bool _loadingAllocation = false;
  bool _savingAllocation = false;
  double? _approvedAllocation;
  String? _allocationError;

  // Allocation is a property-specific month-end figure. The latest saved
  // allocation through this report month carries forward when no value is
  // specified for the selected month.
  double? get _notYetPlaced => _approvedAllocation == null
      ? null
      : (_approvedAllocation! - _totalPortfolio)
            .clamp(0.0, double.infinity)
            .toDouble();

  String? get _reportId => widget.report['id']?.toString();

  // Records may be edited from their card in This Month or History. The
  // original report and site IDs are never changed by a normal edit.
  bool _canEditDeposit(Map<String, dynamic> deposit) =>
      deposit['id'] != null && _siteId != null;

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

  DateTime get _reportMonthEnd {
    final reportMonth = _reportMonth;

    if (reportMonth == null) {
      final now = DateTime.now();
      return DateTime(now.year, now.month + 1, 0);
    }

    return DateTime(reportMonth.year, reportMonth.month + 1, 0);
  }

  String? get _siteId {
    final value = widget.report['site_id']?.toString();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The reporting month the deposit was originally entered in.
  DateTime? _originMonth(Map<String, dynamic> deposit) {
    final parsed = _parseDate(deposit['original_report_month']);
    if (parsed == null) return null;

    return DateTime(parsed.year, parsed.month);
  }

  // Report visibility is governed by the actual Placement Date, not the
  // month in which someone typed the record. Future placements stay hidden.
  bool _visibleInThisReport(Map<String, dynamic> deposit) {
    final placement = _placement(deposit);
    if (placement != null) return !placement.isAfter(_reportMonthEnd);
    final origin = _originMonth(deposit);
    final month = _reportMonth;
    return origin != null && month != null && !origin.isAfter(month);
  }

  // Include the placement month and the maturity month, inclusive.
  // The deposit is carried forward automatically in between; no copies.
  List<Map<String, dynamic>> get _thisMonthDeposits {
    final start = _reportMonth;
    if (start == null) return [];
    final end = _reportMonthEnd;
    final records = _deposits.where((deposit) {
      final placed = _placement(deposit);
      final matures = _maturity(deposit);
      if (placed == null || placed.isAfter(end)) return false;
      return matures == null || !matures.isBefore(start);
    }).toList();
    records.sort((a, b) => (_placement(b) ?? DateTime(1900))
        .compareTo(_placement(a) ?? DateTime(1900)));
    return records;
  }

  // Once the maturity month has passed, the record moves to History.
  List<Map<String, dynamic>> get _historyDeposits {
    final start = _reportMonth;
    if (start == null) return [];
    final records = _deposits.where((deposit) {
      final maturity = _maturity(deposit);
      return maturity != null && maturity.isBefore(start);
    }).toList();
    records.sort((a, b) => (_maturity(b) ?? DateTime(1900))
        .compareTo(_maturity(a) ?? DateTime(1900)));
    return records;
  }

  bool _matchesRegisterFilter(Map<String, dynamic> deposit) {
    if (_selectedStatus != null && _statusLabel(deposit) != _selectedStatus) {
      return false;
    }
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      deposit['bank_name'], deposit['cert'], deposit['deposit_amount'],
      deposit['interest_rate'], _formatDate(_placement(deposit)),
      _formatDate(_maturity(deposit)), _statusLabel(deposit),
    ].join(' ').toLowerCase().contains(query);
  }

  bool _isCarriedDeposit(Map<String, dynamic> deposit) {
    final month = _reportMonth;
    final placed = _placement(deposit);
    return month != null && placed != null &&
        DateTime(placed.year, placed.month).isBefore(month);
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Unknown date';

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  double _amount(Map<String, dynamic> deposit) =>
      FinanceHelpers.moneyValue(deposit['deposit_amount']);

  double _interestRate(Map<String, dynamic> deposit) =>
      FinanceHelpers.moneyValue(deposit['interest_rate']);

  DateTime? _placement(Map<String, dynamic> deposit) =>
      _parseDate(deposit['placement_date']);

  DateTime? _maturity(Map<String, dynamic> deposit) =>
      _parseDate(deposit['maturity_date']);

  bool _isActive(Map<String, dynamic> deposit) {
    final placement = _placement(deposit);
    final maturity = _maturity(deposit);
    final end = _reportMonthEnd;

    return placement != null &&
        maturity != null &&
        !placement.isAfter(end) &&
        maturity.isAfter(end);
  }

  bool _isMatured(Map<String, dynamic> deposit) {
    final maturity = _maturity(deposit);

    return maturity != null && !maturity.isAfter(_reportMonthEnd);
  }

  bool _isPlacedByMonthEnd(Map<String, dynamic> deposit) {
    final placement = _placement(deposit);

    return placement != null && !placement.isAfter(_reportMonthEnd);
  }

  bool _maturesWithinNext30Days(Map<String, dynamic> deposit) {
    final maturity = _maturity(deposit);
    final next30Days = _reportMonthEnd.add(const Duration(days: 30));

    return _isActive(deposit) &&
        maturity != null &&
        !maturity.isAfter(next30Days);
  }

  double get _totalPortfolio =>
      _deposits.fold<double>(0, (sum, deposit) => sum + _amount(deposit));

  double get _activePrincipal => _deposits
      .where(_isActive)
      .fold<double>(0, (sum, deposit) => sum + _amount(deposit));

  double get _maturedPrincipal => _deposits
      .where(_isMatured)
      .fold<double>(0, (sum, deposit) => sum + _amount(deposit));

  double get _maturingSoon => _deposits
      .where(_maturesWithinNext30Days)
      .fold<double>(0, (sum, deposit) => sum + _amount(deposit));

  @override
  void initState() {
    super.initState();
    final month = _reportMonth;
    if (month != null) {
      _placementDate = DateTime(month.year, month.month, 1);
      _maturityDate = DateTime(month.year + 1, month.month, 1);
    }
    _loadDeposits();
    _loadAllocation();
  }

  @override
  void dispose() {
    _bankController.dispose();
    _amountController.dispose();
    _rateController.dispose();
    _certController.dispose();
    _allocationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDeposits() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final siteId = _siteId;

      if (siteId == null) {
        throw Exception('Residence ID is missing from the report.');
      }

      // One portfolio per property: read by site_id, never by report_id, so
      // earlier months' deposits carry forward without being copied.
      final result = await FinanceHelpers.supabase
          .from('finance_fixed_deposits')
          .select()
          .eq('site_id', siteId)
          .order('maturity_date', ascending: true);

      if (!mounted) return;

      final all = List<Map<String, dynamic>>.from(result);

      setState(() {
        _deposits = all.where(_visibleInThisReport).toList();
        _hiddenLaterCount = all.length - _deposits.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Unable to load fixed deposits: $e';
        _loading = false;
      });
    }
  }

  Future<void> _loadAllocation() async {
    final siteId = _siteId;
    final reportMonth = _reportMonth;
    if (siteId == null || reportMonth == null) return;

    setState(() {
      _loadingAllocation = true;
      _allocationError = null;
    });
    try {
      final cutoff = _dateForDatabase(
        DateTime(reportMonth.year, reportMonth.month, 1),
      );
      final rows = await FinanceHelpers.supabase
          .from('monthly_reports')
          .select('id, report_month, fd_approved_allocation')
          .eq('site_id', siteId)
          .lte('report_month', cutoff)
          .order('report_month', ascending: false);
      double? allocation;
      for (final row in rows) {
        if (row['fd_approved_allocation'] != null) {
          allocation = FinanceHelpers.moneyValue(row['fd_approved_allocation']);
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _approvedAllocation = allocation;
        _allocationController.text = allocation?.toStringAsFixed(2) ?? '';
        _loadingAllocation = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingAllocation = false;
        _allocationError = 'Unable to load allocation: $e';
      });
    }
  }

  Future<void> _saveAllocation() async {
    if (_savingAllocation) return;
    final siteId = _siteId;
    final reportId = _reportId;
    if (siteId == null || reportId == null) {
      _showMessage('Property or monthly report ID is missing.');
      return;
    }
    final amount = double.tryParse(
      _allocationController.text.trim().replaceAll(',', ''),
    );
    if (amount == null || !amount.isFinite || amount < 0) {
      _showMessage('Enter a valid, non-negative approved allocation.');
      return;
    }
    setState(() => _savingAllocation = true);
    try {
      final updated = await FinanceHelpers.supabase
          .from('monthly_reports')
          .update({'fd_approved_allocation': amount})
          .eq('id', reportId)
          .eq('site_id', siteId)
          .eq('report_month', _dateForDatabase(_reportMonth!))
          .select('id')
          .maybeSingle();
      if (updated == null) {
        throw Exception('Nothing was updated. Check report permissions.');
      }
      if (!mounted) return;
      setState(() => _approvedAllocation = amount);
      _showMessage('Approved FD allocation saved successfully.');
    } catch (e) {
      if (mounted) _showMessage('Unable to save allocation: $e');
    } finally {
      if (mounted) setState(() => _savingAllocation = false);
    }
  }

  Widget _buildAllocationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              'Fixed Deposit Allocation',
              'Set the approved FD allocation for this property and reporting month.',
              Icons.account_balance_wallet_outlined,
            ),
            if (_loadingAllocation) const LinearProgressIndicator(),
            TextField(
              controller: _allocationController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Total Approved FD Allocation (RM)',
                hintText: 'e.g. 500000',
                prefixText: 'RM ',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Total Principal Already Placed: ${FinanceHelpers.money(_totalPortfolio)}',
            ),
            const SizedBox(height: 8),
            Text(
              'Not Yet Placed Principal: ${_notYetPlaced == null ? 'Not set' : FinanceHelpers.money(_notYetPlaced!)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (_allocationError != null) ...[
              const SizedBox(height: 8),
              Text(
                _allocationError!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _savingAllocation || _loadingAllocation
                  ? null
                  : _saveAllocation,
              icon: const Icon(Icons.save_outlined),
              label: Text(_savingAllocation ? 'Saving...' : 'Save Allocation'),
            ),
          ],
        ),
      ),
    );
  }

  void _clearForm() {
    _formKey.currentState?.reset();

    setState(() {
      _editingId = null;
      _bankController.clear();
      _amountController.clear();
      _rateController.clear();
      _certController.clear();
      final month = _reportMonth;
      _placementDate = month == null
          ? DateTime.now()
          : DateTime(month.year, month.month, 1);
      _maturityDate = DateTime(
        _placementDate.year + 1,
        _placementDate.month,
        _placementDate.day,
      );
    });
  }

  void _startEdit(Map<String, dynamic> deposit) {
    if (!_canEditDeposit(deposit)) {
      _showMessage('This fixed deposit is not available to edit.');
      return;
    }
    setState(() {
      _editingId = deposit['id']?.toString();
      _bankController.text = (deposit['bank_name'] ?? '').toString();
      _amountController.text = (deposit['deposit_amount'] ?? '').toString();
      _rateController.text = (deposit['interest_rate'] ?? '').toString();
      _certController.text = (deposit['cert'] ?? '').toString();

      _placementDate = _placement(deposit) ?? DateTime.now();
      _maturityDate =
          _maturity(deposit) ?? DateTime.now().add(const Duration(days: 365));
    });
  }

  Future<void> _pickDate({required bool placement}) async {
    final current = placement ? _placementDate : _maturityDate;
    final first = DateTime(2000, 1, 1);
    final last = DateTime(2100, 12, 31);
    final initial = current.isBefore(first)
        ? first : (current.isAfter(last) ? last : current);
    final picked = await showDatePicker(
      context: context, initialDate: initial, firstDate: first, lastDate: last,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (placement) {
        _placementDate = picked;
      } else {
        _maturityDate = picked;
      }
    });
  }

  String _dateForDatabase(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  Future<bool> _saveDeposit() async {
    if (_saving || _formKey.currentState?.validate() != true) return false;

    if (_reportId == null || _siteId == null || _reportMonth == null) {
      _showMessage('Choose a valid property and reporting month first.');
      return false;
    }

    if (_editingId != null && !_deposits.any(
      (d) => d['id']?.toString() == _editingId && _canEditDeposit(d),
    )) {
      _showMessage('This fixed deposit is no longer available to edit.');
      return false;
    }
    if (!_maturityDate.isAfter(_placementDate)) {
      _showMessage('Maturity date must be after placement date.');
      return false;
    }

    final bankName = _bankController.text.trim();
    final amount = double.tryParse(
      _amountController.text.trim().replaceAll(',', ''),
    );
    final rate = double.tryParse(
      _rateController.text.trim().replaceAll(',', ''),
    );
    if (bankName.isEmpty || amount == null || !amount.isFinite || amount <= 0 ||
        rate == null || !rate.isFinite || rate < 0) {
      _showMessage('Enter a valid bank, positive principal and interest rate.');
      return false;
    }

    final editingId = _editingId;
    final siteId = _siteId!;
    setState(() { _saving = true; _error = null; });
    try {
      final data = <String, dynamic>{
        'bank_name': bankName,
        'deposit_amount': amount,
        'placement_date': _dateForDatabase(_placementDate),
        'maturity_date': _dateForDatabase(_maturityDate),
        'interest_rate': rate,
        'cert': _certController.text.trim().isEmpty
            ? null : _certController.text.trim(),
      };
      if (editingId == null) {
        final originMonth = _reportMonth!;
        await FinanceHelpers.supabase.from('finance_fixed_deposits').insert({
          ...data,
          'report_id': _reportId,
          'site_id': siteId,
          'original_report_month': _dateForDatabase(
            DateTime(originMonth.year, originMonth.month),
          ),
        });
      } else {
        // Deliberately do not overwrite report_id, site_id, or the original
        // report month when editing a carried-forward or historical record.
        final updated = await FinanceHelpers.supabase
            .from('finance_fixed_deposits')
            .update(data)
            .eq('id', editingId)
            .eq('site_id', siteId)
            .select('id');
        if (updated.isEmpty) {
          throw Exception('No deposit was updated. Check your UPDATE policy.');
        }
      }
      if (!mounted) return false;
      _showMessage(editingId == null
          ? 'Fixed deposit added successfully.'
          : 'Fixed deposit updated successfully.');
      _clearForm();
      await _loadDeposits();
      return true;
    } catch (e) {
      if (mounted) _showMessage('Unable to save fixed deposit: $e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteDeposit(Map<String, dynamic> deposit) async {
    if (!_canEditDeposit(deposit)) {
      _showMessage('This fixed deposit is not available to delete.');
      return;
    }
    final id = deposit['id']?.toString();
    final siteId = _siteId;

    if (id == null || id.isEmpty || siteId == null) {
      _showMessage('Unable to identify this fixed deposit.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete fixed deposit?'),
        content: Text(
          'Delete the fixed deposit with '
          '${deposit['bank_name']} and principal '
          '${FinanceHelpers.money(deposit['deposit_amount'])}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await FinanceHelpers.supabase
          .from('finance_fixed_deposits')
          .delete()
          .eq('id', id)
          .eq('site_id', siteId);

      if (!mounted) return;

      if (_editingId == id) _clearForm();

      _showMessage('Fixed deposit deleted successfully.');
      await _loadDeposits();
    } catch (e) {
      if (mounted) {
        _showMessage('Unable to delete fixed deposit: $e');
      }
    }
  }

  Future<void> _showHistory(Map<String, dynamic> deposit) {
    final id = deposit['id']?.toString() ?? '';

    String text(dynamic v) =>
        (v == null || v.toString().trim().isEmpty) ? '-' : v.toString();

    String date(dynamic v) => _formatDate(_parseDate(v));

    return showFinanceRecordHistory(
      context: context,
      tableName: 'finance_fixed_deposits',
      recordId: id,
      title: 'Fixed deposit history',
      fields: [
        FinanceHistoryField('bank_name', 'Bank', text),
        FinanceHistoryField(
          'deposit_amount',
          'Principal',
          (v) => FinanceHelpers.money(FinanceHelpers.moneyValue(v)),
        ),
        FinanceHistoryField(
          'interest_rate',
          'Interest rate',
          (v) => '${FinanceHelpers.moneyValue(v).toStringAsFixed(2)}%',
        ),
        FinanceHistoryField('placement_date', 'Placement date', date),
        FinanceHistoryField('maturity_date', 'Maturity date', date),
        FinanceHistoryField('cert', 'FD cert', text),
      ],
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ============================================================
  // REPORT HEADER
  // ============================================================

  Widget _buildHeader() {
    final reportMonth =
        widget.report['report_month'] ??
        widget.report['month'] ??
        widget.report['report_date'];

    final date = reportMonth == null
        ? null
        : DateTime.tryParse(reportMonth.toString());

    final monthLabel = date == null
        ? 'Monthly report'
        : '${_monthName(date.month)} ${date.year}';

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
            'Fixed Deposits',
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

  // ============================================================
  // STATUS
  // ============================================================

  Color _statusColor(Map<String, dynamic> deposit) {
    if (!_isPlacedByMonthEnd(deposit)) {
      return Colors.blueGrey;
    }
    if (_isMatured(deposit)) {
      return Colors.orange.shade800;
    }
    return Colors.green.shade700;
  }

  String _statusLabel(Map<String, dynamic> deposit) {
    if (!_isPlacedByMonthEnd(deposit)) {
      return 'Not yet placed';
    }
    if (_isMatured(deposit)) {
      return 'Matured';
    }
    return 'Active';
  }

  // ============================================================
  // SECTION COMPONENTS
  // ============================================================

  Widget _sectionHeader(String title, String subtitle, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.red, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.black,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.grey),
                ),
              ],
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
    Color? color,
  }) {
    final accent = color ?? AppColors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accent, size: 22),
            const SizedBox(height: 12),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.grey),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                FinanceHelpers.money(amount),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateButton({
    required String label,
    required DateTime date,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton(
      onPressed: _saving ? null : onPressed,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_month_outlined, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatDate(date),
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.keyboard_arrow_down),
        ],
      ),
    );
  }

  Widget _amountField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required String? Function(String?) validator,
    bool showCurrency = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixText: showCurrency ? 'RM ' : null,
          suffixText: showCurrency ? null : '%',
          prefixIcon: Icon(icon, size: 20),
        ),
        validator: validator,
      ),
    );
  }

  // ============================================================
  // FIXED DEPOSIT FORM
  // ============================================================

  Future<void> _openDepositDialog({Map<String, dynamic>? deposit}) async {
    if (_saving) return;
    if (deposit == null) {
      _clearForm();
    } else {
      _startEdit(deposit);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          backgroundColor: AppColors.white,
          surfaceTintColor: Colors.transparent,
          title: Text(deposit == null ? 'Add Fixed Deposit' : 'Edit Fixed Deposit',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 550,
            child: SingleChildScrollView(
              child: _buildDepositForm(refresh),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.red),
              onPressed: _saving ? null : () async {
                final saved = await _saveDeposit();
                if (saved && dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                } else if (dialogContext.mounted) {
                  refresh(() {});
                }
              },
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(deposit == null ? 'Add Deposit' : 'Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepositForm(StateSetter refreshDialog) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _bankController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Bank name', hintText: 'e.g. Maybank',
              prefixIcon: Icon(Icons.account_balance_outlined),
            ),
            validator: (value) => (value == null || value.trim().isEmpty)
                ? 'Enter the bank name.' : null,
          ),
          const SizedBox(height: 16),
          _amountField(
            controller: _amountController,
            label: 'Deposit principal', hint: '0.00',
            icon: Icons.payments_outlined,
            validator: (value) {
              final amount = double.tryParse(
                (value ?? '').trim().replaceAll(',', ''),
              );
              return amount == null || !amount.isFinite || amount <= 0
                  ? 'Enter an amount greater than zero.' : null;
            },
          ),
          _amountField(
            controller: _rateController,
            label: 'Annual interest rate', hint: 'e.g. 3.50',
            icon: Icons.percent, showCurrency: false,
            validator: (value) {
              final rate = double.tryParse(
                (value ?? '').trim().replaceAll(',', ''),
              );
              return rate == null || !rate.isFinite || rate < 0
                  ? 'Enter a valid non-negative rate.' : null;
            },
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final placement = _dateButton(
                label: 'Placement date', date: _placementDate,
                onPressed: () async {
                  await _pickDate(placement: true);
                  refreshDialog(() {});
                },
              );
              final maturity = _dateButton(
                label: 'Maturity date', date: _maturityDate,
                onPressed: () async {
                  await _pickDate(placement: false);
                  refreshDialog(() {});
                },
              );
              if (constraints.maxWidth < 480) {
                return Column(children: [
                  placement, const SizedBox(height: 12), maturity,
                ]);
              }
              return Row(children: [
                Expanded(child: placement), const SizedBox(width: 12),
                Expanded(child: maturity),
              ]);
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _certController, maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'FD Cert',
              hintText: 'Additional information about this deposit',
              alignLabelWithHint: true,
              prefixIcon: Icon(Icons.notes_outlined),
            ),
          ),
        ],
      ),
    );
  }



  // ============================================================
  // DEPOSIT REGISTER
  // ============================================================

  Widget _financeDetail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: LayoutBuilder(builder: (context, constraints) {
        final labelWidth = constraints.maxWidth < 480
            ? constraints.maxWidth * 0.38
            : 200.0;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: const TextStyle(
              color: AppColors.grey, fontSize: 13,
            )),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(value, style: const TextStyle(
            color: AppColors.black, fontSize: 13,
            fontWeight: FontWeight.w600,
          ))),
        ]);
      }),
    );
  }

  Widget _statusButton(Map<String, dynamic> deposit) {
    final label = _statusLabel(deposit);
    final color = _statusColor(deposit);
    return Tooltip(
      message: 'Filter records by $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() {
          _selectedStatus = _selectedStatus == label ? null : label;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.28)),
          ),
          child: Text(label, style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.bold,
          )),
        ),
      ),
    );
  }

  Widget _depositCard(Map<String, dynamic> deposit, int number,
      {bool historical = false}) {
    final bank = deposit['bank_name']?.toString() ?? 'Unknown bank';
    final cert = deposit['cert']?.toString().trim() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42, height: 42, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$number', style: const TextStyle(
              color: AppColors.red, fontWeight: FontWeight.bold,
              fontSize: 17,
            )),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(bank, style: const TextStyle(fontSize: 16,
                  color: AppColors.black, fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              Text(FinanceHelpers.money(_amount(deposit)),
                style: const TextStyle(fontSize: 13,
                    color: AppColors.grey, fontWeight: FontWeight.w600)),
              if (!historical && _isCarriedDeposit(deposit)) ...[
                const SizedBox(height: 5),
                const Text('Carried forward', style: TextStyle(
                  fontSize: 12, color: AppColors.red,
                  fontWeight: FontWeight.bold,
                )),
              ],
            ],
          )),
          const SizedBox(width: 8),
          _statusButton(deposit),
        ]),
        const SizedBox(height: 12),
        _financeDetail('Placed', _formatDate(_placement(deposit))),
        _financeDetail('Matures', _formatDate(_maturity(deposit))),
        _financeDetail('Interest',
            '${_interestRate(deposit).toStringAsFixed(2)}% p.a.'),
        _financeDetail('Principal', FinanceHelpers.money(_amount(deposit))),
        if (cert.isNotEmpty) _financeDetail('cert', cert),
        const Divider(height: 22),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end, runAlignment: WrapAlignment.end,
          spacing: 8, runSpacing: 4, children: [
          TextButton.icon(
            onPressed: _saving ? null : () => _openDepositDialog(deposit: deposit),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit'),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
          ),
          TextButton.icon(
            onPressed: () => _showHistory(deposit),
            icon: const Icon(Icons.history, size: 18),
            label: const Text('History'),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
          ),
          TextButton.icon(
            onPressed: _saving ? null : () => _deleteDeposit(deposit),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete'),
            style: TextButton.styleFrom(foregroundColor: AppColors.red
            ),
          ),
          ],
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildRegisterFilters() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _searchController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search bank, principal, interest, dates or cert...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty ? null : IconButton(
            icon: const Icon(Icons.close), tooltip: 'Clear search',
            onPressed: () {
              _searchController.clear(); setState(() {});
            },
          ),
        ),
      ),
      if (_selectedStatus != null) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(label: Text('Showing: $_selectedStatus')),
            TextButton.icon(
              onPressed: () => setState(() => _selectedStatus = null),
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Clear filter'),
            ),
          ],
        ),
      ],
    ]);
  }

  Widget _buildDepositList() {
    final current = _thisMonthDeposits.where(_matchesRegisterFilter).toList();
    final historical = _historyDeposits.where(_matchesRegisterFilter).toList();
    final groups = <DateTime, List<Map<String, dynamic>>>{};
    for (final deposit in historical) {
      final date = _maturity(deposit)!;
      final month = DateTime(date.year, date.month);
      groups.putIfAbsent(month, () => []).add(deposit);
    }
    final historyMonths = groups.keys.toList()
      ..sort((a, b) => b.compareTo(a));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Fixed Deposit Register', style: TextStyle(
        fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.black,
      )),
      const SizedBox(height: 14),
      _buildRegisterFilters(),
      if (_hiddenLaterCount > 0) ...[
        const SizedBox(height: 10),
        Text('$_hiddenLaterCount future placement(s) hidden.',
            style: const TextStyle(color: AppColors.grey, fontSize: 12)),
      ],
      const SizedBox(height: 22),
      Row(children: [
        const Expanded(child: Text('This Month', style: TextStyle(
          fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.black,
        ))),
        Text('${_thisMonthDeposits.length} records',
          style: const TextStyle(color: AppColors.grey)),
      ]),
      const SizedBox(height: 12),
      if (current.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No fixed deposits matching this month.',
              style: TextStyle(color: AppColors.grey)),
        )
      else
        ...current.asMap().entries.map((entry) =>
            _depositCard(entry.value, entry.key + 1)),
      const SizedBox(height: 24),
      Row(children: [
        const Expanded(child: Text('History', style: TextStyle(
          fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.black,
        ))),
        Text('${_historyDeposits.length} records',
          style: const TextStyle(color: AppColors.grey)),
      ]),
      const SizedBox(height: 12),
      if (historyMonths.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('No matured deposits from earlier months.',
              style: TextStyle(color: AppColors.grey)),
        )
      else
        for (final month in historyMonths)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                key: ValueKey('fd-history-${month.year}-${month.month}'),
                initiallyExpanded: _expandedHistoryMonths.contains(
                  '${month.year}-${month.month}'),
                onExpansionChanged: (open) => setState(() {
                  final id = '${month.year}-${month.month}';
                  if (open) {
                    _expandedHistoryMonths.add(id);
                  } else {
                    _expandedHistoryMonths.remove(id);
                  }
                }),
                title: Text('${_monthName(month.month)} ${month.year}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('${groups[month]!.length} matured deposit(s)'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                children: groups[month]!.asMap().entries.map((entry) =>
                    _depositCard(entry.value, entry.key + 1,
                        historical: true)).toList(),
              ),
            ),
          ),
    ]);
  }

  Widget _buildSummaryCards() {
    return Column(children: [
      SizedBox(width: double.infinity,
        child: _summaryCard('Total portfolio principal', _totalPortfolio,
            Icons.account_balance_wallet_outlined)),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 760 ? 3 :
            (constraints.maxWidth >= 450 ? 2 : 1);
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        final cards = [
          _summaryCard('Active principal', _activePrincipal,
            Icons.trending_up_outlined, color: Colors.green),
          _summaryCard('Matured principal', _maturedPrincipal,
            Icons.check_circle_outline, color: Colors.orange),
          _summaryCard('Maturing within 30 days', _maturingSoon,
            Icons.event_outlined),
        ];
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final card in cards) SizedBox(width: width, child: card),
        ]);
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : () => _openDepositDialog(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Fixed Deposit'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadDeposits();
          await _loadAllocation();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 950),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 16),
                    if (_loading)
                      const Center(child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      )),
                    if (_error != null)
                      Padding(padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!, style: const TextStyle(
                            color: Colors.red))),
                    _buildSummaryCards(),
                    const SizedBox(height: 16),
                    _buildAllocationCard(),
                    const SizedBox(height: 22),
                    _buildDepositList(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}