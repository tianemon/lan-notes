import 'package:drift/drift.dart';

import 'database.dart';
import 'folder.dart';

part 'folder_dao.g.dart';

/// 文件夹 DAO：CRUD、流式查询与同步合并支持。
///
/// 统一以领域对象 [Folder] 出入，内部完成与 drift 行数据的转换；
/// 合并框架与笔记完全同构（docs/技术架构.md 3.3 节 LWW）：
/// - 软删除（deletedAt 置值）——文件夹删除不可恢复，无回收站；
/// - 置顶/排序变更 = version+1 + updatedAt 刷新，随 folder_upsert 同步。
@DriftAccessor(tables: [Folders])
class FolderDao extends DatabaseAccessor<AppDatabase> with _$FolderDaoMixin {
  FolderDao(super.db);

  /// 插入或替换（UPSERT）：以 id 为主键，冲突时整行替换。
  ///
  /// 与 [NoteDao.insertOrReplace] 同理由：用 InsertMode.insertOrReplace
  /// 保证全列字面写入（含 NULL），软删除/恢复状态精确落库。
  Future<void> insertOrReplace(Folder folder) {
    return into(folders).insert(folder.toRow(), mode: InsertMode.insertOrReplace);
  }

  /// 重命名：name 置值 + version+1 + updatedAt 刷新。
  ///
  /// 幂等：与当前状态一致时直接返回当前值，不重复递增版本。重命名随
  /// folder_upsert 同步（LWW 框架不变）。
  Future<Folder> rename(String id, String name) {
    return _mutate(id, '重命名', (current) {
      if (current.name == name) return current; // 幂等
      final now = DateTime.now().millisecondsSinceEpoch;
      return Folder(
        id: id,
        name: name,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: current.isPinned,
        sortOrder: current.sortOrder,
        origin: current.origin,
      );
    });
  }

  /// 置顶/取消置顶：isPinned 置值 + version+1 + updatedAt 刷新。
  ///
  /// 幂等：与当前状态一致时直接返回当前值。置顶随 folder_upsert 同步
  /// （抽屉排序 isPinned DESC → sortOrder ASC）。
  Future<Folder> setPinned(String id, bool isPinned) {
    return _mutate(id, '置顶', (current) {
      if (current.isPinned == isPinned) return current; // 幂等
      final now = DateTime.now().millisecondsSinceEpoch;
      return Folder(
        id: id,
        name: current.name,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: isPinned,
        sortOrder: current.sortOrder,
        origin: current.origin,
      );
    });
  }

  /// 设置排序值：sortOrder 置值 + version+1 + updatedAt 刷新（拖拽排序）。
  ///
  /// 幂等：值一致时直接返回当前值。排序随 folder_upsert 同步；拖拽后
  /// 由仓库层统一归一化为 0..n-1（见 FolderRepository.reorder）。
  Future<Folder> setSortOrder(String id, int sortOrder) {
    return _mutate(id, '排序', (current) {
      if (current.sortOrder == sortOrder) return current; // 幂等
      final now = DateTime.now().millisecondsSinceEpoch;
      return Folder(
        id: id,
        name: current.name,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: current.isPinned,
        sortOrder: sortOrder,
        origin: current.origin,
      );
    });
  }

  /// 软删除：deletedAt 置当前时间 + version+1（文件夹删除不可恢复）。
  ///
  /// 幂等：已删除（deletedAt 非 null）时直接返回当前值，不重复递增版本。
  Future<Folder> softDelete(String id) async {
    final current = await getById(id);
    if (current == null) {
      throw StateError('删除失败：文件夹不存在（id=$id）');
    }
    if (current.deletedAt != null) {
      return current; // 已删除：幂等
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final deleted = Folder(
      id: id,
      name: current.name,
      createdAt: current.createdAt,
      updatedAt: now,
      version: current.version + 1,
      deletedAt: now,
      isPinned: current.isPinned,
      sortOrder: current.sortOrder,
      origin: current.origin,
    );
    await update(folders).replace(deleted.toRow());
    return deleted;
  }

  /// 通用变更：读取当前文件夹 → 变换 → 写回（version+1 由变换内决定）。
  ///
  /// 与 [NoteDao._mutate] 同模式：文件夹不存在抛 StateError；变换返回
  /// 原对象（幂等路径）时跳过写库直接返回。
  Future<Folder> _mutate(
    String id,
    String op,
    Folder Function(Folder current) transform,
  ) async {
    final current = await getById(id);
    if (current == null) {
      throw StateError('$op失败：文件夹不存在（id=$id）');
    }
    final updated = transform(current);
    if (identical(updated, current)) {
      return current; // 幂等：未变化，不写库不递增版本
    }
    await update(folders).replace(updated.toRow());
    return updated;
  }

  /// 活跃文件夹流（deletedAt IS NULL）：置顶优先 → sortOrder 升序
  /// （抽屉主数据源：置顶区在前、区内按拖拽顺序）。
  Stream<List<Folder>> getActiveStream() {
    final query = select(folders)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.isPinned),
        (t) => OrderingTerm.asc(t.sortOrder),
      ]);
    return query.watch().map((rows) => rows.map(Folder.fromRow).toList());
  }

  /// 全部文件夹一次性查询（含软删除条目）：全量同步快照用（对端 LWW
  /// 合并维持各端文件夹状态一致，与笔记全量同步同语义）。
  Future<List<Folder>> getAll() async {
    final rows = await select(folders).get();
    return rows.map(Folder.fromRow).toList();
  }

  /// 按 id 查询单条文件夹，不存在返回 null。
  Future<Folder?> getById(String id) async {
    final row =
        await (select(folders)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : Folder.fromRow(row);
  }

  /// 按 id 物理删除（仅测试/特殊场景用，正常删除走 [softDelete]）。
  Future<int> deleteById(String id) {
    return (delete(folders)..where((t) => t.id.equals(id))).go();
  }

  /// 一次性读取全部活跃文件夹（按置顶 + 排序，抽屉构建/重排用）。
  Future<List<Folder>> getActive() async {
    final query = select(folders)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.isPinned),
        (t) => OrderingTerm.asc(t.sortOrder),
      ]);
    final rows = await query.get();
    return rows.map(Folder.fromRow).toList();
  }
}
