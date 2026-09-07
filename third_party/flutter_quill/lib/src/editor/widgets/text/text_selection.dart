import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../document/nodes/node.dart';
import '../../editor.dart';
import 'magnifier.dart';

TextSelection localSelection(Node node, TextSelection selection, fromParent) {
  final base = fromParent ? node.offset : node.documentOffset;
  assert(base <= selection.end && selection.start <= base + node.length - 1);

  final offset = fromParent ? node.offset : node.documentOffset;
  return selection.copyWith(
      baseOffset: math.max(selection.start - offset, 0),
      extentOffset: math.min(selection.end - offset, node.length - 1));
}

/// The text position that a give selection handle manipulates. Dragging the
/// [start] handle always moves the [start]/[baseOffset] of the selection.
enum _TextSelectionHandlePosition { start, end }


/// internal use, used to get drag direction information
class DragTextSelection extends TextSelection {
  const DragTextSelection({
    super.affinity,
    super.baseOffset = 0,
    super.extentOffset = 0,
    super.isDirectional,
    this.first = true,
  });

  final bool first;

  @override
  DragTextSelection copyWith({
    int? baseOffset,
    int? extentOffset,
    TextAffinity? affinity,
    bool? isDirectional,
    bool? first,
  }) {
    return DragTextSelection(
      baseOffset: baseOffset ?? this.baseOffset,
      extentOffset: extentOffset ?? this.extentOffset,
      affinity: affinity ?? this.affinity,
      isDirectional: isDirectional ?? this.isDirectional,
      first: first ?? this.first,
    );
  }
}

/// An object that manages a pair of text selection handles.
///
/// The selection handles are displayed in the [Overlay] that most closely
/// encloses the given [BuildContext].
class EditorTextSelectionOverlay {
  /// Creates an object that manages overlay entries for selection handles.
  ///
  /// The [context] must not be null and must have an [Overlay] as an ancestor.
  EditorTextSelectionOverlay({
    required this.value,
    required this.context,
    required this.startHandleLayerLink,
    required this.endHandleLayerLink,
    required this.renderObject,
    required this.debugRequiredFor,
    required this.selectionCtrls,
    required this.selectionDelegate,
    required this.contextMenuBuilder,
    this.clipboardStatus,
    this.onSelectionHandleTapped,
    // 本地修改（lan-notes）：见字段处说明，start → down。
    this.dragStartBehavior = DragStartBehavior.down,
    this.handlesVisible = false,
    this.dragOffsetNotifier,
  }) {
    // Clipboard status is only checked on first instance of
    // ClipboardStatusNotifier
    // if state has changed after creation, but prior to
    // our listener being created
    // we won't know the status unless there is forced update
    // i.e. occasionally no paste
    if (clipboardStatus != null && !kIsWeb) {
      // Web - esp Safari Mac/iOS has security measures in place that restrict
      // cliboard status checks w/o direct user interaction. So skip this
      // for web
      clipboardStatus!.update();
    }
  }

  TextEditingValue value;

  /// The offset of the drag handle used to position the magnifier.
  ValueNotifier<Offset?>? dragOffsetNotifier;

  /// Whether selection handles are visible.
  ///
  /// Set to false if you want to hide the handles. Use this property to show or
  /// hide the handle without rebuilding them.
  ///
  /// If this method is called while the [SchedulerBinding.schedulerPhase] is
  /// [SchedulerPhase.persistentCallbacks], i.e. during the build, layout, or
  /// paint phases (see [WidgetsBinding.drawFrame]), then the update is delayed
  /// until the post-frame callbacks phase. Otherwise the update is done
  /// synchronously. This means that it is safe to call during builds, but also
  /// that if you do call this during a build, the UI will not update until the
  /// next frame (i.e. many milliseconds later).
  ///
  /// Defaults to false.
  bool handlesVisible = false;

  /// The context in which the selection handles should appear.
  ///
  /// This context must have an [Overlay] as an ancestor because this object
  /// will display the text selection handles in that [Overlay].
  final BuildContext context;

  /// Debugging information for explaining why the [Overlay] is required.
  final Widget debugRequiredFor;

  /// The objects supplied to the [CompositedTransformTarget] that wraps the
  /// location of start selection handle.
  final LayerLink startHandleLayerLink;

  /// The objects supplied to the [CompositedTransformTarget] that wraps the
  /// location of end selection handle.
  final LayerLink endHandleLayerLink;

  /// The editable line in which the selected text is being displayed.
  final RenderEditor renderObject;

  /// Builds text selection handles and toolbar.
  final TextSelectionControls selectionCtrls;

  /// The delegate for manipulating the current selection in the owning
  /// text field.
  final TextSelectionDelegate selectionDelegate;

  /// {@macro flutter.widgets.EditableText.contextMenuBuilder}
  ///
  /// If not provided, no context menu will be built.
  final WidgetBuilder? contextMenuBuilder;

