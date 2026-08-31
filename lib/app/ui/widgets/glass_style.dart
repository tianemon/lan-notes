import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme.dart';

// ============================================================
// 玻璃装饰（参考 EasyEdit ui_style.dart）
// ============================================================

/// 亮色玻璃模拟底色（滚列表用，不用 BackdropFilter）。
/// 暖白（#FDFCF9）：与亮色主题暖米白背景配套（用户确认：冷白→暖白）。
final Color _glassLookLight = const Color(0xFFFDFCF9).withValues(alpha: 0.88);

/// 暗色玻璃模拟底色（滚列表用）。
final Color _glassLookDark = const Color(0xFF1B2838);

/// Minimal 级——玻璃模拟（可滚动列表卡片，不用 BackdropFilter）。
///
/// 半透底色 + 细边框 + 柔和阴影（黑 6% + blur20 + offset(0,8)）模拟玻璃感，
/// 零 GPU 开销（列表滚动不触发模糊）。
BoxDecoration styledListDecoration({
  required bool isDark,
  double radius = kAppRadius,
}) {
  return BoxDecoration(
    color: isDark ? _glassLookDark : _glassLookLight,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.4),
      width: 0.5,
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.06),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

/// Premium 级——液态玻璃（静态面：弹窗、菜单）。
///
/// 半透底色 + 细边框 + 柔和阴影；需配合 [glassWrap] 的 BackdropFilter
/// blur 20 使用（静态面不影响帧率）。
BoxDecoration styledDecoration({
  required bool isDark,
  double radius = kAppRadius,
  double alpha = 0.75,
}) {
  return BoxDecoration(
    color: isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.white.withValues(alpha: alpha),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.08),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

/// 配合 [styledDecoration] 使用的 BackdropFilter 包装器。
Widget glassWrap({
  required Widget child,
  double radius = kAppRadius,
  double blur = 20,
}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: child,
    ),
  );
}

// ============================================================
// 卡片工厂（全站统一卡片）
// ============================================================

/// 统一卡片：玻璃模拟装饰 + 可选点击涟漪（移动端 InkWell 默认）/
/// hover 微抬升（桌面 MouseRegion + AnimatedScale）。
///
/// - 装饰统一走 [styledListDecoration]（圆角 16 + 柔和阴影 + 玻璃模拟），
///   与列表/同步页卡片完全一致；
/// - [onTap] / [onLongPress] 提供时用 Material + InkWell 实现点击涟漪
///   （移动端默认交互）；桌面 hover 时微抬升（scale 1→1.012 + 阴影加深）；
/// - [heroTag] 提供时把整张卡片（含装饰）包进 Hero，供列表→编辑页
///   的 Hero 过渡使用（task-25）。
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding,
    this.radius = kAppRadius,
    this.hoverLift = true,
    this.heroTag,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry? padding;
  final double radius;

  /// 桌面 hover 微抬升（默认开启；仅桌面平台生效）。
  final bool hoverLift;

  /// Hero 标签：非空时整卡包进 Hero（列表→编辑页过渡，需与目标页同 tag）。
  final Object? heroTag;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  /// 桌面 hover 状态：驱动微抬升（scale + 阴影）。
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final decoration = styledListDecoration(
      isDark: isDark,
      radius: widget.radius,
    );

    Widget card = AnimatedScale(
      scale: _hovered ? 1.012 : 1.0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        // 撑满父级最大宽度：外层约束可能被转成 loose（卡片会收缩到内容
        // 宽度，宽度随文本变化），这里显式撑满保证所有卡片等宽
        // （EE 卡片 width: double.infinity 同款）。
        width: double.infinity,
        decoration: _hovered
            ? decoration.copyWith(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.09),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              )
            : decoration,
        child: Material(
          type: MaterialType.canvas,
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            borderRadius: BorderRadius.circular(widget.radius),
            child: Padding(
              padding: widget.padding ?? EdgeInsets.zero,
              child: widget.child,
            ),
          ),
        ),
      ),
    );

    // 桌面 hover 微抬升：仅对可点击卡片启用（无 onTap 的容器卡不响应指针）。
    if (widget.hoverLift && isDesktopPlatform && widget.onTap != null) {
      card = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: card,
      );
    }

    if (widget.heroTag != null) {
      card = Hero(tag: widget.heroTag!, child: card);
    }

    return card;
  }
}

// ============================================================
// 玻璃弹窗（弹窗/菜单用 styledDecoration + BackdropFilter blur 20）
// ============================================================

/// 统一玻璃弹窗：标题 + 内容 + 操作按钮。
///
/// 装饰走 [styledDecoration] + [glassWrap]（BackdropFilter blur 20），
/// 亮色白 75% 半透明、暗色白 10% 半透明，配细边框与柔和阴影。
class GlassDialog extends StatelessWidget {
  const GlassDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: glassWrap(
        child: Container(
          width: double.maxFinite,
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: styledDecoration(isDark: isDark),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle(
                style: Theme.of(
                  context,
                ).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w600),
                child: title,
              ),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: content)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一玻璃确认弹窗（showDialog 封装）：标题 + 内容 + 操作按钮。
///
/// 供列表删除/清空确认、同步页取消配对/重置 ID 确认等全站弹窗复用，
/// 替代散落的 AlertDialog（task-25 统一弹窗风格）。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required Widget title,
  required Widget content,
  required List<Widget> actions,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (_) =>
        GlassDialog(title: title, content: content, actions: actions),
  );
}

// ============================================================
// 精致开关（task-31：全站替换默认 Switch——更小、圆润、丝滑）
// ============================================================

/// 精致滑动开关：比默认 Switch 更紧凑（track 36×20、thumb 16），圆润造型
/// （track 全圆角、thumb 圆形），开关动画丝滑（AnimatedAlign easeOutCubic），
/// 支持亮暗色与禁用态。
///
/// 替代项目里默认 Switch（「有点胖」反馈，task-31），同步页设备行两个
/// 开关（手动连接/自动连接）垂直排列时也用它保持视觉统一。
class SlimSwitch extends StatefulWidget {
  const SlimSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.inactiveColor,
  });

  /// 当前开关状态。
  final bool value;

  /// 状态变更回调（null 时禁用交互）。
  final ValueChanged<bool>? onChanged;

  /// 开启时的轨道颜色（缺省用主题 primary）。
  final Color? activeColor;

  /// 关闭时的轨道颜色（缺省用主题 outlineVariant）。
  final Color? inactiveColor;

  @override
  State<SlimSwitch> createState() => _SlimSwitchState();
}

class _SlimSwitchState extends State<SlimSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  late final Animation<double> _anim = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    // initState 显式创建（非惰性）：消除 dispose 首次访问 late 字段
    // 触发创建的隐患（同 _StatusDot 模式）。
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.value ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(SlimSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.activeColor ?? scheme.primary;
    final inactive = widget.inactiveColor ?? scheme.outlineVariant;
    final enabled = widget.onChanged != null;

    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      label: '开关',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => widget.onChanged!(!widget.value) : null,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final trackColor = Color.lerp(inactive, active, _anim.value)!;
            final offset = _anim.value; // 0=左 1=右
            return Container(
              width: 36,
              height: 20,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: enabled ? trackColor : trackColor.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Align(
                alignment: Alignment(offset * 2 - 1, 0),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: enabled
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
