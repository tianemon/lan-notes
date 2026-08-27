import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'navigation.dart';

// ============================================================
// 设计令牌（EE 风格，参考 EasyEdit ui_style.dart，task-25）
// ============================================================

/// 是否桌面平台（macOS / Windows / Linux）。
///
/// 桌面启用 hover 微抬升等指针交互（glass_style.dart）；也用于默认列表
/// 布局的平台区分——手机双列、桌面单列（task-26，见 AppSettingsStore）。
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 全局统一圆角。
const double kAppRadius = 16;

/// 亮色（暖米白，用户确认：从冷白调整——背景 #F7F5F0、强调色 #4F6EF7）。
const Color kLightBackground = Color(0xFFF7F5F0);
/// 亮色主题强调色（默认蓝；task-32 曾临时改黑，已恢复）。
const Color kLightAccent = Color(0xFF4F6EF7);

/// 亮色主题按钮图标/文字色（task-32：与强调色一致，蓝色）。
const Color kLightButtonForeground = Color(0xFF4F6EF7);
const Color kLightTextPrimary = Color(0xFF1D1B16);
const Color kLightTextSecondary = Color(0xFF6E6A63);

/// 亮色主题悬浮按钮玻璃底（FAB/扇形选项，用户确认：暖奶油色——
/// 比卡片 #FDFCF9 更暖（红蓝差 12）但比 #F5EFE3 亮，多次微调后
/// 取「浅一点点的暖」：与卡片拉开层次又不发灰发深）。
const Color kLightFabGlass = Color(0xFFFBF7EF);

/// 暗色（暗夜蓝）：背景 #0D1B2A、卡片 #1B2838、强调色 #5B9BD5。
const Color kDarkBackground = Color(0xFF0D1B2A);
const Color kDarkCard = Color(0xFF1B2838);
const Color kDarkFloating = Color(0xFF223344);
const Color kDarkAccent = Color(0xFF5B9BD5);
const Color kDarkTextPrimary = Color(0xFFE0E0E0);

/// 状态色（同步页设备状态点 / 成功提示等，跨亮暗一致）。
const Color kStatusConnected = Color(0xFF34C759); // 已连接：绿
const Color kStatusConnecting = Color(0xFFFF9500); // 连接中：橙
const Color kStatusDisconnected = Color(0xFF9AA0A6); // 未连接：灰

// ============================================================
// 表面分层（背景 / 卡片 / 浮层）
// ============================================================

/// 表面层级：背景（scaffold）/ 卡片（列表卡片）/ 浮层（弹窗/菜单）。
enum AppSurface { background, card, floating }

/// 取当前主题下的表面颜色。
///
/// - 亮色：背景暖米白 #F7F5F0、卡片暖白 90% 半透明、浮层暖白 95% 半透明；
/// - 暗色：背景 #0D1B2A、卡片 #1B2838、浮层 #223344（逐层提亮）。
Color appSurfaceColor(BuildContext context, AppSurface layer) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return switch (layer) {
    AppSurface.background => isDark ? kDarkBackground : kLightBackground,
    AppSurface.card => isDark
        ? kDarkCard
        : const Color(0xFFFDFCF9).withValues(alpha: 0.90),
    AppSurface.floating => isDark
        ? kDarkFloating
        : const Color(0xFFFDFCF9).withValues(alpha: 0.95),
  };
}

/// 阴影派生：从表面色向黑插值（非纯黑阴影，参考 EE ui_style.dart）。
Color shadowFromSurface(Color surface, {double strength = 0.12}) {
  return Color.lerp(surface, Colors.black, strength)!;
}

// ============================================================
// 主题模式（亮 / 暗 / 跟随系统）
// ============================================================

/// 全局主题模式通知器（main.dart 以 ValueListenableBuilder 接入
/// MaterialApp.themeMode，参考 EE app.dart 的 themeMode 处理）。
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

