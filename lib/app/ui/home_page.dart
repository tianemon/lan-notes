import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/note.dart';
import '../repository/app_settings.dart';
import '../repository/providers.dart';
import '../sync/sync_protocol.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import 'widgets/folder_drawer.dart';
import 'widgets/note_actions.dart';
import 'widgets/notes_list.dart';

/// 主页：笔记列表页。
///
/// 布局（task-32 文件夹归类重构）：
/// - 第一行 AppBar：普通态 = [文件夹按钮][同步状态点][排列][设置]；
///   多选态 = [全选][已选 N 项][完成]；
/// - 第二行搜索框独占一行（原 AppBar title 下移，用户确认）；
/// - 标签筛选栏已移除（task-32，切换文件夹靠左侧抽屉）；
/// - 右下角扇形新建菜单（文件夹/笔记）；新建入口经
///   [NoteRepository.createNote]（选中文件夹时自动归入）。
/// 路由见 docs/技术架构.md 第 5 节。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  /// 循环切换布局模式：单列 → 双列 → 单列。
  void _cycleLayout(WidgetRef ref) {
    // 仅单列/双列两种模式循环（四列已取消，用户确认）。
    final next = switch (ref.read(layoutModeProvider)) {
      kLayoutModeSingle => kLayoutModeDouble,
      _ => kLayoutModeSingle,
    };
    ref.read(layoutModeProvider.notifier).state = next;
    // 持久化：下次启动沿用本次选择（main.dart _loadUiSettings 恢复）。
    ref.read(appSettingsProvider).setLayoutMode(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layoutMode = ref.watch(layoutModeProvider);
    final selected = ref.watch(multiSelectProvider);
    final multiActive = selected.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        // 多选模式：全选 + 已选 N 项 + 完成；普通模式：文件夹按钮 + 三按钮。
        leading: multiActive
            ? IconButton(
                tooltip: '全选',
                icon: const Icon(Icons.select_all),
                onPressed: () {
                  final ids = ref
                          .read(notesStreamProvider)
                          .value ??
                      const <Note>[];
                  ref
                      .read(multiSelectProvider.notifier)
                      .selectAll(ids.map((n) => n.id));
                },
              )
            : IconButton(
                tooltip: '文件夹',
                icon: const Icon(Icons.folder_outlined),
                onPressed: () {
                  final open = ref.read(folderDrawerOpenProvider);
                  ref.read(folderDrawerOpenProvider.notifier).state = !open;
                  ref.read(folderDrawerByDragProvider.notifier).state = false;
                },
              ),
        title: multiActive
            ? Text(
                '已选 ${selected.length} 项',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              )
            : null,
        actions: multiActive
            ? [
                TextButton(
                  onPressed: () =>
                      ref.read(multiSelectProvider.notifier).exit(),
                  child: const Text('完成'),
                ),
              ]
            : [
                // 同步状态点（在线绿 / 离线灰），点击进同步页——不占列表空间。
                const _SyncStatusDot(),
                // 排列模式切换（EE 式图标：view_list / view_column / grid_view）
                IconButton(
                  tooltip: '${switch (layoutMode) {
                    kLayoutModeSingle => '单列',
                    _ => '双列',
                  }}（点击切换排列）',
                  icon: switch (layoutMode) {
                    // 单列：1x2（上下堆叠）；双列：2x2（两列网格）——
                    // 现成 Cupertino 图标直接表达语义（用户确认）。
                    kLayoutModeSingle => const Icon(
                        CupertinoIcons.rectangle_grid_1x2,
                      ),
                    _ => const Icon(CupertinoIcons.rectangle_grid_2x2),
                  },
                  onPressed: () => _cycleLayout(ref),
                ),
                IconButton(
                  tooltip: '设置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => context.push('/settings'),
                ),
              ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 第二行：搜索框独占一行（task-32 布局重构）。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                child: const _SearchField(),
              ),
              const Expanded(child: NotesList()),
            ],
          ),
          // 扇形菜单展开时的全屏收回区（在抽屉之下：点抽屉仍正常；
          // FAB 在 Scaffold 槽位上层，点击 FAB 不触发收回）。
          if (ref.watch(fabOpenProvider))
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => ref.read(fabOpenProvider.notifier).state = false,
              ),
            ),
          // 文件夹抽屉（玻璃面板，含全部/置顶区/普通区 + 拖放落点）。
          const FolderDrawer(),
        ],
      ),
      // 新建入口：右下角扇形菜单（恢复 Scaffold 槽位，与改版前位置一致；
      // 多选模式下隐藏）。
      floatingActionButton: multiActive
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 16),
              child: const _FabMenu(),
            ),
    );
  }
}

