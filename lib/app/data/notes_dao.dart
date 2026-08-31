import 'package:drift/drift.dart';

import 'database.dart';
import 'note.dart';

part 'notes_dao.g.dart';

/// 笔记 DAO：全部 CRUD、流式查询与墓碑读写。
///
/// 统一以领域对象 [Note] 出入，内部完成与 drift 行数据的转换；
/// 删除机制为回收站+墓碑（v3 修订，见 docs/技术架构.md 3.3 节）：
/// 软删除（deletedAt 置值）进回收站、恢复清除 deletedAt、清空（物理
/// 删除）写墓碑防复活。
@DriftAccessor(tables: [Notes, Tombstones])
class NoteDao extends DatabaseAccessor<AppDatabase> with _$NoteDaoMixin {
  NoteDao(super.db);

  /// 插入或替换（UPSERT）：以 id 为主键，冲突时整行替换。
  ///
  /// 用 InsertMode.insertOrReplace（INSERT OR REPLACE）而非
  /// insertOnConflictUpdate：后者冲突更新时**不写 NULL 列**（drift 行为，
  /// task-21 联调实测——恢复笔记合并写库 deletedAt=null 残留旧值），
  /// OR REPLACE 全列字面写入（含 NULL），保证软删除/恢复/合并的删除
  /// 状态精确落库。
  Future<void> insertOrReplace(Note note) {
    return into(notes).insert(note.toRow(), mode: InsertMode.insertOrReplace);
  }

  /// 更新笔记标题与正文：自动递增 version 并刷新 updatedAt。
  ///
  /// version 以库内当前值为基准 +1，保证单调递增（LWW 合并前提，
  /// 见 docs/技术架构.md 3.3 节）；isPinned/tags 保持不变（task-28，
  /// 置顶/标签由 [setPinned] / [setTags] 单独变更）。
  Future<Note> updateNote({
    required String id,
    required String title,
    required String content,
  }) {
    return _mutate(id, '更新', (current) {
      final now = DateTime.now().millisecondsSinceEpoch;
      return Note(
        id: id,
        title: title,
        content: content,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: current.isPinned,
        tags: current.tags,
        origin: current.origin,
        folderId: current.folderId,
        localOnly: current.localOnly,
      );
    });
  }

  /// 置顶/取消置顶（task-28）：isPinned 置值 + version+1 + updatedAt 刷新。
  ///
  /// 幂等：与当前状态一致时直接返回当前值，不重复递增版本。置顶状态
  /// 随笔记 upsert 同步（列表排序 isPinned DESC → updatedAt DESC）。
  Future<Note> setPinned(String id, bool isPinned) {
    return _mutate(id, '置顶', (current) {
      if (current.isPinned == isPinned) return current; // 幂等
      final now = DateTime.now().millisecondsSinceEpoch;
      return Note(
        id: id,
        title: current.title,
        content: current.content,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: isPinned,
        tags: current.tags,
        origin: current.origin,
        folderId: current.folderId,
        localOnly: current.localOnly,
      );
    });
  }

  /// 设置标签（task-28）：tags 置值 + version+1 + updatedAt 刷新。
  ///
  /// 幂等：与当前状态一致时直接返回当前值，不重复递增版本。标签随笔记
  /// upsert 同步（列表页标签栏聚合筛选）。
  Future<Note> setTags(String id, List<String> tags) {
    return _mutate(id, '设置标签', (current) {
      if (_sameTags(current.tags, tags)) return current; // 幂等
      final now = DateTime.now().millisecondsSinceEpoch;
      return Note(
        id: id,
        title: current.title,
        content: current.content,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: current.isPinned,
        tags: List.of(tags),
        origin: current.origin,
        folderId: current.folderId,
        localOnly: current.localOnly,
      );
    });
  }

  /// 移动到文件夹（task-32 文件夹归类）：folderId 置值 + version+1 +
  /// updatedAt 刷新。
  ///
  /// [folderId] 传 null = 移出文件夹（未分类）。幂等：与当前状态一致时
  /// 直接返回当前值，不重复递增版本。移动随 note_upsert 同步。
  Future<Note> moveToFolder(String id, String? folderId) {
    return _mutate(id, '移动', (current) {
      if (current.folderId == folderId) return current; // 幂等
      final now = DateTime.now().millisecondsSinceEpoch;
      return Note(
        id: id,
        title: current.title,
        content: current.content,
        createdAt: current.createdAt,
        updatedAt: now,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: current.isPinned,
        tags: current.tags,
        origin: current.origin,
        folderId: folderId,
        localOnly: current.localOnly,
      );
    });
  }

