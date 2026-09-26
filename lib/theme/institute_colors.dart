import 'package:flutter/material.dart';
import 'app_colors.dart';

/// A per-institute brand ramp.
///
/// Historically this only carried 4 tiers (`dark`/`mid`/`light`/`pale`), one
/// hue rotated per institute at the same saturation/lightness as the app's
/// green ramp. The mobile redesign (see
/// `lib/Claude outputs/SmartSwitch-Mobile-Redesign-Handoff.md` §3.6) rebuilt
/// the four themed institutes (IC/ILEGG/ITED/IAAS) in OKLCH for equal
/// perceived strength and added a 5th shade (`wash`, the 50-tier) plus a
/// dedicated hairline `line` color. ADMIN was NOT rebuilt -- it keeps the
/// app's original green ramp, per the handoff.
///
/// Field <-> handoff-tier mapping (confirmed against
/// `smartswitch-mobile-preview.html`'s `.theme-ic/.theme-ilegg/.theme-ited/
/// .theme-iaas` CSS, which is the ground truth for exact hex values):
/// - [shade900] = handoff "900" (hero gradient start / deepest tone). New.
/// - [dark]     = handoff "700" (buttons, switches, links, active outlines).
///   This is the same *role* the old `dark` field already played, so the
///   name is unchanged -- only its value moves to the new OKLCH hex.
/// - [mid]      = handoff "500" (charts, top-bar institute line).
/// - [light]    = also handoff "500" for the four themed institutes -- the
///   preview's CSS defines `--green-light` equal to `--green-mid` for every
///   `.theme-*` class, i.e. the redesign does not give themed institutes a
///   tier distinct from [mid] for this field. Kept as its own field (rather
///   than deleted) because existing mobile screens (e.g.
///   `building_floor_screen.dart`, `dashboard_screen.dart`) already read
///   `.light` as a mid-strength accent color; removing it would silently
///   break those screens ahead of their own redesign phase. ADMIN keeps its
///   own distinct `light` (unchanged, original green ramp).
/// - [pale]     = handoff "200" (selected chips/tabs, tinted backgrounds).
/// - [wash]     = handoff "50" (the new 5th shade -- very light page wash).
/// - [line]     = handoff hairline `line` color for dividers/borders drawn
///   in this institute's context (e.g. the Outline icon box border).
///
/// Nothing here was renamed or removed -- `dark`/`mid`/`light`/`pale` are
/// exactly the fields `lib/screens/web/**` already depends on, unchanged in
/// name and role. `shade900`, `wash`, and `line` are additions.
class InstitutePalette {
  final Color shade900;
  final Color dark;
  final Color mid;
  final Color light;
  final Color pale;
  final Color wash;
  final Color line;

  const InstitutePalette({
    required this.shade900,
    required this.dark,
    required this.mid,
    required this.light,
    required this.pale,
    required this.wash,
    required this.line,
  });
}

/// Per-institute color ramps. Institute codes match building codes (each
/// academic institute is one building on campus).
class InstituteColors {
  // IC -- indigo-violet (handoff §3.6, matches `.theme-ic` in the preview).
  static const ic = InstitutePalette(
    shade900: Color(0xFF342F64),
    dark: Color(0xFF534A9C),
    mid: Color(0xFF7F79D1),
    light: Color(0xFF7F79D1),
    pale: Color(0xFFDADBFC),
    wash: Color(0xFFF4F4FF),
    line: Color(0xFFE6E5F5),
  );

  // ILEGG -- berry/plum (handoff §3.6, matches `.theme-ilegg`).
  static const ilegg = InstitutePalette(
    shade900: Color(0xFF5A203A),
    dark: Color(0xFF8D325C),
    mid: Color(0xFFC1628A),
    light: Color(0xFFC1628A),
    pale: Color(0xFFF8D2DF),
    wash: Color(0xFFFEF1F5),
    line: Color(0xFFF2E2E9),
  );

  // ITED -- honey gold (handoff §3.6, matches `.theme-ited`).
  static const ited = InstitutePalette(
    shade900: Color(0xFF542C07),
    dark: Color(0xFF8B5500),
    mid: Color(0xFFB47D06),
    light: Color(0xFFB47D06),
    pale: Color(0xFFF6E7BB),
    wash: Color(0xFFFCF8E8),
    line: Color(0xFFF0E6CC),
  );

  // IAAS -- ocean blue (handoff §3.6, matches `.theme-iaas`).
  static const iaas = InstitutePalette(
    shade900: Color(0xFF003E5F),
    dark: Color(0xFF006095),
    mid: Color(0xFF0891C9),
    light: Color(0xFF0891C9),
    pale: Color(0xFFC2E4F8),
    wash: Color(0xFFECF7FE),
    line: Color(0xFFDCEAF4),
  );

  // ADMIN, the main-admin's own scope, and any unmapped institute -- the
  // app's ORIGINAL green palette, explicitly kept as-is (not rebuilt in
  // OKLCH) per the handoff. `wash`/`line` use the values the handoff §3.5
  // already documents for the campus palette. There is no handoff-specified
  // "900" tier for the green ramp (only the four rebuilt institutes got
  // one, for their hero gradients) -- [shade900] reuses [dark] rather than
  // inventing an unspecified darker green. Flag this if a future phase
  // needs a genuinely darker admin hero tone.
  static const admin = InstitutePalette(
    shade900: AppColors.greenDark,
    dark: AppColors.greenDark,
    mid: AppColors.greenMid,
    light: AppColors.greenLight,
    pale: AppColors.greenPale,
    wash: Color(0xFFE6F5EB),
    line: Color(0xFFDCEBE1),
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
        shade900: Color.lerp(palette.shade900, other.palette.shade900, t) ??
            palette.shade900,
        dark: Color.lerp(palette.dark, other.palette.dark, t) ?? palette.dark,
        mid: Color.lerp(palette.mid, other.palette.mid, t) ?? palette.mid,
        light: Color.lerp(palette.light, other.palette.light, t) ??
            palette.light,
        pale: Color.lerp(palette.pale, other.palette.pale, t) ?? palette.pale,
        wash: Color.lerp(palette.wash, other.palette.wash, t) ?? palette.wash,
        line: Color.lerp(palette.line, other.palette.line, t) ?? palette.line,
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
