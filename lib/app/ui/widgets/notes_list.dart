import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/note.dart';
import '../../repository/providers.dart';
import '../../theme.dart';
import 'empty_hint.dart';
import 'format.dart';
import 'glass_style.dart';
import 'note_actions.dart';

/// 笔记列表：消费 [notesStreamProvider]，按 updatedAt 倒序渲染。
///
/// 数据流见 docs/技术架构.md 第 6 节：UI 只消费流，写库一律走
/// NoteRepository，drift 流自动驱动刷新。
///
/// 交互（task-32，参照原型自绘手势）：
/// - 长按卡片（300ms）→ 进入多选（浮起动画 + 默认选中）→ **不松手继续
///   拖动直接拖拽**（原型交互：长按进多选后同一手势延续为拖拽）；
/// - 多选模式：按下已选卡可直接拖（未移动松手 = 取消选中），按下未选卡
///   立即选中并可拖；
/// - 拖拽：方形迷你卡层叠 + 拖影跟随；左侧 70px 圆角梯形触发区（拖拽
///   中才出现）→ 拖入展开抽屉；落点命中文件夹/「新建文件夹」→ 批量移动；
///   落空 → ghost 飞回 + 卡片回归（多选保持）。
///
/// 布局（task-26，多列错落）：消费 [layoutModeProvider]——单列 ListView /
/// 双列瀑布流。动效（task-25）：空态切换 AnimatedSwitcher；列表项新增/
/// 恢复由 [NoteListItem] 自带动画。
class NotesList extends ConsumerStatefulWidget {
  const NotesList({super.key});

  @override
  ConsumerState<NotesList> createState() => _NotesListState();
}

/// 按压状态（一次指针按下到抬起）。
class _PressState {
  _PressState({
    required this.id,
    required this.globalPos,
    required this.offsetInCard,
    required this.cardRect,
  });

  final String id;
  final Offset globalPos;

  /// 按下点相对卡片左上角（ghost 定位偏移）。
  final Offset offsetInCard;

  /// 按下时卡片矩形（回弹参考）。
  final Rect cardRect;

  bool moved = false;
  bool canDrag = false; // 多选模式下可拖（已选卡 / 刚点选的未选卡）
  bool pendingDeselect = false; // 已选卡按下：未移动松手 = 取消选中
  Timer? timer; // 300ms 长按进入多选
}

/// 拖拽状态。
class _DragState extends ChangeNotifier {
  _DragState({
    required this.ids,
    required this.mainId,
    required this.offsetInCard,
    required this.rects,
    required this.position,
  });

  /// 选中的全部笔记 id（拖拽集合快照）。
  final List<String> ids;

  /// 拖拽源卡片 id（主卡）。
  final String mainId;

  /// 指针相对主卡的偏移。
  final Offset offsetInCard;

  /// 每张选中卡拖拽前的原矩形（回弹目标）。
  final Map<String, Rect> rects;

  /// ghost 左上角位置（全局坐标）。
  Offset position;

  /// 当前命中的落点（null 无；'__new__' = 新建文件夹按钮；其他 = 文件夹 id）。
  String? target;

  /// 位置/落点更新通知（ghost 层重建）。
  void update() => notifyListeners();
}

class _NotesListState extends ConsumerState<NotesList> {
  /// 左侧梯形触发区参数（用户确认：宽 70px、高 75% 窗口、垂直居中、
  /// 左宽右窄圆角梯形；拖拽动作开始后才出现）。
  static const double zoneWidth = 70;
  static const double zoneHeightRatio = 0.75;

  _PressState? _press;
  _DragState? _drag;

  /// 抽卡集合：拖拽中隐藏（其他卡片补位），松手恢复。
  Set<String> _hiddenIds = {};

  /// 卡片矩形注册表（id → GlobalKey，首次创建复用保证 state 不丢）。
  final Map<String, GlobalKey> _cardKeys = {};

  /// 浮起动画信号（长按进入多选的卡片 + 序号）。
  String? _liftId;
  int _liftSeq = 0;

  /// 梯形触发区 Path（beginDrag 时按窗口尺寸构建，命中检测用）。
  Path? _zonePath;

  OverlayEntry? _ghostEntry;
  PointerRoute? _globalRoute;

  /// 左侧拖放区是否显示（拖拽中）。
  bool _dragging_ = false;

  /// 当前选中集合（watch 由 build 驱动，read 由手势用）。
  Set<String> _selectedNow() => ref.read(multiSelectProvider);

  bool _multiNow() => _selectedNow().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(notesStreamProvider);
    final isSearching = ref.watch(searchQueryProvider).trim().isNotEmpty;
    final layoutMode = ref.watch(layoutModeProvider);
    final multiActive = ref.watch(multiSelectProvider).isNotEmpty;
    // 兜底：多选退出（拖到文件夹落点移动后 exit）时残留的拖拽态一并清除
    //（拖拽回调因组件卸载不再触发清理的场景）。
    if (!multiActive && _dragging_) {
      _dragging_ = false;
    }

    final body = notesAsync.when(
      // 搜索关键字变化（provider 因 watch 重建）时沿用旧数据，避免输入过程闪 loading
      skipLoadingOnReload: true,
      data: (notes) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          // 默认 Stack 对齐是 center：多列列表内容不足时会被垂直居中。
          // 改为顶对齐（列表从顶部开始）；空态内部自行居中（见 _EmptyState）。
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: [
              ...previousChildren,
              ?currentChild,
            ],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: notes.isEmpty
              ? _EmptyState(
                  key: const ValueKey('empty'),
                  isSearching: isSearching,
                )
              : _NoteListBody(
                  key: const ValueKey('list'),
                  notes: notes,
                  columns: layoutMode,
                  cardKeys: _cardKeys,
                  hiddenIds: _hiddenIds,
                  onRegisterCard: _registerCard,
                ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('加载失败：$error')),
    );

