import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../repository/app_settings.dart';
import '../repository/providers.dart';
import '../sync/sync_protocol.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import 'widgets/notes_list.dart';

/// 主页：笔记列表页。
///
/// AppBar 含搜索框（绑定 [searchQueryProvider]，输入即过滤、支持清空）、
/// 排列模式切换（单列/双列/四列瀑布流循环，持久化，task-26）、设置入口
/// （跳 `/settings`）；同步、回收站入口已移入设置页（task-26）。
/// 新建入口为右下角毛玻璃 FAB（照搬 EE _buildFrostedFab，task-26）。
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

    return Scaffold(
      appBar: AppBar(
        title: const _SearchField(),
        actions: [
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
              kLayoutModeSingle => const Icon(CupertinoIcons.rectangle_grid_1x2),
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
      body: Column(
        children: [
          // 标签筛选栏（task-28）：「全部」+ 聚合标签，横滑 chips。
          const _TagFilterBar(),
          const Expanded(child: NotesList()),
        ],
      ),
      // 毛玻璃新建按钮（照搬 EE _buildFrostedFab，task-26）：悬浮于列表
      // 之上，与滚动共存；列表底部留白避免遮挡最后一张卡片。
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 16),
        child: _FrostedFab(
          onPressed: () async {
            // 方案B：点击直接创建空白笔记并进入编辑态（无「新建态」）；
            // 返回时若未输入任何内容，编辑页会物理删除该空笔记。
            final note = await ref
                .read(noteRepositoryProvider)
                .createNote(title: '', content: '');
            if (!context.mounted || note.id.isEmpty) return;
            context.push('/editor/${note.id}');
          },
        ),
      ),
    );
  }
}

/// 右下角毛玻璃圆形新建按钮（照搬 EE home_screen._buildFrostedFab）：
/// BackdropFilter blur 15 + add 图标 + 玻璃底色（暗色白 12% / 亮色黑 8%）。
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
            color: (isDark ? Colors.white : Colors.black)
                .withValues(alpha: isDark ? 0.12 : 0.08),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: const Center(child: Icon(Icons.add, size: 28)),
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

/// 列表页顶部标签筛选栏（task-28）：横滑 chips——「全部」+ 聚合标签列表。
///
/// 数据源 [tagsProvider]（从全部笔记流聚合去重）；点击切换
/// [tagFilterProvider]，与搜索关键字并存（notesStreamProvider 同时过滤）。
class _TagFilterBar extends ConsumerWidget {
  const _TagFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    final selected = ref.watch(tagFilterProvider);
    if (tags.isEmpty && selected.isEmpty) {
      // 无标签可筛选：不占高度（列表直接贴顶）。
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _buildChip(
            context,
            label: '全部',
            selected: selected.isEmpty,
            onTap: () =>
                ref.read(tagFilterProvider.notifier).state = '',
          ),
          for (final tag in tags)
            _buildChip(
              context,
              label: tag,
              selected: selected == tag,
              onTap: () => ref.read(tagFilterProvider.notifier).state = tag,
            ),
        ],
      ),
    );
  }

  /// 单个标签 pill：选中用强调色填充，未选中用表面低层色描边。
  Widget _buildChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary
                : colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? colorScheme.primary : colorScheme.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected
                  ? colorScheme.onPrimary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
