import 'package:flutter/material.dart';

class AppColors {
  // Primary palette
  static const greenDark  = Color(0xFF1A5C35);
  static const greenMid   = Color(0xFF2E9E52);
  static const greenLight = Color(0xFF6ECB8A);
  static const greenPale  = Color(0xFFC2EDD0);

  // Text (original ramp -- still used by screens not yet migrated to the
  // mobile redesign's readability pass; left untouched so those screens
  // don't shift color underneath an unrelated change).
  static const textDark   = Color(0xFF0E2E1A);
  static const textMid    = Color(0xFF3A6B4A);
  static const textMuted  = Color(0xFF7AAA8A);

  // Text (mobile redesign tokens -- handoff §3.3. `ink` is the same hex as
  // [textDark]; kept as its own named constant so new code can spell it the
  // way the design doc does. `inkMid`/`inkMuted` are NEW, darker values
  // (contrast-driven fix for the old `textMid`/`textMuted`, which measured
  // 2.6:1 on white) -- deliberately added as new tokens rather than by
  // overwriting `textMid`/`textMuted` in place, since that would silently
  // recolor every screen still on the old ramp ahead of its own redesign
  // phase. New/redesigned screens should prefer `ink`/`inkMid`/`inkMuted`
  // over `textDark`/`textMid`/`textMuted`.
  static const ink         = Color(0xFF0E2E1A);
  static const inkMid      = Color(0xFF24402E);
  static const inkMuted    = Color(0xFF3A5344);
  static const placeholder = Color(0xFF51685A);
  static const disabledText = Color(0xFF9AAEA1);

  // Semantic
  static const white      = Color(0xFFFFFFFF);
  static const error      = Color(0xFFD64A4A);
  static const errorText  = Color(0xFFB42318);
  static const errorBg    = Color(0xFFFDECEA);
  static const warning    = Color(0xFFE8922A);
  static const warningText = Color(0xFFA15208);
  static const warningBg  = Color(0xFFFDF1E2);
  static const success    = Color(0xFF2E9E52);
  static const successText = Color(0xFF1F7A40);
  static const offline    = Color(0xFF9E9E9E);

  // Surface
  static const surface    = Color(0xFFF4FBF6);
  static const cardBg     = Color(0xFFFFFFFF);
  // Neutral 1px outline for cards, groups and separators on the white
  // mobile layout (handoff `--line`), and a neutral grey for loading
  // placeholders -- mobile screens use these instead of tinted fills.
  static const hairline   = Color(0xFFDCEBE1);
  static const skeleton   = Color(0xFFEDEFEE);
}