  /// Determines the way that drag start behavior is handled.
  ///
  /// If set to [DragStartBehavior.start], handle drag behavior will
  /// begin upon the detection of a drag gesture. If set to
  /// [DragStartBehavior.down] it will begin when a down event is first
  /// detected.
  ///
  /// In general, setting this to [DragStartBehavior.start] will make drag
  /// animation smoother and setting it to [DragStartBehavior.down] will make
  /// drag behavior feel slightly more reactive.
  ///
  /// By default, the drag start behavior is [DragStartBehavior.down].
  ///
  /// See also:
  ///
  ///  * [DragGestureRecognizer.dragStartBehavior],
  ///  which gives an example for the different behaviors.
  // 本地修改（lan-notes）：默认改为 down。
  // 原值 start 会等手指移动超过 touch slop 才触发 onPanStart，手柄要先
  // 「空划一段」才开始响应；期间若按下停顿超过 kLongPressTimeout(500ms)，
  // 编辑器的 LongPressGestureRecognizer 会在手势竞技场里取胜，把手柄的
  // Pan 判负 —— 表现为「偶尔按住手柄却拖不动」。down 让 Pan 在按下瞬间
  // 即进入待命，移动一个像素就能宣告胜利，抢在长按超时之前。
  final DragStartBehavior dragStartBehavior;

  /// {@template flutter.widgets.textSelection.onSelectionHandleTapped}
  /// A callback that's invoked when a selection handle is tapped.
  ///
  /// Both regular taps and long presses invoke this callback, but a drag
  /// gesture won't.
  /// {@endtemplate}
  final VoidCallback? onSelectionHandleTapped;

  /// Maintains the status of the clipboard for determining if its contents can
  /// be pasted or not.
  ///
  /// Useful because the actual value of the clipboard can only be checked
  /// asynchronously (see [Clipboard.getData]).
  final ClipboardStatusNotifier? clipboardStatus;

  /// A pair of handles. If this is non-null, there are always 2, though the
  /// second is hidden when the selection is collapsed.
  List<OverlayEntry>? _handles;

  /// A copy/paste toolbar.
  OverlayEntry? toolbar;

  TextSelection get _selection => value.selection;

  void setHandlesVisible(bool visible) {
    if (handlesVisible == visible) {
      return;
    }
    handlesVisible = visible;
    // If we are in build state, it will be too late to update visibility.
    // We will need to schedule the build in next frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(markNeedsBuild);
    } else {
      markNeedsBuild();
    }
  }

  /// Destroys the handles by removing them from overlay.
  void hideHandles() {
    if (_handles == null) {
      return;
    }
    _handles![0].remove();
    _handles![1].remove();
    _handles = null;
  }

  /// Hides the toolbar part of the overlay.
  ///
  /// To hide the whole overlay, see [hide].
  void hideToolbar() {
    assert(toolbar != null);
    dragOffsetNotifier?.removeListener(_dragOffsetListener);
    toolbar!.remove();
    toolbar = null;
  }

  /// Shows the toolbar by inserting it into the [context]'s overlay.
  void showToolbar() {
    assert(toolbar == null);
    if (contextMenuBuilder == null) return;
    dragOffsetNotifier?.addListener(_dragOffsetListener);
    toolbar = OverlayEntry(builder: (context) {
      // when the dragOffsetNotifier is not null and the value is not null
      // the magnifier is being shown, so we don't want to show the context menu
      if (dragOffsetNotifier?.value != null) {
        return Container();
      }
      return contextMenuBuilder!(context);
    });
    Overlay.of(context, rootOverlay: true, debugRequiredFor: debugRequiredFor)
        .insert(toolbar!);

    // make sure handles are visible as well
    if (_handles == null) {
      showHandles();
    }
  }

  // after dragging and magnifier is removed, restore the context menu
  void _dragOffsetListener() {
    if (dragOffsetNotifier?.value == null) {
      toolbar?.markNeedsBuild();
    }
  }

  Widget _buildHandle(
      BuildContext context, _TextSelectionHandlePosition position) {
    if (_selection.isCollapsed &&
        position == _TextSelectionHandlePosition.end) {
      return const SizedBox.shrink();
    }
    return Visibility(
        visible: handlesVisible,
        child: _TextSelectionHandleOverlay(
          onSelectionHandleChanged: (newSelection) {
            _handleSelectionHandleChanged(newSelection, position);
          },
          onSelectionHandleTapped: onSelectionHandleTapped,
          startHandleLayerLink: startHandleLayerLink,
          endHandleLayerLink: endHandleLayerLink,
          renderObject: renderObject,
          selection: _selection,
          selectionControls: selectionCtrls,
          position: position,
          dragStartBehavior: dragStartBehavior,
          dragOffsetNotifier: dragOffsetNotifier,
        ));
  }

  /// Updates the overlay after the selection has changed.
  ///
  /// If this method is called while the [SchedulerBinding.schedulerPhase] is
  /// [SchedulerPhase.persistentCallbacks], i.e. during the build, layout, or
  /// paint phases (see [WidgetsBinding.drawFrame]), then the update is delayed
  /// until the post-frame callbacks phase. Otherwise the update is done
  /// synchronously. This means that it is safe to call during builds, but also
  /// that if you do call this during a build, the UI will not update until the
  /// next frame (i.e. many milliseconds later).
  void update(TextEditingValue newValue) {
    if (value == newValue) {
      return;
    }
    value = newValue;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(markNeedsBuild);
    } else {
      markNeedsBuild();
    }
  }

  void _handleSelectionHandleChanged(
    TextSelection? newSelection,
    _TextSelectionHandlePosition position,
  ) {
    TextPosition textPosition;
    switch (position) {
      case _TextSelectionHandlePosition.start:
        textPosition = newSelection != null
            ? newSelection.base
            : const TextPosition(offset: 0);
        break;
      case _TextSelectionHandlePosition.end:
        textPosition = newSelection != null
            ? newSelection.extent
            : const TextPosition(offset: 0);
        break;
    }

    final currSelection = newSelection != null
        ? DragTextSelection(
            baseOffset: newSelection.baseOffset,
            extentOffset: newSelection.extentOffset,
            affinity: newSelection.affinity,
            isDirectional: newSelection.isDirectional,
            first: position == _TextSelectionHandlePosition.start,
          )
        : null;

    update(value.copyWith(
      selection: currSelection,
      composing: TextRange.empty,
    ));

    selectionDelegate
      ..userUpdateTextEditingValue(value, SelectionChangedCause.drag)
      ..bringIntoView(textPosition);
  }

  void markNeedsBuild([Duration? duration]) {
    if (_handles != null) {
      _handles![0].markNeedsBuild();
      _handles![1].markNeedsBuild();
    }
    toolbar?.markNeedsBuild();
  }

  /// Hides the entire overlay including the toolbar and the handles.
  void hide() {
    if (_handles != null) {
      _handles![0].remove();
      _handles![1].remove();
      _handles = null;
    }
    if (toolbar != null) {
      hideToolbar();
    }
  }

  /// Final cleanup.
  void dispose() {
    hide();
  }

  /// Builds the handles by inserting them into the [context]'s overlay.
  void showHandles() {
    assert(_handles == null);
    _handles = <OverlayEntry>[
      OverlayEntry(
          builder: (context) =>
              _buildHandle(context, _TextSelectionHandlePosition.start)),
      OverlayEntry(
          builder: (context) =>
              _buildHandle(context, _TextSelectionHandlePosition.end)),
    ];

    Overlay.of(context, rootOverlay: true, debugRequiredFor: debugRequiredFor)
        .insertAll(_handles!);
  }

  /// Causes the overlay to update its rendering.
  ///
  /// This is intended to be called when the [renderObject] may have changed its
  /// text metrics (e.g. because the text was scrolled).
  void updateForScroll() {
    markNeedsBuild();
  }
}

