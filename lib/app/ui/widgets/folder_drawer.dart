import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/folder.dart';
import '../../data/note.dart';
import '../../repository/folder_repository.dart';
import '../../repository/providers.dart';
import '../../theme.dart';
import 'note_actions.dart';

/// 文件夹抽屉（task-32）：左侧滑出玻璃面板。
///
/// 结构：「全部」（固定置顶，不可操作，默认选中）→ 置顶区（内部可拖拽
/// 排序）→ 普通区（内部可拖拽排序）；跨区移动（置顶↔普通）走菜单
/// 「置顶/取消置顶」（与原型一致，见 temp/drafts/文件夹功能-交互规格.md）。
///
/// 打开状态由 [folderDrawerOpenProvider] / [folderDrawerByDragProvider]
/// 控制：按钮打开 = 带 backdrop；拖拽笔记进入左侧区域展开 = 无 backdrop
/// （drag-mode，拖拽时列表仍可穿透操作）。宽度 200px。
class FolderDrawer extends ConsumerWidget {
  const FolderDrawer({super.key});

  /// 抽屉宽度（用户确认：200px）。
  static const double width = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(folderDrawerOpenProvider);
    final byDrag = ref.watch(folderDrawerByDragProvider);
    final foldersAsync = ref.watch(foldersStreamProvider);
    final notesAsync = ref.watch(activeNotesStreamProvider);
    final selected = ref.watch(folderFilterProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 拖放注册表：子组件各自在 build 时注册 GlobalKey（register 幂等）。
    // 不在此处 reset()——FolderDrawer 每次 rebuild 会清空注册表，
    // 但 const 子组件（_NewFolderDropTarget）不随之重建、无法重新注册，
    // 导致 __new__ 被清掉后永远丢失（拖到按钮无反应的根因）。
    // stale 条目（已删除文件夹）由 rectOf 返回 null 自动跳过。
    final registry = ref.read(dropZoneRegistryProvider);

    final folders =
        foldersAsync.maybeWhen(data: (d) => d, orElse: () => const <Folder>[]);
    final notes =
        notesAsync.maybeWhen(data: (d) => d, orElse: () => const <Note>[]);
    // 各文件夹活跃笔记数（计数展示；folderId 指向已删除文件夹的笔记
    // 不属任何活跃文件夹，只计入「全部」）。
    final countOf = <String, int>{};
    for (final n in notes) {
      final fid = n.folderId;
      if (fid == null) continue;
      countOf[fid] = (countOf[fid] ?? 0) + 1;
    }
    final pinned = folders.where((f) => f.isPinned).toList();
    final normal = folders.where((f) => !f.isPinned).toList();

    return Stack(
      children: [
        // backdrop：仅按钮打开模式显示；点击外部收起。
        if (open && !byDrag)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(folderDrawerOpenProvider.notifier).state =
                  false,
            ),
          ),
        // 抽屉本体：AnimatedPositioned 滑入滑出（左对齐，宽 200）。
        AnimatedPositioned(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          left: open ? 0 : -width,
          top: 0,
          bottom: 0,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: Container(
              // 用户确认：抽屉不透明（取消半透明，见 task-32 反馈）。
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF223344)
                    : const Color(0xFFFDFCF9),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                // 顶部避让状态栏（Android/iOS 全屏覆盖组件必需）：
                // 背景仍铺满（Container 在 SafeArea 外层），内容下移。
                // 桌面平台 padding 为 0，无影响。
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  // 顶部虚线「+ 新建文件夹」拖放目标（常驻显示，
                  // 落点处理在 notes_list 拖拽收尾）。
                  const Padding(
                    padding: EdgeInsets.fromLTRB(10, 10, 10, 9),
                    child: _NewFolderDropTarget(),
                  ),
                  Expanded(
                    child: ListView(
                      // auto-scroll（拖拽到抽屉边缘自动滚动）：controller +
                      // 列表 key 由 DropZoneRegistry 持有，notes_list 拖拽时
                      // 取可视区域矩形判边缘并驱动滚动。
                      key: registry.drawerListKey,
                      controller: registry.drawerScroll,
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        // 「全部」：默认选中；可拖放落点（用户确认：样式
                        // 与普通文件夹一致、图标一致、可拖入=移出文件夹）。
                        _AllFolderDropTarget(
                          child: _FolderItem(
                            id: null,
                            name: '全部',
                            icon: Icons.folder_outlined,
                            count: notes.length,
                            selected: selected == null,
                            onTap: () {
                              ref
                                  .read(folderFilterProvider.notifier)
                                  .state = null;
                              ref
                                  .read(folderDrawerOpenProvider.notifier)
                                  .state = false;
                            },
                          ),
                        ),
                        if (pinned.isNotEmpty) ...[
                          const _SectionLabel('置顶'),
                          _ReorderZone(
                            key: const ValueKey('pinned'),
                            folders: pinned,
                            selected: selected,
                            countOf: countOf,
                            onReorder: (newOrder) => _reorderZone(
                              ref,
                              folders: folders,
                              zone: pinned,
                              newOrder: newOrder,
                            ),
                          ),
                        ],
                        if (normal.isNotEmpty) ...[
                          // 普通区标题已去掉（用户确认：普通文件夹与置顶
                          // 文件夹连续排列，不显示「文件夹」分区标签；
                          // 分区逻辑保留——置顶在前、普通在后，区内拖拽
                          // 排序、跨区走菜单置顶/取消置顶）。
                          _ReorderZone(
                            key: const ValueKey('normal'),
                            folders: normal,
                            selected: selected,
                            countOf: countOf,
                            onReorder: (newOrder) => _reorderZone(
                              ref,
                              folders: folders,
                              zone: normal,
                              newOrder: newOrder,
                            ),
                          ),
                        ],

                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
  }

  /// 区内拖拽重排：把 [zone] 换成 [newOrder]，与另一区原顺序组装完整
  /// 列表（置顶区在前），按位置归一化 sortOrder（[FolderRepository.reorder]）。
  Future<void> _reorderZone(
    WidgetRef ref,
    {required List<Folder> folders,
    required List<Folder> zone,
    required List<Folder> newOrder}) async {
    final other = folders.where((f) => !zone.contains(f)).toList();
    final merged = <Folder>[
      for (final f in other.where((f) => f.isPinned)) f,
      ...newOrder.where((f) => f.isPinned),
      for (final f in other.where((f) => !f.isPinned)) f,
      ...newOrder.where((f) => !f.isPinned),
    ];
    await ref.read(folderRepositoryProvider).reorder(merged);
  }

}

/// 分区标题（置顶）。
///
/// 左 padding 20 与文件夹项内容起点对齐（项 = 水平 margin 10 +
/// 内容 padding 10）；上下间距保持原节奏。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

/// 可拖拽排序区（置顶区 / 普通区）：ReorderableListView（shrinkWrap，
/// 长按与拖拽手柄分离——长按 = 文件夹菜单，拖拽走手柄图标）。
class _ReorderZone extends ConsumerStatefulWidget {
  const _ReorderZone({
    super.key,
    required this.folders,
    required this.selected,
    required this.countOf,
    required this.onReorder,
  });

  final List<Folder> folders;
  final String? selected;
  final Map<String, int> countOf;
  final Future<void> Function(List<Folder> newOrder) onReorder;

  @override
  ConsumerState<_ReorderZone> createState() => _ReorderZoneState();
}

class _ReorderZoneState extends ConsumerState<_ReorderZone> {
  /// 拖放命中注册：按文件夹 id 复用的稳定 GlobalKey（State 持有，
  /// build 重建不更换实例——GlobalKey 每次新建会导致旧 element 卸载、
  /// registry.rectOf 拿不到矩形，拖放命中失败，见 task-32 实测）。
  final Map<String, GlobalKey> _keys = {};

  @override
  Widget build(BuildContext context) {
    final folders = widget.folders;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: folders.length,
      onReorderItem: (oldIndex, newIndex) {
        // onReorderItem 的 newIndex 已针对移除项修正（无需 -1）。
        final list = List<Folder>.of(folders);
        final moved = list.removeAt(oldIndex);
        list.insert(newIndex, moved);
        widget.onReorder(list);
      },
      itemBuilder: (context, index) {
        final folder = folders[index];
        final zoneKey = _keys[folder.id] ??= GlobalKey();
        ref.read(dropZoneRegistryProvider).register(folder.id, zoneKey);
        return _FolderItem(
          key: zoneKey,
          id: folder.id,
          name: folder.name,
          icon: Icons.folder_outlined,
          count: widget.countOf[folder.id] ?? 0,
          selected: widget.selected == folder.id,
          pinned: folder.isPinned,
          onTap: () {
            ref.read(folderFilterProvider.notifier).state = folder.id;
            ref.read(folderDrawerOpenProvider.notifier).state = false;
            // 多选态切文件夹：退出多选（原型 selectFolder 同语义）。
            if (ref.read(multiSelectProvider).isNotEmpty) {
              ref.read(multiSelectProvider.notifier).exit();
            }
          },
          // 拖拽手柄：拖动排序（长按保留给菜单）。
          dragHandle: ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.drag_handle, size: 16),
            ),
          ),
        );
      },
    );
  }
}

