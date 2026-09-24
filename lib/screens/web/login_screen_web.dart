import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/app_mode.dart';
import '../../services/automation_scheduler_service.dart';
import '../../theme/app_fonts.dart';
import '../../theme/sps_colors.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/power_emblem.dart';

/// Web sign-in screen: power emblem on the left, green sign-in card on the
/// right; stacks into a single column below [_breakpoint].
///
/// "Remember me" maps to Firebase Auth persistence on web (LOCAL keeps the
/// session across browser restarts, SESSION ends it with the tab) and
/// remembers the email address. Unlike the mobile screen, the password is
/// never written to browser storage.
class LoginScreenWeb extends StatefulWidget {
  const LoginScreenWeb({super.key});

  @override
  State<LoginScreenWeb> createState() => _LoginScreenWebState();
}

enum _BannerKind { error, success }

class _LoginScreenWebState extends State<LoginScreenWeb> {
  static const double _breakpoint = 800;

  // Shared with the mobile login screen so the checkbox state carries over.
  static const _rememberMeKey = 'login.rememberMe';
  static const _rememberEmailKey = 'login.rememberEmail';
  static const _rememberPasswordKey = 'login.rememberPassword';
  static const _rememberedAtKey = 'login.rememberedAt';

  static final _emailPattern =
      RegExp(r'^[^\s@]+@dnsc\.edu\.ph$', caseSensitive: false);

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _rememberMe = false;
  String? _emailError;
  String? _passwordError;
  String? _bannerText;
  _BannerKind _bannerKind = _BannerKind.error;
  bool _didReadRouteArgs = false;

  /// Bumped on every failed attempt so a repeated error shakes again.
  int _shake = 0;