  /// 仅本机保存开关（localOnly）：置值 + version+1，updatedAt **保持不变**
  /// （标记不是内容修改——切换标记不该让笔记跳到列表最前）。
  ///
  /// version+1 是标记能传播到对端的前提（LWW 按版本比较）：对端收到
  /// localOnly=true 的 upsert 会删除自己那份副本（同步层处理，见
  /// sync_service 的 localOnly 拦截）；true → false 后内容恢复同步。
  /// 幂等：与当前状态一致时直接返回当前值，不重复递增版本。
  Future<Note> setLocalOnly(String id, bool localOnly) {
    return _mutate(id, '仅本机保存', (current) {
      if (current.localOnly == localOnly) return current; // 幂等
      return Note(
        id: id,
        title: current.title,
        content: current.content,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
        version: current.version + 1,
        deletedAt: current.deletedAt,
        isPinned: current.isPinned,
        tags: current.tags,
        origin: current.origin,
        folderId: current.folderId,
        localOnly: localOnly,
      );
    });
  }

  /// 通用变更：读取当前笔记 → 变换 → 写回（version+1 由变换内决定）。
  ///
  /// 笔记不存在时抛 StateError（操作名用于错误文案）；变换返回原对象
  /// （幂等路径）时跳过写库直接返回，不产生冗余写入。
  Future<Note> _mutate(
    String id,
    String op,
    Note Function(Note current) transform,
  ) async {
    final current = await getById(id);
    if (current == null) {
      throw StateError('$op失败：笔记不存在（id=$id）');
    }
    final updated = transform(current);
    if (identical(updated, current)) {
      return current; // 幂等：未变化，不写库不递增版本
    }
    await update(notes).replace(updated.toRow());
    return updated;
  }

