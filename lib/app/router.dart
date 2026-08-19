import 'package:go_router/go_router.dart';

import 'navigation.dart';
import 'ui/editor_page.dart';
import 'ui/home_page.dart';
import 'ui/settings_page.dart';
import 'ui/sync_page.dart';
import 'ui/trash_page.dart';

/// 全局路由表（go_router，见 docs/技术架构.md 第 5 节）。
///
/// - `/` → HomePage：笔记列表主页（AppBar 含搜索框/排列模式切换/设置入口，
///   新建为右下角毛玻璃 FAB；同步、回收站入口在设置页）
/// - `/editor` → EditorPage：无 id，新建模式
/// - `/editor/:id` → EditorPage：有 id，编辑对应笔记
///   （go_router 不支持 `:id?` 可选路径段语法，可选 id 用两条路由表达）
/// - `/sync` → SyncPage：同步管理
/// - `/trash` → TrashPage：回收站（软删除笔记的恢复/清空）
/// - `/settings` → SettingsPage：设置（主题三档 + 同步/回收站/设备设置入口，
///   task-26）
///
/// 页面间仅通过路由参数传 id，笔记数据一律从 Riverpod Provider 读取，
/// 避免跨页传对象（见 docs/技术架构.md 第 5 节）。
///
/// [rootNavigatorKey]：全局根导航 key，供配对请求等全局弹窗在任意页面
/// 之上展示（task-14，见 docs/技术架构.md 7.3 节）。
final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/editor/:id',
      name: 'editorDetail',
      builder: (context, state) => EditorPage(id: state.pathParameters['id']),
    ),
    GoRoute(
      path: '/sync',
      name: 'sync',
      builder: (context, state) => const SyncPage(),
    ),
    GoRoute(
      path: '/trash',
      name: 'trash',
      builder: (context, state) => const TrashPage(),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsPage(),
    ),
  ],
);
