import 'package:flutter/material.dart';

// ============================================================
// 手绘图标（MaterialIcons 字体替代，CLAUDE.md「图标优先 SVG/手绘」）
// ============================================================
//
// 背景：MaterialIcons-Regular.otf 是 CFF 轮廓字体，Windows 渲染路径
// 下部分字形显示空白（用户实测：文件夹/设备图标空白，其他正常；
// macOS 正常）。这些图标改用手绘 CustomPainter（24x24 坐标系 +
// Material Symbols 官方 path 数据），完全不依赖字体，跨平台一致。
//
// 用法：`AppIcon.folder(size: 17, color: ...)` 或
// `AppIcon(icon: AppIconData.folder, size: 17, color: ...)`。

/// 手绘图标枚举（避免运行时 IconData 变量引用 + 不依赖字体）。
enum AppIconData { folder, folderOff, desktopWindows, smartphone, laptopMac, tablet }

/// 手绘图标组件：用法同 Icon，但走 CustomPainter。
class AppIcon extends StatelessWidget {
  const AppIcon(this.icon, {super.key, this.size = 24, this.color});

  final AppIconData icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _AppIconPainter(
        icon,
        color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 便捷：文件夹图标（24x24 坐标系，fill 风格，与 Material folder 一致）。
/// 自动读取 IconTheme（与 Icon 组件一致：size/color 可被外层 IconTheme
/// 覆盖），默认取主题 onSurfaceVariant。
class AppFolderIcon extends StatelessWidget {
  const AppFolderIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return AppIcon(
      AppIconData.folder,
      size: size ?? theme.size ?? 24,
      color: color ?? theme.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

/// 便捷：文件夹 + 斜线图标（folder_off 风格，「未分类」用）。
/// 主题/尺寸/颜色语义与 [AppFolderIcon] 完全一致。
class AppFolderOffIcon extends StatelessWidget {
  const AppFolderOffIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return AppIcon(
      AppIconData.folderOff,
      size: size ?? theme.size ?? 24,
      color: color ?? theme.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

class _AppIconPainter extends CustomPainter {
  _AppIconPainter(this.icon, this.color);

  final AppIconData icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // folder 用描边（空心，与 Material folder_outlined 一致，用户确认）；
    // 设备图标用填充（原 Icons.smartphone/laptop_mac/desktop_windows 均
    // 为实心 baseline 变体）。
    final isStroke =
        icon == AppIconData.folder || icon == AppIconData.folderOff;
    final paint = Paint()
      ..color = color
      ..style = isStroke ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);
    canvas.drawPath(_pathFor(icon), paint);
    canvas.restore();
  }

  /// folder 轮廓（24x24，material folder 官方 path）。
  void _folderPath(Path p) {
    p.moveTo(10, 4);
    p.lineTo(4, 4);
    p.cubicTo(2.9, 4, 2.01, 4.9, 2.01, 6);
    p.lineTo(2, 18);
    p.cubicTo(2, 19.1, 2.9, 20, 4, 20);
    p.lineTo(20, 20);
    p.cubicTo(21.1, 20, 22, 19.1, 22, 18);
    p.lineTo(22, 8);
    p.cubicTo(22, 6.9, 21.1, 6, 20, 6);
    p.lineTo(12, 6);
    p.lineTo(10, 4);
    p.close();
  }

  /// Material Symbols 官方 24x24 path 数据（填充风格）。
  Path _pathFor(AppIconData icon) {
    final p = Path();
    switch (icon) {
      case AppIconData.folder:
        // material folder: M10,4H4C2.9,4 2.01,4.9 2.01,6L2,18c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2V8c0,-1.1 -0.9,-2 -2,-2h-8L10,4z
        _folderPath(p);
      case AppIconData.folderOff:
        // folder + 45° 斜线（material folder_off 的斜线走向，左上→右下，
        // 端点略超出文件夹轮廓）：用于「未分类」（不属于任何文件夹）。
        _folderPath(p);
        p.moveTo(3.5, 3.5);
        p.lineTo(20.5, 20.5);
      case AppIconData.desktopWindows:
        // material desktop_windows: M21,2H3C1.9,2 1,2.9 1,4v13c0,1.1 0.9,2 2,2h7v2H8v2h8v-2h-2v-2h7c1.1,0 2,-0.9 2,-2V4C23,2.9 22.1,2 21,2zM21,17H3V4h18V17z
        p.moveTo(21, 2);
        p.lineTo(3, 2);
        p.cubicTo(1.9, 2, 1, 2.9, 1, 4);
        p.lineTo(1, 17);
        p.cubicTo(1, 18.1, 1.9, 19, 3, 19);
        p.lineTo(10, 19);
        p.lineTo(10, 21);
        p.lineTo(8, 21);
        p.lineTo(8, 23);
        p.lineTo(16, 23);
        p.lineTo(16, 21);
        p.lineTo(14, 21);
        p.lineTo(14, 19);
        p.lineTo(21, 19);
        p.cubicTo(22.1, 19, 23, 18.1, 23, 17);
        p.lineTo(23, 4);
        p.cubicTo(23, 2.9, 22.1, 2, 21, 2);
        p.close();
        p.moveTo(21, 17);
        p.lineTo(3, 17);
        p.lineTo(3, 4);
        p.lineTo(21, 4);
        p.lineTo(21, 17);
        p.close();
      case AppIconData.smartphone:
        // material smartphone: M17,1.01L7,1C5.9,1 5,1.9 5,3v18c0,1.1 0.9,2 2,2h10c1.1,0 2,-0.9 2,-2V3C19,1.9 18.1,1.01 17,1.01zM17,19H7V5h10V19z
        p.moveTo(17, 1.01);
        p.lineTo(7, 1);
        p.cubicTo(5.9, 1, 5, 1.9, 5, 3);
        p.lineTo(5, 21);
        p.cubicTo(5, 22.1, 5.9, 23, 7, 23);
        p.lineTo(17, 23);
        p.cubicTo(18.1, 23, 19, 22.1, 19, 21);
        p.lineTo(19, 3);
        p.cubicTo(19, 1.9, 18.1, 1.01, 17, 1.01);
        p.close();
        p.moveTo(17, 19);
        p.lineTo(7, 19);
        p.lineTo(7, 5);
        p.lineTo(17, 5);
        p.lineTo(17, 19);
        p.close();
      case AppIconData.laptopMac:
        // material laptop_mac: M20,18c1.1,0 1.99,-0.9 1.99,-2L22,6c0,-1.1 -0.9,-2 -2,-2H4C2.9,4 2,4.9 2,6v10c0,1.1 0.9,2 2,2H0v2h24v-2h-4zM4,6h16v10H4V6z
        p.moveTo(20, 18);
        p.cubicTo(21.1, 18, 21.99, 17.1, 21.99, 16);
        p.lineTo(22, 6);
        p.cubicTo(22, 4.9, 21.1, 4, 20, 4);
        p.lineTo(4, 4);
        p.cubicTo(2.9, 4, 2, 4.9, 2, 6);
        p.lineTo(2, 16);
        p.cubicTo(2, 17.1, 2.9, 18, 4, 18);
        p.lineTo(0, 18);
        p.lineTo(0, 20);
        p.lineTo(24, 20);
        p.lineTo(24, 18);
        p.lineTo(20, 18);
        p.close();
        p.moveTo(4, 6);
        p.lineTo(20, 6);
        p.lineTo(20, 16);
        p.lineTo(4, 16);
        p.lineTo(4, 6);
        p.close();
      case AppIconData.tablet:
        // material tablet: M21,4H3C1.9,4 1,4.9 1,6v12c0,1.1 0.9,2 2,2h18c1.1,0 2,-0.9 2,-2V6C23,4.9 22.1,4 21,4zM7,18H3V6h4V18zM21,18h-4V6h4V18z
        p.moveTo(21, 4);
        p.lineTo(3, 4);
        p.cubicTo(1.9, 4, 1, 4.9, 1, 6);
        p.lineTo(1, 18);
        p.cubicTo(1, 19.1, 1.9, 20, 3, 20);
        p.lineTo(21, 20);
        p.cubicTo(22.1, 20, 23, 19.1, 23, 18);
        p.lineTo(23, 6);
        p.cubicTo(23, 4.9, 22.1, 4, 21, 4);
        p.close();
        p.moveTo(7, 18);
        p.lineTo(3, 18);
        p.lineTo(3, 6);
        p.lineTo(7, 6);
        p.lineTo(7, 18);
        p.close();
        p.moveTo(21, 18);
        p.lineTo(17, 18);
        p.lineTo(17, 6);
        p.lineTo(21, 6);
        p.lineTo(21, 18);
        p.close();
    }
    return p;
  }

  @override
  bool shouldRepaint(_AppIconPainter old) =>
      old.icon != icon || old.color != color;
}