  @override
  void initState() {
    super.initState();
    _loadRemembered();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didReadRouteArgs) return;
    _didReadRouteArgs = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['forceLogoutReason'] == 'inactivity') {
      _bannerText = 'You were signed out after 20 minutes of inactivity.';
      _bannerKind = _BannerKind.success;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ── Remember me ───────────────────────────────────────────────

  Future<void> _loadRemembered() async {
    final prefs = await SharedPreferences.getInstance();
    // The mobile screen used to keep the password here; never leave it in
    // browser storage.
    await prefs.remove(_rememberPasswordKey);
    if (!mounted) return;
    final remember = prefs.getBool(_rememberMeKey) ?? false;
    setState(() {
      _rememberMe = remember;
      if (remember && _emailController.text.isEmpty) {
        _emailController.text = prefs.getString(_rememberEmailKey) ?? '';
      }
    });
  }

  Future<void> _saveRemembered(String email) async {
    final prefs = await SharedPreferences.getInstance();
    if (_rememberMe) {
      await prefs.setBool(_rememberMeKey, true);
      await prefs.setString(_rememberEmailKey, email);
      await prefs.setInt(
          _rememberedAtKey, DateTime.now().millisecondsSinceEpoch);
    } else {
      await prefs.remove(_rememberMeKey);
      await prefs.remove(_rememberEmailKey);
      await prefs.remove(_rememberedAtKey);
    }
  }

  // ── Actions ───────────────────────────────────────────────────

  void _showBanner(String text, _BannerKind kind) {
    setState(() {
      _bannerText = text;
      _bannerKind = kind;
      if (kind == _BannerKind.error) _shake++;
    });
  }

  Future<void> _handleLogin() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final emailBad = !_emailPattern.hasMatch(email);
    final passwordBad = password.isEmpty;

    setState(() {
      _emailError = emailBad ? 'Use your @dnsc.edu.ph email.' : null;
      _passwordError = passwordBad ? 'Password is required.' : null;
      if (emailBad || passwordBad) _shake++;
      _bannerText = null;
    });
    if (emailBad) {
      _emailFocus.requestFocus();
      return;
    }
    if (passwordBad) {
      _passwordFocus.requestFocus();
      return;
    }

    setState(() => _isLoading = true);

    if (kUseMockData) {
      final role = email.startsWith('admin') ? 'admin' : 'faculty';
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard',
          arguments: {'role': role, 'name': email.split('@').first});
      return;
    }

    try {
      final auth = FirebaseAuth.instance;
      if (kIsWeb) {
        await auth.setPersistence(
            _rememberMe ? Persistence.LOCAL : Persistence.SESSION);
      }
      final cred = await auth.signInWithEmailAndPassword(
          email: email, password: password);
      final uid = cred.user!.uid;
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();

      var role = 'faculty';
      var name = email.split('@').first;
      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        role = data['role'] as String? ?? role;
        name = data['name'] as String? ?? name;
      } else {
        await FirebaseDatabase.instance.ref('users/$uid').set({
          'email': email,
          'name': name,
          'role': 'faculty',
        });
      }

      await _saveRemembered(email);
      await AutomationSchedulerService.startIfNeeded();
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard',
          arguments: {'role': role, 'name': name});
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _showBanner(_authErrorText(e.code), _BannerKind.error);
      _passwordFocus.requestFocus();
      _passwordController.selection = TextSelection(
          baseOffset: 0, extentOffset: _passwordController.text.length);
    } catch (_) {
      if (!mounted) return;
      _showBanner('Something went wrong. Please try again.', _BannerKind.error);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();
    if (!_emailPattern.hasMatch(email)) {
      setState(() {
        _emailError = 'Use your @dnsc.edu.ph email.';
        _shake++;
        _bannerText = null;
      });
      _emailFocus.requestFocus();
      return;
    }
    if (kUseMockData) {
      _showBanner('Reset link sent to your email.', _BannerKind.success);
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      // Don't reveal whether an account exists.
      if (e.code != 'user-not-found' && e.code != 'invalid-credential') {
        if (mounted) _showBanner(_authErrorText(e.code), _BannerKind.error);
        return;
      }
    } catch (_) {
      if (mounted) {
        _showBanner(
            'Something went wrong. Please try again.', _BannerKind.error);
      }
      return;
    }
    if (mounted) {
      _showBanner('Reset link sent to your email.', _BannerKind.success);
    }
  }

  String _authErrorText(String code) {
    switch (code) {
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-email':
        return 'Wrong email or password.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: AppFonts.family),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: SpsColors.brand,
          selectionColor: SpsColors.energy.withValues(alpha: .35),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: AppFonts.family),
        child: Scaffold(
          backgroundColor: SpsColors.ground,
          body: SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= _breakpoint;
              return SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - 64)
                          .clamp(0, double.infinity)),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: wide ? _wideLayout() : _narrowLayout(),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _wideLayout() {
    // Both columns share a 520 minimum height and are centered against each
    // other, matching the design's equal-height grid cells.
    const minHeight = BoxConstraints(minHeight: 520);
    return Row(
      children: [
        Expanded(
          child: Transform.translate(
            offset: const Offset(-24, 0),
            child: ConstrainedBox(
              constraints: minHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 48, 48, 36),
                child: _emblemPanel(maxEmblem: 360, tagGap: 28),
              ),
            ),
          ),
        ),
        const SizedBox(width: 88),
        Expanded(
          child: ConstrainedBox(
            constraints: minHeight,
            child: _card(padding: const EdgeInsets.all(48)),
          ),
        ),
      ],
    );
  }

  Widget _narrowLayout() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: _emblemPanel(maxEmblem: 260, tagGap: 16),
        ),
        const SizedBox(height: 24),
        _card(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32)),
      ],
    );
  }

  Widget _emblemPanel({required double maxEmblem, required double tagGap}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LayoutBuilder(builder: (context, c) {
          final size = c.maxWidth < maxEmblem ? c.maxWidth : maxEmblem;
          return PowerEmblem(size: size);
        }),
        SizedBox(height: tagGap),
        const Text(
          'Campus energy, in your hands.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, height: 1.4, color: SpsColors.muted),
        ),
      ],
    );
  }

  Widget _card({required EdgeInsets padding}) {
    return Container(
      padding: padding,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SpsColors.brand,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: SpsColors.ink.withValues(alpha: .06),
              offset: const Offset(0, 1),
              blurRadius: 2),
          BoxShadow(
              color: SpsColors.ink.withValues(alpha: .12),
              offset: const Offset(0, 24),
              blurRadius: 64),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: AutofillGroup(child: _form()),
      ),
    );
  }

  Widget _form() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: const Text(
            'Sign in',
            style: TextStyle(
              fontSize: 28,
              height: 34 / 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -.015 * 28,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 28),
        if (_bannerText != null) ...[
          ShakeOnError(
            error: _bannerKind == _BannerKind.error ? _bannerText : null,
            trigger: _shake,
            child: _Banner(text: _bannerText!, kind: _bannerKind),
          ),
          const SizedBox(height: 16),
        ],
        _SpsField(
          label: 'Email address',
          hint: 'you@dnsc.edu.ph',
          icon: Icons.mail_outline,
          controller: _emailController,
          focusNode: _emailFocus,
          error: _emailError,
          shakeTrigger: _shake,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _passwordFocus.requestFocus(),
          onChanged: (_) {
            if (_emailError != null || _bannerText != null) {
              setState(() {
                _emailError = null;
                _bannerText = null;
              });
            }
          },
        ),
        const SizedBox(height: 16),
        _SpsField(
          label: 'Password',
          hint: 'Password',
          icon: Icons.lock_outline,
          controller: _passwordController,
          focusNode: _passwordFocus,
          error: _passwordError,
          shakeTrigger: _shake,
          obscureText: _obscurePassword,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _handleLogin(),
          onChanged: (_) {
            if (_passwordError != null || _bannerText != null) {
              setState(() {
                _passwordError = null;
                _bannerText = null;
              });
            }
          },
          suffix: _EyeButton(
            obscured: _obscurePassword,
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            _RememberCheckbox(
              value: _rememberMe,
              onChanged:
                  _isLoading ? null : (v) => setState(() => _rememberMe = v),
            ),
            _LinkButton(
              text: 'Forgot password?',
              onPressed: _isLoading ? null : _handleForgotPassword,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _PrimaryButton(loading: _isLoading, onPressed: _handleLogin),
        const SizedBox(height: 20),
        const _CampusLine(),
      ],
    );
  }
}

