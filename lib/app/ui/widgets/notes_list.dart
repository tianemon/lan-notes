import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/note.dart';
import '../../repository/providers.dart';
import '../../theme.dart';
import 'empty_hint.dart';
import 'format.dart';
import 'glass_style.dart';

/// 笔记列表：消费 [notesStreamProvider]，按 updatedAt 倒序渲染。
///
/// 数据流见 docs/技术架构.md 第 6 节：UI 只消费流，写库一律走
/// NoteRepository，drift 流自动驱动刷新。
///
/// 布局（task-26，多列错落）：消费 [layoutModeProvider]——
/// - 单列：ListView.builder 保持虚拟滚动；
/// - 双列/四列：SingleChildScrollView + Row + Expanded 多路拆列
///   （i % columns 拆列，参考 EE _buildGrid），列内瀑布流错落。
///
/// 动效（task-25）：
/// - 空态 ↔ 列表切换经 AnimatedSwitcher 淡入 + 上移；
/// - 列表项新增/恢复由 [NoteListItem] 自带动画（按 ValueKey 匹配元素，
///   滚动复用不重复动画，见 _NoteListItemState）。
class NotesList extends ConsumerWidget {
  const NotesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(notesStreamProvider);
    final isSearching = ref.watch(searchQueryProvider).trim().isNotEmpty;
    final layoutMode = ref.watch(layoutModeProvider);

    return notesAsync.when(
      // 搜索关键字变化（provider 因 watch 重建）时沿用旧数据，避免输入过程闪 loading
      skipLoadingOnReload: true,
      data: (notes) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          // 默认 Stack 对齐是 center：多列列表内容不足时会被垂直居中。
          // 改为顶对齐（列表从顶部开始）；空态内部自行居中（见 _EmptyState）。
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: [
              ...previousChildren,
              ?currentChild,
            ],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: notes.isEmpty
              ? _EmptyState(
                  key: const ValueKey('empty'),
                  isSearching: isSearching,
                )
              : _NoteListBody(
                  key: const ValueKey('list'),
                  notes: notes,
                  columns: layoutMode,
                ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('加载失败：$error')),
    );
  }
}

/// 列表主体：按布局模式渲染单列列表或双列/四列瀑布流。
///
/// 滚动本身不叠加动画（见 NoteListItem 说明）；切换布局模式时本组件
/// 同 key 重建（不触发 AnimatedSwitcher），布局即时切换。
class _NoteListBody extends StatelessWidget {
  const _NoteListBody({
    super.key,
    required this.notes,
    required this.columns,
  });

  final List<Note> notes;

  /// 布局模式：1=单列 / 2=双列 / 4=四列。
  final int columns;

  /// 底部留白：容纳悬浮的毛玻璃新建按钮（EE _buildFrostedFab），
  /// 滚动到底部最后一张卡片不被 FAB 遮挡。
  static const double _fabSpacing = 88;

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, _fabSpacing),
        itemCount: notes.length,
        itemBuilder: (context, index) {
          final note = notes[index];
          // 外层 key：列表元素按笔记 id 匹配——滚动复用同一元素（不重复
          // 动画），新增/恢复创建新元素（触发入场动画）。
          return NoteListItem(key: ValueKey(note.id), note: note);
        },
      );
    }
    return _buildGrid(context);
  }

  /// 多列瀑布流：SingleChildScrollView + Row + Expanded 多路拆列
  /// （参考 EE _buildGrid：i % columns 拆列，列间错落）。
  Widget _buildGrid(BuildContext context) {
    final columnIndices = List.generate(columns, (_) => <int>[]);
    for (var i = 0; i < notes.length; i++) {
      columnIndices[i % columns].add(i);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, _fabSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < columns; c++) ...[
            if (c > 0) const SizedBox(width: 10),
            Expanded(child: _buildGridColumn(context, columnIndices[c])),
          ],
        ],
      ),
    );
  }

  Widget _buildGridColumn(BuildContext context, List<int> indices) {
    // 摘要行数适配：四列窄卡片 1 行，双列 2 行（与单列一致）。
    final maxSummaryLines = columns >= 4 ? 1 : 2;
    return Column(
      children: [
        for (final i in indices) ...[
          NoteListItem(
            key: ValueKey(notes[i].id),
            note: notes[i],
            maxSummaryLines: maxSummaryLines,
          ),
          // 卡片自身垂直 6+6 间距，再加 4 凑近 EE 12px 列间距。
          const SizedBox(height: 4),
        ],
      ],
    );
  }
}

/// 单个笔记卡片项：点击进入编辑；左滑或长按菜单可「移到回收站」（软删除，
/// 见 [NoteRepository.softDeleteNote]）；长按菜单另有「置顶/取消置顶」
/// （task-28，见 [NoteRepository.setPinned]）。置顶笔记标题右侧显示小图钉。
///
/// 卡片风格（task-25，EE 式）：圆角 16 + 柔和阴影（黑 6% + blur20 +
/// offset(0,8)）+ 玻璃模拟装饰（[GlassCard]）；布局三段式——标题 16bold
/// （无标题兜底）+ 摘要 13 灰（[maxSummaryLines] 行截断）+ 时间 11 outline。
class NoteListItem extends ConsumerStatefulWidget {
  const NoteListItem({
    super.key,
    required this.note,
    this.maxSummaryLines = 2,
  });

