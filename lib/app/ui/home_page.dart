import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/note.dart';
import '../repository/app_settings.dart';
import '../repository/providers.dart';
import '../repository/search_history.dart';
import '../sync/sync_protocol.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/folder_drawer.dart';
import 'widgets/glass_style.dart';
import 'widgets/notes_list.dart';
import 'widgets/search_history_list.dart';

/// 搜索框是否聚焦（跨组件共享：[HomePage] 的 PopScope 返回键拦截要用）。
/// 由 [_SearchField] 的 FocusNode 监听同步，[HomePage] 只读。
final _searchFocusedProvider = StateProvider<bool>((ref) => false);

/// 双击返回退出：上次按返回的时间戳（null = 无待确认的退出）。
/// 无任何拦截状态时按返回 → 提示「再返回一次退出」并记录时间；
/// 2 秒内再次按返回 → 真正退出（业内标准 2s，Android 主流做法）。
final _lastBackPressProvider = StateProvider<DateTime?>((ref) => null);

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

    // 系统返回（安卓返回键）全量拦截，回调内分级处理：
    // 抽屉 → 搜索聚焦 → 多选 → 双击返回退出。
    // canPop 恒 false：保证每次返回都进回调（否则系统直接 pop 退出，
    // 双击确认与各级拦截都无从触发）；真正退出用 SystemNavigator.pop()
    // 绕过 PopScope 拦截。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 抽屉展开 → 只关抽屉（不退出应用）。
        if (ref.read(folderDrawerOpenProvider)) {
          ref.read(folderDrawerOpenProvider.notifier).state = false;
          ref.read(folderDrawerByDragProvider.notifier).state = false;
          return;
        }
        // 搜索框聚焦 → 只取消聚焦（收起键盘，关键字保留）。
        if (ref.read(_searchFocusedProvider)) {
          FocusManager.instance.primaryFocus?.unfocus();
          return;
        }
        // 多选激活 → 退出多选（不退出应用）。
        if (ref.read(multiSelectProvider).isNotEmpty) {
          ref.read(multiSelectProvider.notifier).exit();
          return;
        }
        // 无拦截状态：双击返回退出（2 秒窗口，业内标准）。
        final now = DateTime.now();
        final last = ref.read(_lastBackPressProvider);
        if (last != null && now.difference(last) < const Duration(seconds: 2)) {
          // 2 秒内再次返回 → 真正退出（时间戳过期视为首次，等价于清除状态）。
          ref.read(_lastBackPressProvider.notifier).state = null;
          SystemNavigator.pop();
          return;
        }
        // 首次返回（或距上次超过 2 秒）：记录时间并提示。
        ref.read(_lastBackPressProvider.notifier).state = now;
        showAppSnackBar('再返回一次退出', duration: const Duration(seconds: 2));
      },
      // 抽屉全屏覆盖（用户确认）：FolderDrawer 挂在 Scaffold 外层 Stack，
      // 高度覆盖整个窗口（含 AppBar 区域），展开时盖住文件夹按钮。
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              // 多选模式：全选 + 已选 N 项 + 完成；普通模式：文件夹按钮 + 三按钮。
              // 全选用文字按钮（需求 7）：视觉密度紧凑，与右侧「完成」样式呼应。
              leading: multiActive
                  ? TextButton(
                      onPressed: () {
                        final ids =
                            ref.read(notesStreamProvider).value ??
                            const <Note>[];
                        ref
                            .read(multiSelectProvider.notifier)
                            .selectAll(ids.map((n) => n.id));
                      },
                      child: const Text('全选'),
                    )
                  // 普通态 leading 留空：文件夹按钮移到外层 Stack（z 序在
                  // 抽屉之上），抽屉展开时按钮在抽屉上层向左滑出（可见）。
                  : const SizedBox.shrink(),
              title: multiActive
                  ? Text(
                      '已选 ${selected.length} 项',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
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
                        tooltip:
                            '${switch (layoutMode) {
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
                        final selected = ref.read(folderFilterProvider);
                        // 「未分类」筛选下新建 = 不归入任何文件夹（哨兵不能入库）。
                        final folderId = selected == kUncategorizedFolderId
                            ? null
                            : selected;
                        final note = await ref
                            .read(noteRepositoryProvider)
                            .createNote(
                              title: '',
                              content: '',
                              folderId: folderId,
                            );
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
      ),
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

