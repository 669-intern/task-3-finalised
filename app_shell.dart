import 'package:flutter/material.dart';

import '../widgets/styles.dart';
import 'app_sidebar.dart';

/// Shares only navigation state. Existing pages retain their own AppBars,
/// Scaffolds, data loading, editing and PDF export logic.
class AppShellController extends ChangeNotifier {
  bool _authorized = false;
  String? _role;
  String _currentSection = 'dashboard';
  String? _selectedSiteId;
  String? _selectedSiteName;
  String? _selectedReportSection;
  DateTime _selectedPeriod = DateTime(DateTime.now().year, DateTime.now().month);

  bool get authorized => _authorized;
  bool get isAdmin => _role == 'admin';
  String get currentSection => _currentSection;
  String? get selectedSiteId => _selectedSiteId;
  String? get selectedSiteName => _selectedSiteName;
  String? get selectedReportSection => _selectedReportSection;
  DateTime get selectedPeriod => _selectedPeriod;

  void activate(String role) {
    if (_authorized && _role == role) return;
    _authorized = true;
    _role = role;
    _currentSection = 'dashboard';
    notifyListeners();
  }

  void deactivate() {
    if (!_authorized &&
        _role == null &&
        _selectedSiteId == null &&
        _selectedReportSection == null) {
      return;
    }
    _authorized = false;
    _role = null;
    _currentSection = 'dashboard';
    _selectedSiteId = null;
    _selectedSiteName = null;
    _selectedReportSection = null;
    notifyListeners();
  }

  void selectSection(String section) {
    if (_currentSection == section) return;
    _currentSection = section;
    notifyListeners();
  }

  /// Saves the dropdown selection without changing the current page.
  void rememberSite({required String id, required String name}) {
    if (_selectedSiteId == id && _selectedSiteName == name) return;
    _selectedSiteId = id;
    _selectedSiteName = name;
    notifyListeners();
  }

  void selectSite({required String id, required String name}) {
    _selectedSiteId = id;
    _selectedSiteName = name;
    _currentSection = 'reports';
    notifyListeners();
  }

  void selectReportSection(String? section) {
    if (_selectedReportSection == section) return;
    _selectedReportSection = section;
    notifyListeners();
  }

  void selectPeriod(DateTime date) {
    final value = DateTime(date.year, date.month, 1);
    if (_selectedPeriod.year == value.year &&
        _selectedPeriod.month == value.month) {
      return;
    }
    _selectedPeriod = value;
    notifyListeners();
  }
}

/// Tracks high-level navigation so the sidebar selection follows Back buttons.
/// Unknown routes are the existing reporting subpages and retain their parent
/// section (usually Monthly Reports).
class AppShellRouteObserver extends NavigatorObserver {
  AppShellRouteObserver(this.controller);

  final AppShellController controller;

  void _syncRoute(Route<dynamic>? route) {
    if (route == null) return;
    if (route.isFirst) {
    controller.selectSection('dashboard');
      return;
    }
    switch (route.settings.name) {
      case 'app:properties':
        controller.selectSection('properties');
        break;
      case 'app:staff':
        controller.selectSection('staff');
        break;
      case 'app:reports':
      case 'app:report-details':
        controller.selectSection('reports');
        break;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _syncRoute(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _syncRoute(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _syncRoute(newRoute);
  }
}

/// Places a fixed side menu alongside the application's Navigator.
/// A thin black area at the top of the sidebar extends the existing AppBar
/// background, so every page keeps exactly its current AppBar (no duplication).
///
/// Because the Navigator is a single child, routes pushed by existing modules
/// also keep the sidebar without changing those modules.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.controller,
    required this.onNavigate,
    required this.onOpenPeriod,
  });

  final Widget child;
  final AppShellController controller;
  final ValueChanged<String> onNavigate;
  final ValueChanged<DateTime> onOpenPeriod;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _expanded = true;
  bool _mobileMenuOpen = false;

  void _handleNavigation(String destination) {
    if (_mobileMenuOpen) {
      setState(() => _mobileMenuOpen = false);
    }
    widget.controller.selectSection(destination);
    widget.onNavigate(destination);
  }

  void _openPeriod(DateTime selected) {
    if (_mobileMenuOpen) {
      setState(() => _mobileMenuOpen = false);
    }
    widget.onOpenPeriod(selected);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        // Keep the Navigator in the same widget subtree before and after
        // sign-in, so authentication does not reset its route stack.
        return LayoutBuilder(
          builder: (context, constraints) {
            final authenticated = widget.controller.authorized;
            final desktop = authenticated && constraints.maxWidth >= 900;
            final sidebarWidth = desktop ? (_expanded ? 236.0 : 64.0) : 0.0;

            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.only(left: sidebarWidth),
                    child: widget.child,
                  ),
                ),
                if (desktop)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: sidebarWidth,
                    child: Column(
                      children: <Widget>[
                        _topBarExtension(
                          expanded: _expanded,
                          onPressed: () => setState(
                            () => _expanded = !_expanded,
                          ),
                        ),
                        Expanded(
                          child: AppSidebar(
                            controller: widget.controller,
                            expanded: _expanded,
                            onExpand: () => setState(() => _expanded = true),
                            onNavigate: _handleNavigation,
                            onOpenPeriod: _openPeriod,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (authenticated && !desktop) ...<Widget>[
                  if (_mobileMenuOpen)
                    Positioned.fill(
                      child: Material(
                        color: Colors.black45,
                        child: InkWell(
                          onTap: () => setState(() => _mobileMenuOpen = false),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  if (_mobileMenuOpen)
                    Positioned(
                      left: 0,
                      top: kToolbarHeight + 3,
                      bottom: 0,
                      width: constraints.maxWidth < 310
                          ? constraints.maxWidth * 0.88
                          : 284,
                      child: Material(
                        elevation: 14,
                        child: AppSidebar(
                          controller: widget.controller,
                          expanded: true,
                          onExpand: () {},
                          onNavigate: _handleNavigation,
                          onOpenPeriod: _openPeriod,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 12,
                    top: kToolbarHeight + 12,
                    child: Material(
                      color: AppColors.black,
                      elevation: 3,
                      borderRadius: BorderRadius.circular(9),
                      child: IconButton(
                        icon: Icon(
                          _mobileMenuOpen ? Icons.close : Icons.menu,
                          color: Colors.white,
                        ),
                        tooltip: _mobileMenuOpen ? 'Close menu' : 'Open menu',
                        onPressed: () => setState(
                          () => _mobileMenuOpen = !_mobileMenuOpen,
                        ),
                      ),
                    ),
                  ),
                ],
                // Draw one continuous 3 px red line over both the sidebar
                // header extension and each page's existing AppBar divider.
                if (desktop)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: kToolbarHeight,
                    height: 3,
                    child: const IgnorePointer(
                      child: ColoredBox(color: AppColors.red),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// The actual page AppBar remains in the existing Scaffold on the right.
  /// Only the menu button occupies the left header area, so the brand name
  /// is not rendered twice and the black/red header runs edge to edge.
  Widget _topBarExtension({
    required bool expanded,
    required VoidCallback onPressed,
  }) {
    return Container(
      height: kToolbarHeight + 3,
      decoration: const BoxDecoration(
        color: AppColors.black,
        border: Border(
          bottom: BorderSide(color: AppColors.red, width: 3),
        ),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 8),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(
          expanded ? Icons.menu_open_rounded : Icons.menu_rounded,
          color: Colors.white,
        ),
        tooltip: expanded ? 'Collapse sidebar' : 'Expand sidebar',
      ),
    );
  }
}
