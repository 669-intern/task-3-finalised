import 'package:flutter/material.dart';

import '../widgets/styles.dart';
import 'finance_helpers.dart';

class FinanceBilling extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceBilling({super.key, required this.report});

  @override
  State<FinanceBilling> createState() => _FinanceBillingState();
}

class _FinanceBillingState extends State<FinanceBilling> {
  final _formKey = GlobalKey<FormState>();

  // Total Billing fields.
  // Service Charge and Sinking Fund are recurring monthly billing amounts.
  // Other Income is recorded separately for each month.
  final Map<String, TextEditingController> _controllers = {
    'billing_service_charge': TextEditingController(text: '0.00'),
    'billing_sinking_fund': TextEditingController(text: '0.00'),
    'billing_other': TextEditingController(text: '0.00'),

    // Total Collection fields are independent monthly values.
    'collection_service_charge': TextEditingController(text: '0.00'),
    'collection_sinking_fund': TextEditingController(text: '0.00'),
    'collection_other': TextEditingController(text: '0.00'),
    'collection_open_credit': TextEditingController(text: '0.00'),
  };

  bool _loading = true;
  bool _saving = false;
  bool _completed = false;
  String? _reportMonth;
  String? _billingUpdatedAt;
  String? _actionError;
  bool get _busy => _saving;
  final Map<String, String> _loadedAmounts = {};
  int _loadRequestId = 0;

  String? _error;
  String? _message;

  double _amount(String key) =>
      double.tryParse(_controllers[key]!.text.trim().replaceAll(',', '')) ?? 0;

  // Total Billing = Service Charge + Sinking Fund + Other Income.
  // Open Credit is NOT included in Total Billing.
  double get _billingTotal =>
      _amount('billing_service_charge') +
      _amount('billing_sinking_fund') +
      _amount('billing_other');

  // Total Collection = collected Service Charge + collected Sinking Fund
  //                  + collected Other Income + Open Credit.
  double get _collectionTotal =>
      _amount('collection_service_charge') +
      _amount('collection_sinking_fund') +
      _amount('collection_other') +
      _amount('collection_open_credit');

  // Match the monthly report: Total Collection / Total Billing * 100.
  // Open Credit is in Total Collection only, never the denominator.
  // No billing means the percentage is not applicable (not 0%).
  double? get _collectionRate =>
      _billingTotal <= 0 ? null : _collectionTotal / _billingTotal * 100;

  String? get _reportId {
    final id = widget.report['id']?.toString();
    return id == null || id.isEmpty ? null : id;
  }

  @override
  void initState() {
    super.initState();

    for (final controller in _controllers.values) {
      controller.addListener(_changed);
    }

    _load();
  }