  final Note note;

  /// 摘要最大行数：单列/双列 2 行、四列 1 行（窄列适配，task-26）。
  final int maxSummaryLines;

  @override
  ConsumerState<NoteListItem> createState() => _NoteListItemState();
}

class _NoteListItemState extends ConsumerState<NoteListItem> {
  /// 入场动画标记：元素首次构建（新增/恢复）时播放淡入 + 上移；
  /// 滚动复用（同 id 元素重建，ValueKey 保证不换笔记）不重复动画。
  bool _animateIn = true;

  @override
  void didUpdateWidget(NoteListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 理论不会发生（外层 ValueKey 已按 id 匹配元素）；防御性兜底：
    // 元素被复用于另一条笔记时重新触发入场动画。
    if (oldWidget.note.id != widget.note.id) {
      _animateIn = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_animateIn) {
      return _buildItem(context);
    }
    // 淡入 + 上移（320ms，easeOutCubic），播放完毕移除包装（_animateIn=false）
    // 使滚动复用路径零动画开销。
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (mounted) setState(() => _animateIn = false);
      },
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: _buildItem(context),
    );
  }

  Widget _buildItem(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final note = widget.note;
    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        // 撑满列宽：多列布局（Column）中卡片不收缩到内容宽度，
        // 保证双列/四列等宽对齐（EE 卡片 width: double.infinity 同款）。
        width: double.infinity,
        child: Dismissible(
          key: ValueKey(note.id),
          direction: DismissDirection.endToStart,
          background: const _DeleteBackground(),
          confirmDismiss: (_) => _confirmDelete(context),
          onDismissed: (_) {
            // 删除已在 confirmDismiss 中完成，列表经 drift 流自动移除该项。
          },
          child: GestureDetector(
            // 桌面右键：弹统一笔记菜单（在鼠标位置）。
            onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
            child: GlassCard(
            heroTag: null,
            // 卡片宽度恒定：关闭 hover 缩放（EE 卡片无 hover 效果，
            // 悬停放大 1.2% 会被感知为宽度不一致）。
            hoverLift: false,
            onTap: () => context.push('/editor/${note.id}'),
            // 长按（手机端主入口）：统一笔记菜单（定位卡片底部）。
            onLongPress: () => _showContextMenu(context, null),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              // 标题行：16 bold（无标题兜底）+ 置顶小图钉（task-28）
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (note.isPinned)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.push_pin,
                        size: 14,
                        color: colorScheme.primary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // 摘要：13 灰，按布局模式截断（单列/双列 2 行、四列 1 行）
              Text(
                excerptOf(note.content),
                maxLines: widget.maxSummaryLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              // 时间：11 outline
              Text(
                relativeTime(note.updatedAt),
                style: TextStyle(fontSize: 11, color: colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      ),
      ),
    );
  }

  /// 统一笔记菜单（桌面右键 / 手机长按共用）：置顶/取消置顶 + 移到回收站。
  ///
  /// 自定义 Overlay 弹层：菜单项 hover/涟漪圆角贴合容器——首项上圆角、
  /// 末项下圆角、中间直角（单选项则全圆角）；宽度自适应内容（不固定）。
  /// 定位：右键在鼠标位置（[tapGlobal]）；长按在卡片底部中心（null）。
  /// 点外部 / 选中动作即关闭。
  Future<void> _showContextMenu(
    BuildContext context,
    Offset? tapGlobal,
  ) async {
    if (!context.mounted) return;
    final note = widget.note;
    final overlay = Overlay.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1B2838) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    const itemHeight = 34.0;
    const radius = 12.0;
    final pinLabel = note.isPinned ? '取消置顶' : '置顶';
    final deleteLabel = '删除';
    // 共享项宽：用 TextPainter 量最长文案宽度（icon+gap+文字+内边距），
    // 所有菜单项同宽 → hover 一致；宽度真实自适应内容。
    // 注意：不能用 Column crossAxisAlignment.stretch——Overlay 里菜单是
    // 无约束（w=Infinity），stretch 无从取宽会布局断言崩溃（曾导致右键卡死）。
    final itemWidth = _menuItemWidth([
      pinLabel.length >= deleteLabel.length ? pinLabel : deleteLabel,
    ]);
    late final OverlayEntry overlayEntry;
    // 菜单项（动作统一不进闭包外，避免重复：置顶 / 移到回收站）。
    final items = <Widget>[
      _MenuButton(
        width: itemWidth,
        height: itemHeight,
        radius: BorderRadius.vertical(top: Radius.circular(radius)),
        icon: note.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: pinLabel,
        onTap: () {
          overlayEntry.remove();
          _setPinned(!note.isPinned);
        },
      ),
      _MenuButton(
        width: itemWidth,
        height: itemHeight,
        radius: BorderRadius.vertical(bottom: Radius.circular(radius)),
        icon: Icons.delete_outline,
        label: deleteLabel,
        labelColor: Theme.of(context).colorScheme.error,
        iconColor: Theme.of(context).colorScheme.error,
        onTap: () {
          overlayEntry.remove();
          _confirmDelete(context);
        },
      ),
    ];
    final menuH = items.length * itemHeight;
    final screen = MediaQuery.sizeOf(context);
    // 定位：右键用鼠标位置；长按用卡片底部中心。left 用估算菜单宽度 clamp。
    final box = context.findRenderObject() as RenderBox?;
    final cardBottom = box == null
        ? null
        : (box.localToGlobal(Offset.zero) & box.size).bottomCenter;
    final anchor = tapGlobal ?? cardBottom ?? Offset.zero;
    const estWidth = 148.0;
    var left = anchor.dx - 8;
    var top = anchor.dy + 6;
    left = left.clamp(8.0, screen.width - estWidth - 8);
    top = top.clamp(8.0, screen.height - menuH - 8);

    overlayEntry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // ModalBarrier：官方遮罩（非全屏 translucent GestureDetector），
          // 正确管理 pointer/hover 生命周期，点击外部关闭——避免
          // overlay 出现时 mouse_tracker hit test 0 尺寸渲染盒导致卡死。
          Positioned.fill(
            child: ModalBarrier(
              dismissible: true,
              onDismiss: () => overlayEntry.remove(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                // 所有项已共享同一宽度（_menuItemWidth 测得），
                // 无需 stretch（Overlay 无约束下 stretch 会布局崩溃）。
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: items,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(overlayEntry);
  }

  /// 计算菜单项宽度：icon(16) + gap(10) + 最长文字宽 + 左右内边距(14*2)。
  double _menuItemWidth(List<String> labels) {
    final longest = labels.reduce((a, b) => a.length >= b.length ? a : b);
    final tp = TextPainter(
      text: TextSpan(text: longest, style: const TextStyle(fontSize: 13)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    // +4 余量：TextPainter 测量与真实渲染有亚像素差（曾 0.8px 溢出）。
    return (14 * 2 + 16 + 10 + tp.width + 4).ceilToDouble();
  }

  /// 置顶/取消置顶（task-28）：翻转置顶状态并持久化（version+1 随同步）。
  Future<void> _setPinned(bool pinned) async {
    await ref
        .read(noteRepositoryProvider)
        .setPinned(widget.note.id, pinned);
  }

  /// 弹出「移到回收站」玻璃确认框；确认后调 [noteRepositoryProvider]
  /// .softDeleteNote 软删除，返回 true 供 Dismissible 完成滑出动画
  /// （长按删除时返回值被忽略）。
  Future<bool> _confirmDelete(BuildContext context) async {
    final title = widget.note.title.trim().isEmpty
        ? '无标题'
        : widget.note.title.trim();
    final confirmed = await showGlassDialog<bool>(
      context: context,
      title: const Text('移到回收站'),
      content: Text('将「$title」移到回收站吗？可在回收站中恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('移到回收站'),
        ),
      ],
    );
    if (confirmed != true) {
      return false;
    }
    await ref.read(noteRepositoryProvider).softDeleteNote(widget.note.id);
    return true;
  }
}

/// 左滑露出的删除背景（玻璃卡片风格：圆角 16 与卡片一致，柔和阴影）。
class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: const BorderRadius.all(Radius.circular(kAppRadius)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
    );
  }
}

/// 空态：区分「还没有笔记」与「搜索无结果」两种引导（图标 + 淡入）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    final icon = isSearching ? Icons.search_off : Icons.edit_note;
    final title = isSearching ? '未找到相关笔记' : '还没有笔记';
    final subtitle = isSearching ? '换个关键词试试' : '点击右下角 + 新建第一条笔记';

    return SizedBox(
      // 撑满可用高度：空态内容垂直居中（列表态由 AnimatedSwitcher
      // topCenter 对齐顶置，空态在此内部居中）。
      height: double.infinity,
      child: Center(child: EmptyHint(icon: icon, title: title, subtitle: subtitle)),
    );
  }
}

/// 菜单按钮（自定义右键菜单项）：InkWell hover 圆角贴合菜单容器——
/// 单选项全圆角，多选项首项上圆角、末项下圆角、中间直角（调用方传入）。
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.width,
    required this.height,
    required this.radius,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.labelColor,
  });

  final double width;
  final double height;
  final BorderRadius radius;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inkIcon = iconColor ?? colorScheme.onSurface;
    final inkLabel = labelColor ?? colorScheme.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius, // hover 圆角贴合容器（首/末/单项圆角、中间直角）。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: width,
            minHeight: height,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: inkIcon),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(fontSize: 13, color: inkLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
