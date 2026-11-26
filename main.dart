import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'auth_gate.dart';
import 'property_selection_page.dart';
import 'staff_management_page.dart';
import 'widgets/app_shell.dart';
import 'widgets/app_common_app_bar.dart';
import 'widgets/styles.dart';
import 'site_profile_page.dart';
import 'finance/finance_page.dart';
import 'operation/operations_page.dart';
import 'occupancy-unit/occupancy_unit_page.dart';
import 'contracts-compliance/contracts_compliance_page.dart';
import 'archived_records.dart';
import 'export_pdf.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  usePathUrlStrategy();

  await Supabase.initialize(
    url: 'https://inovaclxtkcfnnzzymii.supabase.co',
    publishableKey: 
  );

  runApp(const PropertyReportApp());
}

class PropertyReportApp extends StatefulWidget {
  const PropertyReportApp({super.key});

  @override
  State<PropertyReportApp> createState() => _PropertyReportAppState();
}

class _PropertyReportAppState extends State<PropertyReportApp> {
  // This Navigator lives inside MaterialApp.home (under its Overlay), so
  // the persistent sidebar has a valid Overlay for Tooltip and dropdowns.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final HeroController _reportsHeroController =
      MaterialApp.createMaterialHeroController();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final AppShellController _shellController = AppShellController();
  late final AppShellRouteObserver _routeObserver =
      AppShellRouteObserver(_shellController);
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      if (state.event != AuthChangeEvent.signedOut) return;
      // The AuthGate already handles sign-out; also close any pushed reports
      // so their content cannot remain visible above the sign-in screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _navigatorKey.currentState?.popUntil((route) => route.isFirst);
      });
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _shellController.dispose();
    super.dispose();
  }

  void _openSite(
    BuildContext context,
    Map<String, dynamic> site,
    String accessToken,
  ) {
    final siteId = site['id'].toString();
    final siteName = site['site_name'].toString();
    _shellController.selectSite(id: siteId, name: siteName);

    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: 'app:reports'),
        builder: (_) => MonthlyReportsPage(
          siteId: siteId,
          siteName: siteName,
          shellController: _shellController,
        ),
      ),
    );
  }

  void _openPropertySelection() {
    _shellController.selectSection('properties');
    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'app:properties'),
        builder: (_) => PropertySelectionPage(onSiteOpened: _openSite),
      ),
    );
  }

  void _navigateFromSidebar(String destination) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !_shellController.authorized) return;

    switch (destination) {
      case 'dashboard':
        _shellController.selectSection('dashboard');
        navigator.popUntil((route) => route.isFirst);
        break;
      case 'properties':
        _openPropertySelection();
        break;
      case 'staff':
        if (!_shellController.isAdmin) return;
        _shellController.selectSection('staff');
        navigator.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'app:staff'),
            builder: (_) => const StaffManagementPage(),
          ),
        );
        break;
      case 'reports':
        final siteId = _shellController.selectedSiteId;
        final siteName = _shellController.selectedSiteName;
        if (siteId == null || siteName == null) {
          _openPropertySelection();
          return;
        }
        _shellController.selectSection('reports');
        navigator.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'app:reports'),
            builder: (_) => MonthlyReportsPage(
              siteId: siteId,
              siteName: siteName,
              shellController: _shellController,
            ),
          ),
        );
        break;
    }
  }

  /// Reuse the same destination widgets as the report-section tiles below.
  Widget _selectedReportDestination(
    Map<String, dynamic> report,
    String? section,
  ) {
    switch (section) {
      case 'site_profile':
        return SiteProfilePage(
          siteId: report['site_id']?.toString() ?? '',
          reportMonth: DateTime.tryParse(
            report['report_month']?.toString() ?? '',
          ),
        );
      case 'finance':
        return FinancePage(report: report);
      case 'operations':
        return OperationsPage(report: report);
      case 'occupancy':
        return OccupancyUnitPage(report: report);
      case 'contracts':
        return ContractsCompliancePage(report: report);
      case 'archived_records':
        return ArchivedRecordsPage(report: report);
      case 'export_pdf':
        return ExportPdfPage(report: report);
      default:
        return ReportDetailsPage(report: report);
    }
  }

  Future<void> _openSelectedPeriod(DateTime date) async {
    if (!_shellController.authorized) return;
    final siteId = _shellController.selectedSiteId;
    final targetSection = _shellController.selectedReportSection;
    if (siteId == null) {
      _openPropertySelection();
      return;
    }

    final monthValue =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-01';
    _shellController.selectPeriod(date);

    try {
      final existing = await Supabase.instance.client
          .from('monthly_reports')
          .select('id, site_id, report_month, status, created_at')
          .eq('site_id', siteId)
          .eq('report_month', monthValue)
          .maybeSingle();

      if (!mounted ||
          !_shellController.authorized ||
          _shellController.selectedSiteId != siteId) {
        return;
      }
      if (existing == null) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('No monthly report exists for the selected period.'),
          ),
        );
        return;
      }

      _shellController.selectSection('reports');
      _navigatorKey.currentState?.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'app:report-details'),
          builder: (_) => _selectedReportDestination(
            Map<String, dynamic>.from(existing),
            targetSection,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not open the report: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Property Monthly Report System',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      scaffoldMessengerKey: _messengerKey,
      // AppShell must be BELOW MaterialApp's Navigator/Overlay, otherwise its
      // sidebar controls (Tooltip, DropdownButton) throw "No Overlay widget
      // found". An inner Navigator keeps the sidebar on every report page.
      home: AppShell(
        controller: _shellController,
        onNavigate: _navigateFromSidebar,
        onOpenPeriod: _openSelectedPeriod,
        child: HeroControllerScope(
          controller: _reportsHeroController,
          child: Navigator(
            key: _navigatorKey,
            observers: <NavigatorObserver>[_routeObserver],
            onGenerateRoute: (settings) {
              if (settings.name == Navigator.defaultRouteName) {
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => AuthGate(
                    onSiteOpened: _openSite,
                    shellController: _shellController,
                  ),
                );
              }
              return null;
            },
          ),
        ),
      ),
    );
  }
}