  @override
  void didUpdateWidget(covariant FinanceBilling oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['id']?.toString() != widget.report['id']?.toString() ||
        oldWidget.report['site_id']?.toString() !=
            widget.report['site_id']?.toString() ||
        oldWidget.report['status']?.toString() !=
            widget.report['status']?.toString()) {
      _load();
    }
  }

  bool _isCurrentLoad(int requestId, String reportId) =>
      mounted && requestId == _loadRequestId && _reportId == reportId;

  void _changed() {
    if (!mounted || _loading || _busy) return;

    setState(() {
      _message = null;
      _actionError = null;
    });
  }

  void _setAmount(String key, dynamic value) {
    _controllers[key]!.text = FinanceHelpers.moneyValue(
      value,
    ).toStringAsFixed(2);
  }

  Map<String, String> _currentAmounts() => {
    for (final key in _controllers.keys) key: _amount(key).toStringAsFixed(2),
  };

  void _rememberAmounts() {
    _loadedAmounts
      ..clear()
      ..addAll(_currentAmounts());
  }

  void _applyBillingData(Map<String, dynamic> data) {
    _setAmount('billing_service_charge', data['billing_service_charge']);
    _setAmount('billing_sinking_fund', data['billing_sinking_fund']);
    // Keep a genuine zero rather than replacing it with a legacy value.
    _setAmount('billing_other', data['billing_other'] ?? data['other_income']);
    _setAmount('collection_service_charge', data['collection_service_charge']);
    _setAmount('collection_sinking_fund', data['collection_sinking_fund']);
    _setAmount('collection_other', data['collection_other']);
    _setAmount('collection_open_credit', data['collection_open_credit']);
    // Preserve the database timestamp verbatim for optimistic locking.
    _billingUpdatedAt = data['updated_at']?.toString();
    if (_billingUpdatedAt == null || _billingUpdatedAt!.isEmpty) {
      throw Exception('Billing version is missing. Reload the report.');
    }
    _rememberAmounts();
  }

  // Exceptional missing rows must use effective-date history, never a
  // one-time monthly correction or a later property's recurring amount.
  Future<Map<String, dynamic>?> _effectiveBilling(
    String siteId,
    String reportMonth,
  ) async {
    return await FinanceHelpers.supabase
        .from('finance_billing_rate_history')
        .select('service_charge, sinking_fund')
        .eq('site_id', siteId)
        .lte('effective_month', reportMonth)
        .inFilter('scope', ['baseline', 'future'])
        .isFilter('restored_at', null)
        .order('id', ascending: false)
        .limit(1)
        .maybeSingle();
  }

  bool get _hasUnsavedChanges {
    if (_loadedAmounts.isEmpty) return false;
    for (final entry in _controllers.entries) {
      final raw = entry.value.text.trim().replaceAll(',', '');
      final value = double.tryParse(raw);
      if (value == null || !value.isFinite || value < 0 ||
          !RegExp(r'^(?:[0-9]+(?:\.[0-9]{0,2})?|\.[0-9]{1,2})$').hasMatch(raw) ||
          value.toStringAsFixed(2) != _loadedAmounts[entry.key]) {
        return true;
      }
    }
    return false;
  }

  String get _selectedMonthLabel {
    final date = DateTime.tryParse(_reportMonth ?? '');
    return date == null ? 'Selected month' : '${_monthName(date.month)} ${date.year}';
  }

  Future<void> _load({String? successMessage}) async {
    final requestId = ++_loadRequestId;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _saving = false;
      _error = null;
      _actionError = null;
      _message = null;
      _reportMonth = null;
      _billingUpdatedAt = null;
      _completed = false;
      _loadedAmounts.clear();
    });
    for (final key in _controllers.keys) {
      _setAmount(key, 0);
    }

    try {
      final id = _reportId;
      if (id == null) {
        throw Exception('Monthly report ID is missing.');
      }
      final reportData = await FinanceHelpers.supabase
          .from('monthly_reports')
          .select('id, site_id, report_month, status')
          .eq('id', id)
          .maybeSingle();
      if (!_isCurrentLoad(requestId, id)) return;
      if (reportData == null) {
        throw Exception('Monthly report could not be found.');
      }
      final siteId = reportData['site_id']?.toString();
      final reportMonth = reportData['report_month']?.toString();
      if (siteId == null || siteId.isEmpty) {
        throw Exception('This monthly report is not linked to a property.');
      }
      if (reportMonth == null || DateTime.tryParse(reportMonth) == null) {
        throw Exception('Monthly report date is missing or invalid.');
      }
      _reportMonth = reportMonth;
      _completed = reportData['status']?.toString() != 'draft';

      // The actual monthly row is authoritative for both the web and PDF.
      final data = await FinanceHelpers.supabase
          .from('finance_billing_collection')
          .select()
          .eq('report_id', id)
          .maybeSingle();
      if (!_isCurrentLoad(requestId, id)) return;
      if (data != null) {
        _applyBillingData(data);
      } else if (!_completed) {
        final defaults = await _effectiveBilling(siteId, reportMonth);
        if (!_isCurrentLoad(requestId, id)) return;
        _setAmount('billing_service_charge', defaults?['service_charge'] ?? 0);
        _setAmount('billing_sinking_fund', defaults?['sinking_fund'] ?? 0);
        _rememberAmounts();
      } else {
        // Do not present an inferred amount as a saved completed report.
        throw Exception('No saved billing record for this completed report.');
      }
      _message = successMessage;
    } catch (e) {
      if (mounted && requestId == _loadRequestId) {
        _error = successMessage == null
            ? 'Unable to load billing data: $e'
            : '$successMessage Unable to refresh billing data: $e';
      }
    } finally {
      if (mounted && requestId == _loadRequestId) {
        setState(() => _loading = false);
      }
    }
  }

  // Compare whole cents to match the database's exact 20% calculation.
  bool _largeChange(String key, Map<String, String> values) {
    final before = ((double.tryParse(_loadedAmounts[key] ?? '0') ?? 0) * 100).round();
    final after = ((double.tryParse(values[key] ?? '0') ?? 0) * 100).round();
    return before > 0 && (after - before).abs() * 5 > before;
  }

  Widget _billingChangeRow(String label, String before, String after) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Previous: RM $before', style: const TextStyle(color: AppColors.grey)),
          Text('New: RM $after', style: TextStyle(
            fontWeight: FontWeight.w600,
            color: before != after ? AppColors.red : AppColors.black,
          )),
        ],
      ),
    );
  }

  Future<String?> _confirmBillingSave(
    Map<String, String> values,
    bool largeChange,
  ) {
    // Called only when a recurring billing amount has changed.
    String scope = 'current';
    bool acknowledged = false;
    final monthLabel = _selectedMonthLabel;
    final previous = Map<String, String>.of(_loadedAmounts);
    final changedLabels = [
      if (_largeChange('billing_service_charge', values)) 'Service Charge',
      if (_largeChange('billing_sinking_fund', values)) 'Sinking Fund',
    ].join(' and ');
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Update Billing Amounts'),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(monthLabel, style: const TextStyle(color: AppColors.grey)),
                const SizedBox(height: 16),
                _billingChangeRow('Service Charge', previous['billing_service_charge'] ?? '0.00', values['billing_service_charge']!),
                _billingChangeRow('Sinking Fund', previous['billing_sinking_fund'] ?? '0.00', values['billing_sinking_fund']!),
                const Divider(),
                const Text('Apply billing amounts to:', style: TextStyle(fontWeight: FontWeight.w600)),
                RadioGroup<String>(
                  groupValue: scope,
                  onChanged: (value) => setDialogState(() {
                    scope = value ?? 'current';
                    acknowledged = false;
                  }),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        activeColor: AppColors.red,
                        title: const Text('This month only'),
                        value: 'current',
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        activeColor: AppColors.red,
                        title: const Text('This month & upcoming months'),
                        value: 'future',
                      ),
                    ],
                  ),
                ),
                if (scope == 'future')
                  _statusMessage(
                    icon: Icons.warning_amber_rounded,
                    message: 'Existing upcoming draft billing amounts will be replaced, including previously saved amounts. Newly created months will inherit these amounts. Completed reports will not be affected.',
                    color: const Color(0xFF98610B),
                  )
                else
                  const Text('Only this report will be updated. Recurring billing amounts for other months remain unchanged.', style: TextStyle(fontSize: 13, color: AppColors.grey)),
                const SizedBox(height: 12),
                const Text('Other Income and Total Collection are saved only for the selected month.', style: TextStyle(fontSize: 12, color: AppColors.grey)),
                if (largeChange) ...[
                  const SizedBox(height: 12),
                  _statusMessage(
                    icon: Icons.warning_amber_rounded,
                    message: '$changedLabels changed by more than 20%. Please check the entered amounts.',
                    color: const Color(0xFF98610B),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: AppColors.red,
                    title: const Text('I have verified the new billing amounts.'),
                    value: acknowledged,
                    onChanged: (value) => setDialogState(() => acknowledged = value ?? false),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.red, foregroundColor: AppColors.white),
              onPressed: largeChange && !acknowledged ? null : () => Navigator.of(dialogContext).pop(scope),
              child: const Text('Confirm & Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_busy || _loading || _completed || _loadedAmounts.isEmpty || _error != null) return;
    if (_formKey.currentState?.validate() != true) return;
    final id = _reportId;
    if (id == null) return;
    final requestId = _loadRequestId;
    final values = _currentAmounts();
    final version = _billingUpdatedAt;
    // Only the two recurring Total Billing fields require a save-scope dialog.
    // Compare normalized amounts (e.g. 100 and 100.00 are identical).
    final billingChanged =
        values['billing_service_charge'] != _loadedAmounts['billing_service_charge'] ||
        values['billing_sinking_fund'] != _loadedAmounts['billing_sinking_fund'];
    final largeChange = billingChanged &&
        (_largeChange('billing_service_charge', values) ||
            _largeChange('billing_sinking_fund', values));
    // Freeze inputs while the dialog and save are in progress.
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _actionError = null;
      _message = null;
    });
    try {
      // Other Income and Total Collection save directly for this month only.
      var scope = 'current';
      if (billingChanged) {
        final selectedScope = await _confirmBillingSave(values, largeChange);
        if (!_isCurrentLoad(requestId, id) || selectedScope == null) return;
        scope = selectedScope;
      }
      if (!_isCurrentLoad(requestId, id)) return;
      // Send the original loaded version, not a freshly queried timestamp.
      // The RPC handles atomic updates, audit history, and stale-write checks.
      final result = await FinanceHelpers.supabase.rpc(
        'save_finance_billing',
        params: {
          'p_report_id': id,
          'p_service_charge': double.parse(values['billing_service_charge']!),
          'p_sinking_fund': double.parse(values['billing_sinking_fund']!),
          'p_billing_other': double.parse(values['billing_other']!),
          'p_collection_service_charge': double.parse(values['collection_service_charge']!),
          'p_collection_sinking_fund': double.parse(values['collection_sinking_fund']!),
          'p_collection_other': double.parse(values['collection_other']!),
          'p_collection_open_credit': double.parse(values['collection_open_credit']!),
          'p_scope': scope,
          'p_expected_updated_at': version,
          'p_confirm_large_change': largeChange,
        },
      );
      if (!_isCurrentLoad(requestId, id)) return;
      final count = result is Map ? result['upcoming_reports'] ?? 0 : 0;
      await _load(successMessage: scope == 'future'
          ? 'Billing & Collection saved. $count upcoming draft report(s) updated. Future reports will inherit these billing amounts.'
          : 'Billing & Collection saved.');
    } catch (e) {
      if (_isCurrentLoad(requestId, id)) {
        setState(() => _actionError = 'Unable to save billing: $e');
      }
    } finally {
      if (_isCurrentLoad(requestId, id)) setState(() => _saving = false);
    }
  }

  Future<void> _reloadAfterConfirmation() async {
    if (_busy || _loading) return;
    final id = _reportId;
    final requestId = _loadRequestId;
    if (id == null) return;
    if (_hasUnsavedChanges) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Reload Billing?'),
          content: const Text('Unsaved changes will be discarded. Reload the latest saved amounts?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Reload')),
          ],
        ),
      );
      if (!_isCurrentLoad(requestId, id) || discard != true) return;
    }
    if (_isCurrentLoad(requestId, id)) await _load();
  }

  OutlineInputBorder _inputBorder({
    Color color = AppColors.border,
    double width = 1,
  }) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  Widget _amountField(String key, String label, {bool enabled = true}) {
    final fieldEnabled = enabled && !_busy && !_completed && _error == null;
    return SizedBox(
      width: double.infinity,
      child: TextFormField(
        controller: _controllers[key],
        enabled: fieldEnabled,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: false,
        ),
        textAlign: TextAlign.end,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.black,
        ),
        decoration: InputDecoration(
          labelText: label,
          prefixText: 'RM ',
          filled: true,
          fillColor: fieldEnabled ? AppColors.white : AppColors.background,
          labelStyle: const TextStyle(color: AppColors.grey, fontSize: 14),
          floatingLabelStyle: const TextStyle(color: AppColors.red),
          prefixStyle: const TextStyle(color: AppColors.grey, fontSize: 14),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 17,
          ),
          border: _inputBorder(),
          enabledBorder: _inputBorder(),
          focusedBorder: _inputBorder(color: AppColors.red, width: 1.5),
          disabledBorder: _inputBorder(),
          errorBorder: _inputBorder(color: AppColors.red),
          focusedErrorBorder: _inputBorder(color: AppColors.red, width: 1.5),
        ),
        validator: (value) {
          final raw = (value ?? '').trim().replaceAll(',', '');
          final amount = double.tryParse(raw);

          if (amount == null || !amount.isFinite) {
            return 'Enter a valid amount';
          }

          if (amount < 0) {
            return 'Amount cannot be negative';
          }
          if (amount >= 10000000000) {
            return 'Amount exceeds the supported limit';
          }
          if (!RegExp(r'^(?:[0-9]+(?:\.[0-9]{0,2})?|\.[0-9]{1,2})$').hasMatch(raw)) {
            return 'Enter up to two decimal places';
          }

          return null;
        },
      ),
    );
  }

  Widget _fieldGrid(List<Widget> fields) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 2 : 1;
        const spacing = 16.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: 16,
          children: [
            for (final field in fields)
              SizedBox(width: itemWidth, child: field),
          ],
        );
      },
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String description,
    required List<Widget> fields,
    required String totalLabel,
    required double total,
  }) {
    return Card(
      color: AppColors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
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
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _fieldGrid(fields),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      totalLabel,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    'RM ${total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: AppColors.black,
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

  Widget _metricCard({
    required String label,
    required double? amount,
    required IconData icon,
    String suffix = '',
  }) {
    return Container(
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
              Icon(icon, size: 19, color: AppColors.red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: AppColors.grey, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              amount == null ? 'N/A' : '${amount.toStringAsFixed(2)}$suffix',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.black,
              ),
            ),
          ),
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
            'Billing & Collection',
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

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.removeListener(_changed);
      controller.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
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

    return Form(
      key: _formKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 900;
          final pagePadding = isWide ? 28.0 : 16.0;

          return ListView(
            padding: EdgeInsets.all(pagePadding),
            children: [
              _buildHeader(),
              const SizedBox(height: 24),

              LayoutBuilder(
                builder: (context, metricConstraints) {
                  final columns = metricConstraints.maxWidth >= 700 ? 3 : 1;
                  const spacing = 14.0;
                  final width =
                      (metricConstraints.maxWidth - spacing * (columns - 1)) /
                      columns;

                  return Wrap(
                    spacing: spacing,
                    runSpacing: 14,
                    children: [
                      SizedBox(
                        width: width,
                        child: _metricCard(
                          label: 'Total Billing (RM)',
                          amount: _billingTotal,
                          icon: Icons.receipt_long_outlined,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _metricCard(
                          label: 'Total Collection (RM)',
                          amount: _collectionTotal,
                          icon: Icons.account_balance_wallet_outlined,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _metricCard(
                          label: '% of Total Collection',
                          amount: _collectionRate,
                          suffix: '%',
                          icon: Icons.trending_up_rounded,
                        ),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 24),

              _sectionCard(
                icon: Icons.receipt_long_outlined,
                title: 'Total Billing',
                description:
                    '',
                fields: [
                  _amountField('billing_service_charge', 'Service Charge (RM)'),
                  _amountField('billing_sinking_fund', 'Sinking Fund (RM)'),
                  _amountField('billing_other', 'Other Income (RM)'),
                ],
                totalLabel: 'Total Billing (RM)',
                total: _billingTotal,
              ),

              const SizedBox(height: 20),

              _sectionCard(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Total Collection',
                description:
                    '',
                fields: [
                  _amountField(
                    'collection_service_charge',
                    'Service Charge (RM)',
                  ),
                  _amountField('collection_sinking_fund', 'Sinking Fund (RM)'),
                  _amountField('collection_other', 'Other Income (RM)'),
                  _amountField('collection_open_credit', 'Open Credit (RM)'),
                ],
                totalLabel: 'Total Collection (RM)',
                total: _collectionTotal,
              ),

              const SizedBox(height: 20),

              if (_completed) ...[
                _statusMessage(
                  icon: Icons.lock_outline,
                  message: 'This report is completed and billing is read-only.',
                  color: AppColors.grey,
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                _statusMessage(
                  icon: Icons.error_outline,
                  message: _error!,
                  color: AppColors.red,
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _reloadAfterConfirmation,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry loading billing data'),
                ),
                const SizedBox(height: 12),
              ],

              if (_actionError != null) ...[
                _statusMessage(
                  icon: Icons.error_outline,
                  message: _actionError!,
                  color: AppColors.red,
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _reloadAfterConfirmation,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reload latest billing amounts'),
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
                      onPressed: _busy || _loading || _completed || _error != null
                        ? null
                        : _save,
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
                      label: Text(_saving ? 'Saving...' : 'Save Changes'),
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
}