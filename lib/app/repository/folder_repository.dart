import 'dart:async';

import 'package:uuid/uuid.dart';

import '../data/folder.dart';
import '../data/folder_dao.dart';
import 'note_repository.dart';

/// 文件夹变更事件：同步推送钩子的载荷。
///
/// SyncService 订阅 [FolderRepository.changes]，把本地变更推送到对端
/// （folder_upsert，见 docs/技术架构.md 7.2 节）。
sealed class FolderChangeEvent {
  const FolderChangeEvent();
}

/// 文件夹新增或内容变更（对应同步协议 folder_upsert）。
class FolderUpsertedEvent extends FolderChangeEvent {
  const FolderUpsertedEvent(this.folder);

  /// 变更后的完整文件夹（含递增后的 version）。
  final Folder folder;
}

/// 文件夹软删除（对应同步协议 folder_upsert：deletedAt 非空即删除）。
class FolderTrashedEvent extends FolderChangeEvent {
  const FolderTrashedEvent(this.folder);

  /// 软删除后的完整文件夹（deletedAt 非 null，version 已 +1）。
  final Folder folder;
}

/// 文件夹仓库：本地数据库读写的统一入口（UI 与同步层共用）。
///
/// 单向数据流保证（同 [NoteRepository]，见 docs/技术架构.md 第 6 节）：
/// UI 变更一律走本类方法，写库后由 drift 流自动驱动 UI 刷新。
///
/// 同步推送钩子：createFolder / renameFolder / setPinned / softDeleteFolder /
/// reorder 写库成功后向 [changes] 发出变更事件（本地变更 → folder_upsert）。
/// 同步层接收远端数据写库（LWW 合并）走 [mergeRemoteFolder]，不经
/// changes 通道（避免把远端变更回推造成回声，同 [NoteRepository]）。
class FolderRepository {
  FolderRepository(this._dao, this._noteRepo);

  final FolderDao _dao;

  /// 笔记仓库引用：删除文件夹时联动批量处理笔记（事件由 NoteRepository
  /// 自身广播，保持单一职责）。
  final NoteRepository _noteRepo;

  /// 本机 deviceId：本地创建/修改文件夹的 origin 标记（最后修改者）；
  /// 由 SyncService 在身份加载后设置（同 [NoteRepository.localDeviceId]）。
  String? localDeviceId;

  /// 变更事件通道（广播：允许多个订阅者）。
  final StreamController<FolderChangeEvent> _changes =
      StreamController<FolderChangeEvent>.broadcast();

  /// 文件夹变更事件流：本地增删改成功后发出，供同步推送订阅。
  Stream<FolderChangeEvent> get changes => _changes.stream;

  /// 新建文件夹：生成 UUID、记录创建/更新时间，version 从 0 开始，
  /// sortOrder 取当前最大 + 1（追加到普通区末尾）。
  Future<Folder> createFolder(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final active = await _dao.getActive();
    var maxSort = -1;
    for (final f in active) {
      if (f.sortOrder > maxSort) maxSort = f.sortOrder;
    }
    final folder = Folder(
      id: const Uuid().v4(),
      name: name,
      createdAt: now,
      updatedAt: now,
      sortOrder: maxSort + 1,
      origin: localDeviceId,
    );
    await _dao.insertOrReplace(folder);
    _changes.add(FolderUpsertedEvent(folder));
    return folder;
  }

  /// 重命名：name 置值 + version+1 + updatedAt 刷新（随 folder_upsert 同步）。
  Future<Folder> renameFolder(String id, String name) async {
    final updated = await _dao.rename(id, name);
    _changes.add(FolderUpsertedEvent(updated));
    return updated;
  }

  /// 置顶/取消置顶：isPinned 置值 + version+1（抽屉置顶区/普通区切换）。
  ///
  /// 置顶时把 sortOrder 调整为置顶区末尾（置顶区排序连续，见
  /// [FolderDao.setPinned] 说明）；取消置顶时调整到普通区末尾。
  Future<Folder> setPinned(String id, bool pinned) async {
    final updated = await _dao.setPinned(id, pinned);
    // 置顶/取消置顶后，把该文件夹排到目标区末尾（保持两区 sortOrder 连续）。
    await _normalizeSort();
    _changes.add(FolderUpsertedEvent(updated));
    return updated;
  }

  /// 删除文件夹（软删除，不可恢复）：文件夹本身软删除 + 按模式处理笔记。
  ///
  /// [deleteNotes] = true：「同时删除笔记」——文件夹内全部活跃笔记软删除
  /// 进回收站；false：「笔记移到全部」——文件夹内全部活跃笔记移出（未分类）。
  /// 文件夹软删除经 [FolderTrashedEvent] 推送（folder_upsert，deletedAt
  /// 非空即删除）；笔记操作经 NoteRepository 批量方法广播（note_upsert）。
  Future<void> softDeleteFolder(String id, {required bool deleteNotes}) async {
    // 1. 处理文件夹内活跃笔记（先笔记后文件夹，保证 UI 流一致）。
    final notes = await _noteRepo.getAll();
    final noteIds = notes
        .where((n) => n.deletedAt == null && n.folderId == id)
        .map((n) => n.id)
        .toList();
    if (deleteNotes) {
      await _noteRepo.softDeleteNotes(noteIds);
    } else {
      await _noteRepo.moveNotesToFolder(noteIds, null);
    }
    // 2. 软删除文件夹本身。
    final deleted = await _dao.softDelete(id);
    _changes.add(FolderTrashedEvent(deleted));
  }

