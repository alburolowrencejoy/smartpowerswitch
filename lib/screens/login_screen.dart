import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController    = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey            = GlobalKey<FormState>();

  bool    _obscurePassword = true;
  bool    _isLoading       = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      // Step 1: Sign in with Firebase Auth
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email:    _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      final uid  = cred.user!.uid;
      final user = cred.user!;

      // Step 2: Read user data from Realtime Database
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();

      String role = 'faculty';
      String name = _emailController.text.trim().split('@').first;

      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        role = data['role'] as String? ?? 'faculty';
        name = data['name'] as String? ?? name;

        // Step 3: Check if admin set a new password for this account
        final newPassword = data['passwordReset'] as String?;
        if (newPassword != null && newPassword.isNotEmpty) {
          try {
            await user.updatePassword(newPassword);
            await FirebaseDatabase.instance
                .ref('users/$uid/passwordReset')
                .remove();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Your password has been updated by an admin.'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          } catch (_) {
            // If password update fails, continue login anyway
          }
        }
      } else {
        // First login — store as faculty by default
        await FirebaseDatabase.instance.ref('users/$uid').set({
          'email': _emailController.text.trim(),
          'name':  name,
          'role':  'faculty',
        });
      }

      if (!mounted) return;

      // Step 4: Navigate to dashboard
      Navigator.pushReplacementNamed(
        context,
        '/dashboard',
        arguments: {'role': role, 'name': name},
      );

    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = _friendlyError(e.code));
    } catch (e) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset email sent.')),
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = _friendlyError(e.code));
    }
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'user-not-found':     return 'No account found with this email.';
      case 'wrong-password':     return 'Incorrect password. Please try again.';
      case 'invalid-email':      return 'Please enter a valid email address.';
      case 'invalid-credential': return 'Invalid email or password.';
      case 'too-many-requests':  return 'Too many attempts. Please wait and try again.';
      default:                   return 'Login failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.greenDark,
      body: SafeArea(
        child: Column(
          children: [
            _buildHero(),
            Expanded(
              child: Container(
                color: AppColors.greenPale,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
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
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Email is required';
                            if (!v.contains('@')) return 'Enter a valid email';
                            if (!v.endsWith('@dnsc.edu.ph'))
                              return 'Only @dnsc.edu.ph emails are allowed';
                            return null;
                          },
                        ),
                        const SizedBox(height: 18),
                        _buildPasswordField(),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _handleForgotPassword,
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero),
                            child: const Text('Forgot password?',
                                style: TextStyle(fontSize: 12,
                                    color: AppColors.greenMid,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 8),
                          _buildErrorBox(),
                        ],
                        const SizedBox(height: 16),
                        _buildLoginButton(),
                        const SizedBox(height: 28),
                        Center(
                          child: RichText(
                            text: const TextSpan(
                              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                              children: [
                                TextSpan(text: 'DNSC Campus · '),
                                TextSpan(
                                  text: 'Davao del Norte State College',
                                  style: TextStyle(color: AppColors.textMid,
                                      fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(36, 24, 36, 40),
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(40),
          bottomRight: Radius.circular(40),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                  color: AppColors.greenMid,
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.bolt, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            RichText(text: const TextSpan(
              style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
                  fontWeight: FontWeight.w600, color: Colors.white),
              children: [
                TextSpan(text: 'Smart'),
                TextSpan(text: 'Power',
                    style: TextStyle(color: AppColors.greenLight)),
                TextSpan(text: 'Switch'),
              ],
            )),
          ]),
          const SizedBox(height: 28),
          const Text('Welcome back,',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 28,
                  fontWeight: FontWeight.w700, color: Colors.white, height: 1.2)),
          const Text('Sign in to continue.',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 20,
                  fontWeight: FontWeight.w400, color: AppColors.greenLight)),
          const SizedBox(height: 8),
          const Text('DNSC Campus Energy Control',
              style: TextStyle(fontSize: 13, color: Color(0xB3C2EDD0))),
        ],
      ),
    );
  }

  Widget _buildField(String label, IconData icon,
      TextEditingController controller, {
        String hint = '',
        TextInputType keyboard = TextInputType.text,
        String? Function(String?)? validator,
      }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11,
            fontWeight: FontWeight.w600, color: AppColors.textMid,
            letterSpacing: 0.8)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboard,
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
        const Text('PASSWORD', style: TextStyle(fontSize: 11,
            fontWeight: FontWeight.w600, color: AppColors.textMid,
            letterSpacing: 0.8)),
        const SizedBox(height: 6),
        TextFormField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          style: const TextStyle(color: AppColors.textDark, fontSize: 14),
          decoration: _inputDeco(
            hint: '••••••••',
            icon: Icons.lock_outline,
            suffix: IconButton(
              icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: AppColors.textMuted, size: 20),
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
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          elevation: 4,
          shadowColor: AppColors.greenDark.withAlpha(102),
        ),
        child: _isLoading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5))
            : const Text('Sign In',
                style: TextStyle(fontFamily: 'Outfit', fontSize: 16,
                    fontWeight: FontWeight.w600, color: Colors.white)),
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
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51), width: 1.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51), width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.greenMid, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
    );
  }
}