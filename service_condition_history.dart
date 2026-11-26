import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as flutter_widgets;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';
import 'historical_records.dart';

class ServiceConditionHistoryPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const ServiceConditionHistoryPage({super.key, required this.report});

  @override
  State<ServiceConditionHistoryPage> createState() =>
      _ServiceConditionHistoryPageState();
}

class _ServiceConditionHistoryPageState
    extends State<ServiceConditionHistoryPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  final Set<String> _selectedConditions = <String>{}; // Empty means All
  final GlobalKey _serviceSectionKey = GlobalKey();

  List<Map<String, dynamic>> _assets = [];
  List<Map<String, dynamic>> _snapshots = [];
  List<Map<String, dynamic>> _serviceRecords = [];
  // One asset condition per asset and report month; service entries are dated separately.
  final Map<String, Map<String, dynamic>> _conditionsByAssetMonth = {};
  final Map<String, String> _reportIdsByMonth = {};

  String get _reportId => widget.report['id'].toString();
  String get _siteId => widget.report['site_id'].toString();

  bool get _readOnly => widget.report['status'] != 'draft';

  static const List<String> _conditions = [
    'Good',
    'Fair',
    'Poor',
    'Out of Service',
  ];

  DateTime? get _currentMonth => HistoricalRecords.monthOf(widget.report);

  // Service records form the single This Month/History list. Search is shared.
  List<Map<String, dynamic>> _filteredServices(
    List<Map<String, dynamic>> records,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    return records.where((record) {
      final asset = _assetFor(record['asset_uuid']?.toString() ?? '');
      final condition =
          _conditionForService(record)?['condition']?.toString() ??
          'Not Recorded';
      if (_selectedConditions.isNotEmpty &&
          !_selectedConditions.contains(condition)) {
        return false;
      }
      if (query.isEmpty) return true;
      final searchable = <dynamic>[
        asset?['asset_id'],
        asset?['asset_item'],
        asset?['category'],
        asset?['location'],
        asset?['brand_model'],
        record['remarks'],
        record['service_date'],
        condition,
      ].where((part) => part != null).join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';

  String _conditionKey(String assetId, DateTime date) =>
      '$assetId|${_monthKey(date)}';

  Map<String, dynamic>? _conditionForAssetMonth(
    String assetId,
    DateTime date,
  ) => _conditionsByAssetMonth[_conditionKey(assetId, date)];

  Map<String, dynamic>? _conditionForService(Map<String, dynamic> record) {
    final date = _parseDate(record['service_date']);
    final assetId = record['asset_uuid']?.toString();
    if (date == null || assetId == null) return null;
    return _conditionForAssetMonth(assetId, date);
  }

  String? _reportIdForServiceDate(DateTime date) =>
      _reportIdsByMonth[_monthKey(date)];

  int get _recordedCount => _assets.where((asset) {
    return _snapshotFor(asset['id'].toString()) != null;
  }).length;

  int get _unrecordedCount => _assets.length - _recordedCount;

  DateTime? _parseDate(dynamic value) =>
      value == null ? null : DateTime.tryParse(value.toString());

  DateTime? get _monthStart {
    final month = _currentMonth;
    return month == null ? null : DateTime(month.year, month.month);
  }

  DateTime? get _nextMonth {
    final month = _currentMonth;
    return month == null ? null : DateTime(month.year, month.month + 1);
  }

  bool _isThisMonthService(Map<String, dynamic> record) {
    final date = _parseDate(record['service_date']);
    final start = _monthStart;
    final end = _nextMonth;
    return date != null &&
        start != null &&
        end != null &&
        !date.isBefore(start) &&
        date.isBefore(end);
  }

  bool _isHistoricalService(Map<String, dynamic> record) {
    final date = _parseDate(record['service_date']);
    final start = _monthStart;
    return date != null && start != null && date.isBefore(start);
  }

  List<Map<String, dynamic>> get _thisMonthServices =>
      _serviceRecords.where(_isThisMonthService).toList();

  List<Map<String, dynamic>> get _historicalServices =>
      _serviceRecords.where(_isHistoricalService).toList();

  int _countCondition(String condition) => _assets.where((asset) {
    final snapshot = _snapshotFor(asset['id'].toString());
    final value = snapshot?['condition']?.toString() ?? 'Not Recorded';
    return value == condition;
  }).length;

  void _filterToCondition(String condition) {
    setState(() {
      if (!_selectedConditions.add(condition)) {
        _selectedConditions.remove(condition);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _serviceSectionKey.currentContext;
      if (mounted && ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          alignment: 0.06,
        );
      }
    });
  }

  void _scrollToServices() {
    final ctx = _serviceSectionKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        alignment: 0.06,
      );
    }
  }

  @override
  void initState() {
    super.initState();

    if (widget.report['site_id'] == null || widget.report['id'] == null) {
      _loading = false;
      _error = 'The property or monthly report ID is missing.';
    } else {
      _loadData();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        _supabase
            .from('asset_register')
            .select()
            .eq('site_id', _siteId)
            .order('asset_id'),
        _supabase
            .from('monthly_asset_conditions')
            .select()
            .eq('report_id', _reportId),
        _supabase
            .from('monthly_reports')
            .select('id, report_month')
            .eq('site_id', _siteId),
      ]);
      final assets = List<Map<String, dynamic>>.from(results[0] as List);
      final currentConditions = List<Map<String, dynamic>>.from(
        results[1] as List,
      );
      final siteReports = List<Map<String, dynamic>>.from(results[2] as List);
      final monthsById = <String, String>{};
      final reportsByMonth = <String, String>{};
      final selectedMonth = _monthStart;
      for (final report in siteReports) {
        final date = _parseDate(report['report_month']);
        final id = report['id']?.toString();
        if (date == null || id == null) continue;
        final month = DateTime(date.year, date.month);
        if (selectedMonth != null && month.isAfter(selectedMonth)) continue;
        final key = _monthKey(month);
        reportsByMonth[key] = id;
        monthsById[id] = key;
      }
      // The selected report may not be included in the site query due to RLS.
      if (selectedMonth != null) {
        reportsByMonth[_monthKey(selectedMonth)] = _reportId;
        monthsById[_reportId] = _monthKey(selectedMonth);
      }
      final conditionRows = monthsById.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await _supabase
                  .from('monthly_asset_conditions')
                  .select()
                  .inFilter('report_id', monthsById.keys.toList()),
            );
      final conditionIndex = <String, Map<String, dynamic>>{};
      for (final item in conditionRows) {
        final assetId = item['asset_uuid']?.toString();
        final monthKey = monthsById[item['report_id']?.toString()];
        if (assetId != null && monthKey != null) {
          conditionIndex['$assetId|$monthKey'] = item;
        }
      }
      final assetIds = assets.map((a) => a['id'].toString()).toList();
      final serviceRows = assetIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await _supabase
                  .from('asset_service_history')
                  .select()
                  .inFilter('asset_uuid', assetIds)
                  .order('service_date', ascending: false),
            );
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _snapshots = currentConditions;
        _serviceRecords = serviceRows;
        _conditionsByAssetMonth
          ..clear()
          ..addAll(conditionIndex);
        _reportIdsByMonth
          ..clear()
          ..addAll(reportsByMonth);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Map<String, dynamic>? _snapshotFor(String assetId) {
    for (final snapshot in _snapshots) {
      if (snapshot['asset_uuid']?.toString() == assetId) {
        return snapshot;
      }
    }

    return null;
  }

  Map<String, dynamic>? _assetFor(String assetId) {
    for (final asset in _assets) {
      if (asset['id']?.toString() == assetId) {
        return asset;
      }
    }

    return null;
  }

  Future<void> _addServiceRecord({Map<String, dynamic>? existing}) async {
    if (_readOnly || _saving) return;
    if (_assets.isEmpty) {
      _showMessage('Add an asset in Asset Register first.', error: true);
      return;
    }
    final editing = existing != null;
    String selectedAssetId =
        existing?['asset_uuid']?.toString() ?? _assets.first['id'].toString();
    final selectedMonth = _currentMonth;
    final now = DateTime.now();
    DateTime selectedDate =
        _parseDate(existing?['service_date']) ??
        (selectedMonth != null &&
                selectedMonth.year == now.year &&
                selectedMonth.month == now.month
            ? DateTime(now.year, now.month, now.day)
            : DateTime(
                selectedMonth?.year ?? now.year,
                selectedMonth?.month ?? now.month,
                1,
              ));
    final remarksController = TextEditingController(
      text: existing?['remarks']?.toString() ?? '',
    );
    final quantityController = TextEditingController();
    String condition = 'Good';

    void useMonthlyCondition() {
      final asset = _assetFor(selectedAssetId);
      final monthSnapshot = _conditionForAssetMonth(
        selectedAssetId,
        selectedDate,
      );
      final suggested = monthSnapshot?['condition']?.toString();
      condition = _conditions.contains(suggested) ? suggested! : 'Good';
      quantityController.text =
          '${monthSnapshot?['qty'] ?? asset?['qty'] ?? 1}';
    }

    useMonthlyCondition();

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: AppColors.white,
            surfaceTintColor: Colors.transparent,
            title: Text(
              editing ? 'Edit Service Record' : 'Add Service Record',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.black,
              ),
            ),
            content: flutter_widgets.SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'SERVICE DETAILS',
                      style: TextStyle(
                        color: AppColors.red,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'service-asset-${existing?['id'] ?? 'new'}',
                      ),
                      initialValue: selectedAssetId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Asset'),
                      items: _assets.map((asset) {
                        final id = asset['id'].toString();
                        final name = asset['asset_item']?.toString() ?? '';
                        final code = asset['asset_id']?.toString() ?? id;
                        return DropdownMenuItem<String>(
                          value: id,
                          child: Text(
                            '$code - $name',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() {
                            selectedAssetId = value;
                            useMonthlyCondition();
                          });
                        }
                      },
                    ),
                    const flutter_widgets.SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                        foregroundColor: AppColors.charcoal,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      icon: const Icon(Icons.calendar_month_outlined),
                      label: Text(
                        'Service Date: ${_formatDate(_dateOnly(selectedDate))}',
                      ),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: dialogContext,
                          initialDate: selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setDialogState(() {
                            selectedDate = picked;
                            useMonthlyCondition();
                          });
                        }
                      },
                    ),
                    const flutter_widgets.SizedBox(height: 18),
                    const Text(
                      'MONTHLY ASSET CONDITION',
                      style: TextStyle(
                        color: AppColors.red,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      // Recreate on asset/date change to refresh the dropdown.
                      key: ValueKey(
                        'condition-$selectedAssetId-${_dateOnly(selectedDate)}',
                      ),
                      initialValue: condition,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Condition'),
                      items: _conditions
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => condition = value);
                        }
                      },
                    ),
                    const flutter_widgets.SizedBox(height: 12),
                    TextFormField(
                      controller: quantityController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Monthly Quantity',
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 16),
                    TextField(
                      controller: remarksController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Service Remarks',
                        hintText: 'Describe the service or repair',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 8),
                    const Text(
                      'Condition and monthly quantity are saved for this asset '
                      'and report month. Multiple services in the same month '
                      'share that monthly condition.',
                      style: TextStyle(color: AppColors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: AppColors.white,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(editing ? 'Save Changes' : 'Save Record'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;

      final qty = int.tryParse(quantityController.text.trim());
      if (qty == null || qty < 1) {
        _showMessage(
          'Monthly Quantity must be a whole number of at least 1.',
          error: true,
        );
        return;
      }
      final monthStart = _monthStart;
      if (!editing &&
          monthStart != null &&
          _monthKey(selectedDate) != _monthKey(monthStart)) {
        _showMessage(
          'New services must be dated within the selected report month.',
          error: true,
        );
        return;
      }
      if (monthStart != null &&
          DateTime(selectedDate.year, selectedDate.month).isAfter(monthStart)) {
        _showMessage(
          'Cannot save service entries in a future report month.',
          error: true,
        );
        return;
      }
      final registeredQty = (_assetFor(selectedAssetId)?['qty'] as num?)
          ?.toInt();
      if (registeredQty != null && qty > registeredQty) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Quantity exceeds registered amount'),
            content: const Text('Save this monthly quantity anyway?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save Anyway'),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) return;
      }

      setState(() => _saving = true);
      bool savedService = false;
      String? conditionWarning;
      try {
        final serviceValues = <String, dynamic>{
          'asset_uuid': selectedAssetId,
          'service_date': _dateOnly(selectedDate),
          'remarks': _nullable(remarksController.text),
        };
        if (editing) {
          final updated = await _supabase
              .from('asset_service_history')
              .update(serviceValues)
              .eq('id', existing['id'].toString())
              .eq('asset_uuid', existing['asset_uuid'].toString())
              .select('id');
          if (updated.isEmpty) {
            throw Exception(
              'No service record updated. Check Supabase permissions.',
            );
          }
        } else {
          await _supabase.from('asset_service_history').insert(serviceValues);
        }
        savedService = true;
        final monthReportId = _reportIdForServiceDate(selectedDate);
        if (monthReportId == null) {
          conditionWarning =
              'No monthly report exists for the service date; '
              'condition and monthly quantity could not be saved.';
        } else {
          try {
            await _supabase.from('monthly_asset_conditions').upsert({
              'report_id': monthReportId,
              'asset_uuid': selectedAssetId,
              'condition': condition,
              'qty': qty,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }, onConflict: 'report_id,asset_uuid');
          } catch (error) {
            conditionWarning =
                'Service saved, but its monthly condition '
                'was not saved: $error';
          }
        }
        if (mounted) await _loadData();
        if (!mounted) return;
        _showMessage(
          conditionWarning ??
              (editing ? 'Service record updated.' : 'Service record added.'),
          error: conditionWarning != null,
        );
      } catch (error) {
        if (mounted) {
          _showMessage(
            savedService
                ? 'Service saved, but an additional operation failed: $error'
                : 'Failed to save service record: $error',
            error: true,
          );
        }
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    } finally {
      remarksController.dispose();
      quantityController.dispose();
    }
  }

  Future<void> _deleteServiceRecord(Map<String, dynamic> record) async {
    if (_readOnly || _saving) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Delete Service Record?',
          style: TextStyle(color: AppColors.black, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'This service record will be permanently deleted. '
          'The monthly asset condition will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);

    try {
      final deleted = await _supabase
          .from('asset_service_history')
          .delete()
          .eq('id', record['id'].toString())
          .eq('asset_uuid', record['asset_uuid'].toString())
          .select('id');
      if (deleted.isEmpty) {
        throw Exception(
          'No service record was deleted. Check Supabase permissions.',
        );
      }

      await _loadData();

      if (!mounted) return;
      _showMessage('Service record deleted.');
    } catch (error) {
      if (!mounted) return;
      _showMessage('Failed to delete service record: $error', error: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String? _nullable(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _dateOnly(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  String _formatDate(String? value) {
    if (value == null || value.isEmpty) return '—';

    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;

    return '${parsed.day.toString().padLeft(2, '0')}/'
        '${parsed.month.toString().padLeft(2, '0')}/'
        '${parsed.year}';
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? AppColors.redDark : AppColors.charcoal,
        ),
      );
  }

  String _monthLabel() {
    final month = _currentMonth;
    if (month == null) return 'Monthly report';

    return HistoricalRecords.monthLabel(month);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Service & Condition History'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving ? null : _loadData,
            icon: const Icon(Icons.refresh),
          ),
          const flutter_widgets.SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : () => _addServiceRecord(),
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Service'),
            ),
      body: Center(
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
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.red, size: 44),
              const flutter_widgets.SizedBox(height: 12),
              const Text('Unable to load service and condition records.'),
              const flutter_widgets.SizedBox(height: 8),
              SelectableText(
                _error!,
                style: const TextStyle(color: AppColors.grey),
              ),
              const flutter_widgets.SizedBox(height: 16),
              FilledButton(
                onPressed: _loadData,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }
    final current = _filteredServices(_thisMonthServices);
    final historical = _filteredServices(_historicalServices);
    return RefreshIndicator(
      color: AppColors.red,
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const flutter_widgets.SizedBox(height: 18),
          _buildSummary(),
          const flutter_widgets.SizedBox(height: 22),
          _buildSearchAndFilters(),
          const flutter_widgets.SizedBox(height: 18),
          KeyedSubtree(
            key: _serviceSectionKey,
            child: _sectionHeading('This Month', null, current.length),
          ),
          const flutter_widgets.SizedBox(height: 12),
          if (current.isEmpty)
            _emptyPanel(
              icon: Icons.build_outlined,
              title: 'No matching service records',
              description:
                  'Use Add Service to record service and asset condition.',
            )
          else
            ...current.asMap().entries.map(
              (e) => _buildServiceCard(e.value, number: e.key + 1),
            ),
          const flutter_widgets.SizedBox(height: 24),
          _buildServiceHistory(historical),
          if (_saving) ...[
            const flutter_widgets.SizedBox(height: 12),
            const LinearProgressIndicator(color: AppColors.red),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeading(String title, String? subtitle, int count) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const flutter_widgets.SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        Text(
          '$count records',
          style: const TextStyle(color: AppColors.grey, fontSize: 12),
        ),
      ],
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
            'OPERATIONS',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const flutter_widgets.SizedBox(height: 8),
          const Text(
            'Service & Condition History',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const flutter_widgets.SizedBox(height: 8),
          Text(
            '${_monthLabel()} • Report ID: $_reportId',
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 13),
          ),
          if (_readOnly) ...[
            const flutter_widgets.SizedBox(height: 14),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, color: AppColors.white, size: 16),
                flutter_widgets.SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Completed report — editing disabled',
                    style: TextStyle(color: AppColors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return Column(
      children: [
        flutter_widgets.SizedBox(
          width: double.infinity,
          child: _summaryCard(
            'Total Assets',
            _assets.length,
            Icons.inventory_2_outlined,
            AppColors.red,
            onTap: () => setState(() {
              _selectedConditions.clear();
            }),
          ),
        ),
        const flutter_widgets.SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'Good',
                _countCondition('Good'),
                Icons.check_circle_outline,
                const Color(0xFF22683D),
                onTap: () => _filterToCondition('Good'),
              ),
            ),
            const flutter_widgets.SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'Fair',
                _countCondition('Fair'),
                Icons.schedule,
                const Color(0xFF946200),
                onTap: () => _filterToCondition('Fair'),
              ),
            ),
          ],
        ),
        const flutter_widgets.SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'Poor',
                _countCondition('Poor'),
                Icons.warning_amber_outlined,
                AppColors.red,
                onTap: () => _filterToCondition('Poor'),
              ),
            ),
            const flutter_widgets.SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'Out of Service',
                _countCondition('Out of Service'),
                Icons.block_outlined,
                AppColors.grey,
                onTap: () => _filterToCondition('Out of Service'),
              ),
            ),
          ],
        ),
        const flutter_widgets.SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'Not Recorded',
                _unrecordedCount,
                Icons.pending_actions_outlined,
                AppColors.grey,
                onTap: () => _filterToCondition('Not Recorded'),
              ),
            ),
            const flutter_widgets.SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'Services This Month',
                _thisMonthServices.length,
                Icons.build_outlined,
                AppColors.red,
                onTap: _scrollToServices,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(
    String label,
    int count,
    IconData icon,
    Color accent, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 104),
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
            const flutter_widgets.SizedBox(width: 12),
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
                  const flutter_widgets.SizedBox(height: 5),
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
    );
  }

  Widget _buildSearchAndFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search asset, category, service date or remarks...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const flutter_widgets.SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'Showing:',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
            if (_selectedConditions.isEmpty)
              const Text(
                'All conditions',
                style: TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            for (final value in [..._conditions, 'Not Recorded'])
              if (_selectedConditions.contains(value))
                Chip(
                  label: Text(value),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => _filterToCondition(value),
                ),
            if (_selectedConditions.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _selectedConditions.clear()),
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Clear filter'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _conditionBadge(String condition) {
    final Color color;

    switch (condition) {
      case 'Good':
        color = const Color(0xFF22683D);
        break;
      case 'Fair':
        color = const Color(0xFF946200);
        break;
      case 'Poor':
      case 'Out of Service':
        color = AppColors.red;
        break;
      default:
        color = AppColors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        condition,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _detail(String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 75, maxWidth: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.grey,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
          const flutter_widgets.SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServiceHistory(List<Map<String, dynamic>> history) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final record in history) {
      final date = _parseDate(record['service_date']);
      if (date == null) continue;
      final key =
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-01';
      grouped.putIfAbsent(key, () => []).add(record);
    }
    final months = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeading('History', null, history.length),
        const flutter_widgets.SizedBox(height: 12),
        if (months.isEmpty)
          _emptyPanel(
            icon: Icons.history,
            title: 'No historical services',
            description: 'No service records were found before this month.',
          )
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
                key: PageStorageKey('service-history-$_reportId-$month'),
                initiallyExpanded: false,
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                title: Text(
                  HistoricalRecords.monthLabel(DateTime.parse(month)),
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${grouped[month]!.length} service record(s)',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  for (var i = 0; i < grouped[month]!.length; i++)
                    _buildServiceCard(grouped[month]![i], number: i + 1),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildServiceCard(Map<String, dynamic> record, {required int number}) {
    final asset = _assetFor(record['asset_uuid']?.toString() ?? '');
    final label = asset == null
        ? 'Unknown asset'
        : '${asset['asset_id']} - ${asset['asset_item']}';
    final remarks = _display(record['remarks']);
    final monthly = _conditionForService(record);
    final condition = monthly?['condition']?.toString() ?? 'Not Recorded';
    final quantity = monthly?['qty']?.toString() ?? 'Not recorded';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
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
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const flutter_widgets.SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const flutter_widgets.SizedBox(height: 5),
                    Text(
                      'Service Date: ${_formatDate(record['service_date']?.toString())}',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const flutter_widgets.SizedBox(width: 8),
              Align(
                alignment: Alignment.topRight,
                child: _conditionBadge(condition),
              ),
            ],
          ),
          const flutter_widgets.SizedBox(height: 14),
          _detail('MONTHLY QUANTITY', quantity),
          if (remarks != null) ...[
            const flutter_widgets.SizedBox(height: 12),
            _detail('SERVICE REMARKS', remarks),
          ],
          if (!_readOnly) ...[
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _addServiceRecord(existing: record),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _deleteServiceRecord(record),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyPanel({
    required IconData icon,
    required String title,
    required String description,
    Widget? action,
  }) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: AppColors.red),
          const flutter_widgets.SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const flutter_widgets.SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.grey, height: 1.5),
          ),
          if (action != null) ...[
            const flutter_widgets.SizedBox(height: 8),
            action,
          ],
        ],
      ),
    );
  }

  String? _display(dynamic value, {String? fallback}) {
    if (value == null || value.toString().trim().isEmpty) {
      return fallback;
    }

    return value.toString().trim();
  }
}
