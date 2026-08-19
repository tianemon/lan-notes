import 'package:flutter/material.dart';

import '../data/device_dao.dart';
import '../theme.dart';

/// UI 设置键：列表布局模式（'1'=单列 / '2'=双列 / '4'=四列，task-26）。
const String kDeviceSettingLayoutMode = 'layout_mode';

/// UI 设置键：主题模式（'system' / 'light' / 'dark'，task-26）。
const String kDeviceSettingThemeMode = 'theme_mode';

/// 布局模式：单列横排。
const int kLayoutModeSingle = 1;

/// 布局模式：双列瀑布流。
const int kLayoutModeDouble = 2;

/// 布局模式：四列瀑布流。
/// 已废弃（四列模式取消）：仅保留用于旧持久化值兼容（4 → 按双列处理）。
const int kLayoutModeQuad = 4;

/// UI 设置存储：列表布局模式 + 主题模式的持久化（task-26）。
///
/// 存储走 DeviceSettings 键值表（与 [DeviceIdentityStore] 同表不同键，
/// 复用 DeviceDao.getSetting/setSetting，不引入 shared_preferences 依赖）；
/// 内存缓存提供同步读取，[ensureLoaded] 从数据库加载持久化值（幂等，
/// 模式同 [DeviceIdentityStore.ensureLoaded]，参考 EE SettingsService）。
///
/// - 布局模式：未持久化（首次运行）时返回平台默认——Android/iOS 双列、
///   macOS/Windows/Linux 单列（[defaultLayoutMode]）；
/// - 主题模式：默认跟随系统（ThemeMode.system），三档见设置页。
class AppSettingsStore {
  AppSettingsStore(this._dao);

  final DeviceDao _dao;

  /// null = 未持久化，使用平台默认布局。
  int? _layoutMode;
  ThemeMode _themeMode = ThemeMode.system;
  Future<void>? _loading;

  /// 当前布局模式（未持久化时返回平台默认：手机双列、桌面单列）。
  int get layoutMode => _layoutMode ?? defaultLayoutMode;

  /// 当前主题模式（默认跟随系统）。
  ThemeMode get themeMode => _themeMode;

  /// 平台默认布局：Android/iOS 双列，桌面（macOS/Windows/Linux）单列。
  static int get defaultLayoutMode =>
      isDesktopPlatform ? kLayoutModeSingle : kLayoutModeDouble;

  /// 从数据库加载持久化设置并缓存（幂等；返回的 Future 缓存复用）。
  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final layout = await _dao.getSetting(kDeviceSettingLayoutMode);
    final parsed = int.tryParse(layout ?? '');
    // 兼容旧值：四列已取消（kLayoutModeQuad=4 → 按双列 2 处理）。
    _layoutMode = (parsed == kLayoutModeQuad) ? kLayoutModeDouble : parsed;
    final theme = await _dao.getSetting(kDeviceSettingThemeMode);
    _themeMode = switch (theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  /// 设置列表布局模式并持久化（'1'/'2'）。
  Future<void> setLayoutMode(int mode) async {
    _layoutMode = mode;
    await _dao.setSetting(kDeviceSettingLayoutMode, '$mode');
  }

  /// 设置主题模式并持久化。
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _dao.setSetting(kDeviceSettingThemeMode, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }
}