    return Listener(
      // 原始指针事件：长按计时 + 拖拽（不参与手势竞技场，与卡片 InkWell
      // 的 tap/longPress 并存；拖拽开始后经全局路由接收后续 move/up）。
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        // 多选模式下点空白退出多选（卡片点击被消费，不冒泡到这里；
        // 拖拽中不触发退出）。
        behavior: HitTestBehavior.translucent,
        onTap: multiActive && !_dragging_
            ? () => ref.read(multiSelectProvider.notifier).exit()
            : null,
        child: Stack(
          children: [
            Positioned.fill(child: body),
            // 左侧圆角梯形触发区：拖拽动作开始后才出现（用户确认）。
            if (_dragging_)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: zoneWidth,
                child: IgnorePointer(
                  child: _DropZoneTrapezoid(
                    heightRatio: zoneHeightRatio,
                    width: zoneWidth,
                  ),
                ),
              ),
            // 底部多选操作面板（非模态：拖拽共存）。
            if (multiActive)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _MultiSelectSheet(),
              ),
          ],
        ),
      ),
    );
  }

  // ===== 卡片注册 =====

  void _registerCard(String id, GlobalKey key) {
    _cardKeys[id] = key;
  }

  /// 命中检测：全局坐标落在哪张卡片上。
  String? _cardAt(Offset globalPos) {
    for (final entry in _cardKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(globalPos)) return entry.key;
    }
    return null;
  }

  // ===== 手势：按下 =====

  void _onPointerDown(PointerDownEvent e) {
    if (_dragging_) return;
    final id = _cardAt(e.position);
    if (id == null) return;
    final box =
        (_cardKeys[id]?.currentContext?.findRenderObject() as RenderBox?);
    final cardRect = box == null
        ? const Rect.fromLTWH(0, 0, 0, 0)
        : (box.localToGlobal(Offset.zero) & box.size);
    final press = _PressState(
      id: id,
      globalPos: e.position,
      offsetInCard: e.position - cardRect.topLeft,
      cardRect: cardRect,
    );
    _press = press;
    if (!_multiNow()) {
      // 非多选：300ms 长按进入多选（不松手继续拖，见 _beginMultiSelect）。
      press.timer = Timer(
        const Duration(milliseconds: 300),
        () => _beginMultiSelect(id),
      );
    } else {
      final selected = _selectedNow();
      if (selected.contains(id)) {
        // 已选卡：可直接拖；未移动松手 = 取消选中（原型 pendingDeselect）。
        press.canDrag = true;
        press.pendingDeselect = true;
      } else {
        // 未选卡：立即选中并可拖（原型：按下即加入选中）。
        ref.read(multiSelectProvider.notifier).toggle(id);
        press.canDrag = true;
        press.pendingDeselect = false;
      }
    }
  }

  // ===== 手势：移动 =====

  void _onPointerMove(PointerMoveEvent e) {
    final p = _press;
    if (p == null) {
      if (_dragging_) _moveDrag(e.position);
      return;
    }
    final dist = (e.position - p.globalPos).distance;
    if (dist > 10) {
      p.moved = true;
      p.timer?.cancel();
      // 长按进入多选后（或多选模式按下可拖卡）移动超阈值 → 开始拖拽。
      if (_multiNow() && p.canDrag && !_dragging_) {
        _beginDrag(e.position);
      }
    }
    if (_dragging_) _moveDrag(e.position);
  }

  // ===== 手势：抬起 / 取消 =====

  void _onPointerUp(PointerUpEvent e) {
    final p = _press;
    if (p == null) {
      if (_dragging_) _endDrag();
      return;
    }
    p.timer?.cancel();
    if (_dragging_) {
      _endDrag();
      _press = null;
      return;
    }
    // 已选卡按下未移动松手：取消选中（点击 toggle 由卡片 InkWell 处理，
    // 这里只处理"已选卡点按取消"的原型语义，避免双重 toggle）。
    if (_multiNow() && p.pendingDeselect && !p.moved) {
      ref.read(multiSelectProvider.notifier).toggle(p.id);
    }
    _press = null;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _press?.timer?.cancel();
    _press = null;
    if (_dragging_) _endDrag();
  }

  // ===== 进入多选（长按触发） =====

  void _beginMultiSelect(String id) {
    final notifier = ref.read(multiSelectProvider.notifier);
    if (notifier.active) return;
    notifier.enter(id);
    setState(() {
      _liftId = id;
      _liftSeq++;
    });
    final p = _press;
    if (p != null) {
      // 长按后不松手：同一次手势延续为拖拽（原型核心交互）。
      p.canDrag = true;
      p.pendingDeselect = false;
    }
  }

  // ===== 拖拽 =====

  void _beginDrag(Offset globalPos) {
    final selected = _selectedNow();
    if (selected.isEmpty) return;
    final p = _press!;
    // 记录每张选中卡原矩形（回弹目标）。
    final rects = <String, Rect>{};
    for (final id in selected) {
      final ctx = _cardKeys[id]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null) rects[id] = box.localToGlobal(Offset.zero) & box.size;
    }
    final drag = _DragState(
      ids: List<String>.of(selected),
      mainId: p.id,
      offsetInCard: p.offsetInCard,
      rects: rects,
      position: globalPos - p.offsetInCard,
    );
    _drag = drag;
    setState(() {
      _dragging_ = true;
      // 抽卡：选中的卡片从列表抽走（其他卡片补位），松手恢复。
      _hiddenIds = Set<String>.of(selected);
      // 触发区：拖拽动作开始后才出现（用户确认）。
      final size = MediaQuery.sizeOf(context);
      _zonePath = _buildZonePath(size);
    });
    // ghost 层（Overlay 顶层渲染，不挤压列表；笔记数据快照传入）。
    final currentNotes =
        ref.read(notesStreamProvider).value ?? const <Note>[];
    _ghostEntry = OverlayEntry(
      builder: (_) => _GhostLayer(
        drag: drag,
        isFlyingBack: false,
        notes: currentNotes,
      ),
    );
    Overlay.of(context).insert(_ghostEntry!);
    // 全局路由：指针移出列表区域（抽屉上/屏幕边缘）仍能收到 move/up。
    _globalRoute = (event) {
      if (event is PointerMoveEvent) {
        _moveDrag(event.position);
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        _endDrag();
      }
    };
    WidgetsBinding.instance.pointerRouter.addGlobalRoute(_globalRoute!);
  }

  void _moveDrag(Offset globalPos) {
    final d = _drag;
    if (d == null) return;
    d.position = globalPos - d.offsetInCard;
    d.update();
    // 梯形触发区命中 → 展开抽屉（drag-mode 无 backdrop）。
    if (_zonePath?.contains(globalPos) ?? false) {
      if (!ref.read(folderDrawerOpenProvider)) {
        ref.read(folderDrawerOpenProvider.notifier).state = true;
        ref.read(folderDrawerByDragProvider.notifier).state = true;
      }
    }
    // 落点命中检测（抽屉展开时）：新建文件夹按钮 + 各文件夹项。
    final registry = ref.read(dropZoneRegistryProvider);
    String? target;
    if (ref.read(folderDrawerOpenProvider)) {
      final candidates = ['__new__', ...registry.keys];
      for (final id in candidates) {
        final r = registry.rectOf(id);
        if (r != null && r.inflate(6).contains(globalPos)) {
          target = id;
          break;
        }
      }
    }
    if (target != d.target) {
      d.target = target;
      registry.highlighted.value = target;
    }
  }

  Future<void> _endDrag() async {
    final d = _drag;
    if (d == null) return;
    _drag = null;
    if (_globalRoute != null) {
      WidgetsBinding.instance.pointerRouter.removeGlobalRoute(_globalRoute!);
      _globalRoute = null;
    }
    ref.read(dropZoneRegistryProvider).highlighted.value = null;
    final target = d.target;
    final wasDrawerByDrag = ref.read(folderDrawerByDragProvider);
    _dragging_ = false;
    _zonePath = null;

    if (target != null) {
      // 落点命中：移除 ghost、关闭抽屉、恢复卡片、执行移动。
      _removeGhost();
      ref.read(folderDrawerOpenProvider.notifier).state = false;
      ref.read(folderDrawerByDragProvider.notifier).state = false;
      setState(() => _hiddenIds = {});
      ref.read(multiSelectProvider.notifier).exit();
      if (target == '__new__') {
        await _createFolderAndMove(d.ids);
      } else {
        await _moveToFolder(d.ids, target);
      }
      return;
    }
    // 落空：ghost 飞回原矩形，卡片回归，多选保持。
    setState(() => _hiddenIds = {});
    if (wasDrawerByDrag) {
      ref.read(folderDrawerOpenProvider.notifier).state = false;
      ref.read(folderDrawerByDragProvider.notifier).state = false;
    }
    _flyBackGhost(d);
  }

  /// 移除 ghost 层（落点命中时直接移除）。
  void _removeGhost() {
    _ghostEntry?.remove();
    _ghostEntry = null;
  }

  /// 回弹：ghost 层切换为回弹模式（动画飞回原矩形后自动移除）。
  void _flyBackGhost(_DragState d) {
    final entry = _ghostEntry;
    if (entry == null) return;
    _ghostEntry = null;
    entry.remove();
    final fly = OverlayEntry(
      builder: (_) => _GhostLayer(
        drag: d,
        isFlyingBack: true,
        notes: ref.read(notesStreamProvider).value ?? const <Note>[],
        onDone: _removeGhost,
      ),
    );
    Overlay.of(context).insert(fly);
    _ghostEntry = fly;
  }

  /// 批量移动到文件夹（拖拽落点）。
  Future<void> _moveToFolder(List<String> ids, String folderId) async {
    final folderName = ref
        .read(foldersStreamProvider)
        .value
        ?.where((f) => f.id == folderId)
        .firstOrNull
        ?.name;
    await ref.read(noteRepositoryProvider).moveNotesToFolder(ids, folderId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已移动 ${ids.length} 条笔记到「${folderName ?? '文件夹'}」'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 拖到「+ 新建文件夹」：创建「未命名」→ 批量移入 → 立即弹重命名。
  Future<void> _createFolderAndMove(List<String> ids) async {
    final folderRepo = ref.read(folderRepositoryProvider);
    final noteRepo = ref.read(noteRepositoryProvider);
    final folder = await folderRepo.createFolder('未命名');
    await noteRepo.moveNotesToFolder(ids, folder.id);
    if (!mounted) return;
    final name = await showFolderNameDialog(
      context,
      title: '重命名文件夹',
      initial: '未命名',
      confirmLabel: '确定',
    );
    if (name != null) {
      await folderRepo.renameFolder(folder.id, name);
    }
  }

  /// 梯形触发区 Path：宽 [w]、高 = 窗口 75%（[heightRatio]）、垂直居中；
  /// 左缘（贴屏幕边）= 底边全高（宽），右缘收窄（高 60% 居中）→ 左宽右窄
  /// 圆角梯形（用户确认 Q1）。
  static Path _buildZonePath(Size screen, {double w = zoneWidth}) {
    final h = screen.height * zoneHeightRatio;
    final top = (screen.height - h) / 2;
    final narrowH = h * 0.6;
    final r = 14.0; // 圆角
    final path = Path();
    // 顺时针：左下 → 右下(收窄) → 右上 → 左上，四角圆角。
    // 左下角
    path.moveTo(0, top + h - r);
    path.quadraticBezierTo(0, top + h, r, top + h);
    // 右下角（窄边下端）
    path.lineTo(w - r, top + h - (h - narrowH) / 2 - r + (h - narrowH));
    // 简化：直接四边形 + 用 arcTo 圆角
    // 重新构建：先画直角梯形，再手动圆角（用二次贝塞尔）。
    path.reset();
    final leftBottom = Offset(0, top + h);
    final rightBottom = Offset(w, top + h - (h - narrowH) / 2);
    final rightTop = Offset(w, top + (h - narrowH) / 2);
    final leftTop = Offset(0, top);
    // 圆角梯形 Path（每角 r 圆角，二次贝塞尔近似）
    path
      ..moveTo(leftTop.dx + r, leftTop.dy)
      ..lineTo(rightTop.dx - r, rightTop.dy)
      ..quadraticBezierTo(rightTop.dx, rightTop.dy, rightTop.dx, rightTop.dy + r)
      ..lineTo(rightBottom.dx, rightBottom.dy - r)
      ..quadraticBezierTo(
        rightBottom.dx,
        rightBottom.dy,
        rightBottom.dx - r,
        rightBottom.dy,
      )
      ..lineTo(leftBottom.dx + r, leftBottom.dy)
      ..quadraticBezierTo(leftBottom.dx, leftBottom.dy, leftBottom.dx, leftBottom.dy - r)
      ..lineTo(leftTop.dx, leftTop.dy + r)
      ..quadraticBezierTo(leftTop.dx, leftTop.dy, leftTop.dx + r, leftTop.dy)
      ..close();
    return path;
  }
}

/// 列表主体：按布局模式渲染单列列表或双列/四列瀑布流。
///
/// 滚动本身不叠加动画（见 NoteListItem 说明）；切换布局模式时本组件
/// 同 key 重建（不触发 AnimatedSwitcher），布局即时切换。
class _NoteListBody extends StatelessWidget {
  const _NoteListBody({
    super.key,
    required this.notes,
    required this.columns,
    required this.cardKeys,
    required this.hiddenIds,
    required this.onRegisterCard,
  });

  final List<Note> notes;

  /// 布局模式：1=单列 / 2=双列 / 4=四列。
  final int columns;

  /// 卡片 GlobalKey 注册表（手势命中检测用，首次创建后复用）。
  final Map<String, GlobalKey> cardKeys;

  /// 抽卡集合（拖拽中隐藏的卡片）。
  final Set<String> hiddenIds;

  final void Function(String id, GlobalKey key) onRegisterCard;

  /// 底部留白：容纳悬浮的毛玻璃新建按钮（EE _buildFrostedFab），
  /// 滚动到底部最后一张卡片不被 FAB 遮挡。
  static const double _fabSpacing = 88;

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, _fabSpacing),
        itemCount: notes.length,
        itemBuilder: (context, index) {
          final note = notes[index];
          if (hiddenIds.contains(note.id)) {
            // 抽卡占位：高度收缩动画（补位平滑），松手恢复。
            return _ShrinkPlaceholder(key: ValueKey('ph-${note.id}'));
          }
          final key = cardKeys[note.id] ??= GlobalKey();
          onRegisterCard(note.id, key);
          return NoteListItem(
            key: key,
            note: note,
            liftSeq: _liftSeqOf(context),
            isLift: _liftIdOf(context) == note.id,
          );
        },
      );
    }
    return _buildGrid(context);
  }

  int? _liftSeqOf(BuildContext context) =>
      context.findAncestorStateOfType<_NotesListState>()?._liftSeq;

  String? _liftIdOf(BuildContext context) =>
      context.findAncestorStateOfType<_NotesListState>()?._liftId;

  /// 多列瀑布流：SingleChildScrollView + Row + Expanded 多路拆列
  /// （参考 EE _buildGrid：i % columns 拆列，列间错落）。
  Widget _buildGrid(BuildContext context) {
    final columnIndices = List.generate(columns, (_) => <int>[]);
    for (var i = 0; i < notes.length; i++) {
      columnIndices[i % columns].add(i);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, _fabSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < columns; c++) ...[
            if (c > 0) const SizedBox(width: 10),
            Expanded(child: _buildGridColumn(context, columnIndices[c])),
          ],
        ],
      ),
    );
  }

  Widget _buildGridColumn(BuildContext context, List<int> indices) {
    return Column(
      children: [
        for (final i in indices) ...[
          if (hiddenIds.contains(notes[i].id))
            _ShrinkPlaceholder(key: ValueKey('ph-${notes[i].id}'))
          else
            _gridCard(context, notes[i]),
          // 卡片自身垂直 6+6 间距，再加 4 凑近 EE 12px 列间距。
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  /// 网格卡片（注册拖拽命中 key + 摘要行数适配：四列 1 行、双列 2 行）。
  Widget _gridCard(BuildContext context, Note note) {
    final key = cardKeys[note.id] ??= GlobalKey();
    onRegisterCard(note.id, key);
    return NoteListItem(
      key: key,
      note: note,
      maxSummaryLines: columns >= 4 ? 1 : 2,
      liftSeq: _liftSeqOf(context),
      isLift: _liftIdOf(context) == note.id,
    );
  }
}

/// 抽卡占位：高度从 48 收缩到 0（AnimatedSize 平滑补位），松手后恢复
/// 由 NoteListItem 入场动画承接。
class _ShrinkPlaceholder extends StatefulWidget {
  const _ShrinkPlaceholder({super.key});

  @override
  State<_ShrinkPlaceholder> createState() => _ShrinkPlaceholderState();
}

class _ShrinkPlaceholderState extends State<_ShrinkPlaceholder> {
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    // 首帧后收缩（AnimatedSize 动画）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _collapsed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: _collapsed
          ? const SizedBox(width: double.infinity, height: 0)
          : const SizedBox(width: double.infinity, height: 56),
    );
  }
}

/// 单个笔记卡片项：点击进入编辑；长按进入多选（手势由 _NotesListState
/// 统一处理，本组件只负责展示与 InkWell 点击）；右键菜单（置顶/移动到/
/// 删除，task-32）；左滑移到回收站（非多选）。
///
/// 卡片风格（task-25，EE 式）：圆角 16 + 柔和阴影 + 玻璃模拟装饰
/// （[GlassCard]）；布局三段式——标题 16bold（无标题兜底）+ 摘要 13 灰
/// （[maxSummaryLines] 行截断）+ 时间 11 outline。
class NoteListItem extends ConsumerStatefulWidget {
  const NoteListItem({
    super.key,
    required this.note,
    this.maxSummaryLines = 2,
    this.liftSeq,
    this.isLift = false,
  });

  final Note note;

  /// 摘要最大行数：单列/双列 2 行、四列 1 行（窄列适配，task-26）。
  final int maxSummaryLines;

  /// 浮起动画信号（进入多选的长按卡片；_NotesListState 驱动）。
  final int? liftSeq;

  /// 本卡是否为本次长按进入多选的卡片。
  final bool isLift;

  @override
  ConsumerState<NoteListItem> createState() => _NoteListItemState();
}

class _NoteListItemState extends ConsumerState<NoteListItem> {
  /// 入场动画标记：元素首次构建（新增/恢复）时播放淡入 + 上移；
  /// 滚动复用（同 id 元素重建，ValueKey 保证不换笔记）不重复动画。
  bool _animateIn = true;

  /// 浮起动画已播放标记（liftSeq 变化时重置）。
  int? _playedLiftSeq;

  @override
  void didUpdateWidget(NoteListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 理论不会发生（外层 ValueKey 已按 id 匹配元素）；防御性兜底：
    // 元素被复用于另一条笔记时重新触发入场动画。
    if (oldWidget.note.id != widget.note.id) {
      _animateIn = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_animateIn) {
      return _wrapLift(_buildItem(context));
    }
    // 淡入 + 上移（320ms，easeOutCubic），播放完毕移除包装（_animateIn=false）
    // 使滚动复用路径零动画开销。
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (mounted) setState(() => _animateIn = false);
      },
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: _wrapLift(_buildItem(context)),
    );
  }

  /// 长按浮起动画：进入多选的卡片播放一次 scale 上浮（原型 liftUp）。
  Widget _wrapLift(Widget child) {
    final liftSeq = widget.liftSeq;
    if (!widget.isLift || liftSeq == null || liftSeq == _playedLiftSeq) {
      return child;
    }
    _playedLiftSeq = liftSeq;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 1.035),
      duration: const Duration(milliseconds: 300),
      curve: const Cubic(0.32, 0.72, 0, 1),
      builder: (context, t, c) => Transform.scale(scale: t, child: c),
      child: child,
    );
  }

  Widget _buildItem(BuildContext context) {
    final selected = ref.watch(multiSelectProvider);
    final multiActive = selected.isNotEmpty;
    final isSelected = selected.contains(widget.note.id);
    final card = _buildCard(
      context,
      multiActive: multiActive,
      isSelected: isSelected,
    );

    if (!multiActive) {
      // 非多选：左滑删除 + 长按（手势层处理）进入多选 + 右键菜单。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          // 撑满列宽：多列布局（Column）中卡片不收缩到内容宽度，
          // 保证双列/四列等宽对齐（EE 卡片 width: double.infinity 同款）。
          width: double.infinity,
          child: Dismissible(
            key: ValueKey(widget.note.id),
            direction: DismissDirection.endToStart,
            background: const _DeleteBackground(),
            confirmDismiss: (_) => _confirmDelete(context),
            onDismissed: (_) {
              // 删除已在 confirmDismiss 中完成，列表经 drift 流自动移除该项。
            },
            child: card,
          ),
        ),
      );
    }
    // 多选模式：点击 = 切换选中（自绘手势层处理拖拽/抽卡，本层只管展示）。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: double.infinity,
        child: card,
      ),
    );
  }

  /// 卡片本体（含多选框）：多选模式点击 = 切换选中、长按禁用；
  /// 非多选点击 = 进编辑页、长按 = 进入多选。
  Widget _buildCard(
    BuildContext context, {
    required bool multiActive,
    required bool isSelected,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final note = widget.note;
    final title = note.title.trim().isEmpty ? '无标题' : note.title.trim();

    return GestureDetector(
      // 桌面右键：弹统一笔记菜单（在鼠标位置）。
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
      child: GlassCard(
        heroTag: null,
        // 卡片宽度恒定：关闭 hover 缩放（EE 卡片无 hover 效果，
        // 悬停放大 1.2% 会被感知为宽度不一致）。
        hoverLift: false,
        // 点击：非多选 = 进编辑页（多选的选中切换由手势层处理，避免
        // 与 Listener 的 pendingDeselect 双重 toggle 冲突）。长按全部交给
        // 手势层（Listener）。
        onTap: multiActive
            ? null
            : () => context.push('/editor/${note.id}'),
        onLongPress: null,
        // 多选时左侧留位给多选框。
        padding: multiActive
            ? const EdgeInsets.fromLTRB(44, 14, 16, 14)
            : const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行：16 bold（无标题兜底）+ 置顶小图钉（task-28）
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (note.isPinned)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(
                          Icons.push_pin,
                          size: 14,
                          color: colorScheme.primary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                // 摘要：13 灰，按布局模式截断（单列/双列 2 行、四列 1 行）
                Text(
                  excerptOf(note.content),
                  maxLines: widget.maxSummaryLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                // 时间：11 outline
                Text(
                  relativeTime(note.updatedAt),
                  style: TextStyle(fontSize: 11, color: colorScheme.outline),
                ),
              ],
            ),
            // 多选框（左上角）：选中 = 强调色实心 + 勾。
            if (multiActive)
              Positioned(
                left: 0,
                top: 0,
                child: _CheckCircle(checked: isSelected),
              ),
          ],
        ),
      ),
    );
  }

  /// 统一笔记菜单（桌面右键）：置顶/取消置顶 + 移动到 + 移到回收站。
  ///
  /// 自定义 Overlay 弹层：菜单项 hover/涟漪圆角贴合容器；宽度自适应
  /// 内容；定位在鼠标位置。
  Future<void> _showContextMenu(
    BuildContext context,
    Offset tapGlobal,
  ) async {
    if (!context.mounted) return;
    final note = widget.note;
    final overlay = Overlay.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1B2838) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    const itemHeight = 34.0;
    const radius = 12.0;
    final pinLabel = note.isPinned ? '取消置顶' : '置顶';
    final moveLabel = '移动到';
    final deleteLabel = '删除';
    final itemWidth = _menuItemWidth([
      for (final label in [pinLabel, moveLabel, deleteLabel]) label,
    ]);
    late final OverlayEntry overlayEntry;
    final items = <Widget>[
      _MenuButton(
        width: itemWidth,
        height: itemHeight,
        radius: BorderRadius.vertical(top: Radius.circular(radius)),
        icon: note.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: pinLabel,
        onTap: () {
          overlayEntry.remove();
          _setPinned(!note.isPinned);
        },
      ),
      _MenuButton(
        width: itemWidth,
        height: itemHeight,
        radius: BorderRadius.zero,
        icon: Icons.drive_file_move_outlined,
        label: moveLabel,
        onTap: () {
          overlayEntry.remove();
          showMoveToPanel(context, ref, noteIds: [note.id]);
        },
      ),
      _MenuButton(
        width: itemWidth,
        height: itemHeight,
        radius: BorderRadius.vertical(bottom: Radius.circular(radius)),
        icon: Icons.delete_outline,
        label: deleteLabel,
        labelColor: Theme.of(context).colorScheme.error,
        iconColor: Theme.of(context).colorScheme.error,
        onTap: () {
          overlayEntry.remove();
          _confirmDelete(context);
        },
      ),
    ];
    final menuH = items.length * itemHeight;
    final screen = MediaQuery.sizeOf(context);
    const estWidth = 148.0;
    var left = tapGlobal.dx - 8;
    var top = tapGlobal.dy + 6;
    left = left.clamp(8.0, screen.width - estWidth - 8);
    top = top.clamp(8.0, screen.height - menuH - 8);

    overlayEntry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: ModalBarrier(
              dismissible: true,
              onDismiss: () => overlayEntry.remove(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: items,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(overlayEntry);
  }

  /// 计算菜单项宽度：icon(16) + gap(10) + 最长文字宽 + 左右内边距(14*2)。
  double _menuItemWidth(List<String> labels) {
    final longest = labels.reduce((a, b) => a.length >= b.length ? a : b);
    final tp = TextPainter(
      text: TextSpan(text: longest, style: const TextStyle(fontSize: 13)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    // +4 余量：TextPainter 测量与真实渲染有亚像素差（曾 0.8px 溢出）。
    return (14 * 2 + 16 + 10 + tp.width + 4).ceilToDouble();
  }

  /// 置顶/取消置顶（task-28）：翻转置顶状态并持久化（version+1 随同步）。
  Future<void> _setPinned(bool pinned) async {
    await ref
        .read(noteRepositoryProvider)
        .setPinned(widget.note.id, pinned);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pinned ? '已置顶' : '已取消置顶'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 弹出「移到回收站」玻璃确认框；确认后调 [noteRepositoryProvider]
  /// .softDeleteNote 软删除，返回 true 供 Dismissible 完成滑出动画
  /// （长按删除时返回值被忽略）。
  Future<bool> _confirmDelete(BuildContext context) async {
    final title = widget.note.title.trim().isEmpty
        ? '无标题'
        : widget.note.title.trim();
    final confirmed = await showGlassDialog<bool>(
      context: context,
      title: const Text('移到回收站'),
      content: Text('将「$title」移到回收站吗？可在回收站中恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('移到回收站'),
        ),
      ],
    );
    if (confirmed != true) {
      return false;
    }
    await ref.read(noteRepositoryProvider).softDeleteNote(widget.note.id);
    return true;
  }
}

/// 左滑露出的删除背景（玻璃卡片风格：圆角 16 与卡片一致，柔和阴影）。
class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: const BorderRadius.all(Radius.circular(kAppRadius)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
    );
  }
}