// ============================================================
// 页面转场（滑动 + 淡入，替代默认 Material 转场，task-25）
// ============================================================

/// 统一页面转场：新页从右侧轻微滑入并淡入（FadeThrough 的轻量变体）。
///
/// 经 MaterialApp.pageTransitionsTheme 全局生效；go_router 的
/// `builder:` 路由默认走 MaterialPage，自动套用此转场。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.05, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

// ============================================================
// 亮色主题
// ============================================================

ThemeData buildLightTheme() {
  final scheme = ColorScheme.light(
    primary: kLightAccent,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE4E8FF),
    onPrimaryContainer: const Color(0xFF2B3FA0),
    secondary: const Color(0xFF5B9BD5),
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFD8EAF9),
    onSecondaryContainer: const Color(0xFF1D4E73),
    tertiary: kStatusConnecting,
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFFFE8CC),
    onTertiaryContainer: const Color(0xFF7A4A00),
    error: const Color(0xFFE5484D),
    onError: Colors.white,
    errorContainer: const Color(0xFFFFE3E3),
    onErrorContainer: const Color(0xFF8A1F1F),
    surface: Colors.white,
    onSurface: kLightTextPrimary,
    onSurfaceVariant: kLightTextSecondary,
    outline: const Color(0xFF9C978F),
    outlineVariant: const Color(0xFFDCD7CE),
  ).copyWith(
    surfaceContainerLowest: const Color(0xFFFBFAF7),
    surfaceContainerLow: const Color(0xFFEDE9E2),
    surfaceContainer: const Color(0xFFE7E3DB),
    surfaceContainerHigh: const Color(0xFFE1DCD4),
    surfaceContainerHighest: const Color(0xFFDDD8D0),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kLightBackground,
    appBarTheme: AppBarTheme(
      backgroundColor: kLightBackground,
      foregroundColor: kLightTextPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: kLightTextPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kAppRadius)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 0.5,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFFFDFCF9).withValues(alpha: 0.94),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: kLightTextPrimary,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kLightButtonForeground,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: kLightButtonForeground,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFFFDFCF9).withValues(alpha: 0.96),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: scheme.onSurfaceVariant,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: AppPageTransitionsBuilder(),
        TargetPlatform.iOS: AppPageTransitionsBuilder(),
        TargetPlatform.macOS: AppPageTransitionsBuilder(),
        TargetPlatform.windows: AppPageTransitionsBuilder(),
        TargetPlatform.linux: AppPageTransitionsBuilder(),
        TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
      },
    ),
  );
}

// ============================================================
// 暗色主题（暗夜蓝）
// ============================================================

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.dark(
    primary: kDarkAccent,
    onPrimary: const Color(0xFF062033),
    primaryContainer: const Color(0xFF1A3A5C),
    onPrimaryContainer: const Color(0xFFB0D0F0),
    secondary: const Color(0xFF7FB3E0),
    onSecondary: const Color(0xFF0A2A40),
    secondaryContainer: const Color(0xFF1E3A52),
    onSecondaryContainer: const Color(0xFFB8D8F0),
    tertiary: kStatusConnecting,
    onTertiary: const Color(0xFF3A2400),
    tertiaryContainer: const Color(0xFF4A3008),
    onTertiaryContainer: const Color(0xFFFFD9A0),
    error: const Color(0xFFFF6B6B),
    onError: const Color(0xFF4A0A0A),
    errorContainer: const Color(0xFF5C1F1F),
    onErrorContainer: const Color(0xFFFFD0D0),
    surface: kDarkCard,
    onSurface: kDarkTextPrimary,
    onSurfaceVariant: const Color(0xFF9FB0C0),
    outline: const Color(0xFF6B7B8D),
    outlineVariant: const Color(0xFF2A3A4A),
  ).copyWith(
    surfaceContainerLowest: const Color(0xFF0A1520),
    surfaceContainerLow: kDarkCard,
    surfaceContainer: kDarkFloating,
    surfaceContainerHigh: const Color(0xFF263548),
    surfaceContainerHighest: const Color(0xFF2A3A4A),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kDarkBackground,
    appBarTheme: AppBarTheme(
      backgroundColor: kDarkBackground,
      foregroundColor: kDarkTextPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: kDarkTextPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kAppRadius)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 0.5,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: kDarkFloating,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2A3A4A),
      contentTextStyle: const TextStyle(color: kDarkTextPrimary, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: kDarkFloating,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: scheme.onSurfaceVariant,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: AppPageTransitionsBuilder(),
        TargetPlatform.iOS: AppPageTransitionsBuilder(),
        TargetPlatform.macOS: AppPageTransitionsBuilder(),
        TargetPlatform.windows: AppPageTransitionsBuilder(),
        TargetPlatform.linux: AppPageTransitionsBuilder(),
        TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
      },
    ),
  );
}

