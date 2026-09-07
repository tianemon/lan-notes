import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// 拖动手柄 / 长按拖选时跟随的放大镜（移动端）。
///
/// 通过 [QuillEditorConfig.quillMagnifierBuilder] 注入，quill 默认**没有**
/// 放大镜（该字段缺省为 null），这也是「手指按住手柄后完全看不到选到哪个
/// 字」的直接原因。
///
/// 坐标约定（踩坑点）：[position] 是 quill 把 `dragOffsetNotifier` 的
/// **全局**坐标用 `globalToLocal` 换算到编辑器 Stack 的**内容坐标**（随正文
/// 一起滚动），本函数返回的 widget 作为该 Stack 的第二个 child 插入，
/// 因此必须自己用 [Positioned] 定位。跟屏幕坐标不是一回事，不能拿
/// MediaQuery 去 clamp。
///
/// 实现要点沿用 EasyEdit 的实测参数（temp/可复用实现整理-工具栏与选区交互.md
/// 第 3.2 节）：
///  - 140×48 的扁长条：文本横向排布，放大镜要「横向宽、纵向窄」，高 48 约
///    一行半，符合阅读习惯；
///  - [focalPointOffset] 必须在确定最终位置后再用**实际中心**重算，否则顶部
///    放不下翻转到下方时，放大内容会整体偏掉。
Widget buildQuillMagnifier(Offset position) {
  const double width = 140;
  const double height = 48;
  // 放大镜底边距选区端点的距离。36 让镜体稳定落在手指上方：手柄画在文字
  // 上方时手指约在端点上方 30，画在下方时手指约在端点下方 30，都能避开。
  const double gap = 36;
  const double margin = 4;

  // 默认放在端点上方；顶部空间不够就翻到下方（避免被裁掉）。
  final above = position.dy - gap - height;
  final top = above >= margin ? above : position.dy + gap;
  final left = math.max(position.dx - width / 2, margin);

  // 焦点 = 选区端点本身，用 clamp/翻转后的实际中心换算。
  final center = Offset(left + width / 2, top + height / 2);

  return Positioned(
    left: left,
    top: top,
    // 必须忽略命中：放大镜叠在正文上，否则会吃掉手柄的拖动事件。
    child: IgnorePointer(
      child: RawMagnifier(
        size: const Size(width, height),
        magnificationScale: 1.5,
        focalPointOffset: position - center,
        clipBehavior: Clip.hardEdge,
        decoration: MagnifierDecoration(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.7),
              width: 0.5,
            ),
          ),
          shadows: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
      ),
    ),
  );
}
