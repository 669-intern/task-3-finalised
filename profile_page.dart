
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'widgets/styles.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  Map<String, dynamic>? _profile;
  String? _avatarUrl;
  String? _error;

  bool _loading = true;
  bool _saving = false;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = _supabase.auth.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'Your session has expired. Please sign in again.';
      });
      return;
    }

    try {
      final data = await _supabase
          .from('user_profiles')
          .select(
            'id, full_name, email, phone, staff_id, designation, '
            'role, account_status, avatar_url',
          )
          .eq('id', user.id)
          .single();

      String? signedUrl;
      final photoPath = data['avatar_url']?.toString();

      if (photoPath != null && photoPath.isNotEmpty) {
        try {
          signedUrl = await _supabase.storage
              .from('profile-photos')
              .createSignedUrl(photoPath, 3600);
        } catch (_) {
          signedUrl = null;
        }
      }

      if (!mounted) return;

      setState(() {
        _profile = Map<String, dynamic>.from(data);
        _nameController.text = data['full_name']?.toString() ?? '';
        _phoneController.text = data['phone']?.toString() ?? '';
        _avatarUrl = signedUrl;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'Unable to load your profile.\n$e';
      });
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    final user = _supabase.auth.currentUser;

    if (user == null) {
      _showMessage('Your session has expired. Please sign in again.');
      return;
    }

    setState(() => _saving = true);

    try {
      final name = _nameController.text.trim();
      final phone = _phoneController.text.trim();

      await _supabase
          .from('user_profiles')
          .update({
            'full_name': name,
            'phone': phone.isEmpty ? null : phone,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', user.id);

      if (!mounted) return;

      setState(() {
        _profile = {
          ...?_profile,
          'full_name': name,
          'phone': phone.isEmpty ? null : phone,
        };
      });

      _showMessage('Profile saved successfully.');
    } catch (e) {
      if (mounted) {
        _showMessage('Unable to save profile: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _changePhoto() async {
    final user = _supabase.auth.currentUser;
    if (user == null || _uploadingPhoto) return;

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1000,
        maxHeight: 1000,
        imageQuality: 85,
      );

      if (image == null || !mounted) return;

      setState(() => _uploadingPhoto = true);

      final Uint8List bytes = await image.readAsBytes();
      final filename = image.name.toLowerCase();

      String extension = 'jpg';
      String contentType = 'image/jpeg';

      if (filename.endsWith('.png')) {
        extension = 'png';
        contentType = 'image/png';
      } else if (filename.endsWith('.webp')) {
        extension = 'webp';
        contentType = 'image/webp';
      }

      final path = '${user.id}/avatar.$extension';

      await _supabase.storage
          .from('profile-photos')
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              upsert: true,
              contentType: contentType,
            ),
          );

      await _supabase
          .from('user_profiles')
          .update({
            'avatar_url': path,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', user.id);

      final signedUrl = await _supabase.storage
          .from('profile-photos')
          .createSignedUrl(path, 3600);

      if (!mounted) return;

      setState(() {
        _avatarUrl = signedUrl;
        _profile = {
          ...?_profile,
          'avatar_url': path,
        };
      });

      _showMessage('Profile picture updated.');
    } catch (e) {
      if (mounted) {
        _showMessage('Unable to upload picture: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingPhoto = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.charcoal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  String _value(dynamic value, [String fallback = 'Not provided']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String _initials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';

    return trimmed
        .split(RegExp(r'\s+'))
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
      case 'approved':
        return const Color(0xFF22683D);
      case 'pending':
      case 'pending review':
        return const Color(0xFF966400);
      case 'inactive':
      case 'suspended':
      case 'disabled':
        return AppColors.red;
      default:
        return AppColors.grey;
    }
  }

  Widget _sectionHeading({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
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
          child: Icon(icon, color: AppColors.red, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.black,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.grey,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.035),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _detailRow({
    required String label,
    required String value,
    required IconData icon,
    bool showDivider = true,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: AppColors.grey,
                  size: 19,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.9,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      value,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showDivider)
          const Divider(
            height: 1,
            color: Color(0xFFEEEEEE),
          ),
      ],
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 21),
      filled: true,
      fillColor: const Color(0xFFFAFAFA),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: AppColors.red,
          width: 1.5,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: AppColors.red,
          width: 1.5,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 17,
      ),
    );
  }

  Widget _buildProfileHeader(Map<String, dynamic> profile) {
    final name = _value(profile['full_name'], 'Your Profile');
    final rawRole = _value(profile['role'], 'User');
    final role = rawRole.isEmpty
        ? 'User'
        : '${rawRole[0].toUpperCase()}${rawRole.substring(1).toLowerCase()}';
    final status = _value(profile['account_status'], 'Unknown');
    final statusColor = _statusColor(status);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.charcoal,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.red),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.10),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'ACCOUNT OVERVIEW',
              style: TextStyle(
                color: AppColors.red,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.7,
              ),
            ),
          ),
          const SizedBox(height: 26),

          // Avatar and photo action share the same centered column.
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.red,
                          width: 2,
                        ),
                      ),
                      child: CircleAvatar(
                        radius: 54,
                        backgroundColor: const Color(0xFFECECEC),
                        backgroundImage: _avatarUrl == null
                            ? null
                            : NetworkImage(_avatarUrl!),
                        child: _avatarUrl == null
                            ? Text(
                                _initials(name),
                                style: const TextStyle(
                                  color: AppColors.black,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w900,
                                ),
                              )
                            : null,
                      ),
                    ),
                    Material(
                      color: AppColors.red,
                      shape: const CircleBorder(),
                      elevation: 3,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _uploadingPhoto ? null : _changePhoto,
                        child: SizedBox(
                          width: 38,
                          height: 38,
                          child: Center(
                            child: _uploadingPhoto
                                ? const SizedBox(
                                    width: 17,
                                    height: 17,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.camera_alt_outlined,
                                    color: AppColors.white,
                                    size: 19,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 9),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: AppColors.white.withValues(alpha: 0.16),
                    ),
                  ),
                  child: Text(
                    role,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: _uploadingPhoto ? null : _changePhoto,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.red,
                    side: const BorderSide(color: AppColors.red),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(
                    Icons.photo_camera_outlined,
                    size: 18,
                  ),
                  label: Text(
                    _uploadingPhoto
                        ? 'Uploading picture...'
                        : 'Change profile picture',
                    style: const TextStyle(
                      color: AppColors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Divider(
            color: AppColors.white.withValues(alpha: 0.15),
            height: 1,
          ),
          const SizedBox(height: 17),
          Row(
            children: [
              const Icon(
                Icons.verified_user_outlined,
                color: AppColors.red,
                size: 19,
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'Account status',
                  style: TextStyle(
                    color: Color(0xFFE0E0E0),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.50),
                  ),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: statusColor == AppColors.grey
                        ? AppColors.white
                        : Color.lerp(
                            statusColor,
                            AppColors.white,
                            0.35,
                          ),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalDetails() {
    return _sectionCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeading(
              icon: Icons.person_outline,
              title: 'Personal Details',
              subtitle: 'Manage the personal information on your account.',
            ),
            const SizedBox(height: 26),
            TextFormField(
              controller: _nameController,
              maxLength: 100,
              textCapitalization: TextCapitalization.words,
              decoration: _inputDecoration(
                label: 'Full name',
                hint: 'Enter your full name',
                icon: Icons.badge_outlined,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter your name.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              maxLength: 30,
              decoration: _inputDecoration(
                label: 'Phone number',
                hint: 'Enter your phone number',
                icon: Icons.phone_outlined,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F8F8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    color: AppColors.grey,
                    size: 18,
                  ),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Your name and phone number can be updated here. '
                      'Account access and staff information are managed '
                      'separately.',
                      style: TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveProfile,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: AppColors.white,
                  disabledBackgroundColor:
                      AppColors.red.withValues(alpha: 0.55),
                  padding: const EdgeInsets.symmetric(vertical: 17),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined, size: 19),
                label: Text(
                  _saving ? 'Saving changes...' : 'Save changes',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountDetails(Map<String, dynamic> profile) {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeading(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Account Details',
            subtitle: 'Your registered account and staff information.',
          ),
          const SizedBox(height: 14),
          _detailRow(
            label: 'Email address',
            value: _value(profile['email']),
            icon: Icons.email_outlined,
          ),
          _detailRow(
            label: 'Staff ID',
            value: _value(profile['staff_id']),
            icon: Icons.badge_outlined,
          ),
          _detailRow(
            label: 'Designation',
            value: _value(profile['designation']),
            icon: Icons.work_outline,
          ),
          _detailRow(
            label: 'Account status',
            value: _value(profile['account_status']),
            icon: Icons.verified_user_outlined,
            showDivider: false,
          ),
          const SizedBox(height: 15),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.red.withValues(alpha: 0.055),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: AppColors.red.withValues(alpha: 0.15),
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline,
                  color: AppColors.red,
                  size: 19,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'These details are managed by your administrator '
                    'and cannot be edited from this page.',
                    style: TextStyle(
                      color: AppColors.grey,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.person_off_outlined,
                  color: AppColors.red,
                  size: 38,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Unable to load your profile',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.black,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.grey,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _loadProfile();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile ?? {};

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        elevation: 0,
        title: const Text(
          'MY PROFILE',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 1.3,
          ),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: AppColors.red,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppColors.red,
              ),
            )
          : _error != null
              ? _buildErrorState()
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        20,
                        24,
                        20,
                        36,
                      ),
                      children: [
                        _buildProfileHeader(profile),
                        const SizedBox(height: 24),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final isWide = constraints.maxWidth >= 760;

                            final personalDetails =
                                _buildPersonalDetails();
                            final accountDetails =
                                _buildAccountDetails(profile);

                            if (isWide) {
                              return Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 6,
                                    child: personalDetails,
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    flex: 5,
                                    child: accountDetails,
                                  ),
                                ],
                              );
                            }

                            return Column(
                              children: [
                                personalDetails,
                                const SizedBox(height: 20),
                                accountDetails,
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 24),
                        const Center(
                          child: Text(
                            'APEX CHOICE  •  ACCOUNT SETTINGS',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.grey,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}