/// 右下角扇形新建菜单（task-32）：点击 FAB 展开两个 56px 圆形按钮
/// （文件夹在上、笔记在左），再点 FAB 或点其他区域收回。
///
/// - 「文件夹」→ 弹命名框创建文件夹；
/// - 「笔记」→ 直接创建空白笔记进编辑页（选中文件夹时自动归入）。
class _FabMenu extends ConsumerStatefulWidget {
  const _FabMenu();

  @override
  ConsumerState<_FabMenu> createState() => _FabMenuState();
}

class _FabMenuState extends ConsumerState<_FabMenu> {
  bool _open = false;

  /// 展开/收回：同步 fabOpenProvider（HomePage 全屏收回区据此显示）。
  void _setOpen(bool v) {
    setState(() => _open = v);
    ref.read(fabOpenProvider.notifier).state = v;
  }

  /// 新建文件夹：命名框 → 创建。
  Future<void> _createFolder() async {
    _setOpen(false);
    if (!mounted) return;
    final name = await showFolderNameDialog(context, title: '新建文件夹');
    if (name == null || !mounted) return;
    await ref.read(folderRepositoryProvider).createFolder(name);
  }

  /// 新建笔记：创建空白笔记进编辑页（当前选中文件夹时自动归入）。
  Future<void> _createNote() async {
    _setOpen(false);
    if (!mounted) return;
    final folderId = ref.read(folderFilterProvider);
    final note = await ref
        .read(noteRepositoryProvider)
        .createNote(title: '', content: '', folderId: folderId);
    if (!mounted || note.id.isEmpty) return;
    context.push('/editor/${note.id}');
  }

  @override
  Widget build(BuildContext context) {
    // 容器 132×132：FAB 在右下角（中心 (104,104)）；选项按钮展开位置
    // 按原型精确坐标（fo-a 文件夹 上方 -4/-66；fo-b 笔记 左侧 -66/-4，
    // 相对 FAB 中心），收起时与 FAB 中心重合。
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 扇形按钮：文件夹（上方）、笔记（左侧）。
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: const Cubic(0.32, 0.72, 0, 1),
            left: _open ? 72 : 76,
            top: _open ? 10 : 76,
            child: IgnorePointer(
              ignoring: !_open,
              child: _FabOption(
                icon: Icons.folder_outlined,
                tooltip: '新建文件夹',
                onTap: _createFolder,
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: const Cubic(0.32, 0.72, 0, 1),
            left: _open ? 10 : 76,
            top: _open ? 72 : 76,
            child: IgnorePointer(
              ignoring: !_open,
              child: _FabOption(
                icon: Icons.note_alt_outlined,
                tooltip: '新建笔记',
                onTap: _createNote,
              ),
            ),
          ),
          // FAB 主按钮：点击展开/收回（图标旋转 45°，原型同款）。
          Positioned(
            right: 0,
            bottom: 0,
            child: _FrostedFab(
              open: _open,
              onPressed: () => _setOpen(!_open),
            ),
          ),
        ],
      ),
    );
  }
}

