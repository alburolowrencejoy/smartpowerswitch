import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/institute_colors.dart';

/// Which title size the top bar renders (handoff §3.4 / preview
/// `.topbar h1` variants).
enum AppTopBarVariant {
  /// 24/30 weight 700. Default for root tabs other than Home.
  standard,

  /// 19/24 weight 700. Pushed/back screens (Device detail, Schedule editor,
  /// Notifications, Users, Settings, Building, ...) -- preview
  /// `.topbar.small`.
  small,

  /// 30/36 weight 700, with a 15/20 subtitle. Home only -- preview
  /// `.dev .topbar.big`.
  big,
}

/// A generic icon action in the top bar's action row (bell, more, custom
/// icons like `link_off`/`delete`/`delete_sweep` on device/schedule/
/// notifications screens).
class AppTopBarAction {
  const AppTopBarAction({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.badgeCount,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  /// When set and > 0, draws the warning-colored count badge (handoff
  /// preview `.icon-btn .badge`) -- used for the notification bell.
  final int? badgeCount;
}

/// The redesign's top bar (handoff §2/§3.4, preview `topbar()` render
/// function): white background, a 1px hairline bottom border, title left
/// (+ optional subtitle), a back arrow on pushed screens, trailing icon
/// actions (e.g. bell with an unread-count badge), and an optional avatar
/// that navigates to "More".
///
/// Institute-admin screens additionally get a 3px institute-color line
/// under the bar and an institute-tinted title (preview:
/// `[class*="theme-"] .topbar{box-shadow:inset 0 -3px 0 var(--*-mid)}`,
/// title colored with the institute's 700 [InstitutePalette.dark]) --
/// controlled by [showInstituteLine].
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.variant = AppTopBarVariant.standard,
    this.showBackButton = false,
    this.onBack,
    this.actions = const [],
    this.showAvatar = false,
    this.avatarInitials,
    this.onAvatarTap,
    this.showInstituteLine = false,
    this.palette,
  });

  final String title;
  final String? subtitle;
  final AppTopBarVariant variant;
  final bool showBackButton;
  final VoidCallback? onBack;
  final List<AppTopBarAction> actions;
  final bool showAvatar;
  final String? avatarInitials;
  final VoidCallback? onAvatarTap;
  final bool showInstituteLine;
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final titleStyle = _titleStyle.copyWith(
      color: showInstituteLine ? resolvedPalette.dark : AppColors.ink,
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: showInstituteLine ? resolvedPalette.mid : resolvedPalette.line,
            width: showInstituteLine ? 3 : 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            showBackButton ? 4 : 16,
            variant == AppTopBarVariant.big ? 10 : 8,
            8,
            variant == AppTopBarVariant.big ? 14 : 12,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (showBackButton)
                _IconBtn(
                  icon: Icons.arrow_back,
                  onTap: onBack ?? () => Navigator.of(context).maybePop(),
                  tooltip: 'Back',
                ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: showBackButton ? 4 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                      if (subtitle != null)
                        Padding(
                          padding: EdgeInsets.only(
                            top: variant == AppTopBarVariant.big ? 2 : 0,
                          ),
                          child: Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: (variant == AppTopBarVariant.big
                                    ? AppTextStyles.dashboardDate
                                    : AppTextStyles.bodySm)
                                .copyWith(color: AppColors.inkMuted),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              for (final action in actions)
                _IconBtn(
                  icon: action.icon,
                  onTap: action.onTap,
                  tooltip: action.tooltip,
                  badgeCount: action.badgeCount,
                ),
              if (showAvatar)
                _Avatar(
                  initials: avatarInitials ?? '',
                  palette: resolvedPalette,
                  onTap: onAvatarTap,
                ),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle get _titleStyle {
    switch (variant) {
      case AppTopBarVariant.standard:
        return AppTextStyles.topBarTitle;
      case AppTopBarVariant.small:
        return AppTextStyles.topBarTitleSmall;
      case AppTopBarVariant.big:
        return AppTextStyles.dashboardTitle;
    }
  }

  double get _contentHeight {
    final titleLineHeight = switch (variant) {
      AppTopBarVariant.standard => 30.0,
      AppTopBarVariant.small => 24.0,
      AppTopBarVariant.big => 36.0,
    };
    final subtitleHeight = subtitle == null
        ? 0.0
        : (variant == AppTopBarVariant.big ? 20.0 + 2 : 20.0);
    final verticalPadding = variant == AppTopBarVariant.big ? 10 + 14 : 8 + 12;
    // The outer Container's BoxDecoration carries a bottom Border (see
    // build()). BoxDecoration.padding reports that border's width, and
    // Container folds it into the effective padding it applies internally
    // (Container._addedPadding), on top of the explicit Padding below. That
    // silently eats `borderWidth` px from this height budget unless it's
    // added back in here, which used to cause a RenderFlex overflow of
    // exactly 1px (or 3px with showInstituteLine) on every AppTopBar.
    final borderWidth = showInstituteLine ? 3.0 : 1.0;
    return titleLineHeight + subtitleHeight + verticalPadding + borderWidth;
  }

  @override
  Size get preferredSize => Size.fromHeight(_contentHeight);
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.badgeCount,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    final hasBadge = (badgeCount ?? 0) > 0;
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon, color: AppColors.ink),
          if (hasBadge)
            Positioned(
              top: -4,
              right: -6,
              child: Container(
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: AppColors.warning,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  badgeCount! > 99 ? '99+' : '$badgeCount',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 20 / 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, required this.palette, this.onTap});

  final String initials;
  final InstitutePalette palette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: palette.mid, width: 1.5),
          ),
          child: Text(
            initials,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: palette.dark,
            ),
          ),
        ),
      ),
    );
  }
}