  /// 拖拽排序（抽屉内置顶区/普通区各自拖拽后调用）：传入**全部活跃
  /// 文件夹的新顺序**（置顶区在前、普通区在后，调用方组装），按位置
  /// 归一化 sortOrder = 0..n-1，version+1 随 folder_upsert 同步。
  ///
  /// 写库一次批量提交（[FolderDao.setSortOrders]）：只触发一次表变更
  /// 通知，避免逐条写库把中间顺序推给 UI 造成列表连续跳变。
  /// 同步事件仍逐条发出——folder_upsert 是单条载荷协议，每条变更都要
  /// 广播给对端。
  ///
  /// 幂等：顺序与现状一致时不写库不递增版本。
  Future<void> reorder(List<Folder> newOrder) async {
    final updated = await _dao.setSortOrders(newOrder);
    for (final folder in updated) {
      _changes.add(FolderUpsertedEvent(folder));
    }
  }

  /// 排序归一化：重排 sortOrder 为 0..n-1（置顶优先 → 原 sortOrder 升序），
  /// 置顶/取消置顶后保持两区顺序连续。逐条 version+1 同步。
  Future<void> _normalizeSort() async {
    final active = await _dao.getActive(); // 已按 isPinned DESC → sortOrder ASC
    await reorder(active);
  }

  /// 活跃文件夹流（deletedAt IS NULL）：置顶优先 → sortOrder 升序
  /// （抽屉主数据源）。
  Stream<List<Folder>> getActiveStream() => _dao.getActiveStream();

  /// 一次性读取全部活跃文件夹（置顶优先 → sortOrder 升序）：
  /// 「移动到」面板 / 排序归一化等一次性场景用。
  Future<List<Folder>> getActive() => _dao.getActive();

  /// 全部文件夹快照（含软删除条目）：全量同步快照携带（对端 LWW 合并）。
  Future<List<Folder>> getAll() => _dao.getAll();

  /// 按 id 读取单条文件夹，不存在返回 null。
  Future<Folder?> getById(String id) => _dao.getById(id);

  /// 远端文件夹合并写库（LWW，防回声：不经 [changes] 通道）。
  ///
  /// 合并规则与 [NoteRepository.mergeRemoteNote] 完全同构（3.3 节统一
  /// 比较器，无墓碑——文件夹软删除无回收站，复活由 LWW 版本裁决）：
  /// 1. 本地不存在 → 直接插入（保留远端 version / deletedAt）；
  /// 2. 本地存在 → version 大者胜；相等时比较操作时间（软删除条目以
  ///    deletedAt 计、正常条目以 updatedAt 计），新者胜；
  /// 3. 采用远端时 version 取 max(本地, 远端)（不 +1，单调递增不变量）；
  /// 4. 内容一致时仅对齐版本/时间戳，不产生无意义变更。
  ///
  /// 返回是否**实际变更了本地**（fan-out 转发门控依据，同笔记）。
  Future<bool> mergeRemoteFolder(Folder remote) async {
    final local = await _dao.getById(remote.id);
    if (local == null) {
      await _dao.insertOrReplace(remote);
      return true;
    }
    final remoteOpTime = remote.deletedAt ?? remote.updatedAt;
    final localOpTime = local.deletedAt ?? local.updatedAt;
    final remoteWins = remote.version > local.version ||
        (remote.version == local.version && remoteOpTime > localOpTime);
    if (!remoteWins) {
      return false;
    }
    final version = remote.version > local.version
        ? remote.version
        : local.version;
    if (remote.name == local.name &&
        remote.deletedAt == local.deletedAt &&
        remote.isPinned == local.isPinned &&
        remote.sortOrder == local.sortOrder) {
      // 内容与状态均一致：仅对齐版本/时间戳（防版本膨胀）。
      final aligned = Folder(
        id: remote.id,
        name: remote.name,
        createdAt: remote.createdAt,
        updatedAt: remote.updatedAt > local.updatedAt
            ? remote.updatedAt
            : local.updatedAt,
        version: version,
        deletedAt: remote.deletedAt,
        isPinned: remote.isPinned,
        sortOrder: remote.sortOrder,
        origin: remote.origin ?? local.origin,
      );
      await _dao.insertOrReplace(aligned);
      return true;
    }
    final merged = Folder(
      id: remote.id,
      name: remote.name,
      createdAt: remote.createdAt,
      updatedAt: remote.updatedAt,
      version: version,
      deletedAt: remote.deletedAt,
      isPinned: remote.isPinned,
      sortOrder: remote.sortOrder,
      origin: remote.origin ?? local.origin,
    );
    await _dao.insertOrReplace(merged);
    return true;
  }

  /// 释放事件通道（应用退出或测试收尾时调用）。
  Future<void> dispose() => _changes.close();
}