/// This widget represents a single draggable text selection handle.
class _TextSelectionHandleOverlay extends StatefulWidget {
  const _TextSelectionHandleOverlay({
    required this.selection,
    required this.position,
    required this.startHandleLayerLink,
    required this.endHandleLayerLink,
    required this.renderObject,
    required this.onSelectionHandleChanged,
    required this.onSelectionHandleTapped,
    required this.selectionControls,
    // 本地修改（lan-notes）：见字段处说明，start → down。
    this.dragStartBehavior = DragStartBehavior.down,
    this.dragOffsetNotifier,
  });

  final TextSelection selection;
  final _TextSelectionHandlePosition position;
  final LayerLink startHandleLayerLink;
  final LayerLink endHandleLayerLink;
  final RenderEditor renderObject;
  final ValueChanged<TextSelection?> onSelectionHandleChanged;
  final VoidCallback? onSelectionHandleTapped;
  final TextSelectionControls selectionControls;
  final DragStartBehavior dragStartBehavior;
  final ValueNotifier<Offset?>? dragOffsetNotifier;

  @override
  _TextSelectionHandleOverlayState createState() =>
      _TextSelectionHandleOverlayState();

  /// 该手柄操纵的是选区的哪一端。
  bool get isStartHandle => position == _TextSelectionHandlePosition.start;

  ValueListenable<bool> get _visibility {
    switch (position) {
      case _TextSelectionHandlePosition.start:
        return renderObject.selectionStartInViewport;
      case _TextSelectionHandlePosition.end:
        return renderObject.selectionEndInViewport;
    }
  }
}