/// 搜索框边框：统一无边框（聚焦也不高亮，只显示光标）。
/// 主题 inputDecorationTheme 的 focusedBorder 是主色描边，必须显式覆盖。
const _kSearchBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(24)),
  borderSide: BorderSide.none,
);

/// 搜索历史浮层最大高度（超出后列表内部滚动）。
const double _kHistoryMaxHeight = 320;

class _SearchFieldState extends ConsumerState<_SearchField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  /// dispose 阶段 element 已标记卸载、ref 不可用：initState 时提前持有
  /// notifier（全局 StateProvider，实例稳定），供卸载兜底清聚焦标记用。
  late final StateController<bool> _focusedNotifier;

  /// 历史浮层锚点：挂在搜索框正下方，随搜索框（含键盘顶起）自动跟随。
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlay;

  /// 历史快照（最新的在前）：store 异步加载，加载完成后 setState 刷新。
  List<String> _history = const [];

  /// 输入停顿后自动记录历史的防抖定时器（用户拍板：首页搜索是输入即
  /// 过滤、通常不按回车，只等回车记录会让历史永远为空——改为停止输入
  /// 约 1 秒后记录当前关键词；回车仍是立即记录）。
  Timer? _historyDebounce;
  static const Duration _historyDebounceDelay = Duration(seconds: 1);

  /// 搜索框宽度（LayoutBuilder 在布局阶段写入）：浮层与框同宽。
  double _fieldWidth = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(searchQueryProvider));
    _controller.addListener(_syncToProvider);
    _focusNode = FocusNode(debugLabel: 'SearchField');
    // 聚焦状态同步到 provider：返回键据此先取消聚焦而不是退出应用。
    _focusNode.addListener(_syncFocusToProvider);
    _focusedNotifier = ref.read(_searchFocusedProvider.notifier);
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _historyDebounce?.cancel();
    _removeOverlay();
    _focusNode
      ..removeListener(_syncFocusToProvider)
      ..dispose();
    _controller.dispose();
    // 兜底：卸载时清除聚焦标记，避免 PopScope 永久拦截返回键。
    _focusedNotifier.state = false;
    super.dispose();
  }

  /// 加载搜索历史（[SearchHistoryScope.home]，与编辑页互不相通）。
  ///
  /// 加载完成后再调一次 _updateOverlay：若用户已在历史加载完成前聚焦了
  /// 搜索框，当时历史为空没浮出浮层，这里补一次展开判断——否则浮层会
  /// 永远不出现（setState 只重建子树，不会触发浮层显隐逻辑）。
  Future<void> _loadHistory() async {
    final store = ref.read(searchHistoryProvider);
    await store.ensureLoaded();
    if (!mounted) return;
    setState(() => _history = store.entries(SearchHistoryScope.home));
    _updateOverlay();
  }

  /// 输入即过滤：每次键入把关键字同步到 provider，并同步浮层显隐。
  /// 同时重置历史记录防抖——停止输入 [duration] 后自动记录。
  void _syncToProvider() {
    ref.read(searchQueryProvider.notifier).state = _controller.text;
    _updateOverlay();
    _scheduleHistoryRecord();
  }

  /// 重置防抖：1 秒内持续输入不记录，停下来才记（避免把打了一半的
  /// 关键词存进历史）；输入已清空则取消待执行的记录。
  void _scheduleHistoryRecord() {
    _historyDebounce?.cancel();
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    _historyDebounce = Timer(_historyDebounceDelay, () {
      unawaited(_recordHistory(keyword));
    });
  }

  Future<void> _recordHistory(String keyword) async {
    final store = ref.read(searchHistoryProvider);
    await store.add(SearchHistoryScope.home, keyword);
    if (!mounted) return;
    setState(() => _history = store.entries(SearchHistoryScope.home));
  }

  /// 聚焦变化同步到 provider（返回键拦截用）+ 浮层显隐。
  void _syncFocusToProvider() {
    ref.read(_searchFocusedProvider.notifier).state = _focusNode.hasFocus;
    _updateOverlay();
  }

  /// 回车提交：记入历史（用户确认：只记真正提交过的关键词）。
  Future<void> _submit(String value) async {
    // 回车是明确提交，立即记录；取消可能还在等待的防抖（去重无害，
    // 但避免 1 秒后同一词再走一遍写库）。
    _historyDebounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) return;
    final store = ref.read(searchHistoryProvider);
    await store.add(SearchHistoryScope.home, keyword);
    if (!mounted) return;
    setState(() => _history = store.entries(SearchHistoryScope.home));
  }

  /// 点历史项：填入搜索框（文本变化即过滤列表）并保持聚焦。
  void _pickHistory(String keyword) {
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(offset: keyword.length);
    _focusNode.requestFocus();
  }

  /// 删除单条历史。
  Future<void> _removeHistory(String keyword) async {
    await ref
        .read(searchHistoryProvider)
        .remove(SearchHistoryScope.home, keyword);
    if (!mounted) return;
    setState(() => _history = List.of(_history)..remove(keyword));
    _updateOverlay();
  }

  /// 清空全部历史。
  Future<void> _clearHistory() async {
    await ref.read(searchHistoryProvider).clear(SearchHistoryScope.home);
    if (!mounted) return;
    setState(() => _history = const []);
    _updateOverlay();
  }

  /// 浮层显隐：仅「聚焦 + 无输入 + 有历史」时展开（输入中/失焦即收起）。
  ///
  /// 已展开时显式 markNeedsBuild：OverlayEntry 不在本 State 的子树里，
  /// setState 重建不到它，删除/清空历史后必须让它重建（条目数与面板
  /// 高度都会变）。
  void _updateOverlay() {
    final shouldShow =
        _focusNode.hasFocus &&
        _controller.text.isEmpty &&
        _history.isNotEmpty &&
        _fieldWidth > 0;
    if (shouldShow && _overlay == null) {
      _overlay = OverlayEntry(builder: _buildHistoryOverlay);
      Overlay.of(context).insert(_overlay!);
    } else if (!shouldShow && _overlay != null) {
      _removeOverlay();
    } else if (shouldShow) {
      _overlay?.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  /// 历史浮层：全屏挡层（点外部收起）+ 锚定搜索框的玻璃面板。
  Widget _buildHistoryOverlay(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final height = SearchHistoryList.preferredHeightFor(
      _history.length,
    ).clamp(0.0, _kHistoryMaxHeight).toDouble();
    return Stack(
      children: [
        // 挡层：opaque 阻止点击穿透到下层卡片（先收起，不误触笔记）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _focusNode.unfocus();
              _removeOverlay();
            },
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: _fieldWidth,
              height: height,
              child: Material(
                // Overlay 里没有 Material 祖先，而列表用 InkWell/
                // TextButton/IconButton——缺 Material 会直接抛
                // "No Material widget found"；透明 Material 只提供
                // Ink 画布，背景仍由下层玻璃装饰决定。
                type: MaterialType.transparency,
                child: glassWrap(
                  child: Container(
                    decoration: styledDecoration(isDark: isDark),
                    child: SearchHistoryList(
                      entries: _history,
                      onPick: _pickHistory,
                      onRemove: _removeHistory,
                      onClearAll: _clearHistory,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
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

    return CompositedTransformTarget(
      link: _layerLink,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 记录搜索框宽度：浮层据此同宽（布局阶段写入，无副作用）。
          _fieldWidth = constraints.maxWidth;
          return TextField(
            controller: _controller,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            onSubmitted: _submit,
            // 点击搜索框外部区域 → 取消聚焦（收起键盘），关键字保留。
            // 浮层展开时交给挡层处理：这里直接 unfocus 会先拆掉浮层，
            // 导致点历史项的手势丢失。
            onTapOutside: (_) {
              if (_overlay == null) _focusNode.unfocus();
            },
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
              // 全部无边框：聚焦也不高亮（覆盖主题 focusedBorder 的描边）。
              border: _kSearchBorder,
              enabledBorder: _kSearchBorder,
              focusedBorder: _kSearchBorder,
              disabledBorder: _kSearchBorder,
              errorBorder: _kSearchBorder,
              focusedErrorBorder: _kSearchBorder,
            ),
          );
        },
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
