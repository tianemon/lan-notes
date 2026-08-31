import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/database.dart';
import 'package:lan_notes/app/data/note.dart';

/// 回收站软删除/恢复的日期语义回归：
/// 1. 软删除时 updatedAt 保持删除前的原值（不改「刚刚」）；
/// 2. 恢复后 updatedAt 仍是原值——列表回到原时间位置，不显示「刚刚」。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('软删除不改 updatedAt；恢复后 updatedAt 仍为原值（回原时间位）', () async {
    final dao = db.noteDao;
    // 直接插入一条「昨天更新」的笔记（绕过 updateNote 的 now 语义）：
    // updatedAt 明显早于现在，用于验证软删除/恢复都不把它污染成当前时间。
    final originalUpdatedAt =
        DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    await dao.insertOrReplace(
      Note(
        id: 'n1',
        title: '标题',
        content: '正文',
        createdAt: originalUpdatedAt,
        updatedAt: originalUpdatedAt,
        version: 1,
        deletedAt: null,
        isPinned: false,
        tags: const [],
        origin: null,
        folderId: null,
        localOnly: false,
      ),
    );

    // 软删除：deletedAt 置现在，但 updatedAt 必须保持原值。
    final trashed = await dao.softDelete('n1');
    expect(trashed.deletedAt, isNotNull, reason: '软删除应设置 deletedAt');
    expect(trashed.updatedAt, originalUpdatedAt,
        reason: '软删除不应污染 updatedAt（否则恢复后显示「刚刚」）');
    expect(trashed.version, 2, reason: '软删除应 version+1 供同步');

    // 恢复：deletedAt 清空，updatedAt 仍保留原值。
    final restored = await dao.restore('n1');
    expect(restored.deletedAt, isNull, reason: '恢复应清空 deletedAt');
    expect(restored.updatedAt, originalUpdatedAt,
        reason: '恢复后 updatedAt 应为原本的更新时间，不变成删除/恢复时间');
    expect(restored.version, 3, reason: '恢复应 version+1 供同步');
  });
}
