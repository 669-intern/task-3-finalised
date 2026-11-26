import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/styles.dart';

class FinanceUtilities extends StatefulWidget {
  final Map<String, dynamic> report;

  const FinanceUtilities({
    super.key,
    required this.report,
  });

  @override
  State<FinanceUtilities> createState() => _FinanceUtilitiesState();
}

class _FinanceUtilitiesState extends State<FinanceUtilities> {
  final _formKey = GlobalKey<FormState>();

  final _electricityController = TextEditingController();
  final _waterController = TextEditingController();
  final _electricityBillController = TextEditingController();
  final _electricityFullBillController = TextEditingController();
  final _waterBillController = TextEditingController();

  DateTime? _waterStartDate;
  DateTime? _waterEndDate;

  bool _loading = true;
  bool _saving = false;

  String? _error;
  String? _message;

  late final DateTime _reportMonth;

  SupabaseClient get _supabase => Supabase.instance.client;

  int get _days => DateUtils.getDaysInMonth(
        _reportMonth.year,
        _reportMonth.month,
      );

  int? get _waterDays {
    if (_waterStartDate == null || _waterEndDate == null) {
      return null;
    }

    final start = DateTime.utc(
      _waterStartDate!.year,
      _waterStartDate!.month,
      _waterStartDate!.day,
    );

    final end = DateTime.utc(
      _waterEndDate!.year,
      _waterEndDate!.month,
      _waterEndDate!.day,
    );

    final days = end.difference(start).inDays;

    return days > 0 ? days : null;
  }

  String get _monthLabel => DateFormat('MMMM yyyy').format(_reportMonth);

  double get _electricityAverage {
    final value = double.tryParse(_electricityController.text.trim());

    if (value == null || value < 0) return 0;

    return value / _days;
  }

  double? get _waterAverage {
    final value = double.tryParse(_waterController.text.trim());
    final days = _waterDays;

    if (value == null || value < 0 || days == null) {
      return null;
    }

    return value / days;
  }

  @override
  void initState() {
    super.initState();

    final rawMonth = widget.report['report_month']?.toString();

    _reportMonth = rawMonth != null
        ? DateTime.tryParse(rawMonth) ?? DateTime.now()
        : DateTime.now();

    _electricityController.addListener(_refreshCalculations);
    _waterController.addListener(_refreshCalculations);

    _load();
  }

  @override
  void dispose() {
    _electricityController.dispose();
    _waterController.dispose();
    _electricityBillController.dispose();
    _electricityFullBillController.dispose();
    _waterBillController.dispose();
    super.dispose();
  }