/// 空态：区分「还没有笔记」与「搜索无结果」两种引导（图标 + 淡入）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    final icon = isSearching ? Icons.search_off : Icons.edit_note;
    final title = isSearching ? '未找到相关笔记' : '还没有笔记';
    final subtitle = isSearching ? '换个关键词试试' : '点击右下角 + 新建第一条笔记';

    return SizedBox(
      // 撑满可用高度：空态内容垂直居中（列表态由 AnimatedSwitcher
      // topCenter 对齐顶置，空态在此内部居中）。
      height: double.infinity,
      child: Center(child: EmptyHint(icon: icon, title: title, subtitle: subtitle)),
    );
  }
}

/// 菜单按钮（自定义右键菜单项）：InkWell hover 圆角贴合菜单容器——
/// 单选项全圆角，多选项首项上圆角、末项下圆角、中间直角（调用方传入）。
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.width,
    required this.height,
    required this.radius,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.labelColor,
  });

  final double width;
  final double height;
  final BorderRadius radius;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inkIcon = iconColor ?? colorScheme.onSurface;
    final inkLabel = labelColor ?? colorScheme.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius, // hover 圆角贴合容器（首/末/单项圆角、中间直角）。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: width,
            minHeight: height,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: inkIcon),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(fontSize: 13, color: inkLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 多选框（卡片左上角）：选中 = 强调色实心 + 勾；未选 = 白底描边。
class _CheckCircle extends StatelessWidget {
  const _CheckCircle({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedScale(
      scale: checked ? 1 : 0.9,
      duration: const Duration(milliseconds: 150),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked
              ? colorScheme.primary
              : (isDark ? const Color(0xFF1B2838) : Colors.white),
          border: checked
              ? null
              : Border.all(
                  color: colorScheme.outlineVariant,
                  width: 1.4,
                ),
        ),
        child: checked
            ? Icon(Icons.check, size: 15, color: colorScheme.onPrimary)
            : null,
      ),
    );
  }
}

