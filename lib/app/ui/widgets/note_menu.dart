import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/note.dart';
import '../../repository/providers.dart';
import '../../theme.dart';
import 'format.dart';
import 'glass_style.dart';
import 'note_actions.dart';

/// 笔记菜单动作。
///
/// 桌面右键菜单（Overlay）与移动端长按后的底部面板**共用同一套动作
/// 枚举与执行逻辑**——此前两处各自实现同一批操作，加/改一个选项要动
/// 两个地方（「仅本机保存」加入时收敛到本文件）。
enum NoteMenuAction { pin, moveTo, localOnly, delete }

/// 菜单项视图模型（图标 + 文案 + 危险色 + 勾选态）。
///
/// 只描述「有哪些项、长什么样的数据」，样式由调用方决定：右键菜单是
/// 横向「图标 + 文字」，底部面板是「图标在上、文字在下」。
class NoteMenuItem {
  const NoteMenuItem({
    required this.action,
    required this.icon,
    required this.label,
    this.danger = false,
    this.checked,
  });

  final NoteMenuAction action;
  final IconData icon;
  final String label;

  /// 危险操作（删除）：渲染成错误色。
  final bool danger;

  /// 勾选态（null = 该项不展示勾选标记）。
  final bool? checked;
}

/// 按当前选中笔记构建菜单项清单（两处菜单共用，顺序与文案一致）。
///
/// - 置顶/取消置顶：仅单选时显示（批量置顶无意义）；
/// - 仅本机保存：全部选中项都已开启时呈勾选态（点击 = 全部取消）；
/// - 移动到 / 删除：始终显示，支持批量。
List<NoteMenuItem> buildNoteMenuItems(List<Note> selected) {
  final single = selected.length == 1 ? selected.first : null;
  final allLocalOnly =
      selected.isNotEmpty && selected.every((n) => n.localOnly);
  return <NoteMenuItem>[
    if (single != null)
      NoteMenuItem(
        action: NoteMenuAction.pin,
        icon: single.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: single.isPinned ? '取消置顶' : '置顶',
      ),
    const NoteMenuItem(
      action: NoteMenuAction.moveTo,
      icon: Icons.drive_file_move_outlined,
      label: '移动到',
    ),
    NoteMenuItem(
      action: NoteMenuAction.localOnly,
      icon: allLocalOnly ? Icons.check_box : Icons.check_box_outline_blank,
      label: '仅本机保存',
      checked: allLocalOnly,
    ),
    const NoteMenuItem(
      action: NoteMenuAction.delete,
      icon: Icons.delete_outline,
      label: '删除',
      danger: true,
    ),
  ];
}

/// 执行菜单动作（两处菜单共用）：置顶 / 移动到 / 仅本机保存 / 删除。
///
/// 执行成功后统一退出多选态（与原交互一致）；用户在确认框/移动面板中
/// 取消则什么都不做、不改变选中状态。
Future<void> runNoteMenuAction(
  BuildContext context,
  WidgetRef ref,
  NoteMenuAction action,
  List<Note> selected,
) async {
  if (selected.isEmpty) return;
  final ids = selected.map((n) => n.id).toList();
  switch (action) {
    case NoteMenuAction.pin:
      {
        final note = selected.first;
        await ref
            .read(noteRepositoryProvider)
            .setPinned(note.id, !note.isPinned);
        if (!context.mounted) return;
        showAppSnackBar(!note.isPinned ? '已置顶' : '已取消置顶');
      }
    case NoteMenuAction.moveTo:
      {
        if (!context.mounted) return;
        await showMoveToPanel(context, ref, noteIds: ids);
      }
    case NoteMenuAction.localOnly:
      {
        // 全部已开启 → 本次点击是取消；否则是开启（批量时统一置值）。
        final enable = !selected.every((n) => n.localOnly);
        if (enable) {
          if (!context.mounted) return;
          final confirmed = await showGlassDialog<bool>(
            context: context,
            title: const Text('仅本机保存'),
            content: Text(
              ids.length == 1
                  ? '开启后这篇笔记不再同步到其他设备，'
                      '其他设备上已有的副本会被删除。'
                  : '开启后这 ${ids.length} 条笔记不再同步到其他设备，'
                      '其他设备上已有的副本会被删除。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('开启'),
              ),
            ],
          );
          if (confirmed != true) return;
        }
        await ref.read(noteRepositoryProvider).setLocalOnlyForNotes(ids, enable);
        if (!context.mounted) return;
        showAppSnackBar(enable ? '已设为仅本机保存' : '已恢复同步到其他设备');
      }
    case NoteMenuAction.delete:
      {
        if (!context.mounted) return;
        final confirmed = ids.length == 1
            ? await _confirmDeleteOne(context, selected.first)
            : await showBatchDeleteConfirm(context, count: ids.length);
        if (confirmed != true || !context.mounted) return;
        await ref.read(noteRepositoryProvider).softDeleteNotes(ids);
        if (!context.mounted) return;
        showAppSnackBar(
          ids.length == 1 ? '已移到回收站' : '已删除 ${ids.length} 条笔记',
        );
      }
  }
  // 操作完成：退出多选态（右键菜单场景下集合本就为空，无副作用）。
  if (context.mounted) {
    ref.read(multiSelectProvider.notifier).exit();
  }
}

/// 单条删除确认（带笔记标题，缺失标题取正文第一句）。
Future<bool> _confirmDeleteOne(BuildContext context, Note note) async {
  final title = displayTitleOf(note.title, note.content);
  return await showGlassDialog<bool>(
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
      ) ??
      false;
}
