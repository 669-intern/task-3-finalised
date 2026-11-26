import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'widgets/styles.dart';
import 'profile_page.dart';
import 'widgets/app_common_app_bar.dart';

class StaffManagementPage extends StatefulWidget {
  const StaffManagementPage({super.key});

  @override
  State<StaffManagementPage> createState() => _StaffManagementPageState();
}

class _StaffManagementPageState extends State<StaffManagementPage> {
  final _supabase = Supabase.instance.client;

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _staffIdController = TextEditingController();
  final _designationController = TextEditingController();
  final _searchController = TextEditingController();

  String _searchQuery = '';
  String _inviteRole = 'staff';
  String _selectedRole = 'all';
  String _selectedStatus = 'all';
  String _selectedProperty = 'all';

  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _admins = [];
  List<Map<String, dynamic>> _sites = [];
  Map<String, Set<String>> _assignments = {};
  Map<String, Map<String, Map<String, bool>>> _sitePermissions = {};
  Map<String, String> _avatarUrls = {};

  bool _isSuperAdmin = false;
  bool _loading = true;

  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _staffIdController.dispose();
    _designationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final session = _supabase.auth.currentSession;

    if (session == null) {
      throw Exception('Your session has expired. Please sign in again.');
    }

    final response = await _supabase.functions.invoke(
      'staff-management',
      body: body,
      headers: {
        'Authorization': 'Bearer ${session.accessToken}',
        'apikey': 'sb_publishable_GyzVcvCNrR4Y0kS5_iCuww_Tdlc7vVM',
      },
    );

    final data = response.data;

    if (data is! Map) {
      throw Exception('The server returned an unexpected response.');
    }

    final result = Map<String, dynamic>.from(data);

    if (result['error'] != null) {
      throw Exception(result['error'].toString());
    }

    return result;
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final results = await Future.wait([
        _invoke({'action': 'list_staff'}),
        _invoke({'action': 'list_sites'}),
      ]);

      final accountResponse = results[0];
      final sitesResponse = results[1];

      final staff = (accountResponse['staff'] as List? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      final admins = (accountResponse['admins'] as List? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      final assignments = (accountResponse['assignments'] as List? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      final sites = (sitesResponse['sites'] as List? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      // Use the signed avatar URLs returned by the Edge Function.
      final avatarUrls = <String, String>{};
      final allAccounts = [...staff, ...admins];

      for (final member in allAccounts) {
        final userId = member['id']?.toString();
        final signedUrl = member['avatar_signed_url']?.toString().trim();

        if (userId != null &&
            userId.isNotEmpty &&
            signedUrl != null &&
            signedUrl.isNotEmpty) {
          avatarUrls[userId] = signedUrl;
        }
      }

      final assignmentMap = <String, Set<String>>{};
      final permissionsMap = <String, Map<String, Map<String, bool>>>{};

      for (final item in assignments) {
        final userId = item['user_id']?.toString();
        final siteId = item['site_id']?.toString();

        if (userId == null ||
            userId.isEmpty ||
            siteId == null ||
            siteId.isEmpty) {
          continue;
        }

        assignmentMap.putIfAbsent(userId, () => <String>{}).add(siteId);
        permissionsMap.putIfAbsent(
          userId,
          () => <String, Map<String, bool>>{},
        )[siteId] = {
          'can_view_site_profile': item['can_view_site_profile'] == true,
          'can_add_site_profile': item['can_add_site_profile'] == true,
          'can_edit_site_profile': item['can_edit_site_profile'] == true,
          'can_delete_site_profile': item['can_delete_site_profile'] == true,
        };
      }

      if (!mounted) return;

      setState(() {
        _staff = staff;
        _admins = admins;
        _sites = sites;
        _assignments = assignmentMap;
        _sitePermissions = permissionsMap;
        _avatarUrls = avatarUrls;
        if (_selectedProperty != 'all' &&
            !_sites.any(
              (site) => site['id']?.toString() == _selectedProperty,
            )) {
          _selectedProperty = 'all';
        }
        _isSuperAdmin = accountResponse['is_super_admin'] == true;

        if (!_isSuperAdmin) {
          _inviteRole = 'staff';
        }

        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not load account management data: $e';
        _loading = false;
      });
    }
  }

  Future<void> _inviteUser({required Set<String> propertyIds}) async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim().toLowerCase();

    if (name.isEmpty || email.isEmpty) {
      setState(() {
        _error = 'Full name and email address are required.';
        _success = null;
      });
      return;
    }

    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() {
        _error = 'Enter a valid email address.';
        _success = null;
      });
      return;
    }

    final role = _isSuperAdmin ? _inviteRole : 'staff';

    setState(() {
      _error = null;
      _success = null;
    });

