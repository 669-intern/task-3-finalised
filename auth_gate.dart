import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dashboard/admin_portal.dart';
import 'staff_management_page.dart';
import 'property_selection_page.dart';
import 'widgets/styles.dart';
import 'widgets/app_shell.dart';
import 'widgets/app_common_app_bar.dart';

// Retain compatibility for code that imported AdminPortalPage from auth_gate.dart.
export 'dashboard/admin_portal.dart' show AdminPortalPage;

typedef SiteOpenedCallback =
    void Function(
      BuildContext context,
      Map<String, dynamic> site,
      String accessToken,
    );

class AuthGate extends StatefulWidget {
  final SiteOpenedCallback onSiteOpened;
  final AppShellController? shellController;

  const AuthGate({super.key, required this.onSiteOpened, this.shellController});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _supabase = Supabase.instance.client;

  bool _completingInvitation = false;
  StreamSubscription<AuthState>? _authSubscription;
  User? _user;
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _passwordRecovery = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    _user = _supabase.auth.currentSession?.user;

    _authSubscription = _supabase.auth.onAuthStateChange.listen((data) {
      if (!mounted || _completingInvitation) return;

      if (data.event == AuthChangeEvent.passwordRecovery) {
        _passwordRecovery = true;
        widget.shellController?.deactivate();
      } else if (data.event == AuthChangeEvent.signedOut) {
        _passwordRecovery = false;
        widget.shellController?.deactivate();
      }

      setState(() {
        _user = data.session?.user;
        _profile = null;
        _error = null;
        _loading = true;
      });

      _loadProfile();
    });

    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = _user;

    if (user == null) {
      if (!mounted) return;
      widget.shellController?.deactivate();

      setState(() {
        _profile = null;
        _loading = false;
        _error = null;
      });

      return;
    }

    try {
      final result = await _supabase
          .from('user_profiles')
          .select(
            'id, full_name, email, phone, staff_id, designation, '
            'role, account_status',
          )
          .eq('id', user.id)
          .maybeSingle();

      if (!mounted || _user?.id != user.id) return;

      if (result == null) {
        widget.shellController?.deactivate();
        setState(() {
          _profile = null;
          _error =
              'Your account profile has not been set up. '
              'Please contact an administrator.';
          _loading = false;
        });

        return;
      }

      final profile = Map<String, dynamic>.from(result);
      final status = profile['account_status']?.toString();
      final role = profile['role']?.toString();

      final validRole = role == 'admin' || role == 'staff';
      final validStatus =
          status == 'active' || (status == 'invited' && validRole);

      if (!validRole || !validStatus) {
        widget.shellController?.deactivate();
        setState(() {
          _profile = null;
          _error =
              'Your account is not active. '
              'Please contact an administrator.';
          _loading = false;
        });

        await _supabase.auth.signOut();
        return;
      }

      setState(() {
        _profile = profile;
        _error = null;
        _loading = false;
      });

      // Only fully active accounts receive the authenticated sidebar.
      // Invitations and password recovery retain their existing full pages.
      if (status == 'active' && !_passwordRecovery) {
        widget.shellController?.activate(role!);
      } else {
        widget.shellController?.deactivate();
      }
    } catch (e) {
      if (!mounted || _user?.id != user.id) return;
      widget.shellController?.deactivate();

      setState(() {
        _profile = null;
        _error = 'Could not verify your account: $e';
        _loading = false;
      });
    }
  }

  void _openPropertySelection(BuildContext context) {
    widget.shellController?.selectSection('properties');
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: 'app:properties'),
        builder: (_) =>
            PropertySelectionPage(onSiteOpened: widget.onSiteOpened),
      ),
    );
  }

  void _openStaffPortal(BuildContext context) {
    // Staff Portal opens Property Selection directly.
    _openPropertySelection(context);
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_passwordRecovery) {
      return const ResetPasswordPage();
    }

    if (_loading) {
      return const _AuthLoadingPage();
    }

    if (_user == null) {
      return LoginPage(initialError: _error);
    }

    if (_profile == null) {
      return AccountErrorPage(
        message: _error ?? 'Your account could not be verified.',
        onRetry: _loadProfile,
        onSignOut: () => _supabase.auth.signOut(),
      );
    }

    if (_profile!['account_status'] == 'invited' &&
        (_profile!['role'] == 'staff' || _profile!['role'] == 'admin')) {
      return InvitationPasswordSetupPage(
        onSetupStarted: () {
          _completingInvitation = true;
        },
        onSetupFinished: () {
          _completingInvitation = false;
          _loadProfile();
        },
      );
    }

    if (_profile!['role'] == 'admin' ||
        _profile!['role'] == 'staff') {
      return AdminPortalPage(
        profile: _profile!,
        onRefresh: _loadProfile,
        onManageProperties: () => _openPropertySelection(context),
        shellController: widget.shellController,
        onOpenStaffPortal: () => _openStaffPortal(context),
        onManageStaff: () {
          if (_profile!['role'] != 'admin') return;
          widget.shellController?.selectSection('staff');
          Navigator.push(
            context,
            MaterialPageRoute(
              settings: const RouteSettings(name: 'app:staff'),
              builder: (_) => const StaffManagementPage(),
            ),
          );
        },
      );
    }

    return PropertySelectionPage(onSiteOpened: widget.onSiteOpened);
  }
}