// ── Components ──────────────────────────────────────────────────

class _SpsField extends StatefulWidget {
  const _SpsField({
    required this.label,
    required this.hint,
    required this.icon,
    required this.controller,
    required this.focusNode,
    this.error,
    this.obscureText = false,
    this.keyboardType,
    this.autofillHints,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.suffix,
    this.shakeTrigger = 0,
  });

  final String label;
  final String hint;
  final IconData icon;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? error;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final int shakeTrigger;

  @override
  State<_SpsField> createState() => _SpsFieldState();
}

class _SpsFieldState extends State<_SpsField> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final hasError = widget.error != null;
    final focused = widget.focusNode.hasFocus;
    final borderColor = hasError
        ? SpsColors.errorBorder
        : focused
            ? SpsColors.energy
            : _hovered
                ? SpsColors.fieldHover
                : Colors.transparent;
    final ring = focused
        ? (hasError
            ? SpsColors.errorBannerBg
            : SpsColors.energy.withValues(alpha: .35))
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 13,
            height: 18 / 13,
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        // The error is drawn outside the inner field's decoration, so the
        // whole box is shaken here instead of by AppTextField itself.
        ShakeOnError(
          error: widget.error,
          trigger: widget.shakeTrigger,
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: 1.5),
                boxShadow: [
                  if (ring != null) BoxShadow(color: ring, spreadRadius: 3),
                ],
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12.5),
                  Icon(widget.icon, size: 18, color: SpsColors.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppTextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      obscureText: widget.obscureText,
                      keyboardType: widget.keyboardType,
                      autofillHints: widget.autofillHints,
                      textInputAction: widget.textInputAction,
                      onSubmitted: widget.onSubmitted,
                      onChanged: widget.onChanged,
                      autocorrect: false,
                      enableSuggestions: !widget.obscureText,
                      style:
                          const TextStyle(fontSize: 15, color: SpsColors.ink),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: widget.hint,
                        hintStyle: TextStyle(
                          fontSize: 15,
                          color: SpsColors.muted.withValues(alpha: .85),
                        ),
                      ),
                    ),
                  ),
                  if (widget.suffix != null) ...[
                    const SizedBox(width: 4),
                    widget.suffix!,
                    const SizedBox(width: 4.5),
                  ] else
                    const SizedBox(width: 42.5),
                ],
              ),
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Semantics(
              liveRegion: true,
              child: Text(
                widget.error!,
                style:
                    const TextStyle(fontSize: 12, color: SpsColors.errorText),
              ),
            ),
          ),
      ],
    );
  }
}

