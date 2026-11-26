import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'styles.dart';
import '../property_sites_service.dart';
import 'app_shell.dart';

/// Shared menu shown alongside every authenticated page.
/// Monthly Reports opens the overview; Report Sections reveals the selectors.
class AppSidebar extends StatefulWidget {
  const AppSidebar({
    super.key,
    required this.controller,
    required this.expanded,
    required this.onExpand,
    required this.onNavigate,
    required this.onOpenPeriod,
  });

  final AppShellController controller;
  final bool expanded;
  final VoidCallback onExpand;
  final ValueChanged<String> onNavigate;
  final ValueChanged<DateTime> onOpenPeriod;

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> {
  bool _reportSectionsExpanded = false;
  Future<AuthenticatedSiteList>? _sitesFuture;

  // Cache available reporting years for the selected property.
  String? _yearsSiteId;
  Future<List<int>>? _yearsFuture;

  Future<List<int>> _loadAvailableYears(String siteId) async {
    final rows = await Supabase.instance.client
        .from('monthly_reports')
        .select('report_month')
        .eq('site_id', siteId);

    final years = rows
        .map(
          (row) => DateTime.tryParse(
            row['report_month']?.toString() ?? '',
          )?.year,
        )
        .whereType<int>()
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    return years;
  }

  Future<List<int>>? _yearsForSelectedSite() {
    final siteId = widget.controller.selectedSiteId;

    if (siteId == null) {
      _yearsSiteId = null;
      _yearsFuture = null;
      return null;
    }

    if (_yearsSiteId != siteId || _yearsFuture == null) {
      _yearsSiteId = siteId;
      _yearsFuture = _loadAvailableYears(siteId);
    }

    return _yearsFuture;
  }

  static const List<String> _monthNames = <String>[
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

  void _toggleReportSections() {
    setState(() {
      _reportSectionsExpanded = !_reportSectionsExpanded;
      if (_reportSectionsExpanded && _sitesFuture == null) {
        _sitesFuture = PropertySitesService.listSitesAuthenticated();
      }
      if (_reportSectionsExpanded) {
        // Refresh the available-year list whenever the menu is reopened.
        _yearsSiteId = null;
        _yearsFuture = null;
      }
    });
    // An icon-only sidebar must expand before it can display dropdowns.
    if (_reportSectionsExpanded && !widget.expanded) {
      widget.onExpand();
    }
  }

  void _retrySites() {
    setState(() {
      _sitesFuture = PropertySitesService.listSitesAuthenticated();
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.controller.currentSection;

    return Material(
      color: Colors.white,
      child: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: widget.expanded ? 12 : 7,
                vertical: 17,
              ),
              children: <Widget>[
                if (widget.expanded)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(11, 0, 8, 12),
                    child: Text(
                      'MAIN MENU',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.3,
                        fontWeight: FontWeight.w800,
                        color: AppColors.grey,
                      ),
                    ),
                  ),
                _menuItem(
                  icon: Icons.space_dashboard_outlined,
                  title: 'Dashboard',
                  active: active == 'dashboard',
                  onTap: () => widget.onNavigate('dashboard'),
                ),
                _menuItem(
                  icon: Icons.apartment_outlined,
                  title: 'Properties',
                  active: active == 'properties',
                  onTap: () => widget.onNavigate('properties'),
                ),
                if (widget.controller.isAdmin)
                  _menuItem(
                    icon: Icons.groups_outlined,
                    title: 'Staff Management',
                    active: active == 'staff',
                    onTap: () => widget.onNavigate('staff'),
                  ),
                _menuItem(
                  icon: Icons.description_outlined,
                  title: 'Monthly Reports',
                  active: active == 'reports',
                  onTap: () => widget.onNavigate('reports'),
                ),
                _menuItem(
                  icon: Icons.list_alt_outlined,
                  title: 'Report Sections',
                  active: false,
                  expanded: _reportSectionsExpanded,
                  onTap: _toggleReportSections,
                ),
                if (widget.expanded && _reportSectionsExpanded) ...<Widget>[
                  const SizedBox(height: 5),
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6F7F9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Text(
                          'PROPERTY',
                          style: TextStyle(
                            color: AppColors.grey,
                            fontSize: 10,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildPropertyPicker(),
                        const SizedBox(height: 16),
                        const Text(
                          'REPORT SECTIONS',
                          style: TextStyle(
                            color: AppColors.grey,
                            fontSize: 10,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildReportSectionPicker(),
                        const SizedBox(height: 16),
                        const Text(
                          'MONTH / YEAR',
                          style: TextStyle(
                            color: AppColors.grey,
                            fontSize: 10,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildPeriodPicker(),
                        const SizedBox(height: 10),
                        _buildOpenButton(),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.expanded)
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'PROPERTY REPORTING SYSTEM',
                  style: TextStyle(
                    color: AppColors.grey,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPropertyPicker() {
    if (_sitesFuture == null) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<AuthenticatedSiteList>(
      future: _sitesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: SizedBox(
                height: 19,
                width: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.red,
                ),
              ),
            ),
          );
        }

        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Unable to load properties.',
                style: TextStyle(color: AppColors.red, fontSize: 12),
              ),
              TextButton.icon(
                onPressed: _retrySites,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try again'),
              ),
            ],
          );
        }

        final sites = snapshot.data?.sites ?? <Map<String, dynamic>>[];
        if (sites.isEmpty) {
          return const Text(
            'No properties assigned.',
            style: TextStyle(color: AppColors.grey, fontSize: 12),
          );
        }

        // The authenticated service filters the list according to the
        // backend-verified user role and property assignments.
        final selectedId = widget.controller.selectedSiteId;
        final selectedIsAvailable = sites.any(
          (site) => site['id']?.toString() == selectedId,
        );

        return _dropdown<String>(
          selected: selectedIsAvailable ? selectedId : null,
          hint: 'Select property',
          entries: sites.map((site) {
            final id = site['id'].toString();
            final name = site['site_name']?.toString() ?? 'Unnamed property';
            return DropdownMenuItem<String>(
              value: id,
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            );
          }).toList(),
          onChanged: (id) {
            if (id == null) return;
            for (final site in sites) {
              if (site['id']?.toString() == id) {
                widget.controller.rememberSite(
                  id: id,
                  name: site['site_name']?.toString() ?? 'Unnamed property',
                );
                return;
              }
            }
          },
        );
      },
    );
  }

  Widget _buildReportSectionPicker() {
    return _dropdown<String>(
      selected: widget.controller.selectedReportSection,
      hint: 'Select report section',
      entries: const <DropdownMenuItem<String>>[
        DropdownMenuItem(value: 'site_profile', child: Text('Site Profile')),
        DropdownMenuItem(value: 'finance', child: Text('Finance')),
        DropdownMenuItem(value: 'operations', child: Text('Operations')),
        DropdownMenuItem(
          value: 'occupancy',
          child: Text(
            'Occupancy & Unit Management',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        DropdownMenuItem(
          value: 'contracts',
          child: Text(
            'Contracts & Compliance',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        DropdownMenuItem(value: 'archived_records', child: Text('Archived Records')
        ),
        DropdownMenuItem(value: 'export_pdf', child: Text('Export PDF')
        ),
      ],
      onChanged: widget.controller.selectReportSection,
    );
  }

  Widget _buildOpenButton() {
    // Only allow opening a property the authenticated user can access,
    // and only after its selected year is confirmed as available.
    final yearsFuture = _yearsForSelectedSite();

    return FutureBuilder<AuthenticatedSiteList>(
      future: _sitesFuture,
      builder: (context, sitesSnapshot) {
        return FutureBuilder<List<int>>(
          future: yearsFuture,
          builder: (context, yearsSnapshot) {
            final selectedSiteId = widget.controller.selectedSiteId;
            final canOpen = sitesSnapshot.hasData &&
                selectedSiteId != null &&
                sitesSnapshot.data!.sites.any(
                  (site) => site['id']?.toString() == selectedSiteId,
                ) &&
                yearsSnapshot.hasData &&
                yearsSnapshot.data!.contains(
                  widget.controller.selectedPeriod.year,
                );

            return SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canOpen
                    ? () => widget.onOpenPeriod(widget.controller.selectedPeriod)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Open Report'),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPeriodPicker() {
    final date = widget.controller.selectedPeriod;
    final yearsFuture = _yearsForSelectedSite();
    return Row(
      children: <Widget>[
        Expanded(
          flex: 3,
          child: _dropdown<int>(
            selected: date.month,
            entries: List<DropdownMenuItem<int>>.generate(
              12,
              (index) => DropdownMenuItem<int>(
                value: index + 1,
                child: Text(
                  _monthNames[index],
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            onChanged: (value) {
              if (value != null) {
                widget.controller.selectPeriod(DateTime(date.year, value));
              }
            },
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 2,
          child: yearsFuture == null
              ? _dropdown<int>(
                  selected: null,
                  hint: 'Year',
                  entries: const <DropdownMenuItem<int>>[],
                  onChanged: (_) {},
                )
              : FutureBuilder<List<int>>(
                  future: yearsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }

                    if (snapshot.hasError) {
                      return const Text(
                        'Load error',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.red,
                        ),
                      );
                    }

                    final years = snapshot.data ?? <int>[];

                    return _dropdown<int>(
                      selected: years.contains(date.year) ? date.year : null,
                      hint: years.isEmpty ? 'No years' : 'Select year',
                      entries: years.map((year) {
                        return DropdownMenuItem<int>(
                          value: year,
                          child: Text('$year'),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          widget.controller.selectPeriod(
                            DateTime(value, date.month),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String title,
    required bool active,
    required VoidCallback onTap,
    bool? expanded,
  }) {
    final content = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: EdgeInsets.symmetric(
          horizontal: widget.expanded ? 11 : 10,
          vertical: 13,
        ),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFCE8EB) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: widget.expanded
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              icon,
              size: 21,
              color: active ? AppColors.red : const Color(0xFF666A73),
            ),
            if (widget.expanded) ...<Widget>[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? AppColors.red : AppColors.black,
                  ),
                ),
              ),
              if (expanded != null)
                Icon(
                  expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 18,
                  color: active ? AppColors.red : const Color(0xFF666A73),
                ),
            ],
          ],
        ),
      ),
    );
    return widget.expanded ? content : Tooltip(message: title, child: content);
  }

  Widget _dropdown<T>({
    required T? selected,
    required List<DropdownMenuItem<T>> entries,
    required ValueChanged<T?> onChanged,
    String? hint,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD7DADE)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: selected,
          hint: hint == null
              ? null
              : Text(
                  hint,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
          isExpanded: true,
          isDense: true,
          style: const TextStyle(
            color: AppColors.black,
            fontSize: 12,
          ),
          items: entries,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