/// 兼容入口：默认亮色主题（main.dart 已改为 theme/darkTheme + themeMode）。
ThemeData buildAppTheme() => buildLightTheme();

// ============================================================
// 全局横幅通知（Overlay 自绘，不随页面切换移动）
// ============================================================

/// 全局横幅通知：Overlay 自绘浮动条，挂在根 Overlay 上（经
/// [rootNavigatorKey] 获取），**固定屏幕底部、不随页面切换移动**。
///
/// 之前用 ScaffoldMessenger（即使锚定根 key）——SnackBar 仍会显示在
/// 当前活跃 Scaffold 上，页面切换时重新锚定导致位置跳动（用户实测：
/// 配对通知在底部，返回首页后上移）。Overlay 方案彻底脱离 Scaffold。
///
/// 视觉对齐 SnackBar 主题（深色圆角条 + 浮出动画）。
///
/// 当前显示的横幅（OverlayEntry 生命周期管理）。
OverlayEntry? _appSnackBarEntry;

/// 横幅自动消失定时器。
Timer? _appSnackBarTimer;

/// 在根 Overlay 上弹横幅（固定底部，不随页面切换移动）。
void showAppSnackBar(String message, {Duration? duration}) {
  final overlay = rootNavigatorKey.currentState?.overlay;
  if (overlay == null) return; // 导航未挂载（启动早期）：跳过

  // 移除旧横幅（不等待动画，直接清）。
  _appSnackBarEntry?.remove();
  _appSnackBarEntry = null;
  _appSnackBarTimer?.cancel();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _AppSnackBarHost(message: message),
  );
  _appSnackBarEntry = entry;
  overlay.insert(entry);

  _appSnackBarTimer = Timer(duration ?? const Duration(seconds: 2), () {
    if (_appSnackBarEntry == entry) {
      entry.remove();
      _appSnackBarEntry = null;
    }
  });
}

/// 横幅本体：底部固定 + SafeArea + 浮出动画 + 自动消失后回调。
class _AppSnackBarHost extends StatefulWidget {
  const _AppSnackBarHost({required this.message});

  final String message;

  @override
  State<_AppSnackBarHost> createState() => _AppSnackBarHostState();
}

class _AppSnackBarHostState extends State<_AppSnackBarHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 对齐 SnackBar 主题外观（深色圆角条）。
    final bg = isDark ? const Color(0xFF2A3A4A) : kLightTextPrimary;
    final fg = isDark ? kDarkTextPrimary : Colors.white;

    return Positioned(
      left: 16,
      right: 16,
      // 固定底部：SafeArea 上沿 + 16（避开系统手势区，不随页面变化）。
      bottom: MediaQuery.paddingOf(context).bottom + 16,
      child: SafeArea(
        top: false,
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.4),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _controller,
              curve: Curves.easeOutCubic,
            )),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    widget.message,
                    style: TextStyle(fontSize: 14, color: fg),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