/// 扇形选项按钮（与 FAB 同尺寸 56px 圆形，玻璃样式）。
class _FabOption extends StatelessWidget {
  const _FabOption({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 56,
      height: 56,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Material(
            // 原型色值：亮色黑 6% / 暗色白 10%（与 FAB 主按钮一致）。
            color: (isDark ? Colors.white : Colors.black)
                .withValues(alpha: isDark ? 0.10 : 0.06),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.black.withValues(alpha: 0.06),
                    width: 0.5,
                  ),
                ),
                child: Tooltip(
                  message: tooltip,
                  child: Center(child: Icon(icon, size: 24)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 右下角毛玻璃圆形新建按钮（照搬 EE home_screen._buildFrostedFab）：
/// BackdropFilter blur 15 + add 图标 + 玻璃底色（暗色白 12% / 亮色黑 8%）。
/// 展开时图标旋转 45°（+ → ×，常见展开状态提示）。
class _FrostedFab extends StatelessWidget {
  const _FrostedFab({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 56,
      height: 56,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Material(
            // 原型色值：亮色黑 6% / 暗色白 10%（用户确认恢复）。
            color: (isDark ? Colors.white : Colors.black)
                .withValues(alpha: isDark ? 0.10 : 0.06),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.black.withValues(alpha: 0.06),
                    width: 0.5,
                  ),
                ),
                child: AnimatedRotation(
                  turns: open ? 0.125 : 0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: const Center(child: Icon(Icons.add, size: 28)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// AppBar 搜索框：绑定 [searchQueryProvider]，输入即过滤，支持一键清空。
class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(searchQueryProvider));
    _controller.addListener(_syncToProvider);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 输入即过滤：每次键入把关键字同步到 provider。
  void _syncToProvider() {
    ref.read(searchQueryProvider.notifier).state = _controller.text;
  }

  @override
  Widget build(BuildContext context) {
    // provider 被外部修改（如清空按钮）时同步回输入框
    ref.listen(searchQueryProvider, (_, next) {
      if (_controller.text != next) {
        _controller.text = next;
      }
    });

    final theme = Theme.of(context);
    final hasQuery = ref.watch(searchQueryProvider).isNotEmpty;

    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      style: theme.textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: '搜索笔记',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: hasQuery
            ? IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.close),
                onPressed: _controller.clear,
              )
            : null,
        isDense: true,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerLow,
        contentPadding: EdgeInsets.zero,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ============================================================
// task-28 新增组件：离线状态条 + 标签筛选栏
// ============================================================

/// 同步状态点（AppBar 右上角）：在线绿点 / 离线灰点，点击进同步页。
///
/// 参考成熟产品模式（状态点不占布局空间，一眼可见）。
/// 状态来源复用同步页的既有流（[SyncService.devicesUpdates] /
/// [SyncService.peerDevices]），无需新增连接状态 API。
class _SyncStatusDot extends ConsumerStatefulWidget {
  const _SyncStatusDot();

  @override
  ConsumerState<_SyncStatusDot> createState() => _SyncStatusDotState();
}

class _SyncStatusDotState extends ConsumerState<_SyncStatusDot> {
  StreamSubscription<List<DeviceInfo>>? _devicesSub;
  StreamSubscription<List<PeerDevice>>? _peersSub;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    final service = ref.read(syncServiceProvider);
    _connected = service.isConnected;
    _devicesSub = service.devicesUpdates.listen((_) => _refresh());
    _peersSub = service.peerDevices.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _peersSub?.cancel();
    super.dispose();
  }

  /// 重新读取连接状态：变化时重建（避免无意义重建）。
  void _refresh() {
    if (!mounted) return;
    final connected = ref.read(syncServiceProvider).isConnected;
    if (connected != _connected) {
      setState(() => _connected = connected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = _connected ? kStatusConnected : kStatusDisconnected;
    return IconButton(
      tooltip: _connected ? '已连接（点此进入同步）' : '离线中，改动将稍后同步（点此进入同步）',
      onPressed: () => context.push('/sync'),
      icon: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: dotColor.withValues(alpha: 0.5),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}
/// - 已连接（[SyncService.isConnected]）→ 绿点「已连接」；
/// - 未开启同步 / 未连接 → 灰点「离线中，改动将稍后同步」。
///
/// 状态来源复用同步页的既有流（[SyncService.devicesUpdates] /
/// [SyncService.peerDevices]，会话就绪/断开/开关切换均会发出），
/// 无需新增连接状态 API。
class _OfflineStatusBar extends ConsumerStatefulWidget {
  const _OfflineStatusBar();

  @override
  ConsumerState<_OfflineStatusBar> createState() => _OfflineStatusBarState();
}

class _OfflineStatusBarState extends ConsumerState<_OfflineStatusBar> {
  StreamSubscription<List<DeviceInfo>>? _devicesSub;
  StreamSubscription<List<PeerDevice>>? _peersSub;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    final service = ref.read(syncServiceProvider);
    _connected = service.isConnected;
    _devicesSub = service.devicesUpdates.listen((_) => _refresh());
    _peersSub = service.peerDevices.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _peersSub?.cancel();
    super.dispose();
  }

  /// 重新读取连接状态：变化时重建（避免无意义重建）。
  void _refresh() {
    if (!mounted) return;
    final connected = ref.read(syncServiceProvider).isConnected;
    if (connected != _connected) {
      setState(() => _connected = connected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = _connected ? kStatusConnected : kStatusDisconnected;
    return IconButton(
      tooltip: _connected ? '已连接（点此进入同步）' : '离线中，改动将稍后同步（点此进入同步）',
      onPressed: () => context.push('/sync'),
      icon: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: dotColor.withValues(alpha: 0.5),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表页顶部标签筛选栏已移除（task-32：切换文件夹靠左侧抽屉，
/// 用户确认移除标签栏；编辑页标签编辑保留）。
