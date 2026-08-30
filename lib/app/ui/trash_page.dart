import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/note.dart';
import '../repository/providers.dart';
import 'widgets/empty_hint.dart';
import 'widgets/format.dart';
import 'widgets/glass_style.dart';
import '../theme.dart';

/// 回收站页：展示软删除（deletedAt 非 null）的笔记，按删除时间倒序。
///
/// 数据流（docs/技术架构.md 第 6 节）：本页只消费 [trashStreamProvider]
/// （drift 流式查询，按 deletedAt 倒序）；恢复/清空一律调 NoteRepository
/// （restoreNote / purgeNote），写库后由 drift 流自动驱动列表刷新。
///
/// 单条操作：
/// - 恢复 ↺：调 [NoteRepository.restoreNote]，笔记回到正常列表，
///   SnackBar 提示「已恢复」；
/// - 清空 🗑：二次确认后调 [NoteRepository.purgeNote]（物理删除 + 写墓碑
///   防复活，见 docs/技术架构.md 3.3 节）。
/// 顶部「清空全部」：二次确认后对当前列表逐条 [NoteRepository.purgeNote]
/// （仓库无批量方法，UI 层循环调用，同步层逐条推送 note_delete）。
class TrashPage extends ConsumerWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashAsync = ref.watch(trashStreamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          // 清空全部：仅回收站非空时展示
          trashAsync.maybeWhen(
            data: (notes) => notes.isEmpty
                ? const SizedBox.shrink()
                : TextButton.icon(
                    onPressed: () => _confirmPurgeAll(context, ref, notes),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    label: const Text('清空全部'),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: trashAsync.when(
        skipLoadingOnReload: true,
        data: (notes) {
          if (notes.isEmpty) {
            return const EmptyHint(
              icon: Icons.delete_outline,
              title: '回收站是空的',
              subtitle: '删除的笔记会保留在这里，可恢复或彻底清空',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: notes.length,
            itemBuilder: (context, index) =>
                _TrashItem(key: ValueKey(notes[index].id), note: notes[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
      ),
    );
  }
}

/// 单个回收站条目：标题（空则无标题兜底）+ 内容摘要 + 删除时间，
/// 尾部提供「恢复」与「清空」两个操作按钮。
///
/// task-25：玻璃卡片化（[GlassCard]，圆角 16 + 柔和阴影），与列表页
/// 卡片风格一致；时间 11 outline 三段式布局对齐列表页。
class _TrashItem extends ConsumerWidget {
  const _TrashItem({super.key, required this.note});

  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 标题为空取正文第一句（需求 5，仅展示层）。
    final title = displayTitleOf(note.title, note.content);
    final deletedAt = note.deletedAt;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题：16 bold（无标题兜底）
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 摘要：13 灰，2 行截断
                  Text(
                    excerptOf(note.content),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 删除时间：11 outline
                  Text(
                    deletedAt != null ? '删除于 ${relativeTime(deletedAt)}' : '',
                    style: TextStyle(fontSize: 11, color: colorScheme.outline),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '恢复',
              icon: const Icon(Icons.restore),
              onPressed: () => _restoreNote(context, ref, note),
            ),
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmPurgeOne(context, ref, note),
            ),
          ],
        ),
      ),
    );
  }
}

/// 恢复单条：调 [NoteRepository.restoreNote]，SnackBar 提示「已恢复」。
Future<void> _restoreNote(BuildContext context, WidgetRef ref, Note note) async {
  await ref.read(noteRepositoryProvider).restoreNote(note.id);
  if (!context.mounted) return;
  showAppSnackBar('已恢复', duration: const Duration(seconds: 1));
}

/// 单条清空：二次确认后调 [NoteRepository.purgeNote]（物理删除 + 写墓碑）。
Future<void> _confirmPurgeOne(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  // 标题为空取正文第一句（需求 5，仅展示层）。
  final title = displayTitleOf(note.title, note.content);
  final confirmed = await showGlassDialog<bool>(
    context: context,
    title: const Text('清空笔记'),
    content: Text('确定彻底清空「$title」吗？清空后不可恢复。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('清空'),
      ),
    ],
  );
  if (confirmed != true) return;
  await ref.read(noteRepositoryProvider).purgeNote(note.id);
}

/// 清空全部：二次确认后对当前列表逐条 [NoteRepository.purgeNote]。
///
/// 仓库无批量方法，UI 层循环调用；purgeNote 幂等（本地不存在直接返回），
/// 循环期间列表被 drift 流刷新不影响剩余条目清空。
Future<void> _confirmPurgeAll(
  BuildContext context,
  WidgetRef ref,
  List<Note> notes,
) async {
  final confirmed = await showGlassDialog<bool>(
    context: context,
    title: const Text('清空回收站'),
    content: Text('确定彻底清空回收站中的 ${notes.length} 条笔记吗？清空后不可恢复。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('清空全部'),
      ),
    ],
  );
  if (confirmed != true) return;
  for (final note in notes) {
    await ref.read(noteRepositoryProvider).purgeNote(note.id);
  }
}
