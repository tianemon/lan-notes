import 'dart:async';
import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../data/folder.dart';
import '../data/note.dart';
import '../sync/sync_service.dart';
import 'app_settings.dart';
import 'attachments.dart';
import 'device_identity.dart';
import 'folder_repository.dart';
import 'note_repository.dart';
import 'search_history.dart';

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

/// 「未分类」筛选的哨兵值（[folderFilterProvider]）：只显示 folderId 为
/// null 的笔记。
///
/// 用哨兵而非 null 是为了与「全部」（null = 不限文件夹）区分；文件夹 id
/// 由 UUID 生成，不会与该值冲突。
const String kUncategorizedFolderId = '__uncategorized__';

/// 当前选中文件夹 id（task-32 文件夹归类）：null = 「全部」——显示全部
/// 笔记（含未分类与各文件夹内）；非 null = 仅显示该文件夹内笔记；
/// [kUncategorizedFolderId] = 只显示未归类（folderId 为 null）的笔记。
/// 默认 null（打开软件默认选中「全部」）。
final folderFilterProvider = StateProvider<String?>((ref) => null);

/// 文件夹抽屉是否打开（task-32）。点击文件夹按钮打开 = 带 backdrop；
/// 拖拽笔记进入左侧区域展开 = 无 backdrop（drag-mode，见
/// [folderDrawerByDragProvider]）。
final folderDrawerOpenProvider = StateProvider<bool>((ref) => false);

/// 抽屉是否由拖拽展开（drag-mode）：无 backdrop，可穿透操作列表。
final folderDrawerByDragProvider = StateProvider<bool>((ref) => false);

/// 多选模式选中集合（task-32 长按多选）：非空 = 多选模式激活。
/// 进入：长按卡片（默认选中该卡）；点击其他卡片切换选中；清空 = 退出。
class MultiSelectNotifier extends StateNotifier<Set<String>> {
  MultiSelectNotifier() : super(const {});

  /// 多选模式是否激活（选中集合非空）。
  bool get active => state.isNotEmpty;

  /// 进入多选并默认选中 [id]（长按卡片）。
  void enter(String id) => state = {id};

  /// 切换选中（点击卡片）。全部取消时自动退出多选。
  void toggle(String id) {
    final next = Set<String>.of(state);
    if (!next.add(id)) {
      next.remove(id);
    }
    state = next;
  }

  /// 全选/取消全选（[all] 为当前全部可选项）。
  void selectAll(Iterable<String> all) => state = all.toSet();

  /// 退出多选（清空）。
  void exit() => state = const {};
}

final multiSelectProvider =
    StateNotifierProvider<MultiSelectNotifier, Set<String>>(
      (ref) => MultiSelectNotifier(),
    );

/// 拖放目标注册表（task-32 自绘拖拽）：FolderDrawer 注册各文件夹项 /
/// 「新建文件夹」按钮的 GlobalKey 与高亮状态，笔记拖拽命中检测用
/// [rectOf] 实时取矩形（拖拽中抽屉动画/滚动后仍准确），高亮由
/// [highlighted] 驱动落点样式。
class DropZoneRegistry {
  final Map<String, GlobalKey> _keys = {};

  /// 抽屉列表滚动控制（task-32 拖拽 auto-scroll）：笔记拖拽到抽屉
  /// 上下边缘时由 notes_list 驱动滚动，文件夹多时不用拖出抽屉找目标。
  final ScrollController drawerScroll = ScrollController();

  /// 抽屉列表根 key（auto-scroll 用：取列表可视区域矩形判边缘）。
  final GlobalKey drawerListKey = GlobalKey();

  /// 当前高亮目标（'__new__' = 新建文件夹按钮；其他 = 文件夹 id；null 无）。
  final ValueNotifier<String?> highlighted = ValueNotifier(null);

  /// 笔记拖拽是否进行中（notes_list _beginDrag 置 true / _endDrag 置
  /// false）。拖拽期间抽屉隐藏所有文件夹的选中背景（用户确认：两个
  /// 文件夹同时出现选中效果时紧贴不好看，拖拽中只显示落点高亮）。
  final ValueNotifier<bool> dragging = ValueNotifier(false);

