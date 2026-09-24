import 'package:flutter/material.dart';

/// Palette for the web sign-in screen (see the login handoff spec).
/// One deep green carries the brand; [energy] is reserved for "on / live"
/// signals and the primary button on dark. Never use [energy] as text on
/// white.
class SpsColors {
  SpsColors._();

  static const ground = Color(0xFFFFFFFF);
  static const brand = Color(0xFF1B5E38);
  static const brandHover = Color(0xFF144A2C);
  static const energy = Color(0xFF4ADE80);
  static const energyHover = Color(0xFF6BE899);
  static const ink = Color(0xFF0F3321);
  static const onEnergy = Color(0xFF0B2E1B);
  static const muted = Color(0xFF2F5A42);
  static const onCardMuted = Color(0xFFB7DCC5);
  static const fieldHover = Color(0xFF7FB897);
  static const errorBorder = Color(0xFFF97066);
  static const errorText = Color(0xFFFFB4AB);
  static const errorBannerBg = Color(0xFFFDECEA);
  static const errorBannerText = Color(0xFFB42318);
  static const successBannerBg = Color(0xFFDDF5E6);
}
