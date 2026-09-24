/// The one typeface used across every screen (mobile, web, splash, login).
///
/// Bundled from `assets/fonts/` (see pubspec.yaml), so it renders the same
/// on every platform without a network fetch. Always refer to the font via
/// [AppFonts.family] -- never a string literal or `google_fonts` -- so the
/// app can't drift back into mixed fonts. `test/ui_conventions_test.dart`
/// enforces this.
class AppFonts {
  AppFonts._();

  static const family = 'Roboto';
}