class _EyeButton extends StatelessWidget {
  const _EyeButton({required this.obscured, required this.onPressed});

  final bool obscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = obscured ? 'Show password' : 'Hide password';
    return Semantics(
      toggled: !obscured,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        style: IconButton.styleFrom(
          foregroundColor: SpsColors.muted,
          hoverColor: SpsColors.successBannerBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(obscured
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined),
      ),
    );
  }
}

class _RememberCheckbox extends StatelessWidget {
  const _RememberCheckbox({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: value,
                  onChanged:
                      onChanged == null ? null : (v) => onChanged!(v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  side: WidgetStateBorderSide.resolveWith((states) => states
                          .contains(WidgetState.selected)
                      ? const BorderSide(color: SpsColors.energy, width: 1.5)
                      : const BorderSide(
                          color: SpsColors.onCardMuted, width: 1.5)),
                  fillColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? SpsColors.energy
                          : Colors.transparent),
                  checkColor: SpsColors.brand,
                  focusColor: SpsColors.energy.withValues(alpha: .35),
                ),
              ),
              const SizedBox(width: 8),
              const Text('Remember me',
                  style: TextStyle(fontSize: 13, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkButton extends StatefulWidget {
  const _LinkButton({required this.text, required this.onPressed});

  final String text;
  final VoidCallback? onPressed;

  @override
  State<_LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<_LinkButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: TextButton(
        onPressed: widget.onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: SpsColors.energy,
          overlayColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        child: Text(
          widget.text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            decoration:
                _hovered ? TextDecoration.underline : TextDecoration.none,
            decorationColor: SpsColors.energy,
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: loading ? .85 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
                color: Color(0x2E000000), offset: Offset(0, 6), blurRadius: 16),
          ],
        ),
        child: FilledButton(
          onPressed: loading ? null : onPressed,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size.fromHeight(50)),
            elevation: const WidgetStatePropertyAll(0),
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12))),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.hovered) &&
                        !states.contains(WidgetState.disabled)
                    ? SpsColors.energyHover
                    : SpsColors.energy),
            foregroundColor: const WidgetStatePropertyAll(SpsColors.onEnergy),
            overlayColor: WidgetStatePropertyAll(
                SpsColors.onEnergy.withValues(alpha: .06)),
            side: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.focused)
                    ? BorderSide(
                        color: Colors.white.withValues(alpha: .6), width: 3)
                    : BorderSide.none),
            mouseCursor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.disabled)
                    ? SystemMouseCursors.progress
                    : SystemMouseCursors.click),
            textStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: SpsColors.onEnergy),
                ),
                const SizedBox(width: 10),
              ],
              Text(loading ? 'Signing in…' : 'Sign in'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.kind});

  final String text;
  final _BannerKind kind;

  @override
  Widget build(BuildContext context) {
    final ok = kind == _BannerKind.success;
    final fg = ok ? SpsColors.brand : SpsColors.errorBannerText;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: ok ? SpsColors.successBannerBg : SpsColors.errorBannerBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 18, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 13, height: 18 / 13, color: fg)),
            ),
          ],
        ),
      ),
    );
  }
}

class _CampusLine extends StatelessWidget {
  const _CampusLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: SpsColors.energy,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: SpsColors.energy.withValues(alpha: .25),
                  spreadRadius: 3),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Flexible(
          child: Text(
            'DNSC · Davao del Norte State College',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: SpsColors.onCardMuted),
          ),
        ),
      ],
    );
  }
}