class _TextSelectionHandleOverlayState
    extends State<_TextSelectionHandleOverlay>
    with SingleTickerProviderStateMixin {
  /// 手柄当前指向的**文本位置**（全局坐标）。
  ///
  /// 这不是手指位置：手柄画在选区端点的上方（iOS 风格）或下方，手指按在
  /// 手柄上时，其 y 与文字行并不重合，直接拿手指坐标算文本位置会命中相邻
  /// 行。上游原实现正是这么做的（并且算出但未使用的 `_dragPosition` 就躺在
  /// 旁边），结果就是「必须把手指挪到文字本体上才能选准」，而手指一挪过去
  /// 就把要选的字挡住了。这里改为端点跟随手指做等量位移。
  late Offset _dragPosition;

  /// 手指按下点 → 手柄锚点（选区端点）的全局偏移，一次拖动内保持不变。
  Offset _grabOffset = Offset.zero;

  late AnimationController _controller;

  Animation<double> get _opacity => _controller.view;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
        duration: const Duration(milliseconds: 150), vsync: this);

    _handleVisibilityChanged();
    widget._visibility.addListener(_handleVisibilityChanged);
  }

  void _handleVisibilityChanged() {
    if (widget._visibility.value) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void didUpdateWidget(_TextSelectionHandleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    oldWidget._visibility.removeListener(_handleVisibilityChanged);
    _handleVisibilityChanged();
    widget._visibility.addListener(_handleVisibilityChanged);
  }

  @override
  void dispose() {
    widget._visibility.removeListener(_handleVisibilityChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 用「选区端点的实际渲染位置」反推抓握偏移。
  ///
  /// 端点与 RenderEditor 绘制手柄 LayerLink 用的是同一个点
  /// （`_paintHandleLayers`），所以这是最精确的一档：手指按在手柄的哪个部位
  /// 都能算对。拿不到时返回 null，交给后面的几何兜底。
  Offset? _grabOffsetFromRender(Offset pointerGlobal) {
    final renderObject = widget.renderObject;
    if (!renderObject.attached) {
      return null;
    }
    final endpoints = renderObject.getEndpointsForSelection(widget.selection);
    if (endpoints.isEmpty) {
      return null;
    }
    final local =
        widget.isStartHandle ? endpoints.first.point : endpoints.last.point;
    final offset = renderObject.localToGlobal(local) - pointerGlobal;
    // 异常值保护：
    //  - 退化成 0 说明这条链路没拿到端点位置（此时用几何兜底，否则表现与
    //    「不做偏移」完全一样 —— 手指移到手柄位置就选到相邻行）；
    //  - 端点不可能离手指这么远，说明渲染状态不对。
    if (offset.distance < 1 || offset.dx.abs() > 200 || offset.dy.abs() > 200) {
      return null;
    }
    return offset;
  }

  /// 计算「手指按下点 → 手柄锚点（选区端点）」的偏移。
  ///
  /// 拖动时端点按这个偏移跟着手指做**等量位移**，而不是把手指坐标直接当成
  /// 文本位置 —— 后者在手柄画在文字上/下方时会命中相邻行。
  ///
  /// 取值优先级：
  /// 1. [_grabOffsetFromRender]：按端点的实际渲染位置反推，最精确；
  /// 2. 拿不到时按手柄几何近似：手指默认按在手柄几何中心，
  ///    于是 `端点 − 中心 = anchor − size / 2`。
  Offset _computeGrabOffset(Offset pointerGlobal) {
    final fromRender = _grabOffsetFromRender(pointerGlobal);
    if (fromRender != null) {
      return fromRender;
    }

    final textPosition = widget.position == _TextSelectionHandlePosition.start
        ? widget.selection.base
        : widget.selection.extent;
    final lineHeight = widget.renderObject.preferredLineHeight(textPosition);
    final type = widget.position == _TextSelectionHandlePosition.start
        ? _chooseType(widget.renderObject.textDirection,
            TextSelectionHandleType.left, TextSelectionHandleType.right)
        : _chooseType(widget.renderObject.textDirection,
            TextSelectionHandleType.right, TextSelectionHandleType.left);

    final controls = widget.selectionControls;
    final size = controls.getHandleSize(lineHeight);
    final anchor =
        controls.getHandleAnchor(type ?? TextSelectionHandleType.left,
            lineHeight);
    return anchor - Offset(size.width / 2, size.height / 2);
  }

  void _handleDragStart(DragStartDetails details) {
    _grabOffset = _computeGrabOffset(details.globalPosition);
    _dragPosition = details.globalPosition + _grabOffset;
    widget.dragOffsetNotifier?.value = _dragPosition;
  }

  void _handleDragEnd(DragEndDetails details) {
    // when the drag is complete, we need to clear the drag offset
    widget.dragOffsetNotifier?.value = null;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragPosition += details.delta;
    // 上报的是端点位置而非手指位置：放大镜要聚焦「选到了哪个字」，
    // 而不是被手指压住的那一块。
    widget.dragOffsetNotifier?.value = _dragPosition;
    final position = widget.renderObject.getPositionForOffset(_dragPosition);
    if (widget.selection.isCollapsed) {
      widget.onSelectionHandleChanged(TextSelection.fromPosition(position));
      return;
    }

    final isNormalized =
        widget.selection.extentOffset >= widget.selection.baseOffset;
    TextSelection newSelection;
    switch (widget.position) {
      case _TextSelectionHandlePosition.start:
        newSelection = TextSelection(
          baseOffset:
              isNormalized ? position.offset : widget.selection.baseOffset,
          extentOffset:
              isNormalized ? widget.selection.extentOffset : position.offset,
        );
        break;
      case _TextSelectionHandlePosition.end:
        newSelection = TextSelection(
          baseOffset:
              isNormalized ? widget.selection.baseOffset : position.offset,
          extentOffset:
              isNormalized ? position.offset : widget.selection.extentOffset,
        );
        break;
    }

    if (newSelection.baseOffset >= newSelection.extentOffset) {
      // 上游原实现在此直接 return，两个后果：
      // 1) 手柄拖到与另一端重合前的一瞬就「完全卡住」，手指继续动也毫无反应；
      // 2) 一旦真的重合，选区折叠会让 _updateOrDisposeSelectionOverlayIfNeeded
      //    把整个 overlay dispose 掉，手柄凭空消失、手指还按着却拖不回来。
      // 改为夹紧到最小 1 字符选区：手柄继续跟随手指，也不会触发 dispose。
      newSelection = widget.position == _TextSelectionHandlePosition.start
          ? newSelection.copyWith(
              baseOffset: math.max(newSelection.extentOffset - 1, 0))
          : newSelection.copyWith(
              extentOffset: newSelection.baseOffset + 1);
    }

    widget.onSelectionHandleChanged(newSelection);
  }

  void _handleTap() {
    widget.onSelectionHandleTapped?.call();
  }

  @override
  Widget build(BuildContext context) {
    late LayerLink layerLink;
    TextSelectionHandleType? type;

    switch (widget.position) {
      case _TextSelectionHandlePosition.start:
        layerLink = widget.startHandleLayerLink;
        type = _chooseType(
          widget.renderObject.textDirection,
          TextSelectionHandleType.left,
          TextSelectionHandleType.right,
        );
        break;
      case _TextSelectionHandlePosition.end:
        // For collapsed selections, we shouldn't be building the [end] handle.
        assert(!widget.selection.isCollapsed);
        layerLink = widget.endHandleLayerLink;
        type = _chooseType(
          widget.renderObject.textDirection,
          TextSelectionHandleType.right,
          TextSelectionHandleType.left,
        );
        break;
    }

    // TODO: This logic doesn't work for TextStyle.height larger 1.
    // It makes the extent handle top end on iOS extend too high which makes
    // stick out above the selection background.
    // May have to use getSelectionBoxes instead of preferredLineHeight.
    // or expose TextStyle on the render object and calculate
    // preferredLineHeight / style.height
    final textPosition = widget.position == _TextSelectionHandlePosition.start
        ? widget.selection.base
        : widget.selection.extent;
    final lineHeight = widget.renderObject.preferredLineHeight(textPosition);
    final handleAnchor =
        widget.selectionControls.getHandleAnchor(type!, lineHeight);
    final handleSize = widget.selectionControls.getHandleSize(lineHeight);

    final handleRect = Rect.fromLTWH(
      -handleAnchor.dx,
      -handleAnchor.dy,
      handleSize.width,
      handleSize.height,
    );

    // Make sure the GestureDetector is big enough to be easily interactive.
    final interactiveRect = handleRect.expandToInclude(
      Rect.fromCircle(
          center: handleRect.center, radius: kMinInteractiveDimension / 2),
    );
    final padding = RelativeRect.fromLTRB(
      math.max((interactiveRect.width - handleRect.width) / 2, 0),
      math.max((interactiveRect.height - handleRect.height) / 2, 0),
      math.max((interactiveRect.width - handleRect.width) / 2, 0),
      math.max((interactiveRect.height - handleRect.height) / 2, 0),
    );

    return CompositedTransformFollower(
      link: layerLink,
      offset: interactiveRect.topLeft,
      showWhenUnlinked: false,
      child: FadeTransition(
        opacity: _opacity,
        child: Container(
          alignment: Alignment.topLeft,
          width: interactiveRect.width,
          height: interactiveRect.height,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            dragStartBehavior: widget.dragStartBehavior,
            onPanStart: _handleDragStart,
            onPanUpdate: _handleDragUpdate,
            onPanEnd: _handleDragEnd,
            onTap: _handleTap,
            child: Padding(
              padding: EdgeInsets.only(
                left: padding.left,
                top: padding.top,
                right: padding.right,
                bottom: padding.bottom,
              ),
              child: widget.selectionControls.buildHandle(
                context,
                type,
                lineHeight,
              ),
            ),
          ),
        ),
      ),
    );
  }

  TextSelectionHandleType? _chooseType(
    TextDirection textDirection,
    TextSelectionHandleType ltrType,
    TextSelectionHandleType rtlType,
  ) {
    if (widget.selection.isCollapsed) return TextSelectionHandleType.collapsed;

    switch (textDirection) {
      case TextDirection.ltr:
        return ltrType;
      case TextDirection.rtl:
        return rtlType;
    }
  }
}

/// A gesture detector to respond to non-exclusive event chains for a
/// text field.
///
/// An ordinary [GestureDetector] configured to handle events like tap and
/// double tap will only recognize one or the other. This widget detects both:
/// first the tap and then, if another tap down occurs within a time limit, the
/// double tap.
///
/// See also:
///
///  * [TextField], a Material text field which uses this gesture detector.
///  * [CupertinoTextField], a Cupertino text field which uses this gesture
///    detector.
class EditorTextSelectionGestureDetector extends StatefulWidget {
  /// Create a [EditorTextSelectionGestureDetector].
  ///
  /// Multiple callbacks can be called for one sequence of input gesture.
  /// The [child] parameter must not be null.
  const EditorTextSelectionGestureDetector({
    required this.child,
    this.onTapDown,
    this.onForcePressStart,
    this.onForcePressEnd,
    this.onSingleTapUp,
    this.onSingleTapCancel,
    this.onSecondaryTapDown,
    this.onSecondarySingleTapUp,
    this.onSecondarySingleTapCancel,
    this.onSecondaryDoubleTapDown,
    this.onSingleLongTapStart,
    this.onSingleLongTapMoveUpdate,
    this.onSingleLongTapEnd,
    this.onDoubleTapDown,
    this.onDragSelectionStart,
    this.onDragSelectionUpdate,
    this.onDragSelectionEnd,
    this.behavior,
    this.detectWordBoundary = true,
    this.dragOffsetNotifier,
    this.quillMagnifierBuilder,
    super.key,
  });

  /// Called for every tap down including every tap down that's part of a
  /// double click or a long press, except touches that include enough movement
  /// to not qualify as taps (e.g. pans and flings).
  final GestureTapDownCallback? onTapDown;

  /// Called when a pointer has tapped down and the force of the pointer has
  /// just become greater than [ForcePressGestureRecognizer.startPressure].
  final GestureForcePressStartCallback? onForcePressStart;

  /// Called when a pointer that had previously triggered [onForcePressStart] is
  /// lifted off the screen.
  final GestureForcePressEndCallback? onForcePressEnd;

  /// Called for each distinct tap except for every second tap of a double tap.
  /// For example, if the detector was configured with [onTapDown] and
  /// [onDoubleTapDown], three quick taps would be recognized as a single tap
  /// down, followed by a double tap down, followed by a single tap down.
  final GestureTapUpCallback? onSingleTapUp;

  /// Called for each touch that becomes recognized as a gesture that is not a
  /// short tap, such as a long tap or drag. It is called at the moment when
  /// another gesture from the touch is recognized.
  final GestureTapCancelCallback? onSingleTapCancel;

  /// onTapDown for mouse right click
  final GestureTapDownCallback? onSecondaryTapDown;

  /// onTapUp for mouse right click
  final GestureTapUpCallback? onSecondarySingleTapUp;

  /// onTapCancel for mouse right click
  final GestureTapCancelCallback? onSecondarySingleTapCancel;

  /// onDoubleTap for mouse right click
  final GestureTapDownCallback? onSecondaryDoubleTapDown;

  /// Called for a single long tap that's sustained for longer than
  /// [kLongPressTimeout] but not necessarily lifted. Not called for a
  /// double-tap-hold, which calls [onDoubleTapDown] instead.
  final GestureLongPressStartCallback? onSingleLongTapStart;

  /// Called after [onSingleLongTapStart] when the pointer is dragged.
  final GestureLongPressMoveUpdateCallback? onSingleLongTapMoveUpdate;

  /// Called after [onSingleLongTapStart] when the pointer is lifted.
  final GestureLongPressEndCallback? onSingleLongTapEnd;

  /// Called after a momentary hold or a short tap that is close in space and
  /// time (within [kDoubleTapTimeout]) to a previous short tap.
  final GestureTapDownCallback? onDoubleTapDown;

  /// Called when a mouse starts dragging to select text.
  final GestureDragStartCallback? onDragSelectionStart;

  /// Called repeatedly as a mouse moves while dragging.
  ///
  /// The frequency of calls is throttled to avoid excessive text layout
  /// operations in text fields. The throttling is controlled by the constant
  /// [_kDragSelectionUpdateThrottle].
  final GestureDragUpdateCallback? onDragSelectionUpdate;

  /// Called when a mouse that was previously dragging is released.
  final GestureDragEndCallback? onDragSelectionEnd;

  /// How this gesture detector should behave during hit testing.
  ///
  /// This defaults to [HitTestBehavior.deferToChild].
  final HitTestBehavior? behavior;

  /// Child below this widget.
  final Widget child;

  final bool detectWordBoundary;

  final ValueNotifier<Offset?>? dragOffsetNotifier;

  final QuillMagnifierBuilder? quillMagnifierBuilder;

  @override
  State<StatefulWidget> createState() =>
      _EditorTextSelectionGestureDetectorState();
}

class _EditorTextSelectionGestureDetectorState
    extends State<EditorTextSelectionGestureDetector> {
  // Counts down for a short duration after a previous tap. Null otherwise.
  Timer? _doubleTapTimer;
  Offset? _lastTapOffset;

  // True if a second tap down of a double tap is detected. Used to discard
  // subsequent tap up / tap hold of the same tap.
  bool _isDoubleTap = false;

  // _isDoubleTap for mouse right click
  bool _isSecondaryDoubleTap = false;

  // The last offset of the drag gesture.
  Offset? _magnifierPosition;

  @override
  void initState() {
    // when the drag offset changes (from handle drag or 1st selection update the magnifier)
    widget.dragOffsetNotifier?.addListener(_dragOffsetListener);
    super.initState();
  }

  @override
  void dispose() {
    _doubleTapTimer?.cancel();
    _dragUpdateThrottleTimer?.cancel();
    widget.dragOffsetNotifier?.removeListener(_dragOffsetListener);
    super.dispose();
  }

  // update magnifier location (hide if null) - this listener is called during a build phase
  // when selection handles are being dragged, so update during the next build
  void _dragOffsetListener() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Offset? position;

      final globalPosition = widget.dragOffsetNotifier?.value;

      if (globalPosition != null) {
        final renderBox = context.findRenderObject()! as RenderBox;
        position = renderBox.globalToLocal(globalPosition);
      }

      if (mounted) {
        setState(() {
          _magnifierPosition = position;
        });
      }
    });
  }

  // The down handler is force-run on success of a single tap and optimistically
  // run before a long press success.
  void _handleTapDown(TapDownDetails details) {
    widget.onTapDown?.call(details);

    // This isn't detected as a double tap gesture in the gesture recognizer
    // because it's 2 single taps, each of which may do different things
    // depending on whether it's a single tap, the first tap of a double tap,
    // the second tap held down, a clean double tap etc.
    if (_doubleTapTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition)) {
      // If there was already a previous tap, the second down hold/tap is a
      // double tap down.

      widget.onDoubleTapDown?.call(details);

      _doubleTapTimer!.cancel();
      _doubleTapTimeout();
      _isDoubleTap = true;
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isDoubleTap) {
      widget.onSingleTapUp?.call(details);
      _lastTapOffset = details.globalPosition;
      _doubleTapTimer = Timer(kDoubleTapTimeout, _doubleTapTimeout);
    }
    _isDoubleTap = false;
  }

  void _handleTapCancel() {
    widget.onSingleTapCancel?.call();
  }

  // added secondary tap function for mouse right click to show toolbar
  void _handleSecondaryTapDown(TapDownDetails details) {
    if (widget.onSecondaryTapDown != null) {
      widget.onSecondaryTapDown?.call(details);
    }
    if (_doubleTapTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition)) {
      widget.onSecondaryDoubleTapDown?.call(details);

      _doubleTapTimer!.cancel();
      _doubleTapTimeout();
      _isDoubleTap = true;
    }
  }

  void _handleSecondaryTapUp(TapUpDetails details) {
    if (!_isSecondaryDoubleTap) {
      widget.onSecondarySingleTapUp?.call(details);
      _lastTapOffset = details.globalPosition;
      _doubleTapTimer = Timer(kDoubleTapTimeout, _doubleTapTimeout);
    }
    _isSecondaryDoubleTap = false;
  }

  void _handleSecondaryTapCancel() {
    widget.onSecondarySingleTapCancel?.call();
  }

  DragStartDetails? _lastDragStartDetails;
  DragUpdateDetails? _lastDragUpdateDetails;
  Timer? _dragUpdateThrottleTimer;

  void _handleDragStart(DragStartDetails details) {
    assert(_lastDragStartDetails == null);
    _lastDragStartDetails = details;
    widget.dragOffsetNotifier?.value = details.globalPosition;
    widget.onDragSelectionStart?.call(details);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _lastDragUpdateDetails = details;
    _dragUpdateThrottleTimer ??= Timer(
      const Duration(milliseconds: 50),
      _handleDragUpdateThrottled,
    );
  }

  /// Drag updates are being throttled to avoid excessive text layouts in text
  /// fields. The frequency of invocations is controlled by the constant
  /// [_kDragSelectionUpdateThrottle].
  ///
  /// Once the drag gesture ends, any pending drag update will be fired
  /// immediately. See [_handleDragEnd].
  void _handleDragUpdateThrottled() {
    assert(_lastDragStartDetails != null);
    assert(_lastDragUpdateDetails != null);
    widget.dragOffsetNotifier?.value = _lastDragUpdateDetails?.globalPosition;
    if (widget.onDragSelectionUpdate != null) {
      widget.onDragSelectionUpdate!(
          //_lastDragStartDetails!,
          _lastDragUpdateDetails!);
    }
    _dragUpdateThrottleTimer = null;
    _lastDragUpdateDetails = null;
  }

  void _handleDragEnd(DragEndDetails details) {
    assert(_lastDragStartDetails != null);
    if (_dragUpdateThrottleTimer != null) {
      // If there's already an update scheduled, trigger it immediately and
      // cancel the timer.
      _dragUpdateThrottleTimer!.cancel();
      _handleDragUpdateThrottled();
    }

    widget.onDragSelectionEnd?.call(details);

    _dragUpdateThrottleTimer = null;
    _lastDragStartDetails = null;
    _lastDragUpdateDetails = null;
  }

  void _forcePressStarted(ForcePressDetails details) {
    _doubleTapTimer?.cancel();
    _doubleTapTimer = null;
    widget.onForcePressStart?.call(details);
  }

  void _forcePressEnded(ForcePressDetails details) {
    if (widget.onForcePressEnd != null) {
      widget.onForcePressEnd?.call(details);
    }
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    if (!_isDoubleTap) {
      widget.dragOffsetNotifier?.value = details.globalPosition;
      widget.onSingleLongTapStart?.call(details);
    }
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_isDoubleTap) {
      widget.dragOffsetNotifier?.value = details.globalPosition;
      widget.onSingleLongTapMoveUpdate?.call(details);
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    if (!_isDoubleTap) {
      widget.onSingleLongTapEnd?.call(details);
    }
    // after a long press (from double tap or drag) make sure
    // magnifier is removed
    widget.dragOffsetNotifier?.value = null;
    _isDoubleTap = false;
  }

  void _doubleTapTimeout() {
    _doubleTapTimer = null;
    _lastTapOffset = null;
  }

  bool _isWithinDoubleTapTolerance(Offset secondTapOffset) {
    if (_lastTapOffset == null) {
      return false;
    }

    return (secondTapOffset - _lastTapOffset!).distance <= kDoubleTapSlop;
  }

  @override
  Widget build(BuildContext context) {
    final gestures = <Type, GestureRecognizerFactory>{};

    // Use _TransparentTapGestureRecognizer so that TextSelectionGestureDetector
    // can receive the same tap events that a selection handle placed visually
    // on top of it also receives.
    gestures[_TransparentTapGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<_TransparentTapGestureRecognizer>(
      () => _TransparentTapGestureRecognizer(debugOwner: this),
      (instance) {
        instance
          ..onTapDown = _handleTapDown
          ..onTapUp = _handleTapUp
          ..onTapCancel = _handleTapCancel
          ..onSecondaryTapDown = _handleSecondaryTapDown
          ..onSecondaryTapUp = _handleSecondaryTapUp
          ..onSecondaryTapCancel = _handleSecondaryTapCancel;
      },
    );

    if (widget.onSingleLongTapStart != null ||
        widget.onSingleLongTapMoveUpdate != null ||
        widget.onSingleLongTapEnd != null) {
      gestures[LongPressGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
        () => LongPressGestureRecognizer(
            debugOwner: this,
            supportedDevices: <PointerDeviceKind>{PointerDeviceKind.touch}),
        (instance) {
          instance
            ..onLongPressStart = _handleLongPressStart
            ..onLongPressMoveUpdate = _handleLongPressMoveUpdate
            ..onLongPressEnd = _handleLongPressEnd;
        },
      );
    }

    if (widget.onDragSelectionStart != null ||
        widget.onDragSelectionUpdate != null ||
        widget.onDragSelectionEnd != null) {
      gestures[HorizontalDragGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
        () => HorizontalDragGestureRecognizer(
            debugOwner: this,
            supportedDevices: <PointerDeviceKind>{PointerDeviceKind.mouse}),
        (instance) {
          // Text selection should start from the position of the first pointer
          // down event.
          instance
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = _handleDragStart
            ..onUpdate = _handleDragUpdate
            ..onEnd = _handleDragEnd;
        },
      );
    }

    if (widget.onForcePressStart != null || widget.onForcePressEnd != null) {
      gestures[ForcePressGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<ForcePressGestureRecognizer>(
        () => ForcePressGestureRecognizer(debugOwner: this),
        (instance) {
          instance
            ..onStart =
                widget.onForcePressStart != null ? _forcePressStarted : null
            ..onEnd = widget.onForcePressEnd != null ? _forcePressEnded : null;
        },
      );
    }

    return RawGestureDetector(
      gestures: gestures,
      excludeFromSemantics: true,
      behavior: widget.behavior,
      child: (widget.quillMagnifierBuilder == null)
          ? widget.child
          : Stack(
              children: [
                widget.child,
                if (_magnifierPosition != null)
                  widget.quillMagnifierBuilder!(_magnifierPosition!)
              ],
            ),
    );
  }
}

// A TapGestureRecognizer which allows other GestureRecognizers to win in the
// GestureArena. This means both _TransparentTapGestureRecognizer and other
// GestureRecognizers can handle the same event.
//
// This enables proper handling of events on both the selection handle and the
// underlying input, since there is significant overlap between the two given
// the handle's padded hit area.  For example, the selection handle needs to
// handle single taps on itself, but double taps need to be handled by the
// underlying input.
class _TransparentTapGestureRecognizer extends TapGestureRecognizer {
  _TransparentTapGestureRecognizer({
    super.debugOwner,
  });

  @override
  void rejectGesture(int pointer) {
    // Accept new gestures that another recognizer has already won.
    // Specifically, this needs to accept taps on the text selection handle on
    // behalf of the text field in order to handle double tap to select. It must
    // not accept other gestures like longpresses and drags that end outside of
    // the text field.
    if (state == GestureRecognizerState.ready) {
      acceptGesture(pointer);
    } else {
      super.rejectGesture(pointer);
    }
  }
}