    try {
      final invitation = await _invoke({
        'action': 'invite_staff',
        'role': role,
        'full_name': name,
        'email': email,
        'phone': _phoneController.text.trim(),
        'staff_id': _staffIdController.text.trim(),
        'designation': role == 'staff'
            ? _designationController.text.trim()
            : '',
      });

      final invitedUserId = invitation['user_id']?.toString() ?? '';
      String? assignmentWarning;
      if (role == 'staff' && propertyIds.isNotEmpty) {
        if (invitedUserId.isEmpty) {
          assignmentWarning =
              'The invitation was sent, but the server did '
              'not return a user ID. Set properties in Edit Details.';
        } else {
          try {
            await _invoke({
              'action': 'update_assignments',
              'user_id': invitedUserId,
              'site_ids': propertyIds.toList(),
            });
          } catch (e) {
            assignmentWarning =
                'The invitation was sent, but property '
                'assignments could not be saved: $e. '
                'Set them in Edit Details.';
          }
        }
      }

      _nameController.clear();
      _emailController.clear();
      _phoneController.clear();
      _staffIdController.clear();
      _designationController.clear();

      if (!mounted) return;
      await _loadData();
      if (!mounted) return;

      setState(() {
        _success =
            'Invitation sent to $email. The invited '
            '${role == 'admin' ? 'Admin' : 'Staff member'} must open '
            'the email link and set a password.';
        _error = assignmentWarning;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not send invitation: $e';
        _success = null;
      });
    }
  }

  // ------------------------------------------------------------
  // RETRACT INVITATION OR DELETE ACCOUNT
  // ------------------------------------------------------------
  Future<void> _removeAccount(
    Map<String, dynamic> member, {
    required bool isAdminAccount,
    required bool retractInvitation,
  }) async {
    final userId = member['id']?.toString();

    if (userId == null || userId.isEmpty) return;

    // Only the Super Admin can manage Admin accounts.
    if (isAdminAccount && !_isSuperAdmin) {
      setState(() {
        _error = 'Only the Super Admin can manage Admin accounts.';
        _success = null;
      });
      return;
    }

    final name = member['full_name']?.toString().trim();
    final email = member['email']?.toString().trim();
    final accountName = name == null || name.isEmpty ? 'this account' : name;

    if (retractInvitation &&
        member['account_status']?.toString() != 'invited') {
      setState(() {
        _error = 'Only invited accounts can have their invitation retracted.';
        _success = null;
      });
      return;
    }

    if (!retractInvitation && !_isSuperAdmin) {
      setState(() {
        _error = 'Only the Super Admin can delete accounts.';
        _success = null;
      });
      return;
    }

    final title = retractInvitation ? 'Retract Invitation?' : 'Delete Account?';

    final message = retractInvitation
        ? 'Retract the invitation for $accountName${email == null || email.isEmpty ? '' : ' ($email)'}?\n\n'
              'The invited account will be removed and will no longer be able to use this invitation.'
        : 'Permanently delete $accountName${email == null || email.isEmpty ? '' : ' ($email)'}?\n\n'
              'This removes the account and its property assignments. '
              'Other staff assignments and historical business records will be preserved.\n\n'
              'This action cannot be undone.';

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          retractInvitation
              ? Icons.mail_outline
              : Icons.delete_forever_outlined,
          color: AppColors.red,
          size: 32,
        ),
        title: Text(title),
        content: SizedBox(width: 420, child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              retractInvitation ? 'Retract Invitation' : 'Delete Account',
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _error = null;
      _success = null;
    });

    try {
      await _invoke({
        'action': retractInvitation ? 'retract_invitation' : 'delete_account',
        'user_id': userId,
      });

      if (!mounted) return;

      setState(() {
        _success = retractInvitation
            ? 'Invitation for $accountName retracted successfully.'
            : 'Account for $accountName deleted successfully.';
        _error = null;
      });

      await _loadData();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = retractInvitation
            ? 'Could not retract invitation: $e'
            : 'Could not delete account: $e';
        _success = null;
      });
    }
  }

  Future<void> _transferSuperAdmin(Map<String, dynamic> member) async {
    final userId = member['id']?.toString();

    if (userId == null || userId.isEmpty || !_isSuperAdmin) {
      return;
    }

    final name = member['full_name']?.toString().trim();
    final email = member['email']?.toString().trim();

    final recipient = name == null || name.isEmpty
        ? (email == null || email.isEmpty ? 'this account' : email)
        : name;

    bool transferring = false;
    bool promotedToAdmin = false;
    String? dialogError;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              icon: const Icon(
                Icons.admin_panel_settings_outlined,
                color: AppColors.red,
                size: 36,
              ),
              title: const Text('Transfer Super Admin?'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'WARNING: You are about to transfer '
                        'Super Admin authority to another person.',
                        style: TextStyle(
                          color: AppColors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Recipient: $recipient'
                        '${email == null || email.isEmpty ? '' : '\nEmail: $email'}',
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'After the transfer, the recipient will become '
                        'the Super Admin and will be able to manage other '
                        'Admin accounts, including inviting Admins, '
                        'editing or disabling accounts, and deleting '
                        'accounts where permitted.',
                      ),
                      const SizedBox(height: 12),
                      if (member['role'] == 'staff') ...[
                        const Text(
                          'This Staff account will first be promoted to Admin. '
                          'Existing Staff property assignments will be removed.',
                        ),
                        const SizedBox(height: 12),
                      ],
                      const Text(
                        'Your account will lose Super Admin authority. '
                        'You will not be able to transfer it again unless '
                        'you are subsequently appointed Super Admin.',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Only proceed if you trust this person with '
                        'these responsibilities. This action changes '
                        'account privileges immediately.',
                        style: TextStyle(fontWeight: FontWeight.w600),
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
              actions: [
                TextButton(
                  onPressed: transferring
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: transferring
                      ? null
                      : () async {
                          setDialogState(() {
                            transferring = true;
                            dialogError = null;
                          });

                          try {
                            if (member['role'] == 'staff' && !promotedToAdmin) {
                              await _invoke({
                                'action': 'promote_to_admin',
                                'user_id': userId,
                              });
                              promotedToAdmin = true;
                            }
                            await _invoke({
                              'action': 'transfer_super_admin',
                              'user_id': userId,
                            });

                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext, true);
                            }
                          } catch (e) {
                            setDialogState(() {
                              transferring = false;
                              dialogError =
                                  'Transfer failed: $e. If promotion was '
                                  'successful, the account may already be an '
                                  'Admin; check the directory before retrying.';
                            });
                          }
                        },
                  child: transferring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Confirm Transfer'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) return;

    await _loadData();
    if (!mounted) return;
    setState(() {
      _success = 'Super Admin authority transferred to $recipient.';
      _error = null;
    });
  }

  Map<String, bool> _defaultSiteProfilePermissions() => {
    'can_view_site_profile': true,
    'can_add_site_profile': false,
    'can_edit_site_profile': false,
    'can_delete_site_profile': false,
  };

  Map<String, bool> _permissionsForSite(String userId, String siteId) {
    return Map<String, bool>.from(
      _sitePermissions[userId]?[siteId] ?? _defaultSiteProfilePermissions(),
    );
  }

  String _propertyName(String siteId) {
    for (final site in _sites) {
      if (site['id']?.toString() == siteId) {
        return site['site_name']?.toString() ?? 'Unnamed property';
      }
    }
    return 'Property unavailable';
  }

  String _assignedPropertiesLabel(_StaffDirectoryEntry entry) {
    if (entry.isAdminAccount) return 'All properties';
    final userId = entry.member['id']?.toString() ?? '';
    final siteIds = _assignments[userId] ?? <String>{};
    if (siteIds.isEmpty) return 'Not assigned';
    final names = siteIds.map(_propertyName).toList()..sort();
    return names.join(', ');
  }

  void _applyRoleSummaryFilter(String role) {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _selectedRole = role;
      _selectedProperty = 'all';
      _selectedStatus = 'all';
    });
  }

  Future<void> _editAccountDetails(
    Map<String, dynamic> member, {
    required bool isAdminAccount,
  }) async {
    final userId = member['id']?.toString();
    if (userId == null || userId.isEmpty) return;

    // Existing Admin and Super Admin restrictions are unchanged.
    if (isAdminAccount && !_isSuperAdmin) {
      setState(() {
        _error = 'Only the Super Admin can edit Admin accounts.';
        _success = null;
      });
      return;
    }

    final nameController = TextEditingController(
      text: member['full_name']?.toString() ?? '',
    );
    final emailController = TextEditingController(
      text: member['email']?.toString() ?? '',
    );
    final phoneController = TextEditingController(
      text: member['phone']?.toString() ?? '',
    );
    final staffIdController = TextEditingController(
      text: member['staff_id']?.toString() ?? '',
    );
    final designationController = TextEditingController(
      text: member['designation']?.toString() ?? '',
    );

    final formKey = GlobalKey<FormState>();
    final originalRole = isAdminAccount ? 'admin' : 'staff';
    String selectedAccountRole = originalRole;
    bool saving = false;
    bool assignmentRemovedOnServer = false;
    String? dialogError;
    String? dialogNotice;

    // Work with local copies until Save Changes is pressed. Existing
    // assignments are never recreated merely to edit their permissions.
    final originalSiteIds = Set<String>.from(
      _assignments[userId] ?? <String>{},
    );
    final selectedSiteIds = Set<String>.from(originalSiteIds);
    final sitePermissions = <String, Map<String, bool>>{
      for (final siteId in originalSiteIds)
        siteId: _permissionsForSite(userId, siteId),
    };
    final savedPermissions = <String, Map<String, bool>>{
      for (final siteId in originalSiteIds)
        siteId: _permissionsForSite(userId, siteId),
    };

    try {
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> deleteAssignment(String siteId) async {
              final name = _propertyName(siteId);
              final confirmed = await showDialog<bool>(
                context: dialogContext,
                builder: (confirmContext) => AlertDialog(
                  title: const Text('Delete Property Assignment?'),
                  content: Text(
                    'Remove ${member['full_name'] ?? 'this staff member'} '
                    'from $name?\n\n'
                    'The staff member will immediately lose access to this '
                    'property. The staff account and property records will '
                    'not be deleted.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(confirmContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => Navigator.pop(confirmContext, true),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete Assignment'),
                    ),
                  ],
                ),
              );
              if (confirmed != true || !dialogContext.mounted) return;

              // An assignment added locally has not been saved yet, so
              // removing it only removes the unsaved selection.
              if (!originalSiteIds.contains(siteId)) {
                setDialogState(() {
                  selectedSiteIds.remove(siteId);
                  sitePermissions.remove(siteId);
                  dialogNotice = 'Unsaved property selection removed.';
                  dialogError = null;
                });
                return;
              }

              setDialogState(() {
                saving = true;
                dialogError = null;
                dialogNotice = null;
              });
              try {
                // Unlike Save Changes, this action revokes access now.
                await _invoke({
                  'action': 'remove_assignment',
                  'user_id': userId,
                  'site_id': siteId,
                });
                originalSiteIds.remove(siteId);
                selectedSiteIds.remove(siteId);
                savedPermissions.remove(siteId);
                sitePermissions.remove(siteId);
                assignmentRemovedOnServer = true;
                if (mounted) {
                  setState(() {
                    _assignments[userId]?.remove(siteId);
                    _sitePermissions[userId]?.remove(siteId);
                  });
                }
                if (dialogContext.mounted) {
                  setDialogState(() {
                    saving = false;
                    dialogNotice = '$name removed. Property access revoked.';
                  });
                }
              } catch (e) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  saving = false;
                  dialogError = 'Could not remove $name: $e';
                });
              }
            }

            Widget staffDetailsCard() {
              return Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.badge_outlined, color: AppColors.red),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            isAdminAccount ? 'Admin Details' : 'Staff Details',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              color: AppColors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: staffIdController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: 'Staff ID',
                        prefixIcon: Icon(Icons.badge_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_isSuperAdmin) ...[
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        key: ValueKey('edit-role-$selectedAccountRole'),
                        initialValue: selectedAccountRole,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Role *',
                          prefixIcon: Icon(Icons.manage_accounts_outlined),
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'staff',
                            child: Text('Staff'),
                          ),
                          DropdownMenuItem(
                            value: 'admin',
                            child: Text('Admin'),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (role) {
                                if (role != null) {
                                  setDialogState(
                                    () => selectedAccountRole = role,
                                  );
                                }
                              },
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: nameController,
                      enabled: !saving,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Full name *',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Full name is required.'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: emailController,
                      enabled: !saving,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email address *',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final email = value?.trim().toLowerCase() ?? '';
                        if (email.isEmpty) return 'Email address is required.';
                        return RegExp(
                              r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                            ).hasMatch(email)
                            ? null
                            : 'Enter a valid email address.';
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: phoneController,
                      enabled: !saving,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        prefixIcon: Icon(Icons.phone_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (!isAdminAccount) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: designationController,
                        enabled: !saving,
                        decoration: const InputDecoration(
                          labelText: 'Designation',
                          prefixIcon: Icon(Icons.work_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }

            Widget assignedPropertiesCard() {
              final orderedIds = selectedSiteIds.toList()
                ..sort((a, b) => _propertyName(a).compareTo(_propertyName(b)));
              return Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.apartment_outlined,
                          color: AppColors.red,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Assigned Properties',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              color: AppColors.black,
                            ),
                          ),
                        ),
                        Text(
                          '${orderedIds.length}',
                          style: const TextStyle(color: AppColors.grey),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (orderedIds.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'No properties assigned.',
                          style: TextStyle(color: AppColors.grey),
                        ),
                      ),
                    ...orderedIds.map((siteId) {
                      final permissions = sitePermissions.putIfAbsent(
                        siteId,
                        _defaultSiteProfilePermissions,
                      );
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F8F9),
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.business_outlined,
                                  color: AppColors.grey,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _propertyName(siteId),
                                    style: const TextStyle(
                                      color: AppColors.black,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Site Profile Access',
                              style: TextStyle(
                                color: AppColors.grey,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 16,
                              runSpacing: 0,
                              children: [
                                for (final permission in const [
                                  ('can_view_site_profile', 'View'),
                                  ('can_add_site_profile', 'Add'),
                                  ('can_edit_site_profile', 'Edit'),
                                  ('can_delete_site_profile', 'Delete'),
                                ])
                                  SizedBox(
                                    width: 120,
                                    child: CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      visualDensity: VisualDensity.compact,
                                      dense: true,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      title: Text(
                                        permission.$2,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                      value: permissions[permission.$1] == true,
                                      onChanged: saving
                                          ? null
                                          : (checked) {
                                              setDialogState(() {
                                                final enabled = checked == true;
                                                permissions[permission.$1] =
                                                    enabled;
                                                if (permission.$1 ==
                                                        'can_view_site_profile' &&
                                                    !enabled) {
                                                  permissions['can_add_site_profile'] =
                                                      false;
                                                  permissions['can_edit_site_profile'] =
                                                      false;
                                                  permissions['can_delete_site_profile'] =
                                                      false;
                                                } else if (enabled) {
                                                  permissions['can_view_site_profile'] =
                                                      true;
                                                }
                                                dialogError = null;
                                              });
                                            },
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.red,
                                ),
                                onPressed: saving
                                    ? null
                                    : () => deleteAssignment(siteId),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 19,
                                ),
                                label: const Text('Delete Assignment'),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              final added = await _pickAdditionalProperties(
                                dialogContext,
                                selectedSiteIds,
                              );
                              if (added == null || !dialogContext.mounted) {
                                return;
                              }
                              setDialogState(() {
                                for (final siteId in added) {
                                  selectedSiteIds.add(siteId);
                                  sitePermissions.putIfAbsent(
                                    siteId,
                                    _defaultSiteProfilePermissions,
                                  );
                                }
                                dialogNotice =
                                    'New properties will be assigned when you save.';
                                dialogError = null;
                              });
                            },
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Add Property'),
                    ),
                  ],
                ),
              );
            }

            Future<void> saveChanges() async {
              if (formKey.currentState?.validate() != true) return;
              setDialogState(() {
                saving = true;
                dialogError = null;
                dialogNotice = null;
              });

              bool detailsSaved = false;
              bool permissionsOrAssignmentsSaved = false;
              try {
                if (!isAdminAccount && selectedAccountRole == 'staff') {
                  final assignmentsChanged =
                      originalSiteIds.length != selectedSiteIds.length ||
                      !originalSiteIds.containsAll(selectedSiteIds);

                  if (assignmentsChanged) {
                    // The Edge Function uses an atomic sync RPC. Unchanged
                    // assignment rows retain their permission settings.
                    await _invoke({
                      'action': 'update_assignments',
                      'user_id': userId,
                      'site_ids': selectedSiteIds.toList(),
                    });
                    permissionsOrAssignmentsSaved = true;
                    originalSiteIds
                      ..clear()
                      ..addAll(selectedSiteIds);
                    if (mounted) {
                      setState(() {
                        _assignments[userId] = Set<String>.from(
                          selectedSiteIds,
                        );
                      });
                    }
                  }

                  for (final siteId in selectedSiteIds) {
                    final next =
                        sitePermissions[siteId] ??
                        _defaultSiteProfilePermissions();
                    final previous = savedPermissions[siteId];
                    final changed =
                        previous == null ||
                        next.keys.any((key) => next[key] != previous[key]);
                    if (!changed) continue;
                    await _invoke({
                      'action': 'update_site_profile_permissions',
                      'user_id': userId,
                      'site_id': siteId,
                      ...next,
                    });
                    permissionsOrAssignmentsSaved = true;
                    savedPermissions[siteId] = Map<String, bool>.from(next);
                    if (mounted) {
                      setState(() {
                        _sitePermissions.putIfAbsent(
                          userId,
                          () => <String, Map<String, bool>>{},
                        )[siteId] = Map<String, bool>.from(
                          next,
                        );
                      });
                    }
                  }
                }

                // The existing staff/admin details and role actions are
                // preserved, including the Super Admin-only role control.
                await _invoke({
                  'action': 'update_details',
                  'user_id': userId,
                  'full_name': nameController.text.trim(),
                  'email': emailController.text.trim().toLowerCase(),
                  'phone': phoneController.text.trim(),
                  'staff_id': staffIdController.text.trim(),
                  'designation': isAdminAccount
                      ? ''
                      : designationController.text.trim(),
                });
                detailsSaved = true;

                if (_isSuperAdmin && selectedAccountRole != originalRole) {
                  await _invoke({
                    'action': selectedAccountRole == 'admin'
                        ? 'promote_to_admin'
                        : 'demote_to_staff',
                    'user_id': userId,
                  });
                }

                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, true);
                }
              } catch (e) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  saving = false;
                  dialogError = detailsSaved
                      ? 'Account details were saved, but the role update '
                            'failed: $e'
                      : permissionsOrAssignmentsSaved
                      ? 'Some property changes were saved, but the '
                            'remaining changes failed: $e. Please check '
                            'the assignments before retrying.'
                      : 'Could not save changes: $e';
                });
              }
            }

            final dialogWidth = MediaQuery.sizeOf(dialogContext).width;
            final compact = dialogWidth < 800;
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 920,
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.88,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 18, 16, 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              isAdminAccount
                                  ? 'Edit Admin Details'
                                  : 'Edit Staff Details',
                              style: const TextStyle(
                                color: AppColors.black,
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: saving
                                ? null
                                : () => Navigator.pop(dialogContext, false),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(18),
                        child: Form(
                          key: formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!isAdminAccount &&
                                  selectedAccountRole == 'staff')
                                compact
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          staffDetailsCard(),
                                          const SizedBox(height: 14),
                                          assignedPropertiesCard(),
                                        ],
                                      )
                                    : Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(child: staffDetailsCard()),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: assignedPropertiesCard(),
                                          ),
                                        ],
                                      )
                              else
                                staffDetailsCard(),
                              if (dialogNotice != null) ...[
                                const SizedBox(height: 14),
                                Text(
                                  dialogNotice!,
                                  style: TextStyle(
                                    color: Colors.green.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                              if (dialogError != null) ...[
                                const SizedBox(height: 14),
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
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_isSuperAdmin &&
                              member['is_super_admin'] != true &&
                              member['account_status'] == 'active')
                            TextButton.icon(
                              onPressed: saving
                                  ? null
                                  : () {
                                      Navigator.pop(dialogContext, false);
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (mounted) {
                                              _transferSuperAdmin(member);
                                            }
                                          });
                                    },
                              icon: const Icon(
                                Icons.admin_panel_settings_outlined,
                              ),
                              label: const Text('Transfer Super Admin'),
                            ),
                          TextButton(
                            onPressed: saving
                                ? null
                                : () => Navigator.pop(dialogContext, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton.icon(
                            onPressed: saving ? null : saveChanges,
                            style: FilledButton.styleFrom(
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
                                : const Icon(Icons.save_outlined),
                            label: Text(saving ? 'Saving...' : 'Save Changes'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );

      if ((saved == true || assignmentRemovedOnServer) && mounted) {
        await _loadData();
        if (!mounted) return;
        if (saved == true) {
          setState(() {
            _success = selectedAccountRole != originalRole
                ? 'Account details and role updated.'
                : isAdminAccount
                ? 'Admin details updated successfully.'
                : 'Staff details and property access updated.';
            _error = null;
          });
        } else {
          setState(() {
            _success = 'Property assignment removed successfully.';
            _error = null;
          });
        }
      }
    } finally {
      nameController.dispose();
      emailController.dispose();
      phoneController.dispose();
      staffIdController.dispose();
      designationController.dispose();
    }
  }

  Future<void> _changeStatus(
    Map<String, dynamic> member,
    String status, {
    required bool isAdminAccount,
  }) async {
    final userId = member['id']?.toString();

    if (userId == null || userId.isEmpty) return;

    // Prevent regular Admins from changing another Admin's status.
    if (isAdminAccount && !_isSuperAdmin) {
      setState(() {
        _error = 'Only the Super Admin can change Admin account status.';
        _success = null;
      });
      return;
    }

    try {
      await _invoke({
        'action': 'update_status',
        'user_id': userId,
        'account_status': status,
      });

      if (!mounted) return;

      setState(() {
        final accountType = isAdminAccount ? 'Admin' : 'Staff';
        final name = member['full_name'] ?? accountType;

        _success = '$name account status updated.';
        _error = null;
      });

      await _loadData();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not update account status: $e';
        _success = null;
      });
    }
  }

  List<Map<String, dynamic>> _filterAccounts(
    List<Map<String, dynamic>> accounts,
  ) {
    return accounts.where((member) {
      final userId = member['id']?.toString() ?? '';
      final assignedNames = (_assignments[userId] ?? <String>{})
          .map(_propertyName)
          .join(' ');
      final fields = [
        member['full_name'],
        member['email'],
        member['staff_id'],
        member['phone'],
        member['designation'],
        member['account_status'],
        assignedNames,
      ];

      return fields.any(
        (field) =>
            (field ?? '').toString().toLowerCase().contains(_searchQuery),
      );
    }).toList();
  }

  Future<Set<String>?> _pickInviteProperties(
    BuildContext parentContext,
    Set<String> initiallySelected,
  ) async {
    final selected = Set<String>.from(initiallySelected);
    return showDialog<Set<String>>(
      context: parentContext,
      builder: (pickContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Property Assigned'),
          content: SizedBox(
            width: 440,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final site in _sites)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        site['site_name']?.toString() ?? 'Unnamed property',
                      ),
                      value: selected.contains(site['id']?.toString()),
                      onChanged: (checked) {
                        final id = site['id']?.toString();
                        if (id == null) return;
                        update(() {
                          if (checked == true) {
                            selected.add(id);
                          } else {
                            selected.remove(id);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(pickContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(pickContext, selected),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  /// Adds only new assignments. Removing an existing assignment is a
  /// separate, explicitly confirmed action inside Edit Staff Details.
  Future<Set<String>?> _pickAdditionalProperties(
    BuildContext parentContext,
    Set<String> assignedSiteIds,
  ) async {
    final available = _sites.where((site) {
      final id = site['id']?.toString() ?? '';
      return id.isNotEmpty && !assignedSiteIds.contains(id);
    }).toList();
    final chosen = <String>{};

    return showDialog<Set<String>>(
      context: parentContext,
      builder: (pickContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Add Property'),
          content: SizedBox(
            width: 440,
            child: available.isEmpty
                ? const Text('All available properties are already assigned.')
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 350),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final site in available)
                          CheckboxListTile(
                            title: Text(
                              site['site_name']?.toString() ??
                                  'Unnamed property',
                            ),
                            value: chosen.contains(site['id']?.toString()),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (checked) {
                              final id = site['id']?.toString();
                              if (id == null) return;
                              update(() {
                                if (checked == true) {
                                  chosen.add(id);
                                } else {
                                  chosen.remove(id);
                                }
                              });
                            },
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(pickContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(pickContext, chosen),
              child: const Text('Add Selected'),
            ),
          ],
        ),
      ),
    );
  }

  // Regular Admins invite Staff; only Super Admins can select Admin.
  Future<void> _showInviteDialog() async {
    _inviteRole = 'staff';
    _staffIdController.clear();
    Set<String> selectedSiteIds = <String>{};
    bool sending = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(_isSuperAdmin ? 'Invite an Account' : 'Invite Staff'),
              content: SizedBox(
                width: 460,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _isSuperAdmin
                            ? 'Invite an Admin or Staff member. They will receive an email link to set their password.'
                            : 'Send an invitation email. Staff members set their own password using the email link.',
                        style: const TextStyle(
                          color: AppColors.grey,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        key: ValueKey('invite-$_inviteRole'),
                        initialValue: _isSuperAdmin ? _inviteRole : 'staff',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Account type *',
                          prefixIcon: Icon(Icons.manage_accounts_outlined),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: 'staff',
                            child: Text('Staff'),
                          ),
                          if (_isSuperAdmin)
                            const DropdownMenuItem(
                              value: 'admin',
                              child: Text('Admin'),
                            ),
                        ],
                        onChanged: sending || !_isSuperAdmin
                            ? null
                            : (value) {
                                if (value == null) return;
                                setDialogState(() {
                                  _inviteRole = value;
                                  selectedSiteIds.clear();
                                });
                              },
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap:
                            sending || _inviteRole != 'staff' || _sites.isEmpty
                            ? null
                            : () async {
                                final chosen = await _pickInviteProperties(
                                  dialogContext,
                                  selectedSiteIds,
                                );
                                if (chosen != null && dialogContext.mounted) {
                                  setDialogState(
                                    () => selectedSiteIds = chosen,
                                  );
                                }
                              },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Property Assigned',
                            prefixIcon: Icon(Icons.apartment_outlined),
                            suffixIcon: Icon(Icons.arrow_drop_down),
                            border: OutlineInputBorder(),
                          ),
                          child: Text(
                            _inviteRole != 'staff'
                                ? 'All properties (Admin access)'
                                : _sites.isEmpty
                                ? 'No properties available'
                                : selectedSiteIds.isEmpty
                                ? 'Select properties'
                                : (selectedSiteIds.map(_propertyName).toList()
                                        ..sort())
                                      .join(', '),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _inviteRole == 'staff'
                                  ? AppColors.black
                                  : AppColors.grey,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _staffIdController,
                        enabled: !sending,
                        decoration: const InputDecoration(
                          labelText: 'Staff ID',
                          prefixIcon: Icon(Icons.badge_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _input(
                        _nameController,
                        'Full name *',
                        Icons.person_outline,
                      ),
                      const SizedBox(height: 12),
                      _input(
                        _emailController,
                        'Email address *',
                        Icons.email_outlined,
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      _input(
                        _phoneController,
                        'Phone number',
                        Icons.phone_outlined,
                        keyboardType: TextInputType.phone,
                      ),
                      if (!_isSuperAdmin || _inviteRole == 'staff') ...[
                        const SizedBox(height: 12),
                        _input(
                          _designationController,
                          'Designation',
                          Icons.work_outline,
                        ),
                      ],
                      if (dialogError != null) ...[
                        const SizedBox(height: 16),
                        _message(dialogError!, isError: true),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: sending
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: sending
                      ? null
                      : () async {
                          setDialogState(() {
                            sending = true;
                            dialogError = null;
                          });
                          // Keep the original invitation method, including
                          // validation, permissions, and post-invite refresh.
                          await _inviteUser(propertyIds: selectedSiteIds);
                          if (!dialogContext.mounted) return;
                          if (_success != null) {
                            Navigator.pop(dialogContext);
                          } else {
                            setDialogState(() {
                              sending = false;
                              dialogError = _error ?? 'Invitation not sent.';
                            });
                          }
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.red,
                    foregroundColor: Colors.white,
                  ),
                  icon: sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.mail_outline),
                  label: Text(sending ? 'Sending...' : 'Send invitation'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAccountDetails(
    Map<String, dynamic> member, {
    required bool isAdminAccount,
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Account Details',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.black,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _accountCard(
                    member,
                    isAdminAccount: isAdminAccount,
                    // Close details before opening an existing account action.
                    onActionSelected: () => Navigator.pop(dialogContext),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _directorySummaryCard({
    required String label,
    required int value,
    required IconData icon,
    required Color color,
    required String roleFilter,
  }) {
    final selected = _selectedRole == roleFilter;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _applyRoleSummaryFilter(roleFilter),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.04) : Colors.white,
            border: Border.all(
              color: selected ? color : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$value',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontWeight: FontWeight.w800,
                        fontSize: 25,
                      ),
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

  Widget _directorySummaries(double width) {
    const gap = 12.0;
    final columns = width >= 680 ? 3 : (width >= 420 ? 2 : 1);
    final cardWidth = (width - gap * (columns - 1)) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        SizedBox(
          width: cardWidth,
          child: _directorySummaryCard(
            label: 'Total Accounts',
            value: _admins.length + _staff.length,
            icon: Icons.people_outline,
            color: AppColors.red,
            roleFilter: 'all',
          ),
        ),
        SizedBox(
          width: cardWidth,
          child: _directorySummaryCard(
            label: 'Staff',
            value: _staff.length,
            icon: Icons.person_outline,
            color: Colors.green.shade700,
            roleFilter: 'staff',
          ),
        ),
        SizedBox(
          width: cardWidth,
          child: _directorySummaryCard(
            label: 'Administrators',
            value: _admins.length,
            icon: Icons.admin_panel_settings_outlined,
            color: AppColors.red,
            roleFilter: 'admin',
          ),
        ),
      ],
    );
  }

  String _readableStatus(String value) {
    final words = value.replaceAll('_', ' ').trim().split(' ');
    return words
        .where((word) => word.isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  Widget _directoryFilters(double width, int visibleCount) {
    final statuses = <String>{'active', 'disabled', 'invited'};
    for (final member in [..._admins, ..._staff]) {
      final status = member['account_status']?.toString() ?? '';
      if (status.isNotEmpty) statuses.add(status);
    }
    if (_selectedStatus != 'all') statuses.add(_selectedStatus);
    final availableStatuses = statuses.toList()..sort();
    final sites = List<Map<String, dynamic>>.from(_sites)
      ..sort(
        (a, b) => (a['site_name']?.toString() ?? '').compareTo(
          b['site_name']?.toString() ?? '',
        ),
      );
    const gap = 12.0;
    final columns = width >= 740 ? 3 : (width >= 420 ? 2 : 1);
    final filterWidth = (width - 40 - gap * (columns - 1)) / columns;

    Widget filterField({
      required String title,
      required String value,
      required List<DropdownMenuItem<String>> items,
      required ValueChanged<String?> onChanged,
    }) {
      return SizedBox(
        width: filterWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: AppColors.grey,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              key: ValueKey('filter-$title-$value'),
              initialValue: value,
              isExpanded: true,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              items: items,
              onChanged: onChanged,
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F9),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            onChanged: (value) {
              setState(() => _searchQuery = value.trim().toLowerCase());
            },
            decoration: InputDecoration(
              hintText: 'Search name, email, staff ID or property',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                      icon: const Icon(Icons.clear),
                    ),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                vertical: 16,
                horizontal: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: gap,
            runSpacing: 12,
            children: [
              filterField(
                title: 'Role',
                value: _selectedRole,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All Roles')),
                  DropdownMenuItem(value: 'admin', child: Text('Admins')),
                  DropdownMenuItem(value: 'staff', child: Text('Staff')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _selectedRole = value);
                },
              ),
              filterField(
                title: 'Property',
                value: _selectedProperty,
                items: [
                  const DropdownMenuItem(
                    value: 'all',
                    child: Text('All Properties'),
                  ),
                  ...sites.map(
                    (site) => DropdownMenuItem(
                      value: site['id']?.toString(),
                      child: Text(
                        site['site_name']?.toString() ?? 'Unnamed property',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _selectedProperty = value);
                },
              ),
              filterField(
                title: 'Status',
                value: _selectedStatus,
                items: [
                  const DropdownMenuItem(
                    value: 'all',
                    child: Text('All Status'),
                  ),
                  ...availableStatuses.map(
                    (status) => DropdownMenuItem(
                      value: status,
                      child: Text(_readableStatus(status)),
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _selectedStatus = value);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Showing $visibleCount of ${_admins.length + _staff.length} accounts',
            style: const TextStyle(color: AppColors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Color _directoryStatusColor(String status) {
    switch (status) {
      case 'active':
        return Colors.green.shade700;
      case 'disabled':
        return Colors.red.shade700;
      case 'invited':
        return Colors.orange.shade800;
      default:
        return AppColors.grey;
    }
  }

  Widget _directoryAvatar(_StaffDirectoryEntry entry) {
    final id = entry.member['id']?.toString() ?? '';
    final signedUrl = _avatarUrls[id];
    return CircleAvatar(
      radius: 21,
      backgroundColor: const Color(0xFFFCE7E7),
      backgroundImage: signedUrl == null ? null : NetworkImage(signedUrl),
      child: signedUrl == null
          ? Icon(
              entry.isAdminAccount
                  ? Icons.admin_panel_settings_outlined
                  : Icons.person_outline,
              color: AppColors.red,
            )
          : null,
    );
  }

  Widget _directoryName(_StaffDirectoryEntry entry) {
    final name = entry.member['full_name']?.toString().trim();
    return Text(
      name == null || name.isEmpty ? 'Unnamed account' : name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontWeight: FontWeight.w700,
        color: AppColors.black,
        fontSize: 14,
      ),
    );
  }

  Widget _directoryTableHeader() {
    const headerStyle = TextStyle(
      color: AppColors.grey,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F6),
        border: Border(
          top: BorderSide(color: AppColors.border),
          left: BorderSide(color: AppColors.border),
          right: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 5, child: Text('NAME', style: headerStyle)),
          Expanded(flex: 2, child: Text('ROLE', style: headerStyle)),
          Expanded(flex: 5, child: Text('PROPERTY', style: headerStyle)),
          Expanded(flex: 2, child: Text('STATUS', style: headerStyle)),
        ],
      ),
    );
  }

  Widget _directoryDesktopRow(_StaffDirectoryEntry entry, bool isLast) {
    final status = entry.member['account_status']?.toString() ?? 'unknown';
    final properties = _assignedPropertiesLabel(entry);
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _showAccountDetails(
          entry.member,
          isAdminAccount: entry.isAdminAccount,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            border: const Border(
              left: BorderSide(color: AppColors.border),
              right: BorderSide(color: AppColors.border),
              bottom: BorderSide(color: AppColors.border),
            ),
            borderRadius: isLast
                ? const BorderRadius.vertical(bottom: Radius.circular(12))
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _directoryAvatar(entry),
                    const SizedBox(width: 12),
                    Expanded(child: _directoryName(entry)),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  entry.member['is_super_admin'] == true
                      ? 'Super Admin'
                      : (entry.isAdminAccount ? 'Admin' : 'Staff'),
                  style: const TextStyle(color: AppColors.black),
                ),
              ),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Tooltip(
                    message: properties,
                    child: Text(
                      properties,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: properties == 'Not assigned'
                            ? AppColors.grey
                            : AppColors.black,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _statusChip(status, _directoryStatusColor(status)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _directoryMobileCard(_StaffDirectoryEntry entry) {
    final status = entry.member['account_status']?.toString() ?? 'unknown';
    final properties = _assignedPropertiesLabel(entry);
    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showAccountDetails(
          entry.member,
          isAdminAccount: entry.isAdminAccount,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _directoryAvatar(entry),
                  const SizedBox(width: 12),
                  Expanded(child: _directoryName(entry)),
                  const Icon(Icons.chevron_right, color: AppColors.grey),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    entry.member['is_super_admin'] == true
                        ? 'Super Admin'
                        : (entry.isAdminAccount ? 'Admin' : 'Staff'),
                    style: const TextStyle(color: AppColors.grey),
                  ),
                  const SizedBox(width: 10),
                  _statusChip(status, _directoryStatusColor(status)),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Assigned Property',
                style: TextStyle(
                  color: AppColors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                properties,
                style: const TextStyle(color: AppColors.black, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredStaff = _filterAccounts(_staff);
    final filteredAdmins = _filterAccounts(_admins);
    final visibleEntries =
        <_StaffDirectoryEntry>[
          ...filteredAdmins.map(
            (member) =>
                _StaffDirectoryEntry(member: member, isAdminAccount: true),
          ),
          ...filteredStaff.map(
            (member) =>
                _StaffDirectoryEntry(member: member, isAdminAccount: false),
          ),
        ].where((entry) {
          final isAdmin = entry.isAdminAccount;
          if (_selectedRole == 'admin' && !isAdmin) return false;
          if (_selectedRole == 'staff' && isAdmin) return false;
          if (_selectedStatus != 'all' &&
              entry.member['account_status']?.toString() != _selectedStatus) {
            return false;
          }
          if (_selectedProperty != 'all' &&
              !isAdmin &&
              !(_assignments[entry.member['id']?.toString() ?? ''] ??
                      <String>{})
                  .contains(_selectedProperty)) {
            return false;
          }
          return true;
        }).toList();

    return Scaffold(
      appBar: AppCommonAppBar(
        title: _isSuperAdmin ? 'Account Management' : 'Staff Management',
        onRefresh: _loadData,
        onProfile: () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const ProfilePage()));
        },
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 760;
                    final inset = compact ? 16.0 : 24.0;
                    final contentWidth = constraints.maxWidth - 2 * inset;
                    return RefreshIndicator(
                      onRefresh: _loadData,
                      child: CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              inset,
                              24,
                              inset,
                              !compact && visibleEntries.isNotEmpty ? 0 : 16,
                            ),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (compact)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const Text(
                                          'Staff Management',
                                          style: TextStyle(
                                            fontSize: 25,
                                            fontWeight: FontWeight.w900,
                                            color: AppColors.black,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        const Text(
                                          'Manage administrators, staff and property access.',
                                          style: TextStyle(
                                            color: AppColors.grey,
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        FilledButton.icon(
                                          onPressed: _showInviteDialog,
                                          style: FilledButton.styleFrom(
                                            backgroundColor: AppColors.red,
                                            foregroundColor: Colors.white,
                                          ),
                                          icon: const Icon(
                                            Icons.person_add_alt_1_outlined,
                                          ),
                                          label: Text(
                                            _isSuperAdmin
                                                ? 'Invite Account'
                                                : 'Invite Staff',
                                          ),
                                        ),
                                      ],
                                    )
                                  else
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Staff Management',
                                                style: TextStyle(
                                                  fontSize: 26,
                                                  fontWeight: FontWeight.w900,
                                                  color: AppColors.black,
                                                ),
                                              ),
                                              SizedBox(height: 6),
                                              Text(
                                                'Manage administrators, staff and property access.',
                                                style: TextStyle(
                                                  color: AppColors.grey,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        FilledButton.icon(
                                          onPressed: _showInviteDialog,
                                          style: FilledButton.styleFrom(
                                            backgroundColor: AppColors.red,
                                            foregroundColor: Colors.white,
                                          ),
                                          icon: const Icon(
                                            Icons.person_add_alt_1_outlined,
                                          ),
                                          label: Text(
                                            _isSuperAdmin
                                                ? 'Invite Account'
                                                : 'Invite Staff',
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 22),
                                  _directorySummaries(contentWidth),
                                  if (_error != null) ...[
                                    const SizedBox(height: 16),
                                    _message(_error!, isError: true),
                                  ],
                                  if (_success != null) ...[
                                    const SizedBox(height: 16),
                                    _message(_success!, isError: false),
                                  ],
                                  const SizedBox(height: 24),
                                  _directoryFilters(
                                    contentWidth,
                                    visibleEntries.length,
                                  ),
                                  const SizedBox(height: 16),
                                  if (!compact && visibleEntries.isNotEmpty)
                                    _directoryTableHeader(),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: inset),
                            sliver: visibleEntries.isEmpty
                                ? SliverToBoxAdapter(
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(32),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: AppColors.border,
                                        ),
                                      ),
                                      child: const Column(
                                        children: [
                                          Icon(
                                            Icons.people_outline,
                                            size: 32,
                                            color: AppColors.grey,
                                          ),
                                          SizedBox(height: 10),
                                          Text(
                                            'No accounts found',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.black,
                                            ),
                                          ),
                                          SizedBox(height: 4),
                                          Text(
                                            'Try changing your search or filters.',
                                            style: TextStyle(
                                              color: AppColors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : SliverList.builder(
                                    itemCount: visibleEntries.length,
                                    itemBuilder: (context, index) {
                                      final entry = visibleEntries[index];
                                      return compact
                                          ? _directoryMobileCard(entry)
                                          : _directoryDesktopRow(
                                              entry,
                                              index ==
                                                  visibleEntries.length - 1,
                                            );
                                    },
                                  ),
                          ),
                          const SliverToBoxAdapter(child: SizedBox(height: 24)),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _input(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _message(String text, {required bool isError}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError
            ? Colors.red.withValues(alpha: 0.08)
            : Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError ? Colors.red.shade200 : Colors.green.shade200,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? Colors.red.shade800 : Colors.green.shade800,
        ),
      ),
    );
  }

  Widget _accountCard(
    Map<String, dynamic> member, {
    required bool isAdminAccount,
    VoidCallback? onActionSelected,
  }) {
    final id = member['id']?.toString() ?? '';
    final name = member['full_name']?.toString().trim();
    final email = member['email']?.toString().trim();
    final phone = member['phone']?.toString().trim();
    final staffId = member['staff_id']?.toString().trim();
    final designation = member['designation']?.toString().trim();
    final status = member['account_status']?.toString() ?? 'unknown';
    final isSuperAdminAccount = member['is_super_admin'] == true;

    final assignedSiteIds = _assignments[id] ?? <String>{};
    final assignedSites = _sites.where((site) {
      return assignedSiteIds.contains(site['id']?.toString());
    }).toList();

    String displayValue(String? value) {
      return value == null || value.isEmpty ? 'Not provided' : value;
    }

    Color statusColor() {
      switch (status) {
        case 'active':
          return Colors.green.shade700;
        case 'disabled':
          return Colors.red.shade700;
        case 'invited':
          return Colors.orange.shade800;
        default:
          return AppColors.grey;
      }
    }

    Widget detailRow(IconData icon, String label, String? value) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: AppColors.grey),
            const SizedBox(width: 10),
            SizedBox(
              width: 105,
              child: Text(
                label,
                style: const TextStyle(color: AppColors.grey, fontSize: 13),
              ),
            ),
            Expanded(
              child: SelectableText(
                displayValue(value),
                style: const TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: const Color(0xFFFCE7E7),
                  backgroundImage: _avatarUrls[id] != null
                      ? NetworkImage(_avatarUrls[id]!)
                      : null,
                  child: _avatarUrls[id] == null
                      ? Icon(
                          isAdminAccount
                              ? Icons.admin_panel_settings_outlined
                              : Icons.person_outline,
                          color: AppColors.red,
                          size: 26,
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayValue(name),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppColors.black,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        displayValue(email),
                        style: const TextStyle(color: AppColors.grey),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _statusChip(status, statusColor()),
                          if (isAdminAccount)
                            Chip(
                              label: Text(
                                isSuperAdminAccount ? 'SUPER ADMIN' : 'ADMIN',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // The Super Admin account is protected from ordinary
                // editing, disabling, and deletion actions.
                if (!isSuperAdminAccount && (!isAdminAccount || _isSuperAdmin))
                  PopupMenuButton<String>(
                    tooltip: 'Account actions',
                    onSelected: (value) {
                      onActionSelected?.call();
                      if (value == 'transfer_super_admin') {
                        _transferSuperAdmin(member);
                      } else if (value == 'details') {
                        _editAccountDetails(
                          member,
                          isAdminAccount: isAdminAccount,
                        );
                      } else if (value == 'retract_invitation') {
                        _removeAccount(
                          member,
                          isAdminAccount: isAdminAccount,
                          retractInvitation: true,
                        );
                      } else if (value == 'delete_account') {
                        _removeAccount(
                          member,
                          isAdminAccount: isAdminAccount,
                          retractInvitation: false,
                        );
                      } else {
                        _changeStatus(
                          member,
                          value,
                          isAdminAccount: isAdminAccount,
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      // Only the current Super Admin may transfer authority.
                      if (_isSuperAdmin &&
                          isAdminAccount &&
                          !isSuperAdminAccount &&
                          status == 'active')
                        const PopupMenuItem<String>(
                          value: 'transfer_super_admin',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.admin_panel_settings_outlined,
                              color: AppColors.red,
                            ),
                            title: Text(
                              'Transfer Super Admin',
                              style: TextStyle(color: AppColors.red),
                            ),
                          ),
                        ),

                      // Admin details: Super Admin only.
                      // Staff details: all Admins.
                      if (!isAdminAccount || _isSuperAdmin)
                        const PopupMenuItem<String>(
                          value: 'details',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.edit_outlined),
                            title: Text('Edit details'),
                          ),
                        ),

                      // Regular Admins can change Staff status only.
                      if ((!isAdminAccount || _isSuperAdmin) &&
                          status == 'active')
                        const PopupMenuItem<String>(
                          value: 'disabled',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.block_outlined),
                            title: Text('Disable account'),
                          ),
                        ),

                      if ((!isAdminAccount || _isSuperAdmin) &&
                          status == 'disabled')
                        const PopupMenuItem<String>(
                          value: 'active',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.check_circle_outline),
                            title: Text('Activate account'),
                          ),
                        ),

                      // Only the Super Admin can retract Admin invitations.
                      if (status == 'invited' &&
                          (!isAdminAccount || _isSuperAdmin))
                        const PopupMenuItem<String>(
                          value: 'retract_invitation',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.mail_outline,
                              color: Colors.orange,
                            ),
                            title: Text('Retract invitation'),
                          ),
                        ),

                      // Deleting accounts is restricted to the Super Admin.
                      if (_isSuperAdmin)
                        const PopupMenuItem<String>(
                          value: 'delete_account',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.delete_forever_outlined,
                              color: Colors.red,
                            ),
                            title: Text(
                              'Delete account',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            if (!isAdminAccount) ...[
              detailRow(Icons.badge_outlined, 'Staff ID', staffId),
              detailRow(Icons.phone_outlined, 'Phone', phone),
              detailRow(Icons.work_outline, 'Designation', designation),
              const SizedBox(height: 16),
              const Text(
                'Assigned Properties',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: AppColors.black,
                ),
              ),
              const SizedBox(height: 8),
              if (assignedSites.isEmpty)
                const Text(
                  'No properties assigned',
                  style: TextStyle(color: AppColors.grey),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: assignedSites.map((site) {
                    return Chip(
                      avatar: const Icon(Icons.apartment_outlined, size: 17),
                      label: Text(
                        site['site_name']?.toString() ?? 'Unnamed property',
                      ),
                      visualDensity: VisualDensity.compact,
                    );
                  }).toList(),
                ),
              const SizedBox(height: 8),
              Text(
                '${assignedSites.length} assigned '
                '${assignedSites.length == 1 ? 'property' : 'properties'}',
                style: const TextStyle(color: AppColors.grey, fontSize: 12),
              ),
            ] else ...[
              detailRow(Icons.phone_outlined, 'Phone', phone),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.replaceAll('_', ' ').toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _StaffDirectoryEntry {
  final Map<String, dynamic> member;
  final bool isAdminAccount;

  const _StaffDirectoryEntry({
    required this.member,
    required this.isAdminAccount,
  });
}

class InvitationPasswordSetupPage extends StatefulWidget {
  final VoidCallback onSetupStarted;
  final VoidCallback onSetupFinished;

  const InvitationPasswordSetupPage({
    super.key,
    required this.onSetupStarted,
    required this.onSetupFinished,
  });

  @override
  State<InvitationPasswordSetupPage> createState() =>
      _InvitationPasswordSetupPageState();
}

class _InvitationPasswordSetupPageState
    extends State<InvitationPasswordSetupPage> {
  final _supabase = Supabase.instance.client;
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _hidePassword = true;
  bool _hideConfirm = true;
  bool _submitting = false;
  bool _completed = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _setPassword() async {
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (password.length < 8) {
      setState(() {
        _error = 'Use a password with at least 8 characters.';
      });
      return;
    }

    if (password != confirm) {
      setState(() {
        _error = 'The passwords do not match.';
      });
      return;
    }

    final session = _supabase.auth.currentSession;

    if (session == null) {
      setState(() {
        _error =
            'Your invitation session is missing or expired. '
            'Open the invitation email link again.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    widget.onSetupStarted();

    try {
      await _supabase.auth.updateUser(UserAttributes(password: password));

      final currentSession = _supabase.auth.currentSession;

      if (currentSession == null) {
        throw Exception(
          'Your session expired. Open the invitation email link again.',
        );
      }

      final response = await _supabase.functions.invoke(
        'staff-management',
        body: {'action': 'complete_invitation'},
        headers: {'Authorization': 'Bearer ${currentSession.accessToken}'},
      );

      final data = response.data;

      if (data is! Map || data['success'] != true) {
        final message = data is Map && data['error'] != null
            ? data['error'].toString()
            : 'The server could not activate your account.';

        throw Exception(message);
      }

      if (!mounted) return;

      setState(() {
        _completed = true;
        _passwordController.clear();
        _confirmController.clear();
      });
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not complete account setup: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
      widget.onSetupFinished();
    }
  }

  Future<void> _continueToSignIn() async {
    await _supabase.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              color: Colors.white,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 5,
                      decoration: BoxDecoration(
                        color: AppColors.red,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'APEX CHOICE',
                      style: TextStyle(
                        color: AppColors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _completed ? 'Account ready' : 'Set your password',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _completed
                          ? 'Your password has been set and your account '
                                'has been activated. You can now sign in '
                                'with your email and new password.'
                          : 'Choose a password for your Property Monthly '
                                'Report System account.',
                      style: const TextStyle(
                        color: AppColors.grey,
                        height: 1.5,
                      ),
                    ),
                    if (!_completed) ...[
                      const SizedBox(height: 24),
                      TextField(
                        controller: _passwordController,
                        obscureText: _hidePassword,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'New password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            onPressed: () {
                              setState(() {
                                _hidePassword = !_hidePassword;
                              });
                            },
                            icon: Icon(
                              _hidePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _confirmController,
                        obscureText: _hideConfirm,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'Confirm password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            onPressed: () {
                              setState(() {
                                _hideConfirm = !_hideConfirm;
                              });
                            },
                            icon: Icon(
                              _hideConfirm
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _setPassword(),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _submitting
                          ? null
                          : _completed
                          ? _continueToSignIn
                          : _setPassword,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _completed
                                  ? 'Continue to sign in'
                                  : 'Set password and activate account',
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}