class MonthlyReportsPage extends StatefulWidget {
  final String siteId;
  final String siteName;
  final AppShellController? shellController;

  const MonthlyReportsPage({
    super.key,
    required this.siteId,
    required this.siteName,
    this.shellController,
  });

  @override
  State<MonthlyReportsPage> createState() => _MonthlyReportsPageState();
}

class _MonthlyReportsPageState extends State<MonthlyReportsPage> {
  final _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _reports = [];
  bool _loading = true;
  bool _creating = false;
  String? _error;

  // UI-only filters for the Monthly Reports history.
  final TextEditingController _searchController = TextEditingController();
  String _selectedYear = 'all';
  String _selectedStatus = 'all';
  int _visibleReportCount = 9;

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadReports() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _supabase
          .from('monthly_reports')
          .select('id, site_id, report_month, status, created_at')
          .eq('site_id', widget.siteId)
          .order('report_month', ascending: false);

      if (!mounted) return;

      setState(() {
        _reports = List<Map<String, dynamic>>.from(result);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Copies occupancy components from the most recent earlier report
  /// for this property that actually contains occupancy records.
  ///
  /// Skips earlier reports with no occupancy components. Each copied row
  /// belongs to the new report and can be edited independently.
  Future<int> _copyPreviousOccupancy({
    required String newReportId,
    required String siteId,
    required String monthValue,
  }) async {
    final previousReports = await _supabase
        .from('monthly_reports')
        .select('id, report_month')
        .eq('site_id', siteId)
        .lt('report_month', monthValue)
        .order('report_month', ascending: false);

    // Search backwards until a report containing occupancy records is found.
    for (final previousReport in previousReports) {
      final previousReportId = previousReport['id'].toString();

      final previousRecords = await _supabase
          .from('occupancy_records')
          .select(
            'line_no, tower_component, vacant, owner_occupied, '
            'tenant_occupied, total_units',
          )
          .eq('report_id', previousReportId)
          .order('line_no', ascending: true);

      if (previousRecords.isEmpty) {
        continue;
      }

      final nowUtc = DateTime.now().toUtc().toIso8601String();

      final newRecords = previousRecords.map((record) {
        return <String, dynamic>{
          'report_id': newReportId,
          'line_no': record['line_no'],
          'tower_component': record['tower_component'],
          'vacant': record['vacant'],
          'owner_occupied': record['owner_occupied'],
          'tenant_occupied': record['tenant_occupied'],
          'total_units': record['total_units'],
          'updated_at': nowUtc,
        };
      }).toList();

      await _supabase.from('occupancy_records').insert(newRecords);

      return newRecords.length;
    }

    // No earlier report contains occupancy components.
    return 0;
  }

  Future<void> _createReport() async {
    final now = DateTime.now();

    final selectedDate = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, now.month, 1),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035, 12, 31),
      helpText: 'Select reporting month',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.red,
              onPrimary: AppColors.white,
              surface: AppColors.white,
              onSurface: AppColors.black,
            ),
          ),
          child: child!,
        );
      },
    );

    if (selectedDate == null || !mounted) return;

    final month = DateTime(selectedDate.year, selectedDate.month, 1);

    final monthValue =
        '${month.year.toString().padLeft(4, '0')}-'
        '${month.month.toString().padLeft(2, '0')}-01';

    setState(() => _creating = true);

    try {
      final result = await _supabase
          .from('monthly_reports')
          .insert({
            'site_id': widget.siteId,
            'report_month': monthValue,
            'status': 'draft',
          })
          .select('id, site_id, report_month, status, created_at')
          .single();

      if (!mounted) return;

      final report = Map<String, dynamic>.from(result);

      int copiedOccupancyCount = 0;
      String? occupancyCopyError;

      try {
        copiedOccupancyCount = await _copyPreviousOccupancy(
          newReportId: report['id'].toString(),
          siteId: widget.siteId,
          monthValue: monthValue,
        );
      } catch (e) {
        // The monthly report already exists. Keep it if copying fails,
        // and notify the user that occupancy carry-forward was unsuccessful.
        occupancyCopyError = e.toString();
      }

      if (!mounted) return;

      await _loadReports();

      if (!mounted) return;

      final message = occupancyCopyError != null
          ? '${_formatMonth(monthValue)} report created, but '
                'occupancy carry-forward failed: $occupancyCopyError'
          : '${_formatMonth(monthValue)} report created.'
                '${copiedOccupancyCount > 0 ? ' '
                          '$copiedOccupancyCount occupancy component(s) '
                          'carried forward.' : ''}';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.charcoal,
          duration: const Duration(seconds: 5),
        ),
      );

      _openReport(report);
    } on PostgrestException catch (e) {
      if (!mounted) return;

      if (e.code == '23505') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'A ${_formatMonth(monthValue)} report already exists '
              'for ${widget.siteName}.',
            ),
            backgroundColor: AppColors.charcoal,
          ),
        );
      } else {
        _showError(e.message);
      }
    } catch (e) {
      if (!mounted) return;
      _showError(e.toString());
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  void _openReport(Map<String, dynamic> report) {
    final reportMonth = report['report_month']?.toString();
    if (reportMonth != null) {
      final parsed = DateTime.tryParse(reportMonth);
      if (parsed != null) widget.shellController?.selectPeriod(parsed);
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReportDetailsPage(report: report)),
    );
  }

  Future<void> _updateReportStatus(
    Map<String, dynamic> report,
    String newStatus,
  ) async {
    try {
      final updated = await _supabase
          .from('monthly_reports')
          .update({'status': newStatus})
          .eq('id', report['id'])
          .eq('site_id', widget.siteId)
          .select('id, status')
          .maybeSingle();

      if (!mounted) return;

      if (updated == null) {
        _showError(
          'Could not update the report status. '
          'Please check your database permissions.',
        );
        return;
      }

      setState(() {
        final index = _reports.indexWhere((item) => item['id'] == report['id']);

        if (index != -1) {
          _reports[index] = {..._reports[index], 'status': updated['status']};
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Report marked as '
            '${newStatus == 'completed' ? 'Completed' : 'Draft'}.',
          ),
          backgroundColor: AppColors.charcoal,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showError(e.toString());
    }
  }

  Future<void> _deleteReport(Map<String, dynamic> report) async {
    final status = report['status'] as String? ?? 'draft';
    final month = _formatMonth(report['report_month'] as String);

    // Only Draft reports can be deleted.
    if (status != 'draft') {
      _showError('Only Draft reports can be deleted.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete report?'),
        content: Text(
          'Are you sure you want to permanently delete the $month report '
          'for ${widget.siteName}?\n\n'
          'All information saved under this report, including finance, '
          'operations, occupancy, and compliance records, will also be '
          'permanently deleted.\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.redDark),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final deleted = await _supabase
          .from('monthly_reports')
          .delete()
          .eq('id', report['id'])
          .eq('site_id', widget.siteId)
          .eq('status', 'draft')
          .select('id');

      if (!mounted) return;

      if (deleted.isEmpty) {
        _showError(
          'The report was not deleted. It may no longer be a Draft, '
          'or you may not have permission to delete it.',
        );
        return;
      }

      await _loadReports();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$month report deleted.'),
          backgroundColor: AppColors.charcoal,
        ),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;

      _showError('Could not delete the report. ${e.message}');
    } catch (e) {
      if (!mounted) return;
      _showError(e.toString());
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Something went wrong: $message'),
        backgroundColor: AppColors.redDark,
      ),
    );
  }

  static String _formatMonth(String value) {
    final date = DateTime.parse(value);

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

    return '${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final draftCount = _reports
        .where((report) => report['status'] == 'draft')
        .length;
    final completedCount = _reports
        .where((report) => report['status'] == 'completed')
        .length;

    final narrow = MediaQuery.sizeOf(context).width < 600;

    final header = <Widget>[
      _buildHero(narrow: narrow),
      const SizedBox(height: 24),
      LayoutBuilder(
        builder: (context, constraints) {
          const gap = 14.0;
          final columns = constraints.maxWidth >= 850
              ? 3
              : constraints.maxWidth >= 550
                  ? 2
                  : 1;
          final cardWidth =
              (constraints.maxWidth - gap * (columns - 1)) / columns;

          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                width: cardWidth,
                child: _SummaryCard(
                  label: 'TOTAL REPORTS',
                  value: '${_reports.length}',
                  icon: Icons.description_outlined,
                  accent: AppColors.red,
                  compact: narrow,
                ),
              ),
              SizedBox(
                width: cardWidth,
                child: _SummaryCard(
                  label: 'DRAFT REPORTS',
                  value: '$draftCount',
                  icon: Icons.edit_note_outlined,
                  accent: AppColors.black,
                  compact: narrow,
                ),
              ),
              SizedBox(
                width: cardWidth,
                child: _SummaryCard(
                  label: 'COMPLETED REPORTS',
                  value: '$completedCount',
                  icon: Icons.check_circle_outline,
                  accent: const Color(0xFF16A34A),
                  compact: narrow,
                ),
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 28),
      Row(
        children: [
          Expanded(
            child: Text(
              'Report history',
              style: TextStyle(
                fontSize: narrow ? 20 : 22,
                fontWeight: FontWeight.bold,
                color: AppColors.black,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: _creating ? null : _createReport,
            icon: const Icon(Icons.add, size: 20),
            label: Text(_creating ? 'Creating...' : 'New report'),
          ),
        ],
      ),
      const SizedBox(height: 16),
    ];

    return Scaffold(
      appBar: AppCommonAppBar(
        title: 'Monthly Reports',
        onRefresh: _loadReports,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: ListView(
            padding: EdgeInsets.all(narrow ? 16 : 24),
            children: [...header, _buildReportList()],
          ),
        ),
      ),
    );
  }

  Widget _buildHero({bool narrow = false}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(narrow ? 18 : 24),
      decoration: BoxDecoration(
        color: AppColors.charcoal,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.red, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            height: 5,
            decoration: BoxDecoration(
              color: AppColors.red,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'MONTHLY REPORTS',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.siteName,
            style: TextStyle(
              color: AppColors.white,
              fontSize: narrow ? 24 : 28,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Manage monthly property reporting, financial records '
            'and operations.',
            style: TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportList() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.red),
      );
    }

    if (_error != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.red),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.red, size: 44),
              const SizedBox(height: 12),
              const Text(
                'Could not load monthly reports.',
                style: TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                style: const TextStyle(color: AppColors.grey),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadReports,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_reports.isEmpty) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: AppColors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.folder_open_outlined,
                    size: 40,
                    color: AppColors.red,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'No reports yet',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.black,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Create a monthly report to get started.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.grey),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _creating ? null : _createReport,
                  icon: const Icon(Icons.add),
                  label: const Text('Create first report'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final years = _reports
        .map((report) => DateTime.parse(report['report_month'] as String).year)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    final selectedYear = _selectedYear == 'all' ||
            years.any((year) => year.toString() == _selectedYear)
        ? _selectedYear
        : 'all';
    final searchText = _searchController.text.trim().toLowerCase();
    final filteredReports = _reports.where((report) {
      final month = _formatMonth(report['report_month'] as String);
      final year = DateTime.parse(report['report_month'] as String).year;
      final status = report['status']?.toString() ?? 'draft';
      return (searchText.isEmpty || month.toLowerCase().contains(searchText)) &&
          (selectedYear == 'all' || year.toString() == selectedYear) &&
          (_selectedStatus == 'all' || status == _selectedStatus);
    }).toList();
    final visibleReports = filteredReports.take(_visibleReportCount).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildReportFilters(years, selectedYear),
          const SizedBox(height: 16),
          if (filteredReports.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.white,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'No reports match your filters.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.grey),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1000
                    ? 3
                    : constraints.maxWidth >= 600
                        ? 2
                        : 1;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: visibleReports.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: 172,
                  ),
                  itemBuilder: (context, index) =>
                      _buildReportCard(visibleReports[index]),
                );
              },
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Showing ${visibleReports.length} of '
                  '${filteredReports.length} reports',
                  style: const TextStyle(fontSize: 12, color: AppColors.grey),
                ),
              ),
              if (_visibleReportCount < filteredReports.length)
                TextButton.icon(
                  onPressed: () => setState(() => _visibleReportCount += 9),
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  label: const Text('Show more'),
                )
              else if (_visibleReportCount > 9 && filteredReports.length > 9)
                TextButton.icon(
                  onPressed: () => setState(() => _visibleReportCount = 9),
                  icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                  label: const Text('Show less'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReportFilters(List<int> years, String selectedYear) {
    final search = SizedBox(
      height: 44,
      child: TextField(
        controller: _searchController,
        onChanged: (_) => setState(() => _visibleReportCount = 9),
        style: const TextStyle(fontSize: 13, color: AppColors.black),
        decoration: InputDecoration(
          hintText: 'Search month or year...',
          hintStyle: const TextStyle(color: AppColors.grey, fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.grey),
          filled: true,
          fillColor: AppColors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.red),
          ),
        ),
      ),
    );

    final yearDropdown = _buildFilterDropdown(
      value: selectedYear,
      items: [
        const DropdownMenuItem(value: 'all', child: Text('All Years')),
        for (final year in years)
          DropdownMenuItem(value: '$year', child: Text('$year')),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _selectedYear = value;
          _visibleReportCount = 9;
        });
      },
    );

    final statusDropdown = _buildFilterDropdown(
      value: _selectedStatus,
      items: const [
        DropdownMenuItem(value: 'all', child: Text('All Status')),
        DropdownMenuItem(value: 'draft', child: Text('Draft')),
        DropdownMenuItem(value: 'completed', child: Text('Completed')),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _selectedStatus = value;
          _visibleReportCount = 9;
        });
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 570) {
          return Column(
            children: [
              search,
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: yearDropdown),
                  const SizedBox(width: 10),
                  Expanded(child: statusDropdown),
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: search),
            const SizedBox(width: 10),
            SizedBox(width: 135, child: yearDropdown),
            const SizedBox(width: 10),
            SizedBox(width: 150, child: statusDropdown),
          ],
        );
      },
    );
  }

  Widget _buildFilterDropdown({
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          icon: const Icon(Icons.keyboard_arrow_down, size: 18),
          style: const TextStyle(fontSize: 13, color: AppColors.black),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildReportCard(Map<String, dynamic> report) {
    final status = report['status'] as String? ?? 'draft';
    final selectedStatus = status == 'completed' ? 'completed' : 'draft';
    final completed = selectedStatus == 'completed';
    final monthLabel = _formatMonth(report['report_month'] as String);

    Widget statusLabel(String label, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        );

    final statusDropdown = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9FA),
        borderRadius: BorderRadius.circular(9),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selectedStatus,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          icon: const Icon(Icons.keyboard_arrow_down, size: 17),
          selectedItemBuilder: (context) => [
            statusLabel('Draft', AppColors.grey),
            statusLabel('Completed', const Color(0xFF16A34A)),
          ],
          items: [
            DropdownMenuItem(
              value: 'draft',
              child: statusLabel('Draft', AppColors.grey),
            ),
            DropdownMenuItem(
              value: 'completed',
              child: statusLabel('Completed', const Color(0xFF16A34A)),
            ),
          ],
          onChanged: (newStatus) {
            if (newStatus == null || newStatus == status) return;
            _updateReportStatus(report, newStatus);
          },
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openReport(report),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.red.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.calendar_month_outlined,
                        color: AppColors.red,
                        size: 23,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        monthLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.black,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Report Status',
                        style: TextStyle(fontSize: 12, color: AppColors.grey),
                      ),
                    ),
                    statusDropdown,
                  ],
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!completed)
                      IconButton(
                        tooltip: 'Delete draft report',
                        onPressed: () => _deleteReport(report),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: AppColors.redDark,
                          size: 21,
                        ),
                      ),
                    const Icon(Icons.chevron_right, color: AppColors.grey),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color accent;
  final bool compact;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 18),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 36 : 44,
            height: compact ? 36 : 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent),
          ),
          SizedBox(width: compact ? 10 : 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.bold,
                    color: AppColors.grey,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: compact ? 22 : 25,
                    fontWeight: FontWeight.w800,
                    color: AppColors.black,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ReportDetailsPage extends StatelessWidget {
  final Map<String, dynamic> report;

  const ReportDetailsPage({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final date = DateTime.parse(report['report_month'] as String);

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

    final monthName = '${months[date.month - 1]} ${date.year}';

    final narrow = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      appBar: AppCommonAppBar(
        title: 'Report Details',
        onRefresh: () async {
          try {
            final updated = await Supabase.instance.client
                .from('monthly_reports')
                .select('id, site_id, report_month, status, created_at')
                .eq('id', report['id'])
                .maybeSingle();
            if (!context.mounted) return;
            if (updated == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('This report is no longer available.')),
              );
              return;
            }
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'app:report-details'),
                builder: (_) => ReportDetailsPage(
                  report: Map<String, dynamic>.from(updated),
                ),
              ),
            );
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not refresh report: $e')),
            );
          }
        },
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: ListView(
            padding: EdgeInsets.all(narrow ? 16 : 24),
            children: [
              Container(
                padding: EdgeInsets.all(narrow ? 18 : 24),
                decoration: BoxDecoration(
                  color: AppColors.charcoal,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.red, width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'MONTHLY REPORT',
                      style: TextStyle(
                        color: AppColors.red,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.4,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      monthName,
                      style: TextStyle(
                        fontSize: narrow ? 26 : 32,
                        fontWeight: FontWeight.w800,
                        color: AppColors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Report ID: ${report['id']}',
                      style: const TextStyle(color: Color(0xFFE0E0E0)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: EdgeInsets.all(narrow ? 14 : 22),
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Report sections',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose a section to enter this month’s property '
                      'report information.',
                      style: TextStyle(color: AppColors.grey, height: 1.5),
                    ),
                    const SizedBox(height: 20),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columnCount = constraints.maxWidth >= 1050
                            ? 3
                            : constraints.maxWidth >= 600
                                ? 2
                                : 1;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GridView.count(
                          crossAxisCount: columnCount,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          mainAxisExtent: columnCount == 3 ? 198 : 218,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            _ReportSectionTile(
                              icon: Icons.business_outlined,
                              title: 'Site Profile',
                              subtitle:
                                  'Property details, billing rates and '
                                  'management committee',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => SiteProfilePage(
                                      siteId: report['site_id']?.toString() ?? '',
                                      reportMonth: DateTime.tryParse(
                                        report['report_month']?.toString() ?? '',
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            _ReportSectionTile(
                              icon: Icons.account_balance_outlined,
                              title: 'Finance',
                              subtitle:
                                  'Billing, arrears, transfers, deposits, '
                                  'expenditure and utilities',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => FinancePage(report: report),
                                  ),
                                );
                              },
                            ),
                            _ReportSectionTile(
                              icon: Icons.handyman_outlined,
                              title: 'Operations',
                              subtitle:
                                  'Maintenance, complaints, resolutions, '
                                  'lift incidents and assets',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => OperationsPage(report: report),
                                  ),
                                );
                              },
                            ),
                            _ReportSectionTile(
                              icon: Icons.apartment_outlined,
                              title: 'Occupancy & Unit Management',
                              subtitle:
                                  'Occupancy overview, unit movements and renovation works',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => OccupancyUnitPage(report: report),
                                  ),
                                );
                              },
                            ),
                            _ReportSectionTile(
                              icon: Icons.verified_user_outlined,
                              title: 'Contracts & Compliance',
                              subtitle:
                                  'Service providers, licences, compliance and insurance records',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ContractsCompliancePage(report: report),
                                  ),
                                );
                              },
                            ),
                                _ReportSectionTile(
                                  icon: Icons.archive_outlined,
                                  title: 'Archived Records',
                                  subtitle:
                                      'View and manage archived records across all modules.',
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ArchivedRecordsPage(report: report),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),

                            const SizedBox(height: 14),

                            // Full-width Export PDF card.
                            Material(
                              color: AppColors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: AppColors.border),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                leading: Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: AppColors.red.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.picture_as_pdf_outlined,
                                    color: AppColors.red,
                                    size: 27,
                                  ),
                                ),
                                title: const Text(
                                  'Export PDF',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: AppColors.black,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Check report completion, preview and export this month’s report',
                                  style: TextStyle(
                                    color: AppColors.grey,
                                    height: 1.4,
                                  ),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right,
                                  color: AppColors.red,
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ExportPdfPage(report: report),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportSectionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ReportSectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.red.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: AppColors.red, size: 27),
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right, color: AppColors.red),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: AppColors.black,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.grey,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}