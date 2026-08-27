import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/folder.dart';
import '../../repository/providers.dart';
import 'glass_style.dart';

/// 文件夹命名弹窗（新建/重命名共用，task-32）：玻璃输入框。
///
/// [initial] 预填文本（重命名 = 原名；拖拽新建 = 「未命名」）；
/// 返回确认后的名称，取消/空输入返回 null。
Future<String?> showFolderNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String confirmLabel = '创建',
}) async {
  final fieldKey = GlobalKey<_FolderNameFieldState>();
  final result = await showGlassDialog<String>(
    context: context,
    title: Text(title),
    content: _FolderNameField(key: fieldKey, initial: initial),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.of(context).pop(fieldKey.currentState?.text.trim()),
        child: Text(confirmLabel),
      ),
    ],
  );
  if (result == null || result.isEmpty) return null;
  return result;
}

/// 命名输入框（State 持有 controller，dispose 时释放——controller 生命周期
/// 与 TextField element 一致，避免 showDialog future 在 pop 时即完成、
/// 退出动画期间 controller 被先 dispose 导致的
/// “TextEditingController was used after being disposed”崩溃，
/// 见 folder_drawer_test 实测）。
class _FolderNameField extends StatefulWidget {
  const _FolderNameField({super.key, required this.initial});

  final String initial;

  @override
  State<_FolderNameField> createState() => _FolderNameFieldState();
}

class _FolderNameFieldState extends State<_FolderNameField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  /// 当前输入文本（确认按钮经 GlobalKey 读取）。
  String get text => _controller.text;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 20,
      decoration: const InputDecoration(hintText: '文件夹名称'),
      onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
    );
  }
}

/// 「移动到」选择面板（task-32）：模态玻璃底部面板，列出「全部（未分类）」
/// + 全部活跃文件夹；选中后批量移动 [noteIds] 并提示。
///
/// 「全部」= 移出文件夹（folderId 置 null）。从笔记右键菜单 / 多选底部
/// 菜单进入（此时无拖拽手势，用模态面板无冲突）。
Future<void> showMoveToPanel(
  BuildContext context,
  WidgetRef ref, {
  required List<String> noteIds,
}) async {
  if (noteIds.isEmpty) return;
  final folderRepo = ref.read(folderRepositoryProvider);
  final noteRepo = ref.read(noteRepositoryProvider);
  final folders = await folderRepo.getActive();
  if (!context.mounted) return;
  final folderId = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (sheetCtx) => _MoveToSheet(folders: folders),
  );
  // 返回语义：null = 取消（barrier 点击）；'' = 「全部」= 移出文件夹；
  // 其他 = 目标文件夹 id。
  if (folderId == null || !context.mounted) return;
  await noteRepo.moveNotesToFolder(noteIds, folderId.isEmpty ? null : folderId);
  if (!context.mounted) return;
  final target = folderId.isEmpty
      ? '全部'
      : (folders.where((f) => f.id == folderId).firstOrNull?.name ?? '全部');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已移动 ${noteIds.length} 条笔记到「$target」'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 移动选择面板内容（玻璃底部面板：标题 + 全部 + 文件夹列表）。
class _MoveToSheet extends ConsumerWidget {
  const _MoveToSheet({required this.folders});

  final List<Folder> folders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF223344)
            : Colors.white.withValues(alpha: 0.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '移动到',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.folder_off_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: const Text('全部（未分类）'),
                    onTap: () => Navigator.of(context).pop(''),
                  ),
                  for (final folder in folders)
                    ListTile(
                      leading: Icon(
                        Icons.folder_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(folder.name),
                      trailing: folder.isPinned
                          ? const Icon(Icons.push_pin, size: 16)
                          : null,
                      onTap: () => Navigator.of(context).pop(folder.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 删除文件夹确认（task-32 二选一）：「笔记移到全部」/「同时删除笔记」。
///
/// [noteCount] 为文件夹内活跃笔记数（0 时不显示笔记处理选项，直接删除）。
Future<void> showDeleteFolderDialog(
  BuildContext context,
  WidgetRef ref, {
  required Folder folder,
  required int noteCount,
}) async {
  final deleteNotes = await showGlassDialog<bool>(
    context: context,
    title: Text('删除文件夹「${folder.name}」？'),
    content: noteCount > 0
        ? Text('文件夹内有 $noteCount 条笔记，如何处理？')
        : const Text('文件夹为空，删除后不可恢复。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      if (noteCount > 0)
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('笔记移到全部'),
        ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(noteCount > 0 ? '同时删除笔记' : '删除'),
      ),
    ],
  );
  if (deleteNotes == null || !context.mounted) return;
  await ref
      .read(folderRepositoryProvider)
      .softDeleteFolder(folder.id, deleteNotes: deleteNotes);
  // 删除的文件夹若正被选中：退回「全部」。
  if (ref.read(folderFilterProvider) == folder.id) {
    ref.read(folderFilterProvider.notifier).state = null;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除文件夹「${folder.name}」'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 批量删除确认（task-32 多选删除）：确认后软删除进回收站。
Future<bool> showBatchDeleteConfirm(
  BuildContext context, {
  required int count,
}) async {
  final confirmed = await showGlassDialog<bool>(
    context: context,
    title: const Text('移到回收站'),
    content: Text('将 $count 条笔记移到回收站吗？可在回收站中恢复。'),
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
  return confirmed ?? false;
}
