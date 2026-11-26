import 'package:flutter/material.dart';

import '../widgets/styles.dart';
import 'finance_calc.dart';
import 'finance_helpers.dart';

class FinanceArrears extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceArrears({super.key, required this.report});

  @override
  State<FinanceArrears> createState() => _FinanceArrearsState();
}

class _FinanceArrearsState extends State<FinanceArrears> {
  final _formKey = GlobalKey<FormState>();
  final _opening = TextEditingController(text: '0.00');
  final _adjustments = TextEditingController(text: '0.00');

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _message;

  /// True only for the first month with arrears data. Every later month
  /// takes its opening arrears from the previous month's closing.
  bool _openingEditable = true;
  bool _historicalOverride = false;
  int _loadSerial = 0;

  double? _billingTotal;
  double? _collectionTotal;
  double? _previousClosing;

  String? get _reportId {
    final id = widget.report['id']?.toString();
    return id == null || id.isEmpty ? null : id;
  }

  DateTime? get _reportMonth {
    final value = widget.report['report_month'];
    return value == null ? null : DateTime.tryParse(value.toString());
  }

  double? _parse(TextEditingController controller) =>
      double.tryParse(controller.text.trim().replaceAll(',', ''));

  double get _closing => FinanceCalc.closing(
        opening: _parse(_opening) ?? 0,
        billed: _billingTotal ?? 0,
        collected: _collectionTotal ?? 0,
        adjustments: _parse(_adjustments) ?? 0,
      );

  @override
  void initState() {
    super.initState();
    _opening.addListener(_changed);
    _adjustments.addListener(_changed);
    _load();
  }