  /// 软删除：deletedAt 置当前时间 + version+1（笔记进回收站，内容保留）。
  ///
  /// updatedAt **保持不变**（保留删除前的原值）：若在此把它改成删除时间，
  /// 恢复（restore 保留 updatedAt）后列表就会显示「刚刚」，丢失原本的更新
  /// 日期——列表按 updatedAt 排序，恢复后应回到原时间位置。回收站的
  /// 「删除于」用 deletedAt（独立字段），不受影响；version+1 已保证软删除
  /// 经 note_upsert 跨设备传播（同步 LWW 以 version 优先、软删除条目操作
  /// 时间以 deletedAt 计）。幂等：已处于回收站（deletedAt 非 null）时直接
  /// 返回当前值，不重复递增版本。返回软删除后的笔记（含新 version /
  /// deletedAt）。
  Future<Note> softDelete(String id) async {
    final current = await getById(id);
    if (current == null) {
      throw StateError('软删除失败：笔记不存在（id=$id）');
    }
    if (current.deletedAt != null) {
      return current; // 已在回收站：幂等
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final trashed = Note(
      id: id,
      title: current.title,
      content: current.content,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      version: current.version + 1,
      deletedAt: now,
      isPinned: current.isPinned,
      tags: current.tags,
      origin: current.origin,
      folderId: current.folderId,
      localOnly: current.localOnly,
    );
    await update(notes).replace(trashed.toRow());
    return trashed;
  }

  /// 恢复：清除 deletedAt + version+1（回收站条目回到正常列表）。
  ///
  /// updatedAt 保留删除前的原值（用户需求：恢复不改日期——列表按 updatedAt
  /// 排序，恢复后回到原时间位置）；version 仍 +1 保证跨设备同步按新版本
  /// 合并。幂等：不在回收站（deletedAt 为 null）时直接返回当前值。
  Future<Note> restore(String id) async {
    final current = await getById(id);
    if (current == null) {
      throw StateError('恢复失败：笔记不存在（id=$id）');
    }
    if (current.deletedAt == null) {
      return current; // 不在回收站：幂等
    }
    final restored = Note(
      id: id,
      title: current.title,
      content: current.content,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      version: current.version + 1,
      deletedAt: null,
      isPinned: current.isPinned,
      tags: current.tags,
      origin: current.origin,
      folderId: current.folderId,
      localOnly: current.localOnly,
    );
    await update(notes).replace(restored.toRow());
    return restored;
  }

  /// 物理删除（清空回收站）：删除行 + 写墓碑（防复活）。
  ///
  /// 墓碑 version 默认取被删笔记的当前 version（软删除条目已含 +1），
  /// 也可由调用方显式指定（远端 note_delete 合并时传消息 version，见
  /// mergeRemoteDelete）。返回被删笔记的 version（用于变更事件/墓碑），
  /// 笔记不存在返回 null（幂等，不写墓碑）。
  Future<int?> purge(
    String id, {
    int? tombstoneVersion,
    int? tombstoneDeletedAt,
  }) async {
    final current = await getById(id);
    if (current == null) {
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await (delete(notes)..where((t) => t.id.equals(id))).go();
    await upsertTombstone(
      id: id,
      version: tombstoneVersion ?? current.version,
      deletedAt: tombstoneDeletedAt ?? now,
    );
    return current.version;
  }

  /// 按 id 物理删除，返回受影响行数（无墓碑，仅测试/特殊场景用）。
  ///
  /// 「对端标记仅本机保存」删本机副本也走这里：该笔记在对端依然存在
  /// （只是不外传内容），写墓碑会让删除反向传播、或在用户取消标记后
  /// 拦截内容回传（墓碑永不清除）。
  Future<int> deleteById(String id) {
    return (delete(notes)..where((t) => t.id.equals(id))).go();
  }

  /// 正常笔记流（deletedAt IS NULL）：置顶优先 → updatedAt 倒序
  /// （task-28：isPinned DESC → updatedAt DESC，列表页主数据源）。
  Stream<List<Note>> getAllStream() {
    final query = select(notes)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.isPinned),
        (t) => OrderingTerm.desc(t.updatedAt),
      ]);
    return query.watch().map((rows) => rows.map(Note.fromRow).toList());
  }

  /// 回收站流（deletedAt 非 null）：按 deletedAt 倒序（回收站页数据源）。
  Stream<List<Note>> trashStream() {
    final query = select(notes)
      ..where((t) => t.deletedAt.isNotNull())
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch().map((rows) => rows.map(Note.fromRow).toList());
  }

  /// 全量笔记一次性查询（含回收站条目）：主机响应 sync_request 全量快照用。
  ///
  /// 回收站条目必须随全量同步下发（对端 LWW 合并维持各端回收站一致，
  /// 见 docs/技术架构.md 7.2 节 sync_data 载荷说明）。
  Future<List<Note>> getAll() async {
    final rows = await select(notes).get();
    return rows.map(Note.fromRow).toList();
  }

  /// 按 id 查询单条笔记，不存在返回 null。
  Future<Note?> getById(String id) async {
    final row = await (select(
      notes,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : Note.fromRow(row);
  }

  /// 按 id 监听单条笔记（编辑页实时同步数据源，task-18）。
  ///
  /// 底层 drift watchSingle：本地保存写库与远端 mergeRemoteNote 写库均会
  /// 自动推送新值（编辑页据此实时刷新）；笔记不存在时推 null。
  Stream<Note?> watchById(String id) {
    final query = select(notes)..where((t) => t.id.equals(id));
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : Note.fromRow(row),
    );
  }

  /// 搜索流：关键字同时匹配标题与正文（LIKE 模糊匹配），置顶优先 →
  /// updatedAt 倒序（task-28 与全量列表排序一致）。
  ///
  /// 仅搜正常笔记（deletedAt IS NULL，回收站条目不出现在搜索结果）；
  /// 关键字中的 LIKE 通配符（% _ \）按字面处理；空关键字等价于全量列表。
  Stream<List<Note>> searchStream(String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return getAllStream();
    }
    final pattern = '%${_escapeLikePattern(trimmed)}%';
    final query = select(notes)
      ..where(
        (t) =>
            t.deletedAt.isNull() &
            (t.title.like(pattern, escapeChar: r'\') |
                t.content.like(pattern, escapeChar: r'\')),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.isPinned),
        (t) => OrderingTerm.desc(t.updatedAt),
      ]);
    return query.watch().map((rows) => rows.map(Note.fromRow).toList());
  }

  /// 转义 LIKE 通配符，使搜索关键字按字面匹配。
  static String _escapeLikePattern(String keyword) {
    return keyword
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  /// 标签列表相等比较（顺序敏感，task-28 幂等判断用）。
  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- 墓碑读写（防复活，docs/技术架构.md 3.3 节） ----

  /// 写入/更新墓碑（UPSERT：同一 id 重复清空幂等刷新）。
  Future<void> upsertTombstone({
    required String id,
    required int version,
    required int deletedAt,
  }) {
    return into(tombstones).insertOnConflictUpdate(
      TombstonesCompanion.insert(
        id: id,
        version: version,
        deletedAt: deletedAt,
      ),
    );
  }

  /// 按 id 读取墓碑（墓碑拦截判断用），不存在返回 null。
  Future<Tombstone?> getTombstone(String id) async {
    return (select(
      tombstones,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 全部墓碑（全量同步携带，对端据此拦截过期数据防复活）。
  Future<List<Tombstone>> getAllTombstones() {
    return select(tombstones).get();
  }
}