/// 「全部」项拖放注册包装：id 为 null 无法直接注册，这里用特殊 id
/// '__all__' 注册稳定 GlobalKey（State 持有，build 重建不换实例）。
/// 拖到「全部」= 移动到未分类（notes_list 落点处理，用户确认）。
class _AllFolderDropTarget extends ConsumerStatefulWidget {
  const _AllFolderDropTarget({required this.child});

  final Widget child;

  @override
  ConsumerState<_AllFolderDropTarget> createState() =>
      _AllFolderDropTargetState();
}

class _AllFolderDropTargetState extends ConsumerState<_AllFolderDropTarget> {
  final GlobalKey _dropKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    ref.read(dropZoneRegistryProvider).register('__all__', _dropKey);
    return KeyedSubtree(key: _dropKey, child: widget.child);
  }
}

/// 单个文件夹项 / 「全部」项。
///
/// - [id] 为 null = 「全部」固定项（不可操作：无菜单、无拖拽手柄）；
/// - 普通项：点击选中；长按/右键 → 玻璃悬浮菜单（重命名/置顶/删除）；
/// - 包裹 DragTarget：笔记拖拽落点（批量移动）。
class _FolderItem extends ConsumerStatefulWidget {
  const _FolderItem({
    super.key,
    required this.id,
    required this.name,
    required this.icon,
    required this.count,
    required this.selected,
    required this.onTap,
    this.pinned = false,
    this.dragHandle,
  });

