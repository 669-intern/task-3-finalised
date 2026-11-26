
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class Occupancy extends StatefulWidget {
  final Map<String, dynamic> report;

  const Occupancy({
    super.key,
    required this.report,
  });

  @override
  State<Occupancy> createState() => _OccupancyState();
}

class _OccupancyState extends State<Occupancy> {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<_OccupancyRecord> _records = [];
  int _siteTotalUnits = 0;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String get _reportId => widget.report['id']?.toString() ?? '';

  @override
  void initState() {
    super.initState();

    if (_reportId.isEmpty) {
      _loading = false;
      _error = 'The monthly report ID is missing.';
    } else {
      _loadRecords();
    }
  }

  Future<void> _loadRecords() async {
    if (_reportId.isEmpty) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'The monthly report ID is missing.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final reportData = await _supabase
          .from('monthly_reports')
          .select('site_id')
          .eq('id', _reportId)
          .maybeSingle();

      if (reportData == null) {
        throw Exception(
          'Monthly report not found or inaccessible.',
        );
      }

      final siteId = reportData['site_id']?.toString();

      if (siteId == null || siteId.isEmpty) {
        throw Exception(
          'This monthly report is not linked to a residence.',
        );
      }

      final siteData = await _supabase
          .from('property_sites')
          .select('total_units')
          .eq('id', siteId)
          .maybeSingle();

      if (siteData == null) {
        throw Exception(
          'Residence not found or inaccessible.',
        );
      }

      final totalUnits = siteData['total_units'];

      if (totalUnits is! num ||
          totalUnits <= 0 ||
          totalUnits != totalUnits.toInt()) {
        throw Exception(
          'The residence does not have a valid total unit count. '
          'Please update the residence details first.',
        );
      }

      final data = await _supabase
          .from('occupancy_records')
          .select()
          .eq('report_id', _reportId)
          .order('line_no', ascending: true);

      if (!mounted) return;

      setState(() {
        _siteTotalUnits = totalUnits.toInt();
        _records = data
            .map(
              (item) => _OccupancyRecord.fromMap(
                Map<String, dynamic>.from(item),
              ),
            )
            .toList();
        _loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Occupancy load error: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int get _totalVacant =>
      _records.fold(0, (sum, item) => sum + item.vacant);

  int get _totalOwnerOccupied =>
      _records.fold(0, (sum, item) => sum + item.ownerOccupied);

  int get _totalTenantOccupied =>
      _records.fold(0, (sum, item) => sum + item.tenantOccupied);

  int get _totalCommercial =>
      _records.fold(0, (sum, item) => sum + item.commercial);

  int get _totalOccupied =>
      _totalOwnerOccupied + _totalTenantOccupied + _totalCommercial;

  int get _totalUnits => _siteTotalUnits;

  double get _occupancyRate =>
      _totalUnits == 0 ? 0 : _totalOccupied / _totalUnits * 100;

  int _nextLineNo() {
    if (_records.isEmpty) return 1;

    return _records
            .map((record) => record.lineNo)
            .fold<int>(0, (max, value) => value > max ? value : max) +
        1;
  }

  // The dialog owns its controllers and disposes them only
  // when the dialog itself is removed from the widget tree.
  Future<void> _editRecord({_OccupancyRecord? record}) async {
    if (_saving || _loading) return;

    final updated = await showDialog<_OccupancyRecord>(
      context: context,
      builder: (_) => _OccupancyEditDialog(
        record: record,
        nextLineNo: _nextLineNo(),
        totalUnits: _totalUnits,
        existingRecords: List<_OccupancyRecord>.from(_records),
      ),
    );

    if (updated == null || !mounted) return;

    await _saveRecord(updated);
  }
  
  Future<void> _saveRecord(_OccupancyRecord record) async {
    if (_saving) return;

    // Exclude the component being edited, so its old values are not
    // counted alongside its new values.
    final otherUnits = _records
        .where((item) => item.lineNo != record.lineNo)
        .fold<int>(
          0,
          (sum, item) =>
              sum +
              item.vacant +
              item.ownerOccupied +
              item.tenantOccupied +
              item.commercial,
        );

    final combinedTotal = otherUnits +
        record.vacant +
        record.ownerOccupied +
        record.tenantOccupied +
        record.commercial;

    if (combinedTotal > _siteTotalUnits) {
      _message(
        'All components combined cannot exceed '
        '$_siteTotalUnits site units. '
        'Current total: $combinedTotal.',
      );
      return;
    }

    setState(() => _saving = true);

    try {
      await _supabase.from('occupancy_records').upsert({
        'report_id': _reportId,
        'line_no': record.lineNo,
        'tower_component': record.tower,
        'vacant': record.vacant,
        'owner_occupied': record.ownerOccupied,
        'tenant_occupied': record.tenantOccupied,
        'commercial_units': record.commercial,
        'total_units': _siteTotalUnits,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'report_id,line_no');

      if (!mounted) return;

      _message('Occupancy component saved.');
      await _loadRecords();
    } catch (e) {
      if (!mounted) return;
      _message('Unable to save component: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteRecord(_OccupancyRecord record) async {
    if (_saving) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Delete component?',
          style: TextStyle(
            color: AppColors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Delete "${record.tower}" from this monthly report? '
          'This action cannot be undone.',
          style: const TextStyle(color: AppColors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);

    try {
      await _supabase
          .from('occupancy_records')
          .delete()
          .eq('report_id', _reportId)
          .eq('line_no', record.lineNo);

      if (!mounted) return;

      _message('Occupancy component deleted.');
      await _loadRecords();
    } catch (e) {
      if (!mounted) return;
      _message('Unable to delete component: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.charcoal,
      ),
    );
  }

  String _monthLabel() {
    final reportDate = widget.report['report_month'] ??
        widget.report['month'] ??
        widget.report['report_date'];

    final date = reportDate == null
        ? null
        : DateTime.tryParse(reportDate.toString());

    if (date == null) return 'Monthly Report';

    return '${_monthName(date.month)} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Occupancy'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(
            height: 1,
            color: AppColors.red,
          ),
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
        onPressed: _loading || _saving || _error != null
            ? null
            : () => _editRecord(),
        backgroundColor: AppColors.red,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Component'),
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
        child: CircularProgressIndicator(
          color: AppColors.red,
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: AppColors.red,
                size: 44,
              ),
              const SizedBox(height: 12),
              const Text(
                'Unable to load occupancy records.',
                style: TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.grey,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: AppColors.white,
                ),
                onPressed: _loadRecords,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.red,
      onRefresh: _loadRecords,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSummary(),
          const SizedBox(height: 28),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Components',
                  style: TextStyle(
                    color: AppColors.black,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${_records.length} component(s)',
                style: const TextStyle(
                  color: AppColors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Manage occupancy figures for each tower or property component.',
            style: TextStyle(
              color: AppColors.grey,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          if (_records.isEmpty)
            _buildEmptyState()
          else
            ..._records.map(_componentCard),
          const SizedBox(height: 12),
          _buildOverallOccupancy(),
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
            'OCCUPANCY & UNIT MANAGEMENT',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Occupancy Overview',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthLabel()} • Report ID: $_reportId',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 850
            ? 4
            : constraints.maxWidth >= 500
                ? 2
                : 1;

        final cardWidth =
            (constraints.maxWidth - ((columns - 1) * 12)) / columns;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: cardWidth,
              child: _summaryCard(
                'Total Units',
                '$_totalUnits',
                Icons.apartment_outlined,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _summaryCard(
                'Occupied Units',
                '$_totalOccupied',
                Icons.people_outline,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _summaryCard(
                'Vacant Units',
                '$_totalVacant',
                Icons.meeting_room_outlined,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _summaryCard(
                'Commercial Units',
                '$_totalCommercial',
                Icons.storefront_outlined,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _summaryCard(
                'Occupancy Rate',
                '${_occupancyRate.toStringAsFixed(2)}%',
                Icons.pie_chart_outline,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _summaryCard(
    String title,
    String value,
    IconData icon,
  ) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: AppColors.red,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
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
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.apartment_outlined,
            size: 44,
            color: AppColors.red,
          ),
          const SizedBox(height: 12),
          const Text(
            'No components added yet',
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Add a tower or component to begin tracking occupancy.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.grey,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: _saving ? null : () => _editRecord(),
            icon: const Icon(Icons.add),
            label: const Text('Add Component'),
          ),
        ],
      ),
    );
  }

  Widget _componentCard(_OccupancyRecord record) {
    final occupied =
        record.ownerOccupied + record.tenantOccupied + record.commercial;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.apartment_outlined,
                    color: AppColors.red,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    record.tower,
                    style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  enabled: !_saving,
                  tooltip: 'Component actions',
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.grey,
                  ),
                  onSelected: (action) {
                    if (action == 'edit') {
                      _editRecord(record: record);
                    } else if (action == 'delete') {
                      _deleteRecord(record);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit_outlined, size: 20),
                          SizedBox(width: 10),
                          Text('Edit'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: AppColors.red,
                          ),
                          SizedBox(width: 10),
                          Text('Delete'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                _detail('Occupied', '$occupied'),
                _detail('Vacant', '${record.vacant}'),
                _detail('Owner occupied', '${record.ownerOccupied}'),
                _detail('Tenant occupied', '${record.tenantOccupied}'),
                _detail('Commercial', '${record.commercial}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String value) {
    return SizedBox(
      width: 145,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
            value,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverallOccupancy() {
    final progress = (_occupancyRate / 100).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.charcoal,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.red),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.pie_chart_outline,
                color: AppColors.red,
                size: 23,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Overall Occupancy',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: progress,
              backgroundColor: AppColors.white.withValues(alpha: 0.15),
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.red,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  '$_totalOccupied of $_totalUnits units occupied',
                  style: const TextStyle(
                    color: AppColors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${_occupancyRate.toStringAsFixed(2)}%',
                style: const TextStyle(
                  color: AppColors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Owner occupied: $_totalOwnerOccupied  •  '
            'Tenant occupied: $_totalTenantOccupied  •  '
            'Commercial: $_totalCommercial  •  '
            'Vacant: $_totalVacant',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 12,
              height: 1.5,
            ),
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
}

class _OccupancyEditDialog extends StatefulWidget {
  final _OccupancyRecord? record;
  final int nextLineNo;
  final int totalUnits;
  final List<_OccupancyRecord> existingRecords;

  const _OccupancyEditDialog({
    required this.record,
    required this.nextLineNo,
    required this.totalUnits,
    required this.existingRecords,
  });

  @override
  State<_OccupancyEditDialog> createState() =>
      _OccupancyEditDialogState();
}

class _OccupancyEditDialogState extends State<_OccupancyEditDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _towerController;
  late final TextEditingController _vacantController;
  late final TextEditingController _ownerController;
  late final TextEditingController _tenantController;
  late final TextEditingController _commercialController;

  @override
  void initState() {
    super.initState();

    _towerController = TextEditingController(
      text: widget.record?.tower ?? '',
    );
    _vacantController = TextEditingController(
      text: (widget.record?.vacant ?? 0).toString(),
    );
    _ownerController = TextEditingController(
      text: (widget.record?.ownerOccupied ?? 0).toString(),
    );
    _tenantController = TextEditingController(
      text: (widget.record?.tenantOccupied ?? 0).toString(),
    );
    _commercialController = TextEditingController(
      text: (widget.record?.commercial ?? 0).toString(),
    );
  }

  @override
  void dispose() {
    _towerController.dispose();
    _vacantController.dispose();
    _ownerController.dispose();
    _tenantController.dispose();
    _commercialController.dispose();
    super.dispose();
  }

  // Preview the total across this component and all other saved components.
  int? get _enteredUnitTotal {
    var editedTotal = 0;
    for (final controller in [
      _vacantController,
      _ownerController,
      _tenantController,
      _commercialController,
    ]) {
      final value = int.tryParse(controller.text.trim());
      if (value == null || value < 0) return null;
      editedTotal += value;
    }

    final otherUnits = widget.existingRecords
        .where((item) => item.lineNo != (widget.record?.lineNo ?? -1))
        .fold<int>(
          0,
          (sum, item) =>
              sum +
              item.vacant +
              item.ownerOccupied +
              item.tenantOccupied +
              item.commercial,
        );
    return otherUnits + editedTotal;
  }

  Widget _numberInput(
    TextEditingController controller,
    String label,
  ) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      validator: (value) {
        final number = int.tryParse(value?.trim() ?? '');

        if (number == null || number < 0) {
          return 'Enter a non-negative whole number';
        }

        return null;
      },
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final vacant = int.parse(_vacantController.text.trim());
    final owner = int.parse(_ownerController.text.trim());
    final tenant = int.parse(_tenantController.text.trim());
    final commercial = int.parse(_commercialController.text.trim());

    final otherUnits = widget.existingRecords
        .where(
          (item) =>
              item.lineNo != (widget.record?.lineNo ?? -1),
        )
        .fold<int>(
          0,
          (sum, item) =>
              sum +
              item.vacant +
              item.ownerOccupied +
              item.tenantOccupied +
              item.commercial,
        );

    final componentTotal =
        otherUnits + vacant + owner + tenant + commercial;

    if (componentTotal > widget.totalUnits) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'All components combined cannot exceed '
            '${widget.totalUnits} residence units. '
            'Current total: $componentTotal.',
          ),
          backgroundColor: AppColors.charcoal,
        ),
      );
      return;
    }

    Navigator.pop(
      context,
      _OccupancyRecord(
        id: widget.record?.id,
        lineNo: widget.record?.lineNo ?? widget.nextLineNo,
        tower: _towerController.text.trim(),
        vacant: vacant,
        ownerOccupied: owner,
        tenantOccupied: tenant,
        commercial: commercial,
        totalUnits: widget.totalUnits,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final assignedTotal = _enteredUnitTotal;
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: Text(
        widget.record == null ? 'Add Component' : 'Edit Component',
        style: const TextStyle(
          color: AppColors.black,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Record No. '
                    '${widget.record?.lineNo ?? widget.nextLineNo}',
                    style: const TextStyle(
                      color: AppColors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _towerController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Tower / Component *',
                    hintText: 'e.g. Tower A, Tower B, Retail',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? 'Enter a component name'
                          : null,
                ),
                const SizedBox(height: 14),
                _numberInput(_vacantController, 'Vacant Units'),
                const SizedBox(height: 14),
                _numberInput(
                  _ownerController,
                  'Owner-Occupied Units',
                ),
                const SizedBox(height: 14),
                _numberInput(
                  _tenantController,
                  'Tenant-Occupied Units',
                ),
                const SizedBox(height: 14),
                _numberInput(
                  _commercialController,
                  'Commercial Units',
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.charcoal,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Residence total: ${widget.totalUnits} units.\n'
                    'Occupied units and occupancy rate are '
                    'calculated automatically.\n'
                    'Assigned units: ${assignedTotal ?? 'Invalid'} '
                    '/ ${widget.totalUnits}',
                    style: const TextStyle(
                      color: AppColors.white,
                      height: 1.5,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (assignedTotal == null || assignedTotal > widget.totalUnits) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Unit counts must be non-negative whole numbers, and '
                    'the total across all components cannot exceed site units.',
                    style: TextStyle(color: AppColors.red, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.red,
            foregroundColor: AppColors.white,
          ),
          onPressed: _submit,
          child: Text(
            widget.record == null ? 'Add Component' : 'Save Changes',
          ),
        ),
      ],
    );
  }
}

class _OccupancyRecord {
  final String? id;
  final int lineNo;
  final String tower;
  final int vacant;
  final int ownerOccupied;
  final int tenantOccupied;
  final int commercial;
  final int totalUnits;

  const _OccupancyRecord({
    this.id,
    required this.lineNo,
    required this.tower,
    required this.vacant,
    required this.ownerOccupied,
    required this.tenantOccupied,
    required this.commercial,
    required this.totalUnits,
  });

  factory _OccupancyRecord.fromMap(Map<String, dynamic> map) {
    return _OccupancyRecord(
      id: map['id']?.toString(),
      lineNo: (map['line_no'] as num).toInt(),
      tower: map['tower_component']?.toString() ?? '',
      vacant: (map['vacant'] as num?)?.toInt() ?? 0,
      ownerOccupied: (map['owner_occupied'] as num?)?.toInt() ?? 0,
      tenantOccupied: (map['tenant_occupied'] as num?)?.toInt() ?? 0,
      commercial: (map['commercial_units'] as num?)?.toInt() ?? 0,
      totalUnits: (map['total_units'] as num?)?.toInt() ?? 0,
    );
  }
}