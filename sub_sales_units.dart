import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class SubSalesUnits extends StatefulWidget {
  final Map<String, dynamic> report;

  const SubSalesUnits({
    super.key,
    required this.report,
  });

  @override
  State<SubSalesUnits> createState() => _SubSalesUnitsState();
}

class _SubSalesUnitsState extends State<SubSalesUnits> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _records = [];
  String? _siteId;
  DateTime? _reportMonth;
  String? _loadError;
  bool _loading = true;
  String? _deletingId;

  static const Color _pageBackground = Color(0xFFF5F5F7);
  static const Color _bannerBackground = Color(0xFF242424);
  static const Color _cardBorder = Color(0xFFE1E4E8);
  static const Color _mutedText = Color(0xFF707070);

  static const List<String> _statuses = [
    'Pending',
    'In Progress',
    'Completed',
    'Cancelled',
  ];

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String get _reportId => widget.report['id']?.toString() ?? '';

  String get _monthLabel {
    final month = _reportMonth ??
        DateTime.tryParse(
          (widget.report['report_month'] ??
                  widget.report['month'] ??
                  widget.report['report_date'] ??
                  '')
              .toString(),
        );
    return month == null
        ? 'Selected month'
        : DateFormat('MMMM yyyy').format(month);
  }

  DateTime? _dateFrom(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  String _saleMonthLabel(dynamic value) {
    final date = _dateFrom(value);
    return date == null ? '-' : DateFormat('MMMM yyyy').format(date);
  }

  String _errorText(Object error) {
    if (error is PostgrestException) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }

  void _showMessage(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          backgroundColor: isError ? Colors.red.shade800 : null,
        ),
      );
  }

  // A property-wide register: show all transactions up to the selected
  // report month, not just transactions entered during that month.
  Future<void> _loadRecords() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      var siteId = widget.report['site_id']?.toString().trim() ?? '';
      DateTime? month = _dateFrom(
        widget.report['report_month'] ??
            widget.report['month'] ??
            widget.report['report_date'],
      );

      // Some navigation paths pass a partial monthly_reports row.
      if (siteId.isEmpty || month == null) {
        if (_reportId.isEmpty) {
          throw StateError('The selected report has no report ID.');
        }
        final savedReport = await _supabase
            .from('monthly_reports')
            .select('site_id, report_month')
            .eq('id', _reportId)
            .maybeSingle();

        if (savedReport == null) {
          throw StateError('Unable to find the selected monthly report.');
        }
        if (siteId.isEmpty) {
          siteId = savedReport['site_id']?.toString().trim() ?? '';
        }
        month ??= _dateFrom(savedReport['report_month']);
      }

      if (siteId.isEmpty) {
        throw StateError('The selected report has no property (site_id).');
      }
      if (month == null) {
        throw StateError('The selected report has no valid report month.');
      }

      final selectedMonth = DateTime(month.year, month.month);
      final monthEnd = DateTime(month.year, month.month + 1, 0);
      final cutoff = DateFormat('yyyy-MM-dd').format(monthEnd);

      final response = await _supabase
          .from('sub_sales_units')
          .select('id, site_id, unit, status, sale_month, remarks')
          .eq('site_id', siteId)
          .lte('sale_month', cutoff)
          .order('sale_month', ascending: true)
          .order('unit', ascending: true);

      final rows = response
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

      if (!mounted) return;
      setState(() {
        _siteId = siteId;
        _reportMonth = selectedMonth;
        _records = rows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _errorText(error);
      });
    }
  }

  List<Map<String, dynamic>> get _filteredRecords {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _records;

    return _records.where((record) {
      final unit = (record['unit'] ?? '').toString().toLowerCase();
      final status = (record['status'] ?? '').toString().toLowerCase();
      final month = _saleMonthLabel(record['sale_month']).toLowerCase();
      final rawDate = (record['sale_month'] ?? '').toString().toLowerCase();
      final remarks = (record['remarks'] ?? '').toString().toLowerCase();

      return unit.contains(query) ||
          status.contains(query) ||
          month.contains(query) ||
          rawDate.contains(query) ||
          remarks.contains(query);
    }).toList();
  }

  int get _completedCount =>
      _records.where((row) => row['status'] == 'Completed').length;

  Color _statusTextColor(String status) {
    switch (status) {
      case 'Completed':
        return const Color(0xFF207949);
      case 'In Progress':
        return const Color(0xFF2164AA);
      case 'Pending':
        return const Color(0xFF926200);
      case 'Cancelled':
        return const Color(0xFF62666B);
      default:
        return const Color(0xFF62666B);
    }
  }

  Color _statusBackgroundColor(String status) {
    switch (status) {
      case 'Completed':
        return const Color(0xFFE7F3EB);
      case 'In Progress':
        return const Color(0xFFE8F1FC);
      case 'Pending':
        return const Color(0xFFFFF2D8);
      case 'Cancelled':
        return const Color(0xFFF0F0F0);
      default:
        return const Color(0xFFF0F0F0);
    }
  }

  // Add and Edit use the same dialog. site_id is always set from the selected
  // report, and cannot be reassigned from this form.
  Future<void> _openForm({Map<String, dynamic>? record}) async {
    final siteId = _siteId;
    final reportMonth = _reportMonth;
    if (siteId == null || reportMonth == null) {
      _showMessage('Unable to determine the selected property or month.',
          isError: true);
      return;
    }

    final editing = record != null;
    final unitController = TextEditingController(
      text: record?['unit']?.toString() ?? '',
    );
    final remarksController = TextEditingController(
      text: record?['remarks']?.toString() ?? '',
    );
    final formKey = GlobalKey<FormState>();

    final savedDate = _dateFrom(record?['sale_month']) ?? reportMonth;
    var selectedMonth = savedDate.month;
    var selectedYear = savedDate.year;
    var selectedStatus = record?['status']?.toString() ?? 'Completed';
    if (!_statuses.contains(selectedStatus)) selectedStatus = 'Completed';

    final years = List<int>.generate(121, (index) => 1980 + index);
    if (!years.contains(selectedYear)) years.add(selectedYear);
    years.sort((a, b) => b.compareTo(a));

    var saving = false;
    String? dialogError;
    DateTime? savedRecordMonth;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              if (saving || formKey.currentState?.validate() != true) return;

              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              var success = false;
              try {
                final remarks = remarksController.text.trim();
                final values = <String, dynamic>{
                  'unit': unitController.text.trim(),
                  'status': selectedStatus,
                  'sale_month': DateFormat('yyyy-MM-dd').format(
                    DateTime(selectedYear, selectedMonth, 1),
                  ),
                  'remarks': remarks.isEmpty ? null : remarks,
                };

                if (editing) {
                  final id = record['id']?.toString();
                  if (id == null || id.isEmpty) {
                    throw StateError('This record has no valid ID.');
                  }

                  final updated = await _supabase
                      .from('sub_sales_units')
                      .update(values)
                      .eq('id', id)
                      .eq('site_id', siteId)
                      .select('id');

                  if (updated.isEmpty) {
                    throw StateError(
                      'Record not updated. Check your property access.',
                    );
                  }
                } else {
                  final inserted = await _supabase
                      .from('sub_sales_units')
                      .insert({...values, 'site_id': siteId})
                      .select('id');

                  if (inserted.isEmpty) {
                    throw StateError(
                      'Record not added. Check your property access.',
                    );
                  }
                }

                savedRecordMonth = DateTime(selectedYear, selectedMonth);
                success = true;
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(true);
                }
              } catch (error) {
                if (dialogContext.mounted) {
                  setDialogState(() => dialogError = _errorText(error));
                }
              } finally {
                if (!success && dialogContext.mounted) {
                  setDialogState(() => saving = false);
                }
              }
            }

            return AlertDialog(
              title: Text(editing ? 'Edit Sub-Sales' : 'Add Sub-Sales Unit'),
              content: SizedBox(
                width: 460,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          controller: unitController,
                          enabled: !saving,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Unit Number *',
                            hintText: 'e.g. A-1-1',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter the unit number.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: selectedStatus,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Status *',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final status in _statuses)
                              DropdownMenuItem(
                                value: status,
                                child: Text(status),
                              ),
                          ],
                          onChanged: saving
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setDialogState(() => selectedStatus = value);
                                  }
                                },
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<int>(
                                initialValue: selectedMonth,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Month',
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  for (var month = 1; month <= 12; month++)
                                    DropdownMenuItem(
                                      value: month,
                                      child: Text(
                                        DateFormat('MMMM').format(
                                          DateTime(2020, month),
                                        ),
                                      ),
                                    ),
                                ],
                                onChanged: saving
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setDialogState(
                                            () => selectedMonth = value,
                                          );
                                        }
                                      },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: DropdownButtonFormField<int>(
                                initialValue: selectedYear,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Year',
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  for (final year in years)
                                    DropdownMenuItem(
                                      value: year,
                                      child: Text(year.toString()),
                                    ),
                                ],
                                onChanged: saving
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setDialogState(
                                            () => selectedYear = value,
                                          );
                                        }
                                      },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: remarksController,
                          enabled: !saving,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Remarks',
                            hintText: 'e.g. Change ownership',
                            alignLabelWithHint: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (dialogError != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            dialogError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  onPressed: saving ? null : save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.red,
                    foregroundColor: Colors.white,
                  ),
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(saving ? 'Saving...' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    unitController.dispose();
    remarksController.dispose();

    if (!mounted || saved != true) return;
    await _loadRecords();
    if (_loadError == null) {
      if (savedRecordMonth != null &&
          savedRecordMonth!.isAfter(DateTime(reportMonth.year, reportMonth.month))) {
        _showMessage(
          'Record saved. It will appear in ${DateFormat('MMMM yyyy').format(savedRecordMonth!)} reports onward, not in $_monthLabel.',
        );
      } else {
        _showMessage(
          editing ? 'Sub-Sales record updated.' : 'Sub-Sales record added.',
        );
      }
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    final id = record['id']?.toString() ?? '';
    final siteId = _siteId;
    if (id.isEmpty || siteId == null || _deletingId != null) return;

    final unit = (record['unit'] ?? '-').toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Sub-Sales Record?'),
        content: Text(
          'Are you sure you want to delete the Sub-Sales record for '
          'unit $unit? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;
    setState(() => _deletingId = id);

    try {
      final deleted = await _supabase
          .from('sub_sales_units')
          .delete()
          .eq('id', id)
          .eq('site_id', siteId)
          .select('id');

      if (deleted.isEmpty) {
        throw StateError('Record not deleted. Check your property access.');
      }

      await _loadRecords();
      if (_loadError == null) _showMessage('Sub-Sales record deleted.');
    } catch (error) {
      _showMessage('Unable to delete record: ${_errorText(error)}',
          isError: true);
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  Widget _buildBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _bannerBackground,
        border: Border.all(color: AppColors.red, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OPERATIONS',
            style: TextStyle(
              color: AppColors.red,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Sub-Sales Units',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '$_monthLabel \u2022 Report ID: ${_reportId.isEmpty ? '-' : _reportId}',
            style: const TextStyle(
              color: Color(0xFFE2E2E2),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard({
    required String title,
    required int count,
    required IconData icon,
    required Color iconColor,
    required Color iconBackground,
  }) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: iconBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 25),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: const TextStyle(color: _mutedText, fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF272727),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recordCard(Map<String, dynamic> record, int number) {
    final status = (record['status'] ?? 'Pending').toString();
    final remarks = record['remarks']?.toString().trim() ?? '';
    final isDeleting = _deletingId == record['id']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: AppColors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  (record['unit'] ?? '-').toString(),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              // Status has text only. No icon for Completed.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _statusBackgroundColor(status),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: _statusTextColor(status),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          _detailRow('Sub-Sales Date', _saleMonthLabel(record['sale_month'])),
          _detailRow('Remarks', remarks.isEmpty ? '-' : remarks),
          const SizedBox(height: 2),
          const Divider(height: 1, color: Color(0xFFE7E7E7)),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: _deletingId == null
                    ? () => _openForm(record: record)
                    : null,
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('Edit'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.red,
                ),
              ),
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed:
                    _deletingId == null ? () => _deleteRecord(record) : null,
                icon: isDeleting
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline, size: 17),
                label: const Text('Delete'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.red,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleRecords = _filteredRecords;

    return Scaffold(
      backgroundColor: _pageBackground,
      appBar: AppBar(
        backgroundColor: const Color(0xFF171717),
        foregroundColor: Colors.white,
        title: const Text(
          'Sub-Sales Units',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadRecords,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 100),
            children: [
              _buildBanner(),
              const SizedBox(height: 16),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(36),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_loadError != null)
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: _cardBorder),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'Unable to load Sub-Sales records.',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: _mutedText),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _loadRecords,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              else ...[
                _summaryCard(
                  title: 'Total Sub-Sales',
                  count: _records.length,
                  icon: Icons.real_estate_agent_outlined,
                  iconColor: AppColors.red,
                  iconBackground: AppColors.red.withValues(alpha: 0.08),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final completed = _summaryCard(
                      title: 'Completed',
                      count: _completedCount,
                      icon: Icons.check_circle_outline,
                      iconColor: const Color(0xFF21834F),
                      iconBackground: const Color(0xFFE7F3EB),
                    );
                    final incomplete = _summaryCard(
                      title: 'Not Completed',
                      count: _records.length - _completedCount,
                      icon: Icons.access_time_outlined,
                      iconColor: AppColors.red,
                      iconBackground: AppColors.red.withValues(alpha: 0.08),
                    );

                    if (constraints.maxWidth < 520) {
                      return Column(
                        children: [
                          completed,
                          const SizedBox(height: 12),
                          incomplete,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: completed),
                        const SizedBox(width: 12),
                        Expanded(child: incomplete),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                const Text(
                  'Sub-Sales Records',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search unit, status, date, remarks...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 15,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _cardBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.red),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'This Month',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${visibleRecords.length} '
                      '${visibleRecords.length == 1 ? 'record' : 'records'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: _mutedText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (visibleRecords.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(25),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _cardBorder),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Text(
                        _searchController.text.trim().isEmpty
                            ? 'No Sub-Sales records as at $_monthLabel.'
                            : 'No matching Sub-Sales records found.',
                        style: const TextStyle(color: _mutedText),
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < visibleRecords.length; i++)
                    _recordCard(visibleRecords[i], i + 1),
              ],
            ],
          ),
        ),
      ),
      floatingActionButton: !_loading &&
              _loadError == null &&
              _siteId != null &&
              _reportMonth != null
          ? FloatingActionButton.extended(
              onPressed: _deletingId == null ? () => _openForm() : null,
              backgroundColor: AppColors.red,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text(
                'Add Sub-Sales Unit',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            )
          : null,
    );
  }
}