  final String? id;
  final String name;
  final IconData icon;
  final int count;
  final bool selected;
  final bool pinned;
  final VoidCallback onTap;
  final Widget? dragHandle;

  @override
  ConsumerState<_FolderItem> createState() => _FolderItemState();
}

class _FolderItemState extends ConsumerState<_FolderItem> {
  /// 桌面鼠标悬浮（驱动 hover 背景；仅桌面平台生效）。
  bool _hovered = false;

  String? get id => widget.id;
  String get name => widget.name;
  IconData get icon => widget.icon;
  int get count => widget.count;
  bool get selected => widget.selected;
  bool get pinned => widget.pinned;
  VoidCallback get onTap => widget.onTap;
  Widget? get dragHandle => widget.dragHandle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isAll = id == null;
    // 笔记拖拽落点高亮：ValueListenableBuilder 监听 highlighted 变化
    // （ref.watch(provider).highlighted.value 只 watch provider 实例，
    // ValueNotifier 内部变化不触发 rebuild——hover 不生效的实测根因）。
    // 「全部」也参与高亮与拖放（用户确认：样式与普通文件夹一致）。
    final registry = ref.watch(dropZoneRegistryProvider);
    return ValueListenableBuilder<String?>(
      valueListenable: registry.highlighted,
      builder: (context, highlighted, _) {
        final dropHover = highlighted == (isAll ? '__all__' : id);
        // 拖拽中隐藏选中背景（用户确认：拖拽时两个文件夹的选中效果
        // 紧贴不好看；拖到目标才显示落点高亮）。ValueNotifier 值变化
        // 不触发本 builder（watch 的是 provider 实例），需要再包一层
        // ValueListenableBuilder 监听 dragging。
        return ValueListenableBuilder<bool>(
          valueListenable: registry.dragging,
          builder: (context, isDragging, _) {
            // 选中 / 拖拽悬停：统一浅灰高亮（用户确认：取消蓝色与边框，
            // 用默认 hover 效果；背景再浅一档——亮色 surfaceContainer，
            // 暗色保持 surfaceContainerHighest）；选中态额外保留强调色
            // 图标 + 加粗文字。拖拽中选中背景隐藏，仅落点高亮显示。
            // 桌面鼠标悬浮：仅无选中/无落点高亮时显示更浅一档背景
            // （surfaceContainerLow，与选中态区分）。
            final highlightedBg =
                dropHover || (selected && !isDragging);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final bgColor = highlightedBg
                ? (isDark
                    ? colorScheme.surfaceContainerHighest
                    : colorScheme.surfaceContainer)
                : (_hovered && isDesktopPlatform
                    ? colorScheme.surfaceContainerLow
                    : null);
            // 选中/悬停背景左右各缩进 10px（用户确认：看起来窄一些），
            // 内容同步缩进（与新建按钮水平 padding 对齐）。
            // 项高度 36（用户确认：比之前扁一点，避免两个选中项紧贴）。
            final content = Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: selected && !isDragging
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: selected && !isDragging
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Icon(
                        Icons.push_pin,
                        size: 12,
                        color: colorScheme.primary,
                      ),
                    ),
                  Text(
                    '$count',
                    style: TextStyle(fontSize: 11, color: colorScheme.outline),
                  ),
                  if (dragHandle != null) ...[const SizedBox(width: 2), dragHandle!],
                ],
              ),
            );

