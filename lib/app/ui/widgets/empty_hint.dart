import 'package:flutter/material.dart';

/// 空态占位：图标 + 主文案 + 副文案（列表空态通用组件）。
///
/// 列表页（还没有笔记/搜索无结果）与回收站页（回收站是空的）共用，
/// 避免重复的空态布局代码。
///
/// task-25 增强：图标置于柔和圆形底上 + 淡入上移动画（450ms，
/// 仅首次构建播放一次）。
class EmptyHint extends StatefulWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  State<EmptyHint> createState() => _EmptyHintState();
}

class _EmptyHintState extends State<EmptyHint> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: child,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图标：柔和圆形底（表面色分层），主色描边
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                shape: BoxShape.circle,
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 40,
                color: colorScheme.primary.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 16),
            Text(widget.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              widget.subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
