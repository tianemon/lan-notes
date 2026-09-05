import 'dart:async';

import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/note.dart';
import '../data/notes_dao.dart';

/// 笔记变更事件：同步推送钩子的载荷。
///
/// task-7 的 SyncService 将订阅 [NoteRepository.changes]，把本地变更推送
/// 到所有对端（note_upsert / note_delete 消息，见 docs/技术架构.md 7.2 节）。
/// task-20 删除机制改造（回收站+墓碑）：软删除/恢复/清空各自独立事件，
/// 同步层分别映射为 note_upsert（软删除/恢复，deletedAt 非空即删除）与
/// note_delete（清空）。
sealed class NoteChangeEvent {
  const NoteChangeEvent();
}

/// 笔记新增或内容变更（对应同步协议 note_upsert）。
class NoteUpsertedEvent extends NoteChangeEvent {
  const NoteUpsertedEvent(this.note);

  /// 变更后的完整笔记（含递增后的 version）。
  final Note note;
}

/// 笔记软删除进回收站（对应同步协议 note_upsert：deletedAt 非空即删除）。
class NoteTrashedEvent extends NoteChangeEvent {
  const NoteTrashedEvent(this.note);

  /// 软删除后的完整笔记（deletedAt 非 null，version 已 +1）。
  final Note note;
}

/// 笔记从回收站恢复（对应同步协议 note_upsert：deletedAt 恢复为 null）。
class NoteRestoredEvent extends NoteChangeEvent {
  const NoteRestoredEvent(this.note);

  /// 恢复后的完整笔记（deletedAt 为 null，version 已 +1）。
  final Note note;
}

/// 笔记删除（对应同步协议 note_delete，携带 version 防乱序）。
class NoteDeletedEvent extends NoteChangeEvent {
  const NoteDeletedEvent({
    required this.id,
    required this.version,
    this.deletedAt,
  });

  final String id;

  /// 删除时刻的本地 version：对端仅当本地 version ≤ 该值时执行删除
  /// （删除防乱序，见 docs/技术架构.md 3.3 节）。
  final int version;

  /// 删除/清空时刻（epoch ms，task-21 新增）：随 note_delete 携带，对端
  /// 同 version 时按统一比较器做时间裁决（本地操作时间更新则保留复活）。
  final int? deletedAt;
}

/// 笔记仓库：本地数据库读写的统一入口（UI 与同步层共用）。
///
/// 单向数据流保证（见 docs/技术架构.md 第 6 节）：UI 变更一律走本类方法，
/// 写库后由 drift 流自动驱动 UI 刷新，禁止在 Widget 内直接操作数据库。
///
/// 同步推送钩子：createNote / updateNote / deleteNote 写库成功后向
/// [changes] 发出变更事件，供同步层订阅推送（本地变更 → note_upsert /
/// note_delete，见 SyncService）。
/// 同步层接收远端数据写库（LWW 合并）走 [mergeRemoteNote] /
/// [mergeRemoteDelete]，不经 changes 通道（避免把远端变更回推造成回声）。
class NoteRepository {
  NoteRepository(this._dao);

  final NoteDao _dao;

  /// 本机 deviceId（task-32 v5）：本地创建/修改笔记的 origin 标记（最后
  /// 修改者）；由 SyncService 在身份加载后设置。
  String? localDeviceId;

  /// 变更事件通道（广播：允许多个订阅者，如 SyncService 与调试日志）。
  final StreamController<NoteChangeEvent> _changes =
      StreamController<NoteChangeEvent>.broadcast();

  /// 笔记变更事件流：本地增删改成功后发出，供同步推送订阅。
  Stream<NoteChangeEvent> get changes => _changes.stream;

