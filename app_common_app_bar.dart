import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'styles.dart';
import '../profile_page.dart';

/// Standard AppBar for the authenticated property-reporting pages.
///
/// Replace only a page's existing appBar with this widget; its Scaffold body,
/// data loading, and form actions remain unchanged. Each page supplies its
/// existing refresh callback, so Refresh continues to reload its own data.
class AppCommonAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppCommonAppBar({
    super.key,
    required this.title,
    required this.onRefresh,
    this.onProfile,
    this.profileImageUrl,
    this.extraActions = const <Widget>[],
  });

  final String title;
  final VoidCallback onRefresh;
  final VoidCallback? onProfile;
  final String? profileImageUrl;
  /// Existing page-specific toolbar actions, e.g. Save, can be retained here.
  final List<Widget> extraActions;

  static const double dividerHeight = 3;

  @override
  Size get preferredSize => const Size.fromHeight(
        kToolbarHeight + dividerHeight,
      );

  void _openProfilePage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfilePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: true,
      backgroundColor: AppColors.black,
      foregroundColor: AppColors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 20,
      title: Text(
        title,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      actions: <Widget>[
        ...extraActions,
        IconButton(
          tooltip: 'Profile',
          onPressed: onProfile ?? () => _openProfilePage(context),
          icon: profileImageUrl != null && profileImageUrl!.isNotEmpty
              ? CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.white,
                  backgroundImage: NetworkImage(profileImageUrl!),
                )
              : const Icon(Icons.account_circle_outlined),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: 'Log out',
          onPressed: () async {
            await Supabase.instance.client.auth.signOut();
          },
          icon: const Icon(Icons.logout_outlined),
        ),
        const SizedBox(width: 8),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(dividerHeight),
        child: SizedBox(
          height: dividerHeight,
          width: double.infinity,
          child: ColoredBox(color: AppColors.red),
        ),
      ),
    );
  }
}