  void _refreshCalculations() {
    if (!mounted) return;

    setState(() {
      _message = null;
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
    });

    try {
      final reportId = widget.report['id']?.toString();

      if (reportId == null || reportId.isEmpty) {
        throw Exception('The report ID is missing.');
      }

      final response = await _supabase
          .from('finance_utilities')
          .select(
            'electricity_kwh, water_m3, '
            'electricity_bill_rm, electricity_total_bill_rm, '
            'water_bill_rm, water_period_start, water_period_end',
          )
          .eq('report_id', reportId)
          .maybeSingle();

      if (response != null) {
        _electricityController.text =
            response['electricity_kwh']?.toString() ?? '';

        _waterController.text =
            response['water_m3']?.toString() ?? '';

        _electricityBillController.text =
            response['electricity_bill_rm']?.toString() ?? '';

        _electricityFullBillController.text =
            response['electricity_total_bill_rm']?.toString() ?? '';

        _waterBillController.text =
            response['water_bill_rm']?.toString() ?? '';

        _waterStartDate = DateTime.tryParse(
          response['water_period_start']?.toString() ?? '',
        );

        _waterEndDate = DateTime.tryParse(
          response['water_period_end']?.toString() ?? '',
        );
      }

    } catch (e) {
      _error = 'Failed to load utility data: $e';
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
 
    if ((_waterStartDate == null) != (_waterEndDate == null)) {
      setState(() {
        _error = 'Please select both water start and end dates.';
        _message = null;
      });
      return;
    }

    if (_waterStartDate != null &&
        _waterEndDate!.isBefore(_waterStartDate!)) {
      setState(() {
        _error = 'Water end date cannot be before start date.';
        _message = null;
      });
      return;
    }

    final reportId = widget.report['id']?.toString();

    if (reportId == null || reportId.isEmpty) {
      setState(() {
        _error = 'The report ID is missing.';
        _message = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });

    try {

    final data = <String, dynamic>{
      'report_id': reportId,
      'report_month': DateFormat('yyyy-MM-01').format(_reportMonth),

      'electricity_kwh':
          _parseOptionalNumber(_electricityController.text),

      'electricity_bill_rm':
          _parseOptionalNumber(_electricityBillController.text),

      'electricity_total_bill_rm':
          _parseOptionalNumber(_electricityFullBillController.text),

      'water_m3':
          _parseOptionalNumber(_waterController.text),

      'water_bill_rm':
          _parseOptionalNumber(_waterBillController.text),

      'water_period_start': _waterStartDate == null
          ? null
          : DateFormat('yyyy-MM-dd').format(_waterStartDate!),

      'water_period_end': _waterEndDate == null
          ? null
          : DateFormat('yyyy-MM-dd').format(_waterEndDate!),

      'updated_at': DateTime.now().toIso8601String(),
    };

      await _supabase
          .from('finance_utilities')
          .upsert(data, onConflict: 'report_id');

      if (!mounted) return;

      setState(() {
        _message = 'Utility data saved successfully.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Failed to save utility data: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  double? _parseOptionalNumber(String value) {
    final trimmed = value.trim();

    if (trimmed.isEmpty) return null;

    return double.tryParse(trimmed);
  }

  String? _validateNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = double.tryParse(value.trim());

    if (number == null) {
      return 'Enter a valid number';
    }

    if (number < 0) {
      return 'Value cannot be negative';
    }

    return null;
  }

  Widget _numberField({
    required String label,
    required String unit,
    required TextEditingController controller,
    required IconData icon,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: _validateNumber,
      decoration: InputDecoration(
        labelText: label,
        suffixText: unit,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }
  
  Widget _dateField({
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime> onChanged,
  }) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? _reportMonth,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );

        if (picked != null && mounted) {
          setState(() {
            onChanged(picked);
            _message = null;
          });
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.date_range),
          suffixIcon: const Icon(Icons.calendar_today),
          border: const OutlineInputBorder(),
        ),
        child: Text(
          value == null
              ? 'Select date'
              : DateFormat('dd/MM/yyyy').format(value),
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
  }) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              unit,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatNumber(double value) {
    return NumberFormat('#,##0.00').format(value);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: _loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              ),
            )
          : Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Utilities',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Monthly utility consumption for $_monthLabel',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reload'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(color: AppColors.error),
                      ),
                    ),
                  ],

                  if (_message != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.success.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        _message!,
                        style: TextStyle(color: AppColors.success),
                      ),
                    ),
                  ],


                  _sectionCard(
                    title: 'Electricity',
                    icon: Icons.bolt,
                    children: [
                      _numberField(
                        label: 'Electricity Consumption',
                        unit: 'kWh',
                        controller: _electricityController,
                        icon: Icons.electric_meter,
                      ),

                      const SizedBox(height: 16),

                      _numberField(
                        label: 'Total Bill',
                        unit: 'RM',
                        controller: _electricityBillController,
                        icon: Icons.receipt_long,
                      ),

                      const SizedBox(height: 16),

                      _numberField(
                        label: 'Total Bill Including Maximum Demand, ICPT '
                            '& Renewable Energy Fund',
                        unit: 'RM',
                        controller: _electricityFullBillController,
                        icon: Icons.payments,
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                _sectionCard(
                  title: 'Water',
                  icon: Icons.water_drop,
                  children: [
                    _numberField(
                      label: 'Water Consumption',
                      unit: 'm³',
                      controller: _waterController,
                      icon: Icons.water,
                    ),

                    const SizedBox(height: 16),

                    _dateField(
                      label: 'Start Date',
                      value: _waterStartDate,
                      onChanged: (date) {
                        _waterStartDate = date;
                      },
                    ),

                    const SizedBox(height: 16),

                    _dateField(
                      label: 'End Date',
                      value: _waterEndDate,
                      onChanged: (date) {
                        _waterEndDate = date;
                      },
                    ),

                    const SizedBox(height: 16),

                    _numberField(
                      label: 'Total Bill',
                      unit: 'RM',
                      controller: _waterBillController,
                      icon: Icons.receipt_long,
                    ),
                  ],
                ),

                  const SizedBox(height: 16),

                  Text(
                    'Daily Averages',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 600;

                      final electricityCard = _metricCard(
                        title: 'Average Electricity',
                        value: _formatNumber(_electricityAverage),
                        unit: 'kWh per day',
                        icon: Icons.bolt,
                      );

                      final waterCard = _metricCard(
                        title: 'Average Water',
                        value: _waterAverage == null
                          ? '-'
                          : _formatNumber(_waterAverage!),
                        unit: 'm³ per day',
                        icon: Icons.water_drop,
                      );

                      if (isWide) {
                        return Row(
                          children: [
                            Expanded(child: electricityCard),
                            const SizedBox(width: 16),
                            Expanded(child: waterCard),
                          ],
                        );
                      }

                      return Column(
                        children: [
                          electricityCard,
                          const SizedBox(height: 12),
                          waterCard,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),

                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save),
                      label: Text(_saving ? 'Saving...' : 'Save Utilities'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}