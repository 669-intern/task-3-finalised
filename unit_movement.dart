import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

/// Unit movements are dated events, not open/unfinished work.
/// They are shown in the month of movement_date, with older events in History.
class UnitMovement extends StatefulWidget {
  final Map<String, dynamic> report;

  const UnitMovement({super.key, required this.report});

  @override
  State<UnitMovement> createState() => _UnitMovementState();
}

class _UnitMovementState extends State<UnitMovement> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<_MovementRecord> _allRecords = [];
  final Set<String> _selectedTypes = <String>{};
  DateTime? _reportMonth;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _search = '';

  String get _reportId => widget.report['id']?.toString() ?? '';
  String? get _siteId => widget.report['site_id']?.toString();

  /// Preserve the original monthly-report lock.
  bool get _readOnly => widget.report['status'] != 'draft';

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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static DateTime _firstOfMonth(DateTime date) => DateTime(date.year, date.month);

  DateTime? _dateFrom(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String? _dbDate(DateTime? date) {
    if (date == null) return null;
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static String _dateLabel(DateTime? date) {
    if (date == null) return 'Not specified';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  static String _monthLabel(DateTime? date) {
    if (date == null) return 'Monthly Report';
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  // When an old record has no movement date, use the source report's month
  // for display only. New records require an actual movement date.
  DateTime? _eventMonth(_MovementRecord record) {
    final date = record.movementDate ?? record.sourceReportMonth;
    return date == null ? null : _firstOfMonth(date);
  }

  bool _isThisMonth(_MovementRecord record) {
    if (_reportMonth == null) return record.sourceReportId == _reportId;
    final eventMonth = _eventMonth(record);
    return eventMonth != null && eventMonth.isAtSameMomentAs(_reportMonth!);
  }

  bool _isHistorical(_MovementRecord record) {
    if (_reportMonth == null) return false;
    final eventMonth = _eventMonth(record);
    return eventMonth != null && eventMonth.isBefore(_reportMonth!);
  }

  static int _sortMovements(_MovementRecord a, _MovementRecord b) {
    final ad = a.movementDate ?? a.sourceReportMonth ?? DateTime(2000);
    final bd = b.movementDate ?? b.sourceReportMonth ?? DateTime(2000);
    final dateOrder = bd.compareTo(ad);
    if (dateOrder != 0) return dateOrder;
    final reportOrder = b.sourceReportId.compareTo(a.sourceReportId);
    return reportOrder != 0 ? reportOrder : b.lineNo.compareTo(a.lineNo);
  }

  List<_MovementRecord> get _current =>
      _allRecords.where(_isThisMonth).toList()..sort(_sortMovements);

  List<_MovementRecord> get _history =>
      _allRecords.where(_isHistorical).toList()..sort(_sortMovements);

  bool _matchesFilters(_MovementRecord record) {
    if (_selectedTypes.isNotEmpty && !_selectedTypes.contains(record.movement)) {
      return false;
    }
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return true;
    final searchable = [
      record.unit,
      record.movement,
      record.remarks,
      _dateLabel(record.movementDate),
      _dbDate(record.movementDate) ?? '',
    ].join(' ').toLowerCase();
    return searchable.contains(query);
  }

  List<_MovementRecord> get _visibleCurrent =>
      _current.where(_matchesFilters).toList();
  List<_MovementRecord> get _visibleHistory =>
      _history.where(_matchesFilters).toList();

  Future<void> _loadRecords() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Collect all report IDs belonging to the selected property.
      // unit_movements already has report_id, so no new table/column is needed.
      String? siteId = _siteId;
      final chosenReport = await _supabase
          .from('monthly_reports')
          .select('site_id,report_month')
          .eq('id', _reportId)
          .single();
      siteId ??= chosenReport['site_id']?.toString();
      if (siteId == null || siteId.isEmpty) {
        throw StateError('Selected property is missing.');
      }

      final chosenMonth = _dateFrom(
        widget.report['report_month'] ?? chosenReport['report_month'],
      );
      if (chosenMonth == null) {
        throw StateError('The selected report month is missing.');
      }

      final reportRows = await _supabase
          .from('monthly_reports')
          .select('id,report_month,status')
          .eq('site_id', siteId);

      final ids = <String>[];
      final months = <String, DateTime?>{};
      final statuses = <String, String>{};
      for (final row in reportRows) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        ids.add(id);
        months[id] = _dateFrom(row['report_month']);
        statuses[id] = row['status']?.toString() ?? '';
      }
      if (!ids.contains(_reportId)) {
        ids.add(_reportId);
        months[_reportId] = chosenMonth;
        statuses[_reportId] = widget.report['status']?.toString() ?? '';
      }

      // Fetch only records whose parent report belongs to this property.
      // Use batches rather than an enormous PostgREST IN clause.
      final records = <_MovementRecord>[];
      const batchSize = 100;
      for (var i = 0; i < ids.length; i += batchSize) {
        final part = ids.skip(i).take(batchSize).toList();
        final rows = await _supabase
            .from('unit_movements')
            .select()
            .inFilter('report_id', part)
            .order('line_no', ascending: true);
        for (final row in rows) {
          final map = Map<String, dynamic>.from(row);
          final sourceId = map['report_id']?.toString() ?? '';
          records.add(_MovementRecord.fromMap(
            map,
            sourceReportMonth: months[sourceId],
            sourceReportStatus: statuses[sourceId] ?? '',
          ));
        }
      }

      if (!mounted) return;
      setState(() {
        _allRecords = records;
        _reportMonth = _firstOfMonth(chosenMonth);
        _loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Unit Movement load error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int _nextLineNo() {
    final own = _allRecords.where((r) => r.sourceReportId == _reportId);
    var maximum = 0;
    for (final record in own) {
      if (record.lineNo > maximum) maximum = record.lineNo;
    }
    return maximum + 1;
  }

  Future<void> _showMovementDialog({_MovementRecord? existing}) async {
    if (!mounted || _readOnly || _saving || _loading) return;
    // Editing also supports records displayed under History.
    final result = await showDialog<_MovementFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MovementDialog(
        existing: existing,
        isNew: existing == null,
        selectedMonth: existing == null ? _reportMonth : _eventMonth(existing),
      ),
    );
    if (result == null || !mounted) return;
    await _saveMovement(result, existing: existing);
  }

  Future<void> _saveMovement(
    _MovementFormResult form, {
    _MovementRecord? existing,
  }) async {
    if (_saving || _readOnly || !mounted) return;
    if (form.movementDate == null) {
      _message('Movement Date is required.');
      return;
    }
    setState(() => _saving = true);
    try {
      final data = <String, dynamic>{
        'unit': form.unit.trim(),
        'movement': form.movement,
        'movement_date': _dbDate(form.movementDate),
        'remarks': form.remarks.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      if (existing == null) {
        final lineNo = _nextLineNo();
        if (lineNo > 32767) throw StateError('Maximum line number reached.');
        final saved = await _supabase.from('unit_movements').insert({
          ...data,
          'report_id': _reportId,
          'line_no': lineNo,
        }).select('line_no');
        if (saved.isEmpty) throw StateError('Insert did not save a record.');
      } else {
        final saved = await _supabase
            .from('unit_movements')
            .update(data)
            .eq('report_id', existing.sourceReportId)
            .eq('line_no', existing.lineNo)
            .select('line_no');
        if (saved.isEmpty) {
          throw StateError('No record updated. Check permissions or report lock.');
        }
      }

      if (!mounted) return;
      await _loadRecords();
      if (mounted) {
        _message(existing == null
            ? 'Unit movement added successfully.'
            : 'Unit movement updated successfully.');
      }
    } catch (e) {
      if (mounted) _message('Unable to save unit movement: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteMovement(_MovementRecord record) async {
    if (!mounted || _readOnly || _saving || _loading) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Unit Movement?'),
        content: Text(
          'Delete the ${record.movement} record for ${record.unit} '
          'dated ${_dateLabel(record.movementDate)}? '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _saving || _readOnly) return;

    setState(() => _saving = true);
    try {
      final deleted = await _supabase
          .from('unit_movements')
          .delete()
          .eq('report_id', record.sourceReportId)
          .eq('line_no', record.lineNo)
          .select('line_no');
      if (deleted.length != 1) {
        throw StateError('No record deleted. Check permissions or report lock.');
      }
      if (!mounted) return;
      await _loadRecords();
      if (mounted) _message('Unit movement deleted successfully.');
    } catch (e) {
      if (mounted) _message('Unable to delete unit movement: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: AppColors.charcoal,
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _toggleType(String type) {
    setState(() {
      if (!_selectedTypes.add(type)) _selectedTypes.remove(type);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Unit Movement',
            style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving ? null : _loadRecords,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _loading || _saving
                  ? null
                  : () => _showMovementDialog(),
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Movement'),
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
      return const Center(child: CircularProgressIndicator(color: AppColors.red));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: AppColors.red, size: 44),
            const SizedBox(height: 12),
            const Text('Unable to load unit movements.',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.red,
                foregroundColor: AppColors.white,
              ),
              onPressed: _loadRecords,
              child: const Text('Try Again'),
            ),
          ]),
        ),
      );
    }

    final current = _current;
    final visibleCurrent = _visibleCurrent;
    final visibleHistory = _visibleHistory;
    final moveInCount = current.where((r) => r.movement == 'Move In').length;
    final moveOutCount = current.where((r) => r.movement == 'Move Out').length;

    return RefreshIndicator(
      color: AppColors.red,
      onRefresh: _loadRecords,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _buildHeader(),
          const SizedBox(height: 18),
          _buildSummary(current.length, moveInCount, moveOutCount),
          const SizedBox(height: 24),
          const Text('Movement Records',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
            'Track unit move-ins and move-outs for the selected property and month.',
            style: TextStyle(color: AppColors.grey, height: 1.5),
          ),
          const SizedBox(height: 16),
          _buildSearch(),
          const SizedBox(height: 12),
          _buildActiveFilters(),
          _sectionTitle('This Month', visibleCurrent.length),
          if (visibleCurrent.isEmpty)
            _buildEmptyMessage('No matching movements for this month.')
          else
            ...visibleCurrent.asMap().entries.map(
                  (entry) => _movementCard(
                    entry.value,
                    entry.key + 1,
                  ),
                ),
          const SizedBox(height: 12),
          _buildHistoryDropdown(visibleHistory),
        ],
      ),
    );
  }

  // Group historical movements by their original movement month.
  Widget _buildHistoryDropdown(List<_MovementRecord> visibleHistory) {
    final grouped = <DateTime, List<_MovementRecord>>{};
    for (final record in visibleHistory) {
      final month = _eventMonth(record);
      if (month != null) {
        grouped.putIfAbsent(month, () => <_MovementRecord>[]).add(record);
      }
    }
    final months = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('History', visibleHistory.length),
        if (visibleHistory.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No historical movements match these filters.',
              style: TextStyle(color: AppColors.grey),
            ),
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
              clipBehavior: Clip.antiAlias,
              child: Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: ExpansionTile(
                  key: PageStorageKey(
                    'unit-movement-history-$_reportId-${month.year}-${month.month}',
                  ),
                  initiallyExpanded: false,
                  backgroundColor: AppColors.white,
                  collapsedBackgroundColor: AppColors.white,
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  title: Text(
                    _monthLabel(month),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${grouped[month]!.length} movement record(s)',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.grey,
                    ),
                  ),
                  children: [
                    for (var i = 0; i < grouped[month]!.length; i++)
                      _movementCard(
                        grouped[month]![i],
                        i + 1,
                        historical: true,
                      ),
                  ],
                ),
              ),
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('OPERATIONS', style: TextStyle(
          color: AppColors.red, fontSize: 12, fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        )),
        const SizedBox(height: 8),
        const Text('Unit Movement', style: TextStyle(
          color: AppColors.white, fontSize: 25, fontWeight: FontWeight.w800,
        )),
        const SizedBox(height: 8),
        Text('${_monthLabel(_reportMonth)} • Report ID: $_reportId',
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 13)),
      ]),
    );
  }

  Widget _buildSummary(int total, int moveIn, int moveOut) {
    return Column(
      children: [
        // Total movements: full-width card.
        SizedBox(
          width: double.infinity,
          child: InkWell(
            onTap: () => setState(() => _selectedTypes.clear()),
            child: _summaryCard(
              'Total Movements',
              '$total',
              Icons.swap_horiz,
              AppColors.red,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Keep Move In and Move Out side by side.
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => _toggleType('Move In'),
                child: _summaryCard(
                  'Move In',
                  '$moveIn',
                  Icons.login_outlined,
                  const Color(0xFF22683D),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: () => _toggleType('Move Out'),
                child: _summaryCard(
                  'Move Out',
                  '$moveOut',
                  Icons.logout_outlined,
                  const Color(0xFFB53A27),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // All borders remain neutral, including selected filter cards.
  Widget _summaryCard(String title, String value, IconData icon, Color accent) {
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: [BoxShadow(
          color: AppColors.black.withValues(alpha: 0.025),
          blurRadius: 8, offset: const Offset(0, 3),
        )],
      ),
      child: Row(children: [
        Container(
          width: 46, height: 46, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: accent, size: 25),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: const TextStyle(
              fontSize: 12, color: AppColors.grey, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(
              color: AppColors.black, fontSize: 21, fontWeight: FontWeight.w800,
            )),
          ],
        )),
      ]),
    );
  }

  Widget _buildSearch() {
    return TextField(
      controller: _searchController,
      onChanged: (value) => setState(() => _search = value),
      decoration: InputDecoration(
        hintText: 'Search unit, movement type, date, remarks...',
        prefixIcon: const Icon(Icons.search, color: AppColors.grey),
        suffixIcon: _search.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear search',
                onPressed: () {
                  _searchController.clear();
                  setState(() => _search = '');
                },
              ),
        filled: true,
        fillColor: AppColors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.red),
        ),
      ),
    );
  }

  Widget _buildActiveFilters() {
    if (_selectedTypes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8, runSpacing: 8, children: [
        const Text('Showing:', style: TextStyle(
          fontSize: 12, color: AppColors.grey,
        )),
        for (final type in ['Move In', 'Move Out'])
          if (_selectedTypes.contains(type))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(type, style: const TextStyle(fontSize: 12)),
            ),
        TextButton.icon(
          onPressed: () => setState(() => _selectedTypes.clear()),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          icon: const Icon(Icons.close, size: 14),
          label: const Text('Clear filter'),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(title, style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.bold,
            )),
          ),
          Text('$count records', style: const TextStyle(
            color: AppColors.grey, fontSize: 12,
          )),
        ],
      ),
    );
  }

  Widget _buildEmptyMessage(String message) {
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(message, style: const TextStyle(color: AppColors.grey)),
    );
  }

  Widget _movementChip(String movement) {
    final isMoveIn = movement == 'Move In';
    final accent = isMoveIn
        ? const Color(0xFF22683D)
        : const Color(0xFFB53A27);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(isMoveIn ? Icons.login_outlined : Icons.logout_outlined,
            size: 14, color: accent),
        const SizedBox(width: 5),
        Text(movement, style: TextStyle(
          color: accent, fontSize: 12, fontWeight: FontWeight.w700,
        )),
      ]),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 130, child: Text(label,
            style: const TextStyle(color: AppColors.grey, fontSize: 13))),
        Expanded(child: Text(value.isEmpty ? '—' : value,
            style: const TextStyle(
              color: AppColors.black, fontSize: 13,
              fontWeight: FontWeight.w600,
            ))),
      ]),
    );
  }

  Widget _movementCard(_MovementRecord record, int number,
      {bool historical = false}) {
    // Preserve the existing Update Movement action under This Month.
    final canUpdate = !_readOnly && !_saving && !historical &&
        _isThisMonth(record);
    final canEditHistory = !_readOnly && !_saving && historical;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44, height: 44, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$number', style: const TextStyle(
              color: AppColors.red, fontSize: 17,
              fontWeight: FontWeight.bold,
            )),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(record.unit, style: const TextStyle(
                color: AppColors.black, fontWeight: FontWeight.bold,
                fontSize: 16,
              )),
              if (record.movementDate == null)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Movement date not specified',
                      style: TextStyle(color: AppColors.grey, fontSize: 12)),
                ),
            ],
          )),
          Align(
            alignment: Alignment.topRight,
            child: _movementChip(record.movement),
          ),
        ]),
        const SizedBox(height: 14),
        _detailRow('Movement Date', _dateLabel(record.movementDate)),
        _detailRow('Remarks', record.remarks.trim().isEmpty
            ? '—' : record.remarks.trim()),
        const Divider(color: AppColors.border),
        if (historical || canUpdate)
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: canEditHistory || canUpdate
                      ? () => _showMovementDialog(existing: record)
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Edit'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
                TextButton.icon(
                  onPressed: canEditHistory || canUpdate
                      ? () => _deleteMovement(record)
                      : null,
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('Delete'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                ),
              ],
            ),
          ),
      ]),
    );
  }
}