  /// 释放滚动控制器（provider onDispose 调用）。
  void dispose() {
    drawerScroll.dispose();
    highlighted.dispose();
    dragging.dispose();
  }

  /// 注册目标（FolderDrawer build 时逐个调用；重复注册幂等）。
  void register(String id, GlobalKey key) => _keys[id] = key;

  /// 当前注册的全部目标 id（落点命中遍历用）。
  List<String> get keys => _keys.keys.toList();

  /// 清空注册（FolderDrawer build 开头调用，防残留）。
  void reset() => _keys.clear();

  /// 取目标在全局坐标系中的矩形（未挂载返回 null）。
  Rect? rectOf(String id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

final dropZoneRegistryProvider = Provider<DropZoneRegistry>((ref) {
  final registry = DropZoneRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

/// 文件夹仓库：文件夹数据读写统一入口，UI 与同步层共用。
final folderRepositoryProvider = Provider<FolderRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final repo = FolderRepository(
    db.folderDao,
    ref.watch(noteRepositoryProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// 活跃文件夹流（deletedAt IS NULL）：置顶优先 → sortOrder 升序
/// （文件夹抽屉数据源，task-32）。
final foldersStreamProvider = StreamProvider<List<Folder>>((ref) {
  return ref.watch(folderRepositoryProvider).getActiveStream();
});

/// 全部活跃笔记流（不筛选，task-32）：文件夹抽屉计数 / 「全部」计数用
/// （原 task-28 标签栏聚合数据源，标签栏移除后改作抽屉计数）。
final activeNotesStreamProvider = StreamProvider<List<Note>>((ref) {
  return ref.watch(noteRepositoryProvider).getStream();
});

/// UI 设置存储（列表布局模式 + 主题模式，task-26）：构造即触发加载
/// （幂等，见 [AppSettingsStore.ensureLoaded]），加载完成前返回平台默认值。
final appSettingsProvider = Provider<AppSettingsStore>((ref) {
  final store = AppSettingsStore(ref.watch(databaseProvider).deviceDao);
  unawaited(store.ensureLoaded());
  return store;
});

/// 搜索历史存储（编辑页笔记内搜索 / 首页列表搜索各一份，互不相通）：
/// 构造即触发加载（幂等，见 [SearchHistoryStore.ensureLoaded]），加载
/// 完成前 [SearchHistoryStore.entries] 返回空列表。
final searchHistoryProvider = Provider<SearchHistoryStore>((ref) {
  final store = SearchHistoryStore(ref.watch(databaseProvider).deviceDao);
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

/// 笔记列表流：drift 流式查询，置顶优先 → updatedAt 倒序；随搜索关键字
/// 与文件夹筛选自动过滤（并存，task-32）。
///
/// - [folderFilterProvider] 为 null（「全部」）= 所有活跃笔记（含未分类）；
/// - 选中 [kUncategorizedFolderId]（「未分类」）= 仅 folderId 为 null 的笔记；
/// - 选中文件夹 = 仅该文件夹内笔记（folderId == 选中 id）；
/// - 搜索在文件夹过滤结果内生效（与文件夹筛选并存）。
///
/// UI 只消费此流渲染列表；变更一律经 NoteRepository 写库后由 drift 流
/// 自动驱动刷新（单向数据流，见 docs/技术架构.md 第 6 节）。
final notesStreamProvider = StreamProvider<List<Note>>((ref) {
  final keyword = ref.watch(searchQueryProvider);
  final folderId = ref.watch(folderFilterProvider);
  final repo = ref.watch(noteRepositoryProvider);
  if (folderId == null) {
    return repo.search(keyword);
  }
  // 文件夹筛选：在搜索流基础上按 folderId 过滤（个人量级 Dart 侧过滤
  // 开销可忽略）。「未分类」= folderId 为 null 的笔记。
  return repo
      .search(keyword)
      .map(
        (notes) => folderId == kUncategorizedFolderId
            ? notes.where((n) => n.folderId == null).toList()
            : notes.where((n) => n.folderId == folderId).toList(),
      );
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
    folderRepository: ref.watch(folderRepositoryProvider),
    attachments: ref.watch(attachmentsStoreProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