            // 高亮容器（选中/悬停背景统一在此一层定义，与内容分离——
            // 避免双层样式重复定义导致不同步）。水平 margin 10：背景
            // 左右缩进，视觉更紧凑（用户确认）。
            final wrapped = AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: bgColor,
              ),
              child: content,
            );

            // 桌面鼠标悬浮：MouseRegion 驱动 _hovered（仅桌面平台
            // 生效，移动端无鼠标语义）。
            Widget interactive = wrapped;
            if (isDesktopPlatform) {
              interactive = MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: wrapped,
              );
            }

            // 「全部」：可拖放落点（id null，注册 '__all__'），无菜单/手柄。
            if (isAll) {
              return GestureDetector(onTap: onTap, child: interactive);
            }
            // 普通项：长按/右键菜单（拖拽落点由注册表 + notes_list 命中处理）。
            return GestureDetector(
              onTap: onTap,
              onSecondaryTapUp: (d) =>
                  _showContextMenu(context, ref, d.globalPosition),
              onLongPress: () => _showContextMenu(context, ref, null),
              child: interactive,
            );
          },
        );
      },
    );
  }

  /// 文件夹悬浮菜单（重命名 / 置顶 / 删除），定位同笔记菜单
  /// （右键鼠标位置 / 长按项底部中心）。
  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset? tapGlobal,
  ) async {
    if (id == null || !context.mounted) return;
    final overlay = Overlay.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF1B2838) : const Color(0xFFFDFCF9);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    const itemHeight = 34.0;
    const radius = 12.0;
    final pinLabel = pinned ? '取消置顶' : '置顶';
    late final OverlayEntry overlayEntry;
    final items = <Widget>[
      _MenuButton(
        icon: Icons.drive_file_rename_outline,
        label: '重命名',
        radius: BorderRadius.vertical(top: Radius.circular(radius)),
        onTap: () async {
          overlayEntry.remove();
          final newName = await showFolderNameDialog(
            context,
            title: '重命名文件夹',
            initial: name,
            confirmLabel: '确定',
          );
          if (newName != null && context.mounted) {
            await ref.read(folderRepositoryProvider).renameFolder(id!, newName);
          }
        },
      ),
      _MenuButton(
        icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: pinLabel,
        radius: BorderRadius.zero,
        onTap: () async {
          overlayEntry.remove();
          await ref.read(folderRepositoryProvider).setPinned(id!, !pinned);
        },
      ),
      _MenuButton(
        icon: Icons.delete_outline,
        label: '删除',
        radius: BorderRadius.vertical(bottom: Radius.circular(radius)),
        labelColor: Theme.of(context).colorScheme.error,
        iconColor: Theme.of(context).colorScheme.error,
        onTap: () {
          overlayEntry.remove();
          final folder = ref.read(foldersStreamProvider).value?.where(
                (f) => f.id == id,
              ).firstOrNull;
          if (folder == null) return;
          // 计数：从当前活跃笔记流计算。
          final noteCount = ref
              .read(activeNotesStreamProvider)
              .value
              ?.where((n) => n.folderId == folder.id)
              .length ?? 0;
          showDeleteFolderDialog(
            context,
            ref,
            folder: folder,
            noteCount: noteCount,
          );
        },
      ),
    ];
    final menuH = items.length * itemHeight;
    final screen = MediaQuery.sizeOf(context);
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
}

