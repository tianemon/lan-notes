import 'dart:async';
import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../data/note.dart';
import '../sync/sync_service.dart';
import 'app_settings.dart';
import 'attachments.dart';
import 'device_identity.dart';
import 'note_repository.dart';

/// 全局数据库单例：drift_flutter 的 driftDatabase 跨平台统一初始化
/// （桌面/移动端走系统 SQLite，见 docs/技术架构.md 第 6 节）。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(driftDatabase(name: 'lan_notes'));
  ref.onDispose(db.close);
  return db;
});

/// 笔记仓库：数据读写统一入口，UI 与同步层共用。
final noteRepositoryProvider = Provider<NoteRepository>((ref) {
  final repo = NoteRepository(ref.watch(databaseProvider).noteDao);
  ref.onDispose(repo.dispose);
  return repo;
});

/// 当前搜索关键字（空串 = 不过滤），列表页搜索框绑定。
final searchQueryProvider = StateProvider<String>((ref) => '');

/// 当前标签筛选（空串 = 全部，列表页顶部标签栏绑定，task-28）。
///
/// 与搜索并存：notesStreamProvider 同时应用关键字与标签过滤。
final tagFilterProvider = StateProvider<String>((ref) => '');

/// UI 设置存储（列表布局模式 + 主题模式，task-26）：构造即触发加载
/// （幂等，见 [AppSettingsStore.ensureLoaded]），加载完成前返回平台默认值。
final appSettingsProvider = Provider<AppSettingsStore>((ref) {
  final store = AppSettingsStore(ref.watch(databaseProvider).deviceDao);
  unawaited(store.ensureLoaded());
  return store;
});

/// 当前列表布局模式：1=单列 / 2=双列 / 4=四列瀑布流（task-26）。
///
/// 初始值取 [AppSettingsStore.layoutMode]（平台默认或上次持久化值，手机
/// 双列、桌面单列）；切换时同步写回 AppSettingsStore 持久化（下次启动
/// 生效，见 main.dart _loadUiSettings）。
final layoutModeProvider = StateProvider<int>((ref) {
  return ref.watch(appSettingsProvider).layoutMode;
});

/// 全部正常笔记流（不筛选）：标签栏聚合数据源（task-28）。
///
/// 与 [notesStreamProvider]（搜索+标签筛选后）分离——标签栏始终展示
/// 全部笔记的标签全集，切换标签时其他标签不消失。
final allNotesStreamProvider = StreamProvider<List<Note>>((ref) {
  return ref.watch(noteRepositoryProvider).getStream();
});

/// 标签列表（task-28）：从全部笔记流聚合、去重、按名称排序。
///
/// 数据流：笔记增删改/标签变更写库 → drift 流推送 → 本 Provider 重建。
final tagsProvider = Provider<List<String>>((ref) {
  final notes = ref
      .watch(allNotesStreamProvider)
      .maybeWhen(data: (d) => d, orElse: () => const <Note>[]);
  final tags = <String>{};
  for (final note in notes) {
    tags.addAll(note.tags);
  }
  final list = tags.toList()..sort();
  return list;
});

/// 笔记列表流：drift 流式查询，置顶优先 → updatedAt 倒序；随搜索关键字
/// 与标签筛选自动过滤（两者并存，task-28）。
///
/// UI 只消费此流渲染列表；变更一律经 NoteRepository 写库后由 drift 流
/// 自动驱动刷新（单向数据流，见 docs/技术架构.md 第 6 节）。
final notesStreamProvider = StreamProvider<List<Note>>((ref) {
  final keyword = ref.watch(searchQueryProvider);
  final tag = ref.watch(tagFilterProvider);
  final repo = ref.watch(noteRepositoryProvider);
  if (tag.isEmpty) {
    return repo.search(keyword);
  }
  // 标签筛选：在搜索流（置顶优先 → updatedAt 倒序）基础上按标签过滤。
  // 个人笔记量级下 Dart 侧过滤开销可忽略；标签存 JSON 数组字符串，
  // SQL LIKE 匹配需转义且易误匹配子串，故不落 SQL。
  return repo
      .search(keyword)
      .map((notes) => notes.where((n) => n.tags.contains(tag)).toList());
});

/// 回收站流：drift 流式查询，按 deletedAt 倒序（回收站页数据源）。
///
/// 软删除/恢复/清空经 NoteRepository 写库后由 drift 流自动推送刷新
/// （单向数据流，见 docs/技术架构.md 第 6 节）。
final trashStreamProvider = StreamProvider<List<Note>>((ref) {
  return ref.watch(noteRepositoryProvider).trashStream();
});

/// 编辑页当前笔记流：drift watchSingle 订阅单条笔记（task-18 编辑模式实时同步）。
///
/// 远端 mergeRemoteNote 写库后 drift 自动推送新值（另一台设备修改 →
/// 编辑页实时刷新）；本地保存写库同样经此流回推（内容与当前输入一致时
/// 编辑页跳过，避免光标跳动）。
/// 无 id（新建模式）不消费本 provider：创建成功转编辑态后由路由替换
/// 重新进入编辑页再订阅。
final editorNoteProvider = StreamProvider.autoDispose.family<Note?, String>((
  ref,
  id,
) {
  return ref.watch(noteRepositoryProvider).watchNote(id);
});

/// 本机设备身份与信任列表：持久化 deviceId/设备名/连接密码 + 已配对设备
/// （docs/技术架构.md 7.3 节认证与配对，task-12）。
///
/// 构造即触发身份加载（幂等，见 [DeviceIdentityStore.ensureLoaded]）；
/// SyncService 在握手/配对前也会 await ensureLoaded，保证对外使用持久化身份。
final deviceIdentityProvider = Provider<DeviceIdentityStore>((ref) {
  final store = DeviceIdentityStore(ref.watch(databaseProvider).deviceDao);
  unawaited(store.ensureLoaded());
  return store;
});

/// 附件存储目录（生产默认，task-30）：应用支持目录下的 `attachments/`
/// 子目录（path_provider 跨平台解析，懒创建并复用）。
///
/// [AttachmentsStore] 为纯 Dart 设计（联调脚本可注入临时目录），因此
/// path_provider 的默认目录解析收敛在本文件（Flutter 环境）。
Future<Directory> defaultAttachmentsDirectory() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, AttachmentsStore.dirName));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 附件存储单例（编辑器插图与同步层共用同一目录；就绪事件为静态广播流，
/// 见 [AttachmentsStore.attachmentReady]）。
final attachmentsStoreProvider = Provider<AttachmentsStore>((ref) {
  return AttachmentsStore(directoryProvider: defaultAttachmentsDirectory);
});

/// 同步编排服务：握手/认证/配对/全量/增量/LWW 冲突合并
/// （见 docs/技术架构.md 第 7 节）。
///
/// UI 变更一律经 NoteRepository 写库，SyncService 订阅 changes 通道
/// 自动推送；远端合并写库不经 changes 通道（防回声）。
/// 设备身份（deviceId/设备名）来自持久化的 [deviceIdentityProvider]；
/// 附件存储（task-30 图片同步）注入 [attachmentsStoreProvider]。
final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(
    repository: ref.watch(noteRepositoryProvider),
    identity: ref.watch(deviceIdentityProvider),
    attachments: ref.watch(attachmentsStoreProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