// ============================================================
// SHARED AUTHENTICATION UI
// ============================================================

class _AuthLoadingPage extends StatelessWidget {
  const _AuthLoadingPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: CircularProgressIndicator(
                color: AppColors.red,
                strokeWidth: 3,
              ),
            ),
            SizedBox(height: 22),
            Text(
              'APEX CHOICE',
              style: TextStyle(
                color: AppColors.black,
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Verifying your account...',
              style: TextStyle(color: AppColors.grey, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const _BrandHeader({
    required this.title,
    required this.subtitle,
    this.icon = Icons.apartment_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.black,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.red,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'APEX CHOICE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.8,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFCCCCCC),
                    fontSize: 12,
                    height: 1.4,
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

class _InlineMessage extends StatelessWidget {
  final String message;
  final bool isError;

  const _InlineMessage({required this.message, this.isError = true});

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.error : AppColors.success;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// LOGIN PAGE
// ============================================================

class LoginPage extends StatefulWidget {
  final String? initialError;

  const LoginPage({super.key, this.initialError});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _supabase = Supabase.instance.client;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _hidePassword = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Enter your email and password.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _supabase.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Login failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _openForgotPassword() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              elevation: 2,
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
                    const SizedBox(height: 12),
                    const Text(
                      'Sign in',
                      style: TextStyle(
                        color: AppColors.black,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Property Monthly Report System',
                      style: TextStyle(color: AppColors.grey, height: 1.5),
                    ),
                    const SizedBox(height: 28),
                    const _FieldLabel('EMAIL ADDRESS'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enabled: !_submitting,
                      decoration: const InputDecoration(
                        hintText: 'Enter your email address',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      onSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 18),
                    const _FieldLabel('PASSWORD'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passwordController,
                      obscureText: _hidePassword,
                      enabled: !_submitting,
                      decoration: InputDecoration(
                        hintText: 'Enter your password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _hidePassword
                              ? 'Show password'
                              : 'Hide password',
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
                      onSubmitted: (_) => _login(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 18),
                      _InlineMessage(message: _error!),
                    ],
                    const SizedBox(height: 26),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _submitting ? null : _login,
                        child: _submitting
                            ? const SizedBox(
                                width: 21,
                                height: 21,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('Sign in'),
                                  SizedBox(width: 8),
                                  Icon(Icons.arrow_forward, size: 18),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _submitting ? null : _openForgotPassword,
                      child: const Text('Forgot password?'),
                    ),
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 12),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.admin_panel_settings_outlined,
                          color: AppColors.grey,
                          size: 17,
                        ),
                        SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            'Accounts are provided by your administrator.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.grey,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
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

class _FieldLabel extends StatelessWidget {
  final String label;

  const _FieldLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: AppColors.black,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
      ),
    );
  }
}

// ============================================================
// FORGOT PASSWORD PAGE
// ============================================================

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _supabase = Supabase.instance.client;
  final _emailController = TextEditingController();

  bool _sending = false;
  String? _error;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetEmail() async {
    final email = _emailController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _error = 'Enter a valid email address.';
        _message = null;
      });
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
      _message = null;
    });

    try {
      await _supabase.auth.resetPasswordForEmail(
        email,
        redirectTo: Uri.base.origin,
      );

      if (!mounted) return;

      setState(() {
        _message =
            'If an account exists for this email, a password-reset '
            'link has been sent. Check your inbox and spam folder.';
      });
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not send the reset email. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Forgot Password'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(3),
          child: ColoredBox(color: AppColors.red, child: SizedBox(height: 3)),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _BrandHeader(
                      title: 'Account recovery',
                      subtitle: 'Recover access to your account.',
                      icon: Icons.lock_reset_outlined,
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Reset your password',
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                        color: AppColors.black,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Enter your registered email address. '
                      'We will send you a link to choose a new password.',
                      style: TextStyle(color: AppColors.grey, height: 1.6),
                    ),
                    const SizedBox(height: 24),
                    const _FieldLabel('EMAIL ADDRESS'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enabled: !_sending,
                      decoration: const InputDecoration(
                        hintText: 'Enter your registered email',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      onSubmitted: (_) => _sendResetEmail(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      _InlineMessage(message: _error!),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 16),
                      _InlineMessage(message: _message!, isError: false),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _sending ? null : _sendResetEmail,
                        child: _sending
                            ? const SizedBox(
                                width: 21,
                                height: 21,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.send_outlined, size: 18),
                                  SizedBox(width: 9),
                                  Text('Send reset link'),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Back to sign in'),
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

// ============================================================
// RESET PASSWORD PAGE
// ============================================================

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _supabase = Supabase.instance.client;
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _hidePassword = true;
  bool _hideConfirmPassword = true;
  bool _saving = false;
  bool _updated = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _updatePassword() async {
    final password = _passwordController.text;
    final confirmation = _confirmPasswordController.text;

    if (password.length < 8) {
      setState(() {
        _error = 'Your password must be at least 8 characters long.';
      });
      return;
    }

    if (password != confirmation) {
      setState(() {
        _error = 'The passwords do not match.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await _supabase.auth.updateUser(UserAttributes(password: password));

      if (!mounted) return;

      setState(() {
        _updated = true;
      });
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not update your password. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _returnToLogin() async {
    await _supabase.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Reset Password'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(3),
          child: ColoredBox(color: AppColors.red, child: SizedBox(height: 3)),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BrandHeader(
                      title: _updated
                          ? 'Password updated'
                          : 'Secure your account',
                      subtitle: _updated
                          ? 'Your new password is ready to use.'
                          : 'Choose a new password for your account.',
                      icon: _updated
                          ? Icons.check_circle_outline
                          : Icons.lock_reset_outlined,
                    ),
                    const SizedBox(height: 28),
                    Text(
                      _updated ? 'Password updated' : 'Choose a new password',
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                        color: AppColors.black,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _updated
                          ? 'Your password has been changed successfully. '
                                'You can now sign in with your new password.'
                          : 'Enter a new password for your account. '
                                'Use at least 8 characters.',
                      style: const TextStyle(
                        color: AppColors.grey,
                        height: 1.6,
                      ),
                    ),
                    if (!_updated) ...[
                      const SizedBox(height: 24),
                      const _FieldLabel('NEW PASSWORD'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _passwordController,
                        obscureText: _hidePassword,
                        enabled: !_saving,
                        decoration: InputDecoration(
                          hintText: 'Enter your new password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _hidePassword
                                ? 'Show password'
                                : 'Hide password',
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
                      const SizedBox(height: 18),
                      const _FieldLabel('CONFIRM PASSWORD'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _confirmPasswordController,
                        obscureText: _hideConfirmPassword,
                        enabled: !_saving,
                        decoration: InputDecoration(
                          hintText: 'Re-enter your new password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _hideConfirmPassword
                                ? 'Show password'
                                : 'Hide password',
                            onPressed: () {
                              setState(() {
                                _hideConfirmPassword = !_hideConfirmPassword;
                              });
                            },
                            icon: Icon(
                              _hideConfirmPassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _updatePassword(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        _InlineMessage(message: _error!),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: _saving ? null : _updatePassword,
                          child: _saving
                              ? const SizedBox(
                                  width: 21,
                                  height: 21,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.check_circle_outline, size: 19),
                                    SizedBox(width: 9),
                                    Text('Update password'),
                                  ],
                                ),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: _returnToLogin,
                          child: const Text('Back to sign in'),
                        ),
                      ),
                    ],
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

// ============================================================
// STAFF PORTAL
// ============================================================

class StaffPortalPage extends StatelessWidget {
  final Map<String, dynamic> profile;
  final void Function(BuildContext context) onOpenProperties;

  const StaffPortalPage({
    super.key,
    required this.profile,
    required this.onOpenProperties,
  });

  @override
  Widget build(BuildContext context) {
    final name = profile['full_name']?.toString().trim();
    final greetingName = name == null || name.isEmpty ? 'Staff' : name;

    return _PortalScaffold(
      title: 'Staff Portal',
      onRefresh: () {},
      greeting: 'Welcome back, $greetingName',
      subtitle: 'Open an assigned property to access its monthly reports.',
      headerIcon: Icons.work_outline,
      headerLabel: 'STAFF WORKSPACE',
      children: [
        _PortalActionCard(
          icon: Icons.apartment_outlined,
          title: 'My Properties',
          subtitle: 'View properties available to your account.',
          onTap: () => onOpenProperties(context),
        ),
      ],
    );
  }
}

// ============================================================
// SHARED PORTAL LAYOUT
// ============================================================

class _PortalScaffold extends StatelessWidget {
  final String title;
  final VoidCallback onRefresh;
  final String greeting;
  final String subtitle;
  final IconData headerIcon;
  final String headerLabel;
  final List<Widget> children;

  const _PortalScaffold({
    required this.title,
    required this.onRefresh,
    required this.greeting,
    required this.subtitle,
    required this.headerIcon,
    required this.headerLabel,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppCommonAppBar(title: title, onRefresh: onRefresh),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(26),
                  decoration: BoxDecoration(
                    color: AppColors.black,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.red,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              headerIcon,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              headerLabel,
                              style: const TextStyle(
                                color: Color(0xFFE2E2E2),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        greeting,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 27,
                          fontWeight: FontWeight.w900,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFFD0D0D0),
                          fontSize: 14,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                const Text(
                  'QUICK ACCESS',
                  style: TextStyle(
                    color: AppColors.grey,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                ...children.map(
                  (child) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// PORTAL ACTION CARD
// ============================================================

class _PortalActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PortalActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: AppColors.red.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: AppColors.red, size: 27),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.black,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                color: AppColors.red,
                size: 17,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ACCOUNT ERROR PAGE
// ============================================================

class AccountErrorPage extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  final Future<void> Function() onSignOut;

  const AccountErrorPage({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _BrandHeader(
                      title: 'Account verification',
                      subtitle: 'We could not confirm your account access.',
                      icon: Icons.admin_panel_settings_outlined,
                    ),
                    const SizedBox(height: 28),
                    const Icon(
                      Icons.lock_outline,
                      size: 42,
                      color: AppColors.red,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Account access unavailable',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: AppColors.black,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.grey,
                        height: 1.6,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 26),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: onSignOut,
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign out'),
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