  @override
  void didUpdateWidget(covariant FinanceArrears oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['id']?.toString() != widget.report['id']?.toString() ||
        oldWidget.report['site_id']?.toString() !=
            widget.report['site_id']?.toString() ||
        oldWidget.report['report_month']?.toString() !=
            widget.report['report_month']?.toString()) {
      _load();
    }
  }

  void _changed() {
    if (!mounted) return;

    setState(() {
      _message = null;
    });
  }

  Future<void> _load() async {
    final id = _reportId;
    final month = _reportMonth;
    final request = ++_loadSerial;

    if (mounted) {
      // Clear the previous report's visible values before changing properties.
      _opening.text = '0.00';
      _adjustments.text = '0.00';
      setState(() {
        _loading = true;
        _error = null;
        _message = null;
        _billingTotal = null;
        _collectionTotal = null;
        _previousClosing = null;
        _openingEditable = false;
        _historicalOverride = false;
      });
    }

    try {
      if (id == null || month == null) {
        throw Exception('Monthly report ID or month is missing.');
      }

      final client = FinanceHelpers.supabase;
      final billing = await client
          .from('finance_billing_collection')
          .select()
          .eq('report_id', id)
          .maybeSingle();

      final carry = await FinanceCalc.arrearsCarryForward(
        reportId: id,
        reportMonth: month,
      );

      final saved = await client
          .from('finance_arrears_reconciliation')
          .select('opening_arrears, opening_arrears_override, adjustments')
          .eq('report_id', id)
          .maybeSingle();

      if (!mounted || request != _loadSerial || _reportId != id) return;

      final historicalOverride = !carry.openingEditable &&
          saved?['opening_arrears_override'] == true;
      if (!carry.openingEditable && carry.previousClosing == null) {
        throw StateError('Previous closing arrears is unavailable.');
      }
      if (historicalOverride && saved?['opening_arrears'] == null) {
        throw StateError('Historical opening override is missing its amount.');
      }

      final opening = carry.openingEditable
          ? FinanceHelpers.moneyValue(saved?['opening_arrears'])
          : historicalOverride
              ? FinanceHelpers.moneyValue(saved!['opening_arrears'])
              : carry.previousClosing!;

      _openingEditable = carry.openingEditable;
      _historicalOverride = historicalOverride;
      _previousClosing = carry.previousClosing;
      _billingTotal = billing == null ? null : FinanceCalc.billed(billing);
      _collectionTotal = billing == null ? null : FinanceCalc.collected(billing);
      _opening.text = opening.toStringAsFixed(2);
      _adjustments.text =
          FinanceHelpers.moneyValue(saved?['adjustments']).toStringAsFixed(2);

      setState(() => _loading = false);
    } catch (e) {
      if (!mounted || request != _loadSerial || _reportId != id) return;
      setState(() {
        _error = 'Unable to load arrears data: $e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });

    try {
      final id = _reportId;
      final month = _reportMonth;
      if (id == null || month == null) {
        throw Exception('Monthly report ID or month is missing.');
      }

      final client = FinanceHelpers.supabase;
      // Do not save an arrears calculation based on a missing billing row.
      final billing = await client
          .from('finance_billing_collection')
          .select('report_id')
          .eq('report_id', id)
          .maybeSingle();
      if (billing == null) {
        throw StateError('Save Billing & Collection for this month first.');
      }

      // Recalculate at the time of saving, not from a stale screen value.
      final carry = await FinanceCalc.arrearsCarryForward(
        reportId: id,
        reportMonth: month,
      );
      final saved = await client
          .from('finance_arrears_reconciliation')
          .select('opening_arrears, opening_arrears_override')
          .eq('report_id', id)
          .maybeSingle();

      if (_reportId != id) {
        throw StateError('The selected monthly report changed during saving.');
      }

      final historicalOverride = !carry.openingEditable &&
          saved?['opening_arrears_override'] == true;
      if (!carry.openingEditable && carry.previousClosing == null) {
        throw StateError('Previous closing arrears is unavailable.');
      }
      if (historicalOverride && saved?['opening_arrears'] == null) {
        throw StateError('Historical opening override is missing its amount.');
      }

      final opening = carry.openingEditable
          ? _parse(_opening)!
          : historicalOverride
              ? FinanceHelpers.moneyValue(saved!['opening_arrears'])
              : carry.previousClosing!;

      final payload = <String, dynamic>{
        'report_id': id,
        'opening_arrears': opening.toStringAsFixed(2),
        'adjustments': _parse(_adjustments)!.toStringAsFixed(2),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (saved == null || (!carry.openingEditable && !historicalOverride)) {
        // A new/non-overridden month always uses normal carry-forward.
        // Existing historical overrides are intentionally left unchanged.
        payload['opening_arrears_override'] = false;
      }

      final written = await client
          .from('finance_arrears_reconciliation')
          .upsert(payload, onConflict: 'report_id')
          .select('report_id, opening_arrears, adjustments, opening_arrears_override')
          .maybeSingle();
      if (written == null ||
          written['opening_arrears'] == null ||
          (FinanceHelpers.moneyValue(written['opening_arrears']) - opening).abs() >
              0.005 ||
          (FinanceHelpers.moneyValue(written['adjustments']) -
                  _parse(_adjustments)!)
              .abs() >
              0.005 ||
          (!historicalOverride &&
              !carry.openingEditable &&
              written['opening_arrears_override'] != false) ||
          (historicalOverride &&
              written['opening_arrears_override'] != true)) {
        throw StateError('The saved arrears values could not be confirmed.');
      }

      if (!mounted || _reportId != id) return;
      await _load();
      if (!mounted || _reportId != id) return;
      if (_error == null) {
        setState(() {
          _message = 'Arrears Reconciliation saved successfully.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Unable to save arrears: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _amountField(
    TextEditingController controller,
    String label, {
    bool allowNegative = false,
    bool readOnly = false,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: readOnly || _saving,
      keyboardType: TextInputType.numberWithOptions(
        decimal: true,
        signed: allowNegative,
      ),
      textAlign: TextAlign.end,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.black,
      ),
      decoration: const InputDecoration(
        prefixText: 'RM ',
        contentPadding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 17,
        ),
      ).copyWith(
        labelText: label,
        helperText: helperText,
        filled: readOnly,
        fillColor: readOnly ? AppColors.background : null,
      ),
      validator: (value) {
        final amount = double.tryParse(
          (value ?? '').trim().replaceAll(',', ''),
        );

        if (amount == null || !amount.isFinite) {
          return 'Enter a valid amount';
        }

        if (!RegExp(r'^-?\d+(\.\d{1,2})?$')
            .hasMatch((value ?? '').trim().replaceAll(',', ''))) {
          return 'Use up to two decimal places';
        }

        if (!allowNegative && amount < 0) {
          return 'Amount cannot be negative';
        }

        return null;
      },
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
            for (final field in fields)
              SizedBox(width: width, child: field),
          ],
        );
      },
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String description,
    required Widget child,
  }) {
    return Card(
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
                    color: AppColors.red.withValues(alpha: 0.08),
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
            child,
          ],
        ),
      ),
    );
  }

  Widget _amountRow(
    String label,
    double amount, {
    bool bold = false,
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: AppColors.black,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              FinanceHelpers.money(amount),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 14,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: valueColor ?? AppColors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard({
    required String label,
    required String amount,
    required IconData icon,
    required Color iconColor,
    String? subtitle,
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
              Icon(icon, size: 19, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.grey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            amount,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
              color: AppColors.black,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.grey,
              ),
            ),
          ],
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
              style: TextStyle(
                color: color,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final reportMonth = widget.report['report_month'] ??
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
            'Arrears Reconciliation',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$monthLabel • Report ID: ${_reportId ?? 'Unavailable'}',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  static String _monthName(int month) {
    const months = [
      'January', 'February', 'March', 'April',
      'May', 'June', 'July', 'August',
      'September', 'October', 'November', 'December',
    ];

    return months[month - 1];
  }

  @override
  void dispose() {
    _loadSerial++;
    _opening.removeListener(_changed);
    _adjustments.removeListener(_changed);
    _opening.dispose();
    _adjustments.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: AppColors.background,
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Container(
      color: AppColors.background,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Form(
            key: _formKey,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 900;

                return ListView(
                  padding: EdgeInsets.all(isWide ? 28 : 16),
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 24),

                    LayoutBuilder(
                      builder: (context, metricConstraints) {
                        final columns =
                            metricConstraints.maxWidth >= 700 ? 3 : 1;
                        const spacing = 14.0;
                        final width = (metricConstraints.maxWidth -
                                spacing * (columns - 1)) /
                            columns;

                        return Wrap(
                          spacing: spacing,
                          runSpacing: 14,
                          children: [
                            SizedBox(
                              width: width,
                              child: _metricCard(
                                label: 'Opening Arrears',
                                amount: FinanceHelpers.money(
                                  _parse(_opening) ?? 0,
                                ),
                                icon: Icons.account_balance_outlined,
                                iconColor: AppColors.red,
                                subtitle: 'Balance at period start',
                              ),
                            ),
                            SizedBox(
                              width: width,
                              child: _metricCard(
                                label: 'Current Closing Arrears',
                                amount: _billingTotal == null
                                    ? 'Unavailable'
                                    : FinanceHelpers.money(_closing),
                                icon: Icons.receipt_long_outlined,
                                iconColor: _billingTotal == null
                                    ? AppColors.grey
                                    : _closing > 0
                                        ? AppColors.red
                                        : const Color(0xFF27845B),
                                subtitle: 'Calculated balance',
                              ),
                            ),
                            SizedBox(
                              width: width,
                              child: _metricCard(
                                label: 'Previous Closing',
                                amount: _previousClosing == null
                                    ? 'Not applicable'
                                    : FinanceHelpers.money(_previousClosing!),
                                icon: Icons.history_rounded,
                                iconColor: const Color(0xFF3576C5),
                                subtitle: _previousClosing == null
                                    ? 'First month with arrears data'
                                    : 'Previous month balance',
                              ),
                            ),
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 24),

                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.red.withValues(alpha: 0.045),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.red.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline,
                            color: AppColors.red,
                            size: 21,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _openingEditable
                                  ? 'This is the first month with arrears '
                                      'data. Enter the confirmed opening '
                                      'balance once. Later months carry '
                                      'forward automatically.'
                                  : _historicalOverride
                                      ? 'This month has an existing historical '
                                          'opening override. Its saved opening '
                                          'has been preserved and is read-only. '
                                          'Future months will include it when '
                                          'calculating carried-forward arrears.'
                                      : 'Opening arrears is carried forward from '
                                          'the previous closing of '
                                          '${FinanceHelpers.money(_previousClosing ?? 0)}. '
                                          'It is recalculated when this page '
                                          'is loaded or saved.',
                              style: const TextStyle(
                                color: AppColors.black,
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    _sectionCard(
                      icon: Icons.edit_note_rounded,
                      title: 'Opening Balance & Adjustments',
                      description: _openingEditable
                          ? 'Enter the opening arrears and any additional '
                              'adjustments for this reporting period.'
                          : _historicalOverride
                              ? 'Historical opening override is preserved. '
                                  'Only adjustments may be changed.'
                              : 'Opening arrears is calculated. Enter any '
                                  'additional adjustments for this reporting '
                                  'period.',
                      child: _fieldGrid([
                        _amountField(
                          _opening,
                          'Opening Arrears',
                          readOnly: !_openingEditable,
                          helperText: _openingEditable
                              ? null
                              : _historicalOverride
                                  ? 'Saved historical override (read-only)'
                                  : 'Previous month closing arrears',
                        ),
                        _amountField(
                          _adjustments,
                          'Adjustments (+ / −)',
                          allowNegative: true,
                        ),
                      ]),
                    ),

                    const SizedBox(height: 20),

                    _sectionCard(
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Current Month Totals',
                      description:
                          'These amounts are retrieved from Billing & '
                          'Collection for the selected monthly report. '
                          'Open Credit belongs to Total Collection, not Billing.',
                      child: Column(
                        children: [
                          _amountRow('Total Billing', _billingTotal ?? 0),
                          const Divider(),
                          _amountRow(
                            'Total Collection',
                            _collectionTotal ?? 0,
                          ),
                          if (_billingTotal == null ||
                              _collectionTotal == null) ...[
                            const SizedBox(height: 12),
                            _statusMessage(
                              icon: Icons.warning_amber_rounded,
                              message:
                                  'Billing & Collection data is incomplete. '
                                  'Save that section first to calculate arrears '
                                  'accurately.',
                              color: AppColors.red,
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    if (_billingTotal != null && _collectionTotal != null)
                      _sectionCard(
                        icon: Icons.calculate_outlined,
                        title: 'Closing Arrears Calculation',
                        description:
                            'The closing balance is calculated automatically '
                            'from the figures above.',
                        child: Column(
                          children: [
                            _amountRow(
                              'Opening Arrears',
                              _parse(_opening) ?? 0,
                            ),
                            _amountRow(
                              'Add: Billing',
                              _billingTotal ?? 0,
                              valueColor: const Color(0xFF27845B),
                            ),
                            _amountRow(
                              'Less: Collection (incl. Open Credit)',
                              -(_collectionTotal ?? 0),
                              valueColor: const Color(0xFF3576C5),
                            ),
                            _amountRow(
                              'Add / Less: Adjustments',
                              _parse(_adjustments) ?? 0,
                            ),
                            const Divider(height: 28),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Closing Arrears',
                                    style: TextStyle(
                                      color: AppColors.grey,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      FinanceHelpers.money(_closing),
                                      style: TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.bold,
                                        color: _closing > 0
                                            ? AppColors.red
                                            : const Color(0xFF27845B),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Opening Arrears + Billing − Collection '
                                    '+ Adjustments',
                                    style: TextStyle(
                                      color: AppColors.grey,
                                      fontSize: 12,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 20),

                    if (_error != null) ...[
                      _statusMessage(
                        icon: Icons.error_outline,
                        message: _error!,
                        color: AppColors.red,
                      ),
                      const SizedBox(height: 12),
                    ],

                    if (_message != null) ...[
                      _statusMessage(
                        icon: Icons.check_circle_outline,
                        message: _message!,
                        color: const Color(0xFF27845B),
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
                            onPressed: _saving || _billingTotal == null ||
                                    _collectionTotal == null
                                ? null
                                : _save,
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
                              _saving ? 'Saving...' : 'Save Changes',
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
          ),
        ),
      ),
    );
  }
}