  /// 新建笔记：生成 UUID、记录创建/更新时间，version 从 0 开始。
  ///
  /// [folderId] 传当前选中文件夹 id（task-32：选中文件夹时新建自动归入），
  /// null = 未分类。
  Future<Note> createNote({
    required String title,
    required String content,
    String? folderId,
    bool localOnly = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final note = Note(
      id: const Uuid().v4(),
      title: title,
      content: content,
      createdAt: now,
      updatedAt: now,
      origin: localDeviceId,
      folderId: folderId,
      localOnly: localOnly,
    );
    await _dao.insertOrReplace(note);
    _changes.add(NoteUpsertedEvent(note));
    return note;
  }

  /// 更新笔记标题与正文：version 自动递增、updatedAt 刷新（见 [NoteDao.updateNote]）。
  Future<Note> updateNote({
    required String id,
    required String title,
    required String content,
  }) async {
    final updated = await _dao.updateNote(
      id: id,
      title: title,
      content: content,
    );
    // task-32 v5：本地修改 → 最后修改者 = 本机。
    final marked = updated.copyWith(origin: localDeviceId);
    await _dao.insertOrReplace(marked);
    _changes.add(NoteUpsertedEvent(marked));
    return marked;
  }

  /// 置顶/取消置顶（task-28）：isPinned 置值 + version+1 + updatedAt 刷新。
  ///
  /// 变更经 [NoteUpsertedEvent] 推送（note_upsert 随同步，LWW 框架不变）。
  /// 幂等：DAO 层与当前状态一致时不递增版本（见 [NoteDao.setPinned]），
  /// 事件推送对端按 LWW 丢弃（version 相同不产生变更）。
  Future<Note> setPinned(String id, bool isPinned) async {
    final updated = await _dao.setPinned(id, isPinned);
    _changes.add(NoteUpsertedEvent(updated));
    return updated;
  }

  /// 设置标签（task-28）：tags 置值 + version+1 + updatedAt 刷新。
  ///
  /// 变更经 [NoteUpsertedEvent] 推送（note_upsert 随同步，LWW 框架不变）；
  /// 幂等语义同 [setPinned]。
  Future<Note> setTags(String id, List<String> tags) async {
    final updated = await _dao.setTags(id, tags);
    _changes.add(NoteUpsertedEvent(updated));
    return updated;
  }

  /// 批量移动到文件夹（task-32 文件夹归类）：逐条 folderId 置值 +
  /// version+1（幂等：已在目标文件夹的笔记跳过，不递增版本）。
  ///
  /// [folderId] 传 null = 移出文件夹（未分类）。每条变更经
  /// [NoteUpsertedEvent] 推送（note_upsert 随同步）。
  /// 仅本机保存开关（localOnly）：置值 + version+1，updatedAt 不变。
  ///
  /// 变更经 [NoteUpsertedEvent] 推送（同步层按 localOnly 决定传内容还是
  /// 只传标记：true 时不带标题/正文，对端据此删除自己的副本）。幂等
  /// 语义同 [setPinned]。
  Future<Note> setLocalOnly(String id, bool localOnly) async {
    final updated = await _dao.setLocalOnly(id, localOnly);
    _changes.add(NoteUpsertedEvent(updated));
    return updated;
  }

  /// 批量设置仅本机保存（多选菜单）：逐条置值 + version+1（幂等）。
  Future<void> setLocalOnlyForNotes(List<String> ids, bool localOnly) async {
    for (final id in ids) {
      final updated = await _dao.setLocalOnly(id, localOnly);
      _changes.add(NoteUpsertedEvent(updated));
    }
  }

  Future<void> moveNotesToFolder(List<String> ids, String? folderId) async {
    for (final id in ids) {
      final updated = await _dao.moveToFolder(id, folderId);
      _changes.add(NoteUpsertedEvent(updated));
    }
  }

  /// 批量软删除（task-32 删除文件夹「同时删除笔记」模式）：逐条进回收站
  /// （deletedAt 置时间 + version+1，幂等）。每条经 [NoteTrashedEvent] 推送。
  Future<void> softDeleteNotes(List<String> ids) async {
    for (final id in ids) {
      final trashed = await _dao.softDelete(id);
      _changes.add(NoteTrashedEvent(trashed));
    }
  }

  /// 删除笔记（物理删除 + 写墓碑）：**兼容保留，供现有 UI 调用**。
  ///
  /// 语义说明：本方法即「清空」——物理删除并写墓碑（docs/技术架构.md 3.3
  /// v3 修订「清空 = 物理删除 + 写墓碑」），行为与 [purgeNote] 一致，均发
  /// [NoteDeletedEvent]（同步层推送 note_delete）。幂等：本地不存在视为已
  /// 删除，不推送。
  ///
  /// **UI 后续任务**：列表页/编辑页的删除入口将改为 [softDeleteNote]
  /// （软删除进回收站），届时本方法仅由回收站「清空」入口使用。
  Future<void> deleteNote(String id) async {
    final version = await _dao.purge(id);
    if (version == null) {
      return;
    }
    final tombstone = await _dao.getTombstone(id);
    _changes.add(
      NoteDeletedEvent(
        id: id,
        version: version,
        deletedAt: tombstone?.deletedAt,
      ),
    );
  }

  /// 软删除：笔记进回收站（deletedAt 置时间 + version+1），内容保留。
  ///
  /// 同步层收到 [NoteTrashedEvent] 推送 note_upsert（deletedAt 非空即删除，
  /// 对端 LWW 合并后同样进入回收站）。
  Future<Note> softDeleteNote(String id) async {
    final trashed = await _dao.softDelete(id);
    _changes.add(NoteTrashedEvent(trashed));
    return trashed;
  }

  /// 恢复回收站笔记：清除 deletedAt + version+1，回到正常列表。
  ///
  /// 同步层收到 [NoteRestoredEvent] 推送 note_upsert（deletedAt 恢复为 null，
  /// 对端合并后恢复）。
  Future<Note> restoreNote(String id) async {
    final restored = await _dao.restore(id);
    _changes.add(NoteRestoredEvent(restored));
    return restored;
  }

  /// 清空（单条）：物理删除 + 写墓碑（防复活），同步 note_delete。
  ///
  /// 幂等：本地不存在视为已清空，不推送。
  Future<void> purgeNote(String id) async {
    final version = await _dao.purge(id);
    if (version == null) {
      return;
    }
    final tombstone = await _dao.getTombstone(id);
    _changes.add(
      NoteDeletedEvent(
        id: id,
        version: version,
        deletedAt: tombstone?.deletedAt,
      ),
    );
  }

  /// 全量笔记流（正常笔记，deletedAt IS NULL）：按 updatedAt 倒序。
  Stream<List<Note>> getStream() => _dao.getAllStream();

  /// 回收站流（deletedAt 非 null）：按 deletedAt 倒序。
  Stream<List<Note>> trashStream() => _dao.trashStream();

  /// 搜索流：关键字同时匹配标题与正文；空关键字等价于全量列表。
  Stream<List<Note>> search(String keyword) => _dao.searchStream(keyword);

  /// 按 id 读取单条笔记，不存在返回 null。
  Future<Note?> getById(String id) => _dao.getById(id);

  /// 单条笔记流（编辑页实时同步数据源，task-18）。
  ///
  /// 底层 drift watchSingle：本地保存写库与远端 mergeRemoteNote 写库均会
  /// 自动推送新值，编辑页据此实时刷新（内容一致跳过、不一致强覆盖）。
  Stream<Note?> watchNote(String id) => _dao.watchById(id);

  /// 全量笔记快照（含回收站条目）：主机响应 sync_request 时一次性读取。
  Future<List<Note>> getAll() => _dao.getAll();

  /// 全部墓碑（全量同步快照携带，对端防复活拦截用）。
  Future<List<Tombstone>> getAllTombstones() => _dao.getAllTombstones();

  /// 远端笔记合并写库（LWW，防回声：不经 [changes] 通道）。
  ///
  /// 合并规则（docs/技术架构.md 3.3 节 v3 修订，对所有操作统一）：
  /// 1. 墓碑拦截：该 id 已被物理删除（清空）时，远端旧数据（version 更小，
  ///    或 version 相等且操作时间更早/相等）直接丢弃，防复活；
  /// 2. 本地不存在 → 直接插入（保留远端 version / deletedAt）；
  /// 3. 本地存在 → version 大者胜；version 相等时比较操作时间
  ///    （软删除条目以 deletedAt 计、正常条目以 updatedAt 计），新者胜；
  /// 4. 采用远端时 version 取 max(本地, 远端)（不 +1）：
  ///    - 单调递增不变量保持（version 只增不减，禁止回退）；
  ///    - 避免版本膨胀导致 note_delete 防乱序误判（本地 version 膨胀后
  ///      会拒绝主机正常删除消息，task-9 场景三实测发现并修复）；
  ///    - 内容一致时仅对齐版本/时间戳，不产生无意义变更。
  ///
  /// 返回是否**实际变更了本地**（写库成功为 true；未采用远端/内容与版本
  /// 均已一致为 false）。task-15 fan-out 收敛依赖此返回值：SyncService
  /// 仅在返回 true 时才向其他会话转发（未变更消息为重复/回声，直接丢弃），
  /// 三设备全互联 mesh 下消息链因此收敛（docs/技术架构.md 7.2 节修订）。
  Future<bool> mergeRemoteNote(Note remote) async {
    // 墓碑拦截（防复活，docs/技术架构.md 3.3 节）：清空过的 id 不接受
    // 过期数据——远端 version 更小，或 version 相等但操作时间不更新。
    final tombstone = await _dao.getTombstone(remote.id);
    if (tombstone != null) {
      final remoteOpTime = remote.deletedAt ?? remote.updatedAt;
      final blocked =
          remote.version < tombstone.version ||
          (remote.version == tombstone.version &&
              remoteOpTime <= tombstone.deletedAt);
      if (blocked) {
        return false;
      }
    }
    final local = await _dao.getById(remote.id);
    if (local == null) {
      // 本机没有的笔记，若对端标记为「仅本机保存」则不必落库（对端不外传
      // 内容，这条只是标记通知；本机无副本就无事可做）。
      if (remote.localOnly) return false;
      await _dao.insertOrReplace(remote);
      return true;
    }
    // 本地已标记「仅本机保存」：拒收远端任何内容——该笔记独属于本机，
    // 双向隔离（既不外传，也不接受对端/第三台设备的旧副本覆盖）。
    // 用户取消标记（localOnly → false）后恢复正常同步。
    if (local.localOnly) return false;
    // 对端标记「仅本机保存」：删除本机这份副本（不进回收站、不写墓碑——
    // 该笔记在对端依然存在，写墓碑会让删除反向传播或拦截后续恢复同步）。
    if (remote.localOnly) {
      await _dao.deleteById(remote.id);
      return true;
    }
    // 操作时间：软删除条目以 deletedAt 计、正常条目以 updatedAt 计
    //（3.3 节合并规则②）。
    final remoteOpTime = remote.deletedAt ?? remote.updatedAt;
    final localOpTime = local.deletedAt ?? local.updatedAt;
    final remoteWins =
        remote.version > local.version ||
        (remote.version == local.version && remoteOpTime > localOpTime);
    if (!remoteWins) {
      return false;
    }
    final version = remote.version > local.version
        ? remote.version
        : local.version;
    if (remote.title == local.title &&
        remote.content == local.content &&
        remote.deletedAt == local.deletedAt &&
        remote.isPinned == local.isPinned &&
        remote.folderId == local.folderId &&
        remote.localOnly == local.localOnly &&
        Note.tagsEqual(remote.tags, local.tags)) {
      // 内容与删除/置顶/标签/文件夹状态均一致：仅对齐版本/时间戳（防“全量同步→
      // 版本+1→回推→再+1”膨胀）。
      final aligned = Note(
        id: remote.id,
        title: remote.title,
        content: remote.content,
        createdAt: remote.createdAt,
        updatedAt: remote.updatedAt > local.updatedAt
            ? remote.updatedAt
            : local.updatedAt,
        version: version,
        deletedAt: remote.deletedAt,
        isPinned: remote.isPinned,
        tags: remote.tags,
        origin: remote.origin ?? local.origin,
        folderId: remote.folderId ?? local.folderId,
        localOnly: local.localOnly,
      );
      await _dao.insertOrReplace(aligned);
      return true;
    }
    final merged = Note(
      id: remote.id,
      title: remote.title,
      content: remote.content,
      createdAt: remote.createdAt,
      updatedAt: remote.updatedAt,
      version: version,
      deletedAt: remote.deletedAt,
      isPinned: remote.isPinned,
      tags: remote.tags,
      origin: remote.origin ?? local.origin,
      // task-32 实测 bug：folderId 必须直接用远端值（含 null=移出文件夹）——
      // `remote.folderId ?? local.folderId` 会把 null 吞掉、保留本地旧值，
      // 导致「移出文件夹」永远无法跨端同步。
      folderId: remote.folderId,
      localOnly: remote.localOnly,
    );
    await _dao.insertOrReplace(merged);
    return true;
  }

  /// 远端删除合并（防乱序 + 写墓碑，docs/技术架构.md 3.3 节）。
  ///
  /// 仅当本地 version ≤ 消息 version 时执行删除（本地没有更新的修改）；
  /// 本地 version 更大则保留（删除消息乱序过期）。同 version 时按统一
  /// 比较器做时间裁决（[deletedAt] 非 null 且本地操作时间更新 → 保留
  /// 复活，见 docs/技术架构.md 7.4 节）；旧对端 note_delete 不带
  /// [deletedAt]（null）时退化为「同 version 删除优先」旧语义。
  /// 本地不存在时也补写墓碑（幂等，version 只增不减防回退），拦截后续
  /// 可能带回的旧数据。返回是否实际执行了删除（写墓碑但本地本就不存在
  /// 时返回 false，避免回声消息在 mesh 中被继续中继）。
  Future<bool> mergeRemoteDelete({
    required String id,
    required int version,
    int? deletedAt,
  }) async {
    final local = await _dao.getById(id);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (local == null) {
      final tombstone = await _dao.getTombstone(id);
      if (tombstone == null || version > tombstone.version) {
        await _dao.upsertTombstone(
          id: id,
          version: version,
          deletedAt: deletedAt ?? now,
        );
      }
      return false;
    }
    if (local.version > version) {
      return false;
    }
    // 时间裁决（统一比较器）：同 version 且消息携带删除时间时，本地操作
    // 时间更新 → 保留本地（离线修改复活）；否则（含平局）删除优先。
    if (local.version == version && deletedAt != null) {
      final localOpTime = local.deletedAt ?? local.updatedAt;
      if (localOpTime > deletedAt) {
        return false;
      }
    }
    // 墓碑 version 取 max(本地墓碑, 消息 version)（只增不减防回退）：
    // 本地笔记与墓碑共存（复活场景）时墓碑 version 恒 ≤ 本地 version，
    // 显式取 max 保证任何路径下墓碑版本不回落。
    final tombstone = await _dao.getTombstone(id);
    final tombstoneVersion = (tombstone == null || version > tombstone.version)
        ? version
        : tombstone.version;
    final tombstoneDeletedAt =
        (tombstone == null || version >= tombstone.version)
        ? (deletedAt ?? now)
        : tombstone.deletedAt;
    await _dao.purge(
      id,
      tombstoneVersion: tombstoneVersion,
      tombstoneDeletedAt: tombstoneDeletedAt,
    );
    return true;
  }

  /// 远端墓碑合并（全量同步快照携带，docs/技术架构.md 3.3 节）。
  ///
  /// 语义：
  /// 1. 写墓碑：本地墓碑不存在或 version 更小时写入/提升为远端值
  ///    （version 只增不减，墓碑永不清除）；
  /// 2. 墓碑拦截本地旧数据：本地笔记 version < 墓碑 version，或 version
  ///    相等且操作时间 ≤ 墓碑删除时间（平局删除优先）→ 物理删除本地笔记
  ///    （对端已清空的旧数据从本机移除，防止全量对齐后残留）。
  ///
  /// 返回是否实际变更了本地（新写/提升墓碑或删除笔记为 true）。
  Future<bool> mergeRemoteTombstone({
    required String id,
    required int version,
    required int deletedAt,
  }) async {
    var changed = false;
    final localTombstone = await _dao.getTombstone(id);
    if (localTombstone == null || version > localTombstone.version) {
      await _dao.upsertTombstone(
        id: id,
        version: version,
        deletedAt: deletedAt,
      );
      changed = true;
    }
    final localNote = await _dao.getById(id);
    if (localNote != null) {
      final noteOpTime = localNote.deletedAt ?? localNote.updatedAt;
      final blocked =
          localNote.version < version ||
          (localNote.version == version && noteOpTime <= deletedAt);
      if (blocked) {
        await _dao.deleteById(id);
        changed = true;
      }
    }
    return changed;
  }

  /// 释放事件通道（应用退出或测试收尾时调用）。
  Future<void> dispose() => _changes.close();
}
