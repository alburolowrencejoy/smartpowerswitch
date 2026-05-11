import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_mode.dart';
import '../theme/app_colors.dart';
import '../widgets/top_toast.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _rememberEmailKey = 'login.rememberEmail';
  static const _rememberPasswordKey = 'login.rememberPassword';
  static const _rememberMeKey = 'login.rememberMe';
  static const _rememberedAtKey = 'login.rememberedAt';
  static const Duration _rememberMeDuration = Duration(days: 3);

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _rememberMe = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadRememberedCredentials();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadRememberedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final rememberedAt = prefs.getInt(_rememberedAtKey);
    final isExpired = rememberedAt != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(rememberedAt)) >
            _rememberMeDuration;

    if (isExpired) {
      await prefs.remove(_rememberMeKey);
      await prefs.remove(_rememberEmailKey);
      await prefs.remove(_rememberPasswordKey);
      await prefs.remove(_rememberedAtKey);
    }

    setState(() {
      _rememberMe = (prefs.getBool(_rememberMeKey) ?? false) && !isExpired;
      if (_rememberMe) {
        _emailController.text = prefs.getString(_rememberEmailKey) ?? '';
        _passwordController.text = prefs.getString(_rememberPasswordKey) ?? '';
      }
    });
  }

  Future<void> _saveRememberedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_rememberMe) {
      await prefs.setBool(_rememberMeKey, true);
      await prefs.setString(_rememberEmailKey, _emailController.text.trim());
      await prefs.setString(_rememberPasswordKey, _passwordController.text.trim());
      await prefs.setInt(_rememberedAtKey, DateTime.now().millisecondsSinceEpoch);
      return;
    }

    await prefs.remove(_rememberMeKey);
    await prefs.remove(_rememberEmailKey);
    await prefs.remove(_rememberPasswordKey);
    await prefs.remove(_rememberedAtKey);
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    if (kUseMockData) {
      final email = _emailController.text.trim();
      final role = email.startsWith('admin') ? 'admin' : 'faculty';
      final name = email.split('@').first;
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context,
        '/dashboard',
        arguments: {'role': role, 'name': name},
      );
      setState(() => _isLoading = false);
      return;
    }

    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      final uid = cred.user!.uid;
      final user = cred.user!;

      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();

      String role = 'faculty';
      String name = _emailController.text.trim().split('@').first;

      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        role = data['role'] as String? ?? 'faculty';
        name = data['name'] as String? ?? name;

        final newPassword = data['passwordReset'] as String?;
        if (newPassword != null && newPassword.isNotEmpty) {
          try {
            await user.updatePassword(newPassword);
            await FirebaseDatabase.instance
                .ref('users/$uid/passwordReset')
                .remove();
            if (mounted) {
              TopToast.success(
                context,
                'Your password has been updated by an admin.',
                visibleFor: const Duration(seconds: 3),
              );
            }
          } catch (_) {
            // Continue login if password update fails.
          }
        }
      } else {
        await FirebaseDatabase.instance.ref('users/$uid').set({
          'email': _emailController.text.trim(),
          'name': name,
          'role': 'faculty',
        });
      }

      if (!mounted) return;

      await _saveRememberedCredentials();

      Navigator.pushReplacementNamed(
        context,
        '/dashboard',
        arguments: {'role': role, 'name': name},
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = _friendlyError(e.code));
    } catch (_) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    if (kUseMockData) {
      TopToast.error(context, 'Mock mode: password reset is disabled.');
      return;
    }

    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _errorMessage = 'Enter your email first.');
      return;
    }
    if (!email.endsWith('@dnsc.edu.ph')) {
      setState(() => _errorMessage = 'Only @dnsc.edu.ph emails are allowed.');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      TopToast.success(context, 'Password reset email sent.');
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = _friendlyError(e.code));
    }
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      default:
        return 'Login failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.greenDark,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth;
            final isDesktop = maxWidth >= 1100;
            final isTablet = maxWidth >= 760 && maxWidth < 1100;
            final isNarrow = maxWidth < 420;

            if (!isDesktop) {
              return Container(
                color: AppColors.greenPale,
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      children: [
                        _buildHero(isTablet: isTablet, isNarrow: isNarrow),
                        Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: isTablet ? 700 : 560,
                            ),
                            child: _buildFormPane(
                              padding: EdgeInsets.fromLTRB(
                                isNarrow ? 16 : 24,
                                isTablet ? 28 : 22,
                                isNarrow ? 16 : 24,
                                24,
                              ),
                              compact: isNarrow,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return Container(
              color: AppColors.greenPale,
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1160),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: SizedBox(
                      height: constraints.maxHeight,
                      child: Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: Container(
                              color: AppColors.greenDark,
                              padding:
                                  const EdgeInsets.fromLTRB(48, 36, 48, 36),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 460),
                                  child: _buildHero(isDesktop: true),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 6,
                            child: Container(
                              color: AppColors.greenPale,
                              child: SingleChildScrollView(
                                padding:
                                    const EdgeInsets.fromLTRB(28, 24, 28, 24),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 560),
                                    child: _buildFormPane(
                                      padding: const EdgeInsets.fromLTRB(
                                          32, 36, 32, 32),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormPane({
    EdgeInsets padding = const EdgeInsets.fromLTRB(28, 36, 28, 32),
    bool compact = false,
  }) {
    return SingleChildScrollView(
      padding: padding,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildField(
              'EMAIL ADDRESS',
              Icons.email_outlined,
              _emailController,
              hint: 'you@dnsc.edu.ph',
              keyboard: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Email is required';
                if (!v.contains('@')) return 'Enter a valid email';
                if (!v.endsWith('@dnsc.edu.ph')) {
                  return 'Only @dnsc.edu.ph emails are allowed';
                }
                return null;
              },
            ),
            SizedBox(height: compact ? 14 : 18),
            _buildPasswordField(),
            SizedBox(height: compact ? 8 : 10),
            Row(
              children: [
                Checkbox(
                  value: _rememberMe,
                  activeColor: AppColors.greenDark,
                  onChanged: _isLoading
                      ? null
                      : (value) {
                          setState(() => _rememberMe = value ?? false);
                          _saveRememberedCredentials();
                        },
                ),
                const Expanded(
                  child: Text(
                    'Remember me on this device',
                    style: TextStyle(fontSize: 12, color: AppColors.textMid),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _handleForgotPassword,
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, minimumSize: Size.zero),
                child: Text(
                  'Forgot password?',
                  style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      color: AppColors.greenMid,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ),
            if (_errorMessage != null) ...[
              SizedBox(height: compact ? 6 : 8),
              _buildErrorBox(),
            ],
            SizedBox(height: compact ? 14 : 16),
            _buildLoginButton(),
            SizedBox(height: compact ? 22 : 28),
            const Center(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  children: [
                    TextSpan(text: 'DNSC Campus · '),
                    TextSpan(
                      text: 'Davao del Norte State College',
                      style: TextStyle(
                          color: AppColors.textMid,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero({
    bool isDesktop = false,
    bool isTablet = false,
    bool isNarrow = false,
  }) {
    final titleSize = isNarrow ? 24.0 : (isTablet ? 30.0 : 28.0);
    final subtitleSize = isNarrow ? 17.0 : 20.0;
    final logoSize = isNarrow ? 34.0 : 38.0;
    final horizontalPadding = isNarrow ? 20.0 : 36.0;
    final topPadding = isNarrow ? 20.0 : 24.0;
    final bottomPadding = isNarrow ? 30.0 : 40.0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        topPadding,
        horizontalPadding,
        bottomPadding,
      ),
      decoration: BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: isDesktop
            ? null
            : const BorderRadius.only(
                bottomLeft: Radius.circular(40),
                bottomRight: Radius.circular(40),
              ),
      ),
      child: Column(
        mainAxisAlignment:
            isDesktop ? MainAxisAlignment.center : MainAxisAlignment.start,
        crossAxisAlignment:
            isDesktop ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: logoSize,
              height: logoSize,
              padding: const EdgeInsets.all(5),
              child: Image.asset(
                'promo/img/logo.png',
                fit: BoxFit.contain,
              ),
            ),
            SizedBox(width: isNarrow ? 8 : 10),
            Flexible(
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: const TextSpan(
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  children: [
                    TextSpan(text: 'Smart'),
                    TextSpan(
                      text: 'Power',
                      style: TextStyle(color: AppColors.greenLight),
                    ),
                    TextSpan(text: 'Switch'),
                  ],
                ),
              ),
            ),
          ]),
          SizedBox(height: isNarrow ? 22 : 28),
          Text('Welcome back,',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: titleSize,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.2),
              textAlign: isDesktop ? TextAlign.center : TextAlign.start),
          Text('Sign in to continue.',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: subtitleSize,
                  fontWeight: FontWeight.w400,
                  color: AppColors.greenLight),
              textAlign: isDesktop ? TextAlign.center : TextAlign.start),
          SizedBox(height: isNarrow ? 6 : 8),
          Text('DNSC Campus Energy Control',
              style: TextStyle(
                  fontSize: isNarrow ? 12 : 13, color: const Color(0xB3C2EDD0)),
              textAlign: isDesktop ? TextAlign.center : TextAlign.start),
        ],
      ),
    );
  }

  Widget _buildField(
    String label,
    IconData icon,
    TextEditingController controller, {
    String hint = '',
    TextInputType keyboard = TextInputType.text,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textMid,
                letterSpacing: 0.8)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboard,
          textInputAction: textInputAction,
          onFieldSubmitted: onSubmitted,
          style: const TextStyle(color: AppColors.textDark, fontSize: 14),
          decoration: _inputDeco(hint: hint, icon: icon),
          validator: validator,
        ),
      ],
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PASSWORD',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textMid,
                letterSpacing: 0.8)),
        const SizedBox(height: 6),
        TextFormField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _isLoading ? null : _handleLogin(),
          style: const TextStyle(color: AppColors.textDark, fontSize: 14),
          decoration: _inputDeco(
            hint: '••••••••',
            icon: Icons.lock_outline,
            suffix: IconButton(
              icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: AppColors.textMuted,
                  size: 20),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Password is required';
            if (v.length < 6) return 'Minimum 6 characters';
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildErrorBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.error.withAlpha(20),
        border: Border.all(color: AppColors.error.withAlpha(51)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(_errorMessage!,
          style: const TextStyle(fontSize: 12, color: AppColors.error)),
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.greenDark,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 4,
          shadowColor: AppColors.greenDark.withAlpha(102),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5))
            : const Text('Sign In',
                style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
      ),
    );
  }

  InputDecoration _inputDeco({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
      prefixIcon: Icon(icon, color: AppColors.textMuted, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: AppColors.greenMid.withAlpha(51), width: 1.5)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: AppColors.greenMid.withAlpha(51), width: 1.5)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.greenMid, width: 1.5)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
    );
  }
}
