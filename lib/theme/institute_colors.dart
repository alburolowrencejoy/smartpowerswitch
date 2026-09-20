import 'package:flutter/material.dart';
import 'app_colors.dart';

/// A 4-step brand ramp shaped like [AppColors]' green ramp (dark/mid/light/
/// pale), so any institute-scoped screen can swap its accent colors for the
/// institute being viewed. Semantic colors (error/warning/success/text/
/// surface) never change — only this brand ramp does.
class InstitutePalette {
  final Color dark;
  final Color mid;
  final Color light;
  final Color pale;

  const InstitutePalette({
    required this.dark,
    required this.mid,
    required this.light,
    required this.pale,
  });
}

/// Per-institute color ramps. Institute codes match building codes (each
/// academic institute is one building on campus).
///
/// Each ramp uses the *exact same saturation and lightness as the green
/// ramp above*, per tier — only the hue rotates. That's deliberate: it's
/// what keeps every institute's colors feeling as muted/professional as the
/// original green rather than reading as a saturated, eyesore-y accent.
class InstituteColors {
  // IC — violet (hue ~265°)
  static const ic = InstitutePalette(
    dark: Color(0xFF351A5C),
    mid: Color(0xFF5D2E9E),
    light: Color(0xFF956ECB),
    pale: Color(0xFFD4C2ED),
  );

  // ILEGG — maroon (hue ~350°)
  static const ilegg = InstitutePalette(
    dark: Color(0xFF5C1A25),
    mid: Color(0xFF9E2E41),
    light: Color(0xFFCB6E7D),
    pale: Color(0xFFEDC2C9),
  );

  // ITED — gold (hue ~45°)
  static const ited = InstitutePalette(
    dark: Color(0xFF5C4B1A),
    mid: Color(0xFF9E822E),
    light: Color(0xFFCBB46E),
    pale: Color(0xFFEDE2C2),
  );

  // IAAS — blue (hue ~210°)
  static const iaas = InstitutePalette(
    dark: Color(0xFF1A3B5C),
    mid: Color(0xFF2E669E),
    light: Color(0xFF6E9CCB),
    pale: Color(0xFFC2D8ED),
  );

  // ADMIN, the main-admin's own scope, and any unmapped institute — the
  // app's original green palette.
  static const admin = InstitutePalette(
    dark: AppColors.greenDark,
    mid: AppColors.greenMid,
    light: AppColors.greenLight,
    pale: AppColors.greenPale,
  );

  static const Map<String, InstitutePalette> _byCode = {
    'IC': ic,
    'ILEGG': ilegg,
    'ITED': ited,
    'IAAS': iaas,
    'ADMIN': admin,
  };

  /// Resolves a building/institute code (case-insensitive) to its palette,
  /// falling back to the main green palette when unmapped or null.
  static InstitutePalette forCode(String? code) {
    if (code == null || code.trim().isEmpty) return admin;
    return _byCode[code.trim().toUpperCase()] ?? admin;
  }
}

/// Wraps [InstitutePalette] as a Flutter [ThemeExtension] so a screen can
/// register the resolved brand ramp on a local [Theme] override, and any
/// widget below it -- including shared widgets that don't receive
/// `institute`/`role` as constructor params -- can read it back via
/// [InstituteThemeContext.institutePalette].
class InstituteTheme extends ThemeExtension<InstituteTheme> {
  final InstitutePalette palette;

  const InstituteTheme({required this.palette});

  /// THE single source of truth for which roles get institute-themed and
  /// which stay on the app's main green ramp -- this is the "resolver" the
  /// product owner asked to centralize, not just the color data (which
  /// already lived in [InstituteColors] above).
  ///
  /// Rule (confirmed by product owner):
  /// - `institute_admin` and institute-scoped `member`/`faculty` (i.e. a
  ///   non-empty `institute` on their user record) -> [InstituteColors.forCode]
  ///   for that institute.
  /// - `main_admin` / `admin` / `super_admin` -> [InstituteColors.admin]
  ///   (green), no exceptions -- even if an `institute` happens to be set
  ///   on their user record.
  /// - Any other/unknown role, or a themeable role with no institute
  ///   assigned yet -> [InstituteColors.admin] (green) as the safe default.
  factory InstituteTheme.resolve(String role, String? institute) {
    final normalizedRole = role.trim().toLowerCase();

    const superAdminRoles = {'main_admin', 'admin', 'super_admin'};
    if (superAdminRoles.contains(normalizedRole)) {
      return const InstituteTheme(palette: InstituteColors.admin);
    }

    const instituteScopedRoles = {'institute_admin', 'member', 'faculty'};
    final hasInstitute = institute != null && institute.trim().isNotEmpty;
    if (instituteScopedRoles.contains(normalizedRole) && hasInstitute) {
      return InstituteTheme(palette: InstituteColors.forCode(institute));
    }

    return const InstituteTheme(palette: InstituteColors.admin);
  }

  @override
  InstituteTheme copyWith({InstitutePalette? palette}) {
    return InstituteTheme(palette: palette ?? this.palette);
  }

  @override
  InstituteTheme lerp(ThemeExtension<InstituteTheme>? other, double t) {
    if (other is! InstituteTheme) return this;
    return InstituteTheme(
      palette: InstitutePalette(
        dark: Color.lerp(palette.dark, other.palette.dark, t) ?? palette.dark,
        mid: Color.lerp(palette.mid, other.palette.mid, t) ?? palette.mid,
        light: Color.lerp(palette.light, other.palette.light, t) ??
            palette.light,
        pale: Color.lerp(palette.pale, other.palette.pale, t) ?? palette.pale,
      ),
    );
  }
}

/// Ergonomic access to the resolved institute palette from anywhere in the
/// widget tree below a [Theme] carrying an [InstituteTheme] extension.
/// Falls back to the green admin ramp when no [InstituteTheme] has been
/// registered on an ancestor [Theme] (e.g. a screen not yet migrated).
extension InstituteThemeContext on BuildContext {
  InstitutePalette get institutePalette =>
      Theme.of(this).extension<InstituteTheme>()?.palette ??
      InstituteColors.admin;
}