/// 顶部虚线「+ 新建文件夹」拖放目标（笔记拖拽落点，task-32）。
///
/// 常驻显示（用户确认）：始终出现并注册拖放目标（__new__）。
/// 落点命中与高亮经 [DropZoneRegistry]（id='__new__'）由 notes_list 驱动。
///
/// 注意：GlobalKey 必须由 State 持有（每次 build 新建会导致旧 element
/// 卸载、registry.rectOf 拿不到矩形——拖到按钮无反应的实测根因）。
class _NewFolderDropTarget extends ConsumerStatefulWidget {
  const _NewFolderDropTarget();

  @override
  ConsumerState<_NewFolderDropTarget> createState() =>
      _NewFolderDropTargetState();
}

class _NewFolderDropTargetState extends ConsumerState<_NewFolderDropTarget> {
  final GlobalKey _dropKey = GlobalKey();

  /// 点击按下（驱动缩放反馈）。
  bool _pressed = false;

  /// 桌面鼠标悬停（驱动微抬升 + 阴影，参照 GlassCard hoverLift）。
  bool _mouseHover = false;

  /// 点击创建文件夹（用户确认：按钮可点击，弹命名框；与 FAB 扇形菜单
  /// 的「文件夹」同语义）。点击目标与拖放落点同一注册 key——点击时
  /// 命中在按钮上、无拖拽，直接走命名创建。
  Future<void> _onTap() async {
    final name = await showFolderNameDialog(context, title: '新建文件夹');
    if (name == null || !mounted) return;
    await ref.read(folderRepositoryProvider).createFolder(name);
  }

  @override
  Widget build(BuildContext context) {
    // 常驻显示（用户确认）：始终出现并注册拖放目标（__new__）。
    final registry = ref.read(dropZoneRegistryProvider);
    registry.register('__new__', _dropKey);
    // hover 高亮：ValueListenableBuilder 监听（watch provider 实例不
    // 随 ValueNotifier 变化 rebuild——同 _FolderItem 根因）。
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String?>(
      valueListenable: registry.highlighted,
      builder: (context, highlighted, _) {
        final dropHover = highlighted == '__new__';
        // 层次感：常态浅灰底 + 细边框；鼠标悬停背景加深 + 轻阴影
        // （微抬升）；拖拽悬停强调色淡底 + 强调色边框（拖放目标反馈）。
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _mouseHover = true),
          onExit: (_) => setState(() => _mouseHover = false),
          child: AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: GestureDetector(
              key: _dropKey,
              onTap: _onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: dropHover
                      ? colorScheme.primary.withValues(alpha: 0.12)
                      : (_mouseHover
                          ? colorScheme.surfaceContainerHighest
                          : colorScheme.surfaceContainerLow),
                  border: Border.all(
                    color: dropHover
                        ? colorScheme.primary
                        : colorScheme.outlineVariant,
                    width: 1,
                  ),
                  boxShadow: _mouseHover
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add,
                      size: 15,
                      color: (dropHover || _mouseHover)
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '新建文件夹',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: (dropHover || _mouseHover)
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 悬浮菜单按钮（玻璃样式，与笔记菜单一致）。
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.icon,
    required this.label,
    required this.radius,
    required this.onTap,
    this.iconColor,
    this.labelColor,
  });

  final IconData icon;
  final String label;
  final BorderRadius radius;
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
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 148, minHeight: 34),
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
