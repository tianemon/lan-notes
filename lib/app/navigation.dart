import 'package:flutter/material.dart';

/// 全局根导航 key：MaterialApp.router 的根 Navigator 挂载于此。
///
/// 供全局 UI（配对请求弹窗、设备 ID 冲突提示等）在任意页面之上展示——
/// 用户不在同步页也能看到配对请求（task-14，docs/技术架构.md 7.3 节）。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