/// 底部多选操作面板（task-32）：非模态玻璃面板，拖拽时与列表共存。
///
/// 菜单项：选中 1 项 = 置顶/取消置顶 + 移动到 + 删除；≥2 项 = 移动到 +
/// 删除（批量置顶无意义，隐藏）。滑入动画（原型 bottom-sheet 同款曲线）。
class _MultiSelectSheet extends ConsumerWidget {
  const _MultiSelectSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(multiSelectProvider);
    final notes = ref.watch(notesStreamProvider).value ?? const <Note>[];
    final selectedNotes =
        notes.where((n) => selected.contains(n.id)).toList();
    final single = selectedNotes.length == 1 ? selectedNotes.first : null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    // 滑入动画：挂载时从底部滑入（原型 .bottom-sheet .28s 弹性曲线）。
    return TweenAnimationBuilder<Offset>(
      tween: Tween(begin: const Offset(0, 1), end: Offset.zero),
      duration: const Duration(milliseconds: 280),
      curve: const Cubic(0.32, 0.72, 0, 1),
      builder: (context, t, child) => FractionalTranslation(
        translation: t,
        child: child,
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF223344) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (single != null)
              _SheetItem(
                icon: single.isPinned
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                label: single.isPinned ? '取消置顶' : '置顶',
                onTap: () async {
                  await ref
                      .read(noteRepositoryProvider)
                      .setPinned(single.id, !single.isPinned);
                  if (!context.mounted) return;
                  ref.read(multiSelectProvider.notifier).exit();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        single.isPinned ? '已取消置顶' : '已置顶',
                      ),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            _SheetItem(
              icon: Icons.drive_file_move_outlined,
              label: '移动到',
              onTap: () async {
                await showMoveToPanel(
                  context,
                  ref,
                  noteIds: List<String>.of(selected),
                );
                if (context.mounted) {
                  ref.read(multiSelectProvider.notifier).exit();
                }
              },
            ),
            _SheetItem(
              icon: Icons.delete_outline,
              label: '删除',
              color: colorScheme.error,
              onTap: () async {
                final confirmed = await showBatchDeleteConfirm(
                  context,
                  count: selected.length,
                );
                if (!confirmed || !context.mounted) return;
                await ref
                    .read(noteRepositoryProvider)
                    .softDeleteNotes(List<String>.of(selected));
                if (!context.mounted) return;
                ref.read(multiSelectProvider.notifier).exit();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已删除 ${selected.length} 条笔记'),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部面板菜单行（图标 + 文字，hover 高亮）。
class _SheetItem extends StatefulWidget {
  const _SheetItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  State<_SheetItem> createState() => _SheetItemState();
}

class _SheetItemState extends State<_SheetItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.onSurface;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          color: _hovered
              ? Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.06)
              : null,
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: color),
              const SizedBox(width: 12),
              Text(
                widget.label,
                style: TextStyle(fontSize: 14, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 左侧圆角梯形触发区（拖拽中显示）：左缘贴屏幕边 = 底边（全高），
/// 右缘收窄 → 左宽右窄；半透明强调色 + 圆角 + 文件夹图标。
class _DropZoneTrapezoid extends StatelessWidget {
  const _DropZoneTrapezoid({required this.width, required this.heightRatio});

  final double width;
  final double heightRatio;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final path = _NotesListState._buildZonePath(size, w: width);
    return CustomPaint(
      painter: _TrapezoidPainter(path: path, color: colorScheme.primary),
      child: Center(
        child: Padding(
          padding: EdgeInsets.only(right: width * 0.3),
          child: Icon(
            Icons.folder_outlined,
            size: 26,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// 梯形触发区绘制：半透明填充 + 圆角描边（虚线感由 alpha 层次体现）。
class _TrapezoidPainter extends CustomPainter {
  const _TrapezoidPainter({required this.path, required this.color});

  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fill);
    final border = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawPath(path, border);
  }

  @override
  bool shouldRepaint(_TrapezoidPainter old) =>
      old.path != path || old.color != color;
}

/// 拖拽 ghost 层（Overlay 顶层，不挤压列表布局）。
///
/// - 跟随模式（[isFlyingBack] = false）：方形迷你卡层叠 + 拖影跟随指针，
///   位置由 [_DragState] 驱动（ValueListenableBuilder）；
/// - 回弹模式（[isFlyingBack] = true）：动画飞回各卡片原矩形后移除自身。
class _GhostLayer extends StatefulWidget {
  const _GhostLayer({
    required this.drag,
    required this.isFlyingBack,
    required this.notes,
    this.onDone,
  });

  final _DragState drag;
  final bool isFlyingBack;

  /// ghost 渲染用笔记数据快照（Overlay 层无法从子树取 Provider，必须传入）。
  final List<Note> notes;

  /// 回弹动画完成回调（移除 overlay entry，由 _NotesListState 提供）。
  final VoidCallback? onDone;

  @override
  State<_GhostLayer> createState() => _GhostLayerState();
}

class _GhostLayerState extends State<_GhostLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  /// 方形迷你卡尺寸（用户确认：近似方形）。
  static const double cardSize = 132;

  @override
  void initState() {
    super.initState();
    if (widget.isFlyingBack) {
      // 回弹：从当前位置飞到各自原矩形，完成后移除。
      _controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _removeSelf();
        }
      });
      _controller.forward();
    }
  }

  void _removeSelf() {
    widget.onDone?.call();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drag = widget.drag;
    final mainId = drag.mainId;
    // 主卡数据（beginDrag 时的快照，缺失则跳过）。
    final notes = widget.notes;
    final mainNote = notes.where((n) => n.id == mainId).firstOrNull;
    if (mainNote == null) return const SizedBox.shrink();

    if (!widget.isFlyingBack) {
      // 跟随模式：位置由 drag.position 驱动。
      return SizedBox.expand(
        child: ListenableBuilder(
          listenable: drag,
          builder: (context, _) {
            return _buildStack(
              context,
              pos: drag.position,
              progress: null,
              notes: notes,
            );
          },
        ),
      );
    }
    // 回弹模式：位置从 drag.position 插值到各卡原矩形。
    return SizedBox.expand(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value;
          return _buildStack(
            context,
            pos: drag.position,
            progress: t,
            notes: notes,
          );
        },
      ),
    );
  }

  /// 组装层叠 ghost（主卡 + 其余选中卡阶梯偏移 + 拖影残影）。
  Widget _buildStack(
    BuildContext context, {
    required Offset pos,
    required double? progress,
    required List<Note> notes,
  }) {
    final drag = widget.drag;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mainNote = notes.where((n) => n.id == drag.mainId).firstOrNull;
    if (mainNote == null) return const SizedBox.shrink();
    final cards = <Widget>[];
    final others =
        drag.ids.where((id) => id != drag.mainId).toList();
    // 主卡残影（拖影效果：主卡后方两层渐隐残影，参考安卓移动图标）。
    for (var s = 0; s < 2; s++) {
      cards.add(_ghostCard(
        context,
        note: mainNote,
        offset: _fly(
          Offset((s + 1) * 10.0, (s + 1) * 10.0),
          progress,
          drag,
          drag.mainId,
        ),
        opacity: 0.28 - s * 0.13,
        scale: 1.0,
        isDark: isDark,
      ));
    }
    // 其余选中卡：阶梯偏移 + 透明度递减（彗尾拖影感）。
    for (var i = 0; i < others.length && i < 4; i++) {
      final note = notes.where((n) => n.id == others[i]).firstOrNull;
      if (note == null) continue;
      cards.add(_ghostCard(
        context,
        note: note,
        offset: _fly(
          Offset((i + 1) * 14.0, (i + 1) * 14.0),
          progress,
          drag,
          others[i],
        ),
        opacity: math.max(0.45, 0.92 - i * 0.16),
        scale: 1.0,
        isDark: isDark,
      ));
    }
    // 主卡（最上层，放大 1.045 拿起感）。
    cards.add(_ghostCard(
      context,
      note: mainNote,
      offset: _fly(Offset.zero, progress, drag, drag.mainId),
      opacity: 1.0,
      scale: 1.045,
      isDark: isDark,
    ));
    return Stack(
      children: [
        for (final c in cards) c,
      ],
    );
  }

  /// 位置插值：跟随（progress null）= 当前位置；回弹 = 当前位置 → 原矩形。
  Offset _fly(Offset rel, double? progress, _DragState drag, String id) {
    final base = drag.position + rel;
    if (progress == null) return base;
    final rect = drag.rects[id];
    if (rect == null) return base;
    return Offset.lerp(base, rect.topLeft, progress)!;
  }

  /// 单张方形迷你卡（近似方形，标题 + 摘要 + 时间）。
  Widget _ghostCard(
    BuildContext context, {
    required Note? note,
    required Offset offset,
    required double opacity,
    required double scale,
    required bool isDark,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = note == null || note.title.trim().isEmpty
        ? '无标题'
        : note.title.trim();
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: opacity,
          child: Container(
            width: cardSize,
            height: cardSize,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1B2838) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.primary.withValues(alpha: 0.55),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    note == null ? '' : excerptOf(note.content),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (note != null)
                  Text(
                    relativeTime(note.updatedAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}
