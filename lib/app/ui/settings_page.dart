import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../repository/providers.dart';
import '../theme.dart';
import 'widgets/section_label.dart';

/// 设置页：分组列表（参照 EE settings_screen 风格，task-26）。
///
/// - **外观**：主题三档切换（跟随系统 / 亮 / 暗）——EE 式滑动分段滑块
///   （照搬 EE settings_screen._ThemeSlider：支持点击 + 横向拖拽）；
///   选择写入 [themeModeNotifier] 并持久化（[AppSettingsStore]），
///   启动时由 main.dart 恢复；
/// - **设备**：同步设置（push `/sync`）、回收站（push `/trash`）、
///   设备设置（复用同步页 [DeviceSettingsDialog]——设备名/连接密码/
///   自动同步/重置设备 ID，避免重复实现）。
///
/// 分组标题样式照搬 EE（13px outline 色标签，[SectionLabel] 共享组件）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  /// 主题档位 → ThemeMode：0=亮 / 1=暗 / 2=跟随系统（与 EE 顺序一致）。
  ThemeMode _modeOf(int index) => switch (index) {
        0 => ThemeMode.light,
        1 => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  int _indexOf(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 0,
        ThemeMode.dark => 1,
        ThemeMode.system => 2,
      };

  void _onThemeChanged(BuildContext context, WidgetRef ref, int index) {
    final mode = _modeOf(index);
    themeModeNotifier.value = mode; // 立即生效
    ref.read(appSettingsProvider).setThemeMode(mode); // 持久化
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ValueListenableBuilder 监听主题模式：设置页内切换主题即时重建滑块
    // （Riverpod ref.watch 不支持直接 watch ValueNotifier）。
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (context, themeMode, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // ---- 外观组 ----
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: SectionLabel('外观'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _ThemeSlider(
                value: _indexOf(themeMode),
                onChanged: (index) => _onThemeChanged(context, ref, index),
              ),
            ),
            const SizedBox(height: 24),
            // ---- 设备组 ----
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: SectionLabel('设备'),
            ),
            ListTile(
              leading: const Icon(Icons.sync_alt),
              title: const Text('同步设置'),
              subtitle: const Text('设备发现、连接与数据同步管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/sync'),
            ),
            ListTile(
              leading: const Icon(Icons.restore_from_trash_outlined),
              title: const Text('回收站'),
              subtitle: const Text('查看与恢复已删除的笔记'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/trash'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// 主题三档滑块：☀️ 浅色 / 🌙 深色 / 自动（照搬 EE settings_screen
/// `_ThemeSlider`：拖拽滑动 + 点击分段，滑块 AnimatedPositioned 平滑过渡，
/// 选中项主色高亮；底色/滑块色随主题自适应）。
class _ThemeSlider extends StatefulWidget {
  const _ThemeSlider({required this.value, required this.onChanged});

  /// 当前档位：0=浅色 / 1=深色 / 2=自动。
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_ThemeSlider> createState() => _ThemeSliderState();
}

class _ThemeSliderState extends State<_ThemeSlider> {
  // 拖拽过程中的临时位置（0.0~2.0），null 表示没在拖。
  double? _dragValue;

  static const _items = [
    (Icons.wb_sunny_rounded, '浅色'),
    (Icons.nightlight_round, '深色'),
    (Icons.brightness_auto_rounded, '自动'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 底色/滑块色沿用 EE 配色（与项目暗夜蓝/灰白令牌一致）。
    final bgColor = isDark ? kDarkCard : const Color(0xFFF0F0F0);
    final thumbColor = isDark ? const Color(0xFF2A3A4A) : Colors.white;
    final accent = isDark ? kDarkAccent : kLightAccent;

    // 当前显示位置：拖拽中用 _dragValue，否则用 widget.value。
    final displayValue = _dragValue ?? widget.value.toDouble();

    return LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      const height = 52.0;
      const padding = 4.0;
      final segmentWidth = (totalWidth - padding * 2) / 3;
      final thumbWidth = segmentWidth - 2;
      final thumbLeft = padding + 1 + displayValue * segmentWidth;

      return GestureDetector(
        onHorizontalDragStart: (details) {
          setState(() => _dragValue = widget.value.toDouble());
        },
        onHorizontalDragUpdate: (details) {
          if (_dragValue == null) return;
          final newVal = _dragValue! + details.delta.dx / segmentWidth;
          setState(() => _dragValue = newVal.clamp(0.0, 2.0));
        },
        onHorizontalDragEnd: (details) {
          if (_dragValue == null) return;
          final snapped = _dragValue!.round().clamp(0, 2);
          setState(() => _dragValue = null);
          widget.onChanged(snapped);
        },
        child: AnimatedContainer(
          // 颜色过渡与全局主题动画（350ms）同步，切换时平滑渐变
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOutCubic,
          height: height,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Stack(children: [
            // 滑动滑块背景
            AnimatedPositioned(
              duration: _dragValue != null
                  ? Duration.zero
                  : const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              left: thumbLeft,
              top: padding,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOutCubic,
                width: thumbWidth,
                height: height - padding * 2,
                decoration: BoxDecoration(
                  color: thumbColor,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            // 三个选项：图标 + 文案（选中主色高亮）
            Row(children: List.generate(3, (i) {
              final selected = widget.value == i;
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onChanged(i),
                  child: SizedBox(
                    height: height,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(_items[i].$1,
                            size: 18,
                            color: selected ? accent : Colors.grey),
                        const SizedBox(width: 4),
                        Text(_items[i].$2,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: selected ? accent : Colors.grey,
                            )),
                      ],
                    ),
                  ),
                ),
              );
            })),
          ]),
        ),
      );
    });
  }
}