class _MovementRecord {
  final String? id;
  final int lineNo;
  final String sourceReportId;
  final DateTime? sourceReportMonth;
  final String sourceReportStatus;
  final String unit;
  final String movement;
  final DateTime? movementDate;
  final String remarks;

  const _MovementRecord({
    this.id,
    required this.lineNo,
    required this.sourceReportId,
    required this.sourceReportMonth,
    required this.sourceReportStatus,
    required this.unit,
    required this.movement,
    required this.movementDate,
    required this.remarks,
  });

  factory _MovementRecord.fromMap(Map<String, dynamic> map, {
    DateTime? sourceReportMonth,
    required String sourceReportStatus,
  }) {
    return _MovementRecord(
      id: map['id']?.toString(),
      lineNo: (map['line_no'] as num).toInt(),
      sourceReportId: map['report_id']?.toString() ?? '',
      sourceReportMonth: sourceReportMonth,
      sourceReportStatus: sourceReportStatus,
      unit: map['unit']?.toString() ?? '',
      movement: map['movement']?.toString() ?? '',
      movementDate: DateTime.tryParse(map['movement_date']?.toString() ?? ''),
      remarks: map['remarks']?.toString() ?? '',
    );
  }
}

class _MovementFormResult {
  final String unit;
  final String movement;
  final DateTime? movementDate;
  final String remarks;

