import 'package:flutter/material.dart';

import '../../theme.dart';

/// 搜索历史列表：编辑页「笔记内搜索」浮层与首页列表搜索框共用。
///
/// 每行 = 历史项（历史图标 + 关键词 + 右侧删除），最底部固定「全部清除」。
///
/// 列表区需要父级给出**有界高度**：编辑页用 Expanded、首页浮层用
/// 固定高度容器（高度由 [preferredHeightFor] 推导）。
class SearchHistoryList extends StatelessWidget {
  const SearchHistoryList({
    super.key,
    required this.entries,
    required this.onPick,
    required this.onRemove,
    required this.onClearAll,
    this.roundFirstItem = true,
  });

  /// 历史条目（最新的在前）。
  final List<String> entries;

  /// 点击某条历史：填入搜索框并执行搜索。
  final ValueChanged<String> onPick;

  /// 删除某条历史。
  final ValueChanged<String> onRemove;

  /// 清空全部历史。
  final VoidCallback onClearAll;

  /// 首行 hover 是否带顶部圆角。仅当列表**直接贴到**浮层/弹窗顶部圆角时
  /// 需要（首页历史浮层无顶部内边距，首行直角会在玻璃圆角处露出直角）；
  /// 列表上方有其他内容（编辑页顶部是搜索框，首行不接触圆角）时传 false，
  /// 那里矩形 hover 更自然——该一致的一致（hover 撑满），该单独适配的
  /// 单独（首行圆角按场景决定）。
  final bool roundFirstItem;

  /// 单行高度（固定行高：首页据此推导浮层总高，避免留白或裁掉半行；
  /// 37 = 用户确认每条下间距再收 3px，列表更紧凑）。
  static const double itemExtent = 37;

  /// 底部「全部清除」区高度（文字按钮，无分隔线）。
  static const double footerExtent = 36;

  /// 列表 + 底部的总高（首页浮层按条目数推导面板高度）。
  static double preferredHeightFor(int count) =>
      count * itemExtent + footerExtent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemExtent: itemExtent,
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              // 透明 Material 提供「面板背景之上」的 ink 画布：hover/splash
              // 若画在外层 Material 上，会被玻璃面板的半透明背景（深色白
              // 10%）罩住——白 12% 叠在白 10% 之下几乎看不出（用户反馈
              // hover「特别虚、很不明显」）。TextButton 因内部自带 Material
              // 而在背景之上、看起来明显；这里给历史行补上同款结构。
              return Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => onPick(entry),
                  // 深色下 M3 默认 hover 只有白 8%，几乎看不见：显式增强
                  // 到白 12%（亮色维持黑 8% 默认观感，用户未抱怨）。
                  hoverColor: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.black.withValues(alpha: 0.08),
                  // 首行贴浮层顶部圆角：默认矩形 hover 会在玻璃面板圆角处
                  // 露出直角（首页浮层无顶部内边距，第一条直接顶到圆角）。
                  // 编辑页传 roundFirstItem: false（列表上方是搜索框，首行
                  // 不接触圆角，不需要适配）。
                  borderRadius: (roundFirstItem && index == 0)
                      ? const BorderRadius.vertical(
                          top: Radius.circular(kAppRadius),
                        )
                      : null,
                  child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(Icons.history, size: 16, color: muted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // 历史条目比正文小一号，整体更紧凑。
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      // 单项删除：右对齐固定槽位（30px 触控区，行内居中）。
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          iconSize: 16,
                          tooltip: '删除这条历史',
                          icon: Icon(Icons.close, color: muted),
                          onPressed: () => onRemove(entry),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
            },
          ),
        ),
        SizedBox(
          height: footerExtent,
          child: Column(
            children: [
              // 按钮区块沉底（Spacer 在上）：贴到弹窗底边。用户确认
              // 去掉「全部清除」上方的分隔线，列表与按钮区之间留白区分。
              const Spacer(),
              // 厚度说明：桌面端 VisualDensity.compact 会把按钮 padding 上下各
              // 减去 8px（baseSizeAdjustment = density*4），导致之前 vertical 4
              // 在 mac 上被完全抵消（hover 背景与文字等高）。显式指定 standard
              // 让 padding 在所有平台一致生效；vertical 6 → 背景比文字上下各
              // 多 6px（按钮总高 28px，明显「厚」但不夸张）。
              TextButton.icon(
                onPressed: onClearAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.standard,
                ),
                icon: Icon(Icons.delete_sweep_outlined, size: 16, color: muted),
                label: Text(
                  '全部清除',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
