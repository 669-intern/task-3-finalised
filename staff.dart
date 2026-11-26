import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class StaffPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const StaffPage({super.key, required this.report});

  @override
  State<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends State<StaffPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  // Display-only values from the shared Service Providers staffing source.
  final Map<String, Map<String, dynamic>> _staffByProvider = {};
  final Map<String, bool> _explicitStaffInclusion = {};
  final Map<DateTime, List<Map<String, dynamic>>> _historyByMonth = {};
  List<Map<String, dynamic>> _currentProviders = [];
  List<String> _availableCategories = [];
  String _categoryFilter = 'All';
  bool _loading = true;
  String? _error;

  static const Set<String> _initialCategories = {
    'Security',
    'Cleaning',
    'Landscaping',
  };

  String get _reportId => widget.report['id']?.toString() ?? '';
  String get _siteId => widget.report['site_id']?.toString() ?? '';

  DateTime? get _reportMonth {
    final date = DateTime.tryParse(
      widget.report['report_month']?.toString() ?? '',
    );
    return date == null ? null : DateTime(date.year, date.month);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadStaff();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return null;
    return DateTime.tryParse(value.toString());
  }

  static DateTime _monthStart(DateTime date) => DateTime(date.year, date.month);

  static String _databaseDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-01';

  static String _monthLabel(DateTime date) {
    const names = [
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
    return '${names[date.month - 1]} ${date.year}';
  }

  static String _service(Map<String, dynamic> provider) =>
      provider['service']?.toString().trim() ?? '';

  static int? _staffNumber(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return null;
    return int.tryParse(value.toString());
  }

  bool _visibleInMonth(Map<String, dynamic> provider, DateTime month) {
    if (provider['history_deleted_at'] != null) return false;

    final start = _parseDate(provider['commencement_date']);
    if (start != null && _monthStart(start).isAfter(_monthStart(month))) {
      return false;
    }

    final expiry = _parseDate(
      provider['expiry_date'] ?? provider['expiry_renewal_date'],
    );

    final confirmed = _parseDate(provider['renewal_confirmed_at']);
    final nextExpiry = _parseDate(provider['next_expiry_date']);
    final monthEnd = DateTime(month.year, month.month + 1, 0);
    final renewed = expiry != null &&
        confirmed != null &&
        !confirmed.isAfter(monthEnd) &&
        nextExpiry != null &&
        nextExpiry.isAfter(expiry);
    final effectiveExpiry = renewed ? nextExpiry : expiry;
    if (effectiveExpiry != null) {
      final expiryMonth = _monthStart(effectiveExpiry);
      final selectedMonth = _monthStart(month);

      if (expiryMonth.isBefore(selectedMonth) ||
          (effectiveExpiry.day == 1 && expiryMonth == selectedMonth)) {
        return false;
      }
    }

    final status = provider['status']?.toString().trim().toLowerCase();
    final noLongerUsed = status == 'terminated' || status == 'no longer used';
    final stopDate = _parseDate(provider['lifecycle_date']);
    if (noLongerUsed &&
        stopDate != null &&
        _monthStart(stopDate).isBefore(_monthStart(month))) {
      return false;
    }

    if (provider['is_archived'] == true) {
      final archivedAt = _parseDate(provider['archived_at']);
      if (archivedAt == null ||
          !_monthStart(archivedAt).isAfter(_monthStart(month))) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic>? _staffFor(Map<String, dynamic> provider) =>
      _staffByProvider[provider['id']?.toString()];

  bool _matchesSearch(Map<String, dynamic> provider) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final staff = _staffFor(provider);
    return [
      provider['service'],
      provider['company_pic'],
      provider['contact'],
      staff?['service_hours'],
      staff?['frequency'],
    ].where((v) => v != null).join(' ').toLowerCase().contains(query);
  }

  bool _included(Map<String, dynamic> provider) {
    final staff = _staffFor(provider);
    if (staff == null || staff['include_in_staff'] != true) return false;

    return _initialCategories.contains(_service(provider)) ||
        _explicitStaffInclusion[provider['id']?.toString()] == true;
  }

  bool _passesFilters(Map<String, dynamic> provider) =>
      _included(provider) &&
      (_categoryFilter == 'All' || _service(provider) == _categoryFilter) &&
      _matchesSearch(provider);

  int _compareProviders(Map<String, dynamic> a, Map<String, dynamic> b) {
    final category = _service(
      a,
    ).toLowerCase().compareTo(_service(b).toLowerCase());
    if (category != 0) return category;
    return (a['company_pic']?.toString().toLowerCase() ?? '').compareTo(
      b['company_pic']?.toString().toLowerCase() ?? '',
    );
  }

  List<Map<String, dynamic>> get _currentIncluded =>
      _currentProviders.where(_included).toList();

  List<Map<String, dynamic>> get _currentFiltered =>
      _currentProviders.where(_passesFilters).toList();

  List<MapEntry<DateTime, List<Map<String, dynamic>>>> get _history {
    final entries = <MapEntry<DateTime, List<Map<String, dynamic>>>>[];
    for (final entry in _historyByMonth.entries) {
      final filtered = entry.value.where(_passesFilters).toList()
        ..sort(_compareProviders);
      if (filtered.isNotEmpty) entries.add(MapEntry(entry.key, filtered));
    }
    entries.sort((a, b) => b.key.compareTo(a.key));
    return entries;
  }

  Future<void> _loadStaff() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_reportId.isEmpty || _siteId.isEmpty || _reportMonth == null) {
        throw StateError('Report id, site_id and report_month are required.');
      }
      final selectedMonth = _reportMonth!;
      const pageSize = 500;

      final reportRows = <Map<String, dynamic>>[];
      for (var offset = 0;; offset += pageSize) {
        final result = await _supabase
            .from('monthly_reports')
            .select('id,report_month')
            .eq('site_id', _siteId)
            .lte('report_month', _databaseDate(selectedMonth))
            .order('report_month', ascending: true)
            .range(offset, offset + pageSize - 1);
        final rows = List<Map<String, dynamic>>.from(result);
        reportRows.addAll(rows);
        if (rows.length < pageSize) break;
      }

      final months = <String, DateTime>{};
      for (final row in reportRows) {
        final id = row['id']?.toString();
        final date = _parseDate(row['report_month']);
        if (id != null && date != null) months[id] = _monthStart(date);
      }

      months[_reportId] = selectedMonth;

      final providers = <Map<String, dynamic>>[];
      final reportIds = months.keys.toList();
      for (var i = 0; i < reportIds.length; i += 80) {
        final ids = reportIds.skip(i).take(80).toList();
        for (var offset = 0;; offset += pageSize) {
          final result = await _supabase
              .from('service_providers')
              .select()
              .inFilter('report_id', ids)
              .order('id')
              .range(offset, offset + pageSize - 1);
          final rows = List<Map<String, dynamic>>.from(result);
          providers.addAll(rows);
          if (rows.length < pageSize) break;
        }
      }

      final byId = <String, Map<String, dynamic>>{
        for (final provider in providers)
          if (provider['id'] != null)
            provider['id'].toString(): provider,
      };
      final staff = <String, Map<String, dynamic>>{};
      final directStaff = <String, Map<String, dynamic>>{};
      final providerIds = byId.keys.toList();
      for (var i = 0; i < providerIds.length; i += 80) {
        final ids = providerIds.skip(i).take(80).toList();
        final effectiveRows = await _supabase
            .from('staff_effective')
            .select()
            .inFilter('service_provider_id', ids);
        for (final row in List<Map<String, dynamic>>.from(effectiveRows)) {
          staff[row['service_provider_id'].toString()] = row;
        }

        final explicitRows = await _supabase
            .from('staff')
            .select('service_provider_id,include_in_staff')
            .inFilter('service_provider_id', ids);
        for (final row in List<Map<String, dynamic>>.from(explicitRows)) {
          directStaff[row['service_provider_id'].toString()] = row;
        }
      }

      final explicitInclusion = <String, bool>{};
      for (final id in providerIds) {
        var cursor = id;
        final visited = <String>{};
        while (visited.add(cursor)) {
          final saved = directStaff[cursor];
          if (saved != null) {
            explicitInclusion[id] = saved['include_in_staff'] == true;
            break;
          }
          final parent = byId[cursor]?['source_provider_id']?.toString();
          if (parent == null || !byId.containsKey(parent)) break;
          cursor = parent;
        }
      }

      String rootOf(Map<String, dynamic> provider) {
        var id = provider['id'].toString();
        final visited = <String>{};
        while (visited.add(id)) {
          final parent = byId[id]?['source_provider_id']?.toString();
          if (parent == null || !byId.containsKey(parent)) break;
          id = parent;
        }
        return id;
      }

      DateTime savedMonth(Map<String, dynamic> provider) =>
          months[provider['report_id']?.toString()] ?? DateTime(9999);

      int compareSnapshots(Map<String, dynamic> a, Map<String, dynamic> b) {
        final byMonth = savedMonth(a).compareTo(savedMonth(b));
        if (byMonth != 0) return byMonth;
        return (a['updated_at']?.toString() ?? '').compareTo(
          b['updated_at']?.toString() ?? '',
        );
      }

      final groups = <String, List<Map<String, dynamic>>>{};
      for (final provider in providers) {
        (groups[rootOf(provider)] ??= []).add(provider);
      }
      for (final snapshots in groups.values) {
        snapshots.sort(compareSnapshots);
      }

      Map<String, dynamic>? asOfMonth(
        List<Map<String, dynamic>> snapshots,
        DateTime month,
        String reportId, {
        bool allowBeforeFirst = false,
      }) {

        final exact = snapshots
            .where((p) => p['report_id']?.toString() == reportId)
            .toList();
        if (exact.isNotEmpty) {
          final provider = exact.last;
          return _visibleInMonth(provider, month) ? provider : null;
        }
        Map<String, dynamic>? previous;
        for (final provider in snapshots) {
          if (!savedMonth(provider).isAfter(month)) previous = provider;
        }

        if (previous == null && allowBeforeFirst) previous = snapshots.first;
        if (previous == null) return null;
        return _visibleInMonth(previous, month) ? previous : null;
      }

      final current = <Map<String, dynamic>>[];
      for (final snapshots in groups.values) {
        final provider = asOfMonth(snapshots, selectedMonth, _reportId);
        if (provider != null) current.add(provider);
      }
      current.sort(_compareProviders);

      final historical = <DateTime, List<Map<String, dynamic>>>{};
      for (final report in months.entries) {
        if (!report.value.isBefore(selectedMonth)) continue;
        final monthProviders = <Map<String, dynamic>>[];
        for (final snapshots in groups.values) {
          final provider = asOfMonth(snapshots, report.value, report.key);
          if (provider != null) monthProviders.add(provider);
        }
        if (monthProviders.isNotEmpty) {
          monthProviders.sort(_compareProviders);
          historical[report.value] = monthProviders;
        }
      }

      final reportIdsByMonth = <DateTime, String>{
        for (final entry in months.entries) entry.value: entry.key,
      };
      for (final snapshots in groups.values) {
        final hasStaffSelection = snapshots.any((provider) {
          final id = provider['id']?.toString();
          return id != null && directStaff[id]?['include_in_staff'] == true;
        });
        if (!hasStaffSelection) continue;

        final latestSetting = snapshots.reversed
            .map((provider) => directStaff[provider['id']?.toString()])
            .whereType<Map<String, dynamic>>()
            .firstOrNull;
        if (latestSetting?['include_in_staff'] == true) {
          for (final provider in snapshots) {
            final id = provider['id']?.toString();
            if (id != null && !directStaff.containsKey(id)) {
              explicitInclusion[id] = true;
            }
          }
        }

        DateTime? commencement;
        for (final provider in snapshots) {
          final date = _parseDate(provider['commencement_date']);
          if (date != null &&
              (commencement == null || date.isBefore(commencement))) {
            commencement = date;
          }
        }
        final startMonth = _monthStart(
          commencement ?? savedMonth(snapshots.first),
        );
        final contractId = rootOf(snapshots.first);
        for (var month = startMonth;
            month.isBefore(selectedMonth);
            month = DateTime(month.year, month.month + 1)) {
          final provider = asOfMonth(
            snapshots,
            month,
            reportIdsByMonth[month] ?? '',
            allowBeforeFirst: true,
          );
          if (provider == null) continue;
          final rows = historical.putIfAbsent(month, () => []);
          if (!rows.any((row) => rootOf(row) == contractId)) {
            rows.add(provider);
          }
        }
      }
      for (final rows in historical.values) {
        rows.sort(_compareProviders);
      }

      bool includedForDisplay(Map<String, dynamic> provider) {
        final id = provider['id']?.toString();
        final row = staff[id];
        if (row == null || row['include_in_staff'] != true) return false;
        return _initialCategories.contains(_service(provider)) ||
            explicitInclusion[id] == true;
      }

      final available = <String>{};
      for (final provider in [
        ...current,
        ...historical.values.expand((rows) => rows),
      ]) {
        if (includedForDisplay(provider) && _service(provider).isNotEmpty) {
          available.add(_service(provider));
        }
      }
      final sortedCategories = available.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _staffByProvider
          ..clear()
          ..addAll(staff);
        _explicitStaffInclusion
          ..clear()
          ..addAll(explicitInclusion);
        _currentProviders = current;
        _historyByMonth
          ..clear()
          ..addAll(historical);
        _availableCategories = sortedCategories;
        if (_categoryFilter != 'All' &&
            !_availableCategories.contains(_categoryFilter)) {
          _categoryFilter = 'All';
        }
        _loading = false;
      });
    } catch (error, trace) {
      debugPrint('Staff load error: $error');
      debugPrintStack(stackTrace: trace);
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Staff'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadStaff,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
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
              const SizedBox(height: 12),
              const Text(
                'Unable to load Staff.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SelectableText(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadStaff,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final current = _currentFiltered;
    final history = _history;
    final historyTotal = history.fold<int>(
      0,
      (count, entry) => count + entry.value.length,
    );

    return RefreshIndicator(
      color: AppColors.red,
      onRefresh: _loadStaff,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 90),
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildSummary(),
          const SizedBox(height: 14),
          _buildSearchAndFilters(),
          const SizedBox(height: 20),
          _sectionHeading('This Month', current.length),
          if (current.isEmpty)
            _emptySection(
              'No staff records match the selected category or search.',
            )
          else
            for (var i = 0; i < current.length; i++)
              _buildStaffCard(current[i], i + 1),
          const SizedBox(height: 22),
          _sectionHeading('History', historyTotal),
          if (history.isEmpty)
            _emptySection('No historical staff records match.')
          else
            for (final entry in history)
              Card(
                color: AppColors.white,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: AppColors.border),
                ),
                child: ExpansionTile(
                  key: ValueKey(
                    'staff-history-$_reportId-${_monthLabel(entry.key)}',
                  ),
                  title: Text(
                    _monthLabel(entry.key),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${entry.value.length} records',
                    style: const TextStyle(color: AppColors.grey),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    for (var i = 0; i < entry.value.length; i++)
                      _buildStaffCard(entry.value[i], i + 1),
                  ],
                ),
              ),
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
            'OPERATIONS',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Staff',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthLabel(_reportMonth ?? DateTime.now())} '
            '• Report ID: $_reportId',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(
    String label,
    String value,
    IconData icon, {
    String? note,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.025),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.red, size: 24),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.black,
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    note,
                    style: const TextStyle(fontSize: 11, color: AppColors.grey),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final providers = _currentIncluded;
    final values = providers
        .map((p) => _staffNumber(_staffFor(p)?['total_staff']))
        .toList();
    final known = values.whereType<int>().toList();
    final total = known.fold<int>(0, (sum, value) => sum + value);

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: _summaryCard(
            'Total Staff',
            known.isEmpty ? '—' : '$total',
            Icons.people_outline,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: _summaryCard(
            'Total Service Records',
            '${_currentIncluded.length}',
            Icons.business_outlined,
          ),
        ),
      ],
    );
  }

  Widget _buildSearchAndFilters() {
    final categories = [..._availableCategories];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search staff, company or service...',
            prefixIcon: const Icon(Icons.search, color: AppColors.grey),
            border: const OutlineInputBorder(),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.clear),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text(
              'Showing:',
              style: TextStyle(fontSize: 12, color: AppColors.grey),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: PopupMenuButton<String>(
                tooltip: 'Filter by category',
                initialValue: _categoryFilter,
                onSelected: (value) =>
                    setState(() => _categoryFilter = value),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'All',
                    child: Text('All categories'),
                  ),
                  for (final category in categories)
                    PopupMenuItem(value: category, child: Text(category)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _categoryFilter == 'All'
                              ? 'All categories'
                              : _categoryFilter,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.black,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.arrow_drop_down,
                        color: AppColors.grey,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sectionHeading(String title, int count) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.black,
            ),
          ),
        ),
        Text(
          '$count records',
          style: const TextStyle(color: AppColors.grey, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _emptySection(String message) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.white,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.grey)),
  );

  Widget _staffBox(String label, String value) => Container(
    width: 210,
    height: 90,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F8FA),
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(9),
    ),
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
        const SizedBox(height: 5),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.black,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _shiftBox(
    String label,
    dynamic time,
    dynamic pax, {
    int? supervisors,
    int? guards,
  }) {
    final timing = time?.toString().trim() ?? '';
    final count = _staffNumber(pax);
    final hasSecurityPositions = supervisors != null || guards != null;
    return Container(
      width: 210,
      height: hasSecurityPositions ? 132 : 90,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8FA),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(9),
      ),
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
          const SizedBox(height: 5),
          if (timing.isNotEmpty)
            Text(
              'Timing: $timing',
              style: const TextStyle(color: AppColors.black, fontSize: 13),
            ),
          if (count != null)
            Text(
              'Pax: $count',
              style: const TextStyle(color: AppColors.black, fontSize: 13),
            ),
          if (supervisors != null)
            Text(
              'Security Supervisor: $supervisors',
              style: const TextStyle(color: AppColors.black, fontSize: 12),
            ),
          if (guards != null)
            Text(
              'Security Guards: $guards',
              style: const TextStyle(color: AppColors.black, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: constraints.maxWidth < 440 ? 110 : 155,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.grey, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.black,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  static String _shiftTiming(
    Map<String, dynamic>? staff,
    String shift,
  ) {
    if (staff == null) return '';
    final start = staff['${shift}_shift_start_time']?.toString();
    final end = staff['${shift}_shift_end_time']?.toString();
    if (start == null || end == null || start.isEmpty || end.isEmpty) {
      return staff['${shift}_shift_timing']?.toString().trim() ?? '';
    }

    String pretty(String time) {
      final pieces = time.split(':');
      if (pieces.length < 2) return time;
      final hour = int.tryParse(pieces[0]);
      if (hour == null) return time;
      final minute = pieces[1];
      final hour12 = hour % 12 == 0 ? 12 : hour % 12;
      return '$hour12:$minute ${hour < 12 ? 'AM' : 'PM'}';
    }
    return '${pretty(start)} - ${pretty(end)}';
  }

  static String? _shiftWeekdayLabel(Map<String, dynamic>? staff, String shift) {
    final frequency = staff?['frequency']?.toString().trim().toLowerCase();
    if (frequency == 'daily') return null;
    final value = staff?['${shift}_shift_weekdays'];
    if (value is! List || value.isEmpty) return null;
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final selected = <String>[];
    for (final item in value) {
      final number = item is int ? item : int.tryParse(item.toString());
      if (number != null && number >= 1 && number <= 7) {
        selected.add(days[number - 1]);
      }
    }
    return selected.isEmpty ? null : selected.join(', ');
  }

  Widget _buildStaffCard(Map<String, dynamic> provider, int number) {
    final staff = _staffFor(provider);
    final label = provider['company_pic']?.toString() ?? 'Unnamed Provider';
    final contact = provider['contact']?.toString().trim() ?? '';
    final serviceHours = staff?['service_hours']?.toString().trim() ?? '';
    final frequency = staff?['frequency']?.toString().trim() ?? '';
    final totalStaff = _staffNumber(staff?['total_staff']);
    final dayTime = _shiftTiming(staff, 'day');
    final dayPax = _staffNumber(staff?['day_shift_staff']);
    final nightTime = _shiftTiming(staff, 'night');
    final nightPax = _staffNumber(staff?['night_shift_staff']);
    final isSecurity = _service(provider).toLowerCase() == 'security';
    final daySupervisors = isSecurity
        ? _staffNumber(staff?['day_shift_supervisors'])
        : null;
    final dayGuards = isSecurity
        ? _staffNumber(staff?['day_shift_guards'])
        : null;
    final nightSupervisors = isSecurity
        ? _staffNumber(staff?['night_shift_supervisors'])
        : null;
    final nightGuards = isSecurity
        ? _staffNumber(staff?['night_shift_guards'])
        : null;
    final dayWeekdays = _shiftWeekdayLabel(staff, 'day');
    final nightWeekdays = _shiftWeekdayLabel(staff, 'night');
    final hasDayShift = dayPax != 0 && (dayTime.isNotEmpty || dayPax != null);
    final hasNightShift = nightPax != 0 &&
        (nightTime.isNotEmpty || nightPax != null);
    final hasManpowerBoxes = totalStaff != null || hasDayShift || hasNightShift;
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
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: AppColors.red,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_service(provider).isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _service(provider),
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (hasManpowerBoxes) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (totalStaff != null) _staffBox('Total Staff', '$totalStaff'),
                if (hasDayShift)
                  _shiftBox(
                    'Day Shift',
                    dayTime,
                    dayPax,
                    supervisors: daySupervisors,
                    guards: dayGuards,
                  ),
                if (hasNightShift)
                  _shiftBox(
                    'Night Shift',
                    nightTime,
                    nightPax,
                    supervisors: nightSupervisors,
                    guards: nightGuards,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (contact.isNotEmpty) _detailRow('Contact Details', contact),
          if (serviceHours.isNotEmpty)
            _detailRow('Service Hours', serviceHours),
          if (frequency.isNotEmpty) _detailRow('Frequency', frequency),
          if (dayWeekdays != null)
            _detailRow('Day Shift Working Days', dayWeekdays),
          if (nightWeekdays != null)
            _detailRow('Night Shift Working Days', nightWeekdays),
        ],
      ),
    );
  }
}