  const _MovementFormResult({
    required this.unit,
    required this.movement,
    required this.movementDate,
    required this.remarks,
  });
}

class _MovementDialog extends StatefulWidget {
  final _MovementRecord? existing;
  final bool isNew;
  final DateTime? selectedMonth;

  const _MovementDialog({
    required this.existing,
    required this.isNew,
    required this.selectedMonth,
  });

  @override
  State<_MovementDialog> createState() => _MovementDialogState();
}

class _MovementDialogState extends State<_MovementDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _unitController;
  late final TextEditingController _remarksController;
  String? _movement;
  DateTime? _movementDate;

  @override
  void initState() {
    super.initState();
    _unitController = TextEditingController(text: widget.existing?.unit ?? '');
    _remarksController = TextEditingController(
        text: widget.existing?.remarks ?? '');
    _movement = widget.existing?.movement;
    _movementDate = widget.existing?.movementDate;
  }

  @override
  void dispose() {
    _unitController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final initial = _movementDate ?? widget.selectedMonth ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: DateUtils.dateOnly(initial),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'SELECT MOVEMENT DATE',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.red,
            onPrimary: AppColors.white,
            surface: AppColors.white,
            onSurface: AppColors.black,
          ),
        ),
        child: child!,
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _movementDate = selected);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (_movementDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please select a Movement Date.'),
      ));
      return;
    }
    Navigator.pop(context, _MovementFormResult(
      unit: _unitController.text.trim(),
      movement: _movement!,
      movementDate: _movementDate,
      remarks: _remarksController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      title: Text(widget.isNew ? 'Add Unit Movement' : 'Update Unit Movement',
          style: const TextStyle(color: AppColors.black,
              fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 490,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextFormField(
                controller: _unitController,
                decoration: const InputDecoration(
                  labelText: 'Unit Number *',
                  hintText: 'e.g. A-12-03',
                  prefixIcon: Icon(Icons.apartment_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a unit number' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _movement,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Movement Type *',
                  prefixIcon: Icon(Icons.swap_horiz),
                  border: OutlineInputBorder(),
                ),
                hint: const Text('Select movement type'),
                items: const [
                  DropdownMenuItem(value: 'Move In', child: Text('Move In')),
                  DropdownMenuItem(value: 'Move Out', child: Text('Move Out')),
                ],
                validator: (value) => value == null || value.isEmpty
                    ? 'Select a movement type' : null,
                onChanged: (value) => setState(() => _movement = value),
              ),
              const SizedBox(height: 16),
              const Text('Movement Date *', style: TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.black)),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(_movementDate == null
                    ? 'Select date' : _UnitMovementState._dateLabel(_movementDate)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.black,
                  side: const BorderSide(color: AppColors.border),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
                ),
              )),
              const SizedBox(height: 16),
              TextFormField(
                controller: _remarksController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Remarks',
                  prefixIcon: Icon(Icons.notes_outlined),
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ]),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.red, foregroundColor: AppColors.white,
          ),
          child: Text(widget.isNew ? 'Add Movement' : 'Save Movement'),
        ),
      ],
    );
  }
}