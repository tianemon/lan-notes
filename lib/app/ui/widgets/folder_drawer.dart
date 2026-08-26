import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/folder.dart';
import '../../data/note.dart';
import '../../repository/folder_repository.dart';
import '../../repository/providers.dart';
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
    // 拖放注册表：每次 build 清空重建（子组件逐个注册最新 GlobalKey）。
    final registry = ref.read(dropZoneRegistryProvider);
    registry.reset();

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
                color: isDark ? const Color(0xFF223344) : Colors.white,
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 文件夹按钮（用户确认：跟随侧边栏一起弹出——按钮在
                  // 抽屉头部，抽屉滑入时按钮一起滑入；点击收起抽屉）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                    child: Row(
                      children: [
                        InkWell(
                          onTap: () => ref
                              .read(folderDrawerOpenProvider.notifier)
                              .state = false,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.folder_outlined,
                              size: 20,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                  // 顶部虚线「+ 新建文件夹」拖放目标（常驻显示，
                  // 落点处理在 notes_list 拖拽收尾）。
                  const Padding(
                    padding: EdgeInsets.fromLTRB(10, 2, 10, 4),
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
                        // 「全部」：固定置顶、不可操作、默认选中。
                        _FolderItem(
                          id: null,
                          name: '全部',
                          icon: Icons.folder_off_outlined,
                          count: notes.length,
                          selected: selected == null,
                          onTap: () {
                            ref.read(folderFilterProvider.notifier).state = null;
                            ref
                                .read(folderDrawerOpenProvider.notifier)
                                .state = false;
                          },
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
                          const _SectionLabel('文件夹'),
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

/// 分区标题（置顶 / 文件夹）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
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

/// 单个文件夹项 / 「全部」项。
///
/// - [id] 为 null = 「全部」固定项（不可操作：无菜单、无拖拽手柄）；
/// - 普通项：点击选中；长按/右键 → 玻璃悬浮菜单（重命名/置顶/删除）；
/// - 包裹 DragTarget：笔记拖拽落点（批量移动）。
class _FolderItem extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final isAll = id == null;
    // 笔记拖拽落点高亮（自绘拖拽经注册表驱动，见 DropZoneRegistry）。
    final dropHover =
        !isAll && ref.watch(dropZoneRegistryProvider).highlighted.value == id;
    final content = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.14)
            : (dropHover
                ? colorScheme.primary.withValues(alpha: 0.16)
                : null),
        borderRadius: BorderRadius.circular(12),
        border: dropHover
            ? Border.all(color: colorScheme.primary, width: 1.4)
            : null,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 17,
            color: dropHover
                ? colorScheme.primary
                : (selected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
          if (dragHandle != null) ...[
            const SizedBox(width: 2),
            dragHandle!,
          ],
        ],
      ),
    );

    // 「全部」不可操作：无菜单、无拖放。
    if (isAll) {
      return GestureDetector(onTap: onTap, child: content);
    }
    // 普通项：长按/右键菜单（拖拽落点由注册表 + notes_list 命中处理）。
    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: (d) => _showContextMenu(context, ref, d.globalPosition),
      onLongPress: () => _showContextMenu(context, ref, null),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: dropHover
              ? colorScheme.primary.withValues(alpha: 0.16)
              : null,
          border: dropHover
              ? Border.all(color: colorScheme.primary, width: 1.4)
              : null,
        ),
        child: content,
      ),
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
    final bgColor = isDark ? const Color(0xFF1B2838) : Colors.white;
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

  @override
  Widget build(BuildContext context) {
    // 常驻显示（用户确认）：始终出现并注册拖放目标（__new__）。
    final registry = ref.watch(dropZoneRegistryProvider);
    registry.register('__new__', _dropKey);
    final hover = registry.highlighted.value == '__new__';
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: _dropKey,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hover ? colorScheme.primary : colorScheme.outlineVariant,
          width: 1.4,
          style: BorderStyle.solid,
        ),
        color: hover ? colorScheme.primary.withValues(alpha: 0.12) : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.add,
            size: 16,
            color: hover
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            '新建文件夹',
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
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
