import 'package:flutter/material.dart';

/// 设置弹窗/设置页分组标题（小号 outline 色标签，EE 风格 13px）。
///
/// 同步页设备设置弹窗与设置页（settings_page.dart）共用，避免重复实现
/// （task-26）。默认仅底部间距（弹窗内使用）；设置页用外层 Padding
/// 补横向/顶部间距。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 13,
          color: theme.colorScheme.outline,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
