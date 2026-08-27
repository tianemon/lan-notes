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
import 'widgets/app_icons.dart';
import 'widgets/folder_drawer.dart';
import 'widgets/notes_list.dart';

/// 主页：笔记列表页。
///
/// 布局（task-32 文件夹归类重构）：
/// - 第一行 AppBar：普通态 = [文件夹按钮][同步状态点][排列][设置]；
///   多选态 = [全选][已选 N 项][完成]；
/// - 第二行搜索框独占一行（原 AppBar title 下移，用户确认）；
/// - 标签筛选栏已移除（task-32，切换文件夹靠左侧抽屉）；
/// - 右下角圆形新建按钮：点击直接新建笔记；新建入口经
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

    // 抽屉全屏覆盖（用户确认）：FolderDrawer 挂在 Scaffold 外层 Stack，
    // 高度覆盖整个窗口（含 AppBar 区域），展开时盖住文件夹按钮。
    return Stack(
      children: [
        Scaffold(
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
            // 普通态 leading 留空：文件夹按钮移到外层 Stack（z 序在
            // 抽屉之上），抽屉展开时按钮在抽屉上层向左滑出（可见）。
            : const SizedBox.shrink(),
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
        ],
      ),
      // 新建入口：右下角圆形按钮，点击直接新建笔记（task-32 曾改为扇形
      // 菜单，用户确认简化回直接新建；多选模式下隐藏）。
      floatingActionButton: multiActive
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 16),
              child: _FrostedFab(
                onPressed: () async {
                  final folderId = ref.read(folderFilterProvider);
                  final note = await ref
                      .read(noteRepositoryProvider)
                      .createNote(title: '', content: '', folderId: folderId);
                  if (!context.mounted || note.id.isEmpty) return;
                  context.push('/editor/${note.id}');
                },
              ),
            ),
      ),
        // 文件夹按钮（静止，用户确认：去掉跟随抽屉滑出的动画）。
        // 声明在 FolderDrawer **之前**（Stack 后声明者在上层）——
        // 抽屉展开时面板自然盖住按钮，收回时原位露出，无位移动画。
        // 多选模式隐藏（避免与多选框重叠）；top 含状态栏高度
        // （手机端 SafeArea，不与系统通知栏重叠）。
        if (!multiActive)
          Positioned(
            left: 4,
            top: MediaQuery.paddingOf(context).top + 4,
            child: IconButton(
              tooltip: '文件夹',
              icon: const AppFolderIcon(),
              onPressed: () {
                final open = ref.read(folderDrawerOpenProvider);
                ref.read(folderDrawerOpenProvider.notifier).state = !open;
                ref.read(folderDrawerByDragProvider.notifier).state = false;
              },
            ),
          ),
        // 文件夹抽屉（全屏玻璃面板：覆盖整个窗口高度；声明在按钮之后，
        // Stack 上层——展开时盖住按钮，层次正确）。
        const FolderDrawer(),
      ],
    );
  }
}

/// 右下角毛玻璃圆形新建按钮（照搬 EE home_screen._buildFrostedFab）：
/// BackdropFilter blur 15 + add 图标 + 玻璃底色（暗色白 12% / 亮色黑 8%）。
/// 点击直接新建笔记（用户确认：不再弹出扇形菜单）。
class _FrostedFab extends StatelessWidget {
  const _FrostedFab({required this.onPressed});

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
            // 暖奶油玻璃（用户确认）：亮色 = kLightFabGlass #F5EFE3
            // 90% 半透明 + 暖黑 + 图标；暗色保持白 12%。主按钮与
            // 选项按钮同配色（用户确认），并带同款阴影提升层次。
            color: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : kLightFabGlass.withValues(alpha: 0.90),
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
                        : kLightTextPrimary.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.34 : 0.12,
                      ),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    Icons.add,
                    size: 28,
                    color: isDark ? kDarkTextPrimary : kLightTextPrimary,
                  ),
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

/// 列表页顶部标签筛选栏已移除（task-32：切换文件夹靠左侧抽屉，
/// 用户确认移除标签栏；编辑页标签编辑保留）。
