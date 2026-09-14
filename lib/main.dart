import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/repository/intro_note.dart';
import 'app/repository/providers.dart';
import 'app/repository/quill_clipboard.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'app/ui/pairing_dialog_controller.dart';

void main() async {
  // 首帧前加载持久化 UI 设置（主题模式等）：本地 SQLite 毫秒级完成，
  // 保证启动首帧即应用用户选择的深/亮主题，避免「启动亮→暗闪烁」
  // （用户反馈：深色模式用户打开软件先亮后暗）。加载失败不阻塞启动，
  // 保持默认（跟随系统）。
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  try {
    final settings = container.read(appSettingsProvider);
    await settings.ensureLoaded();
    // 首帧前直接把主题模式写入 notifier：否则首帧仍按默认（跟随系统）
    // 渲染，设置异步写入 notifier 后才切深色——造成「亮→暗」一闪
    // （用户反馈：系统亮色 + 应用内深色，启动先亮后暗）。
    themeModeNotifier.value = settings.themeMode;
  } catch (_) {}
  // 首次安装：创建介绍笔记（仅本机保存，可删除、删后不复活）。放在首帧
  // 之前执行，避免用户先看到空列表、笔记随后才出现。
  try {
    await ensureIntroNote(
      container.read(databaseProvider),
      container.read(noteRepositoryProvider),
    );
  } catch (_) {}
  // 剪贴板 HTML 净化：网页/Office 写进剪贴板的 CF_HTML 包装（描述头里的
  // SourceURL 等）不能进正文，须在解析前清掉（见 quill_clipboard.dart）。
  installSanitizingClipboardService();
  runApp(
    UncontrolledProviderScope(container: container, child: const LanNotesApp()),
  );
}

/// 应用根组件：MaterialApp.router 接入 GoRouter（见 docs/技术架构.md 第 5 节）。
///
/// 全局配对弹窗控制器（[pairingDialogControllerProvider]）在此保持存活：
/// 被动收到 pairing_request 时通过 [rootNavigatorKey] 在任意页面之上弹窗
/// 输入对端连接密码；检测到设备 ID 冲突时全局提示（task-14，
/// 见 docs/技术架构.md 7.3 节）。
///
/// 生命周期（task-17，用户实测反馈）：
/// - **启动自动同步**：initState 异步读取 auto_sync 配置（默认开），开启则
///   自动调用 [SyncService.enable]（无需用户手动点开关）；
/// - **后台恢复同步**：监听 [AppLifecycleState]，回前台（resumed）时若
///   auto_sync 开启且同步当前未 enable（安卓后台被系统关闭/挂起/进程重启），
///   自动重新 enable 恢复发现/连接；用户手动关闭同步开关后不自动恢复
///   （见 [SyncService.isUserDisabled] 语义，尊重用户操作）。
class LanNotesApp extends ConsumerStatefulWidget {
  const LanNotesApp({super.key});

  @override
  ConsumerState<LanNotesApp> createState() => _LanNotesAppState();
}

class _LanNotesAppState extends ConsumerState<LanNotesApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 启动自动同步：首帧后异步执行，不阻塞 UI（enable 幂等，可安全重入）。
    unawaited(_resumeSync());
    // 启动恢复持久化 UI 设置（主题模式 + 列表布局模式，task-26）。
    unawaited(_loadUiSettings());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App 生命周期变化：回前台（resumed）时按 auto_sync 配置恢复同步。
  ///
  /// 语义区分（task-17）：
  /// - 用户手动关闭同步开关（[SyncService.disableByUser]）→ 不自动恢复
  ///   （尊重用户操作，[SyncService.isUserDisabled] 为 true）；
  /// - 后台被系统关闭/挂起、enable 失败、进程重启导致未 enable →
  ///   自动重新 enable（恢复发现/连接）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeSync());
    }
  }

  /// 启动/回前台/解锁时恢复同步（enable 幂等 + 已启用断开时主动重连）。
  ///
  /// 条件：auto_sync=true 且非用户手动关闭。
  /// - 未启用（首次启动/进程被后台清理重启）→ enable（自动发现+直连）；
  /// - 已启用但无就绪连接（锁屏/切后台网络被系统挂起断开）→
  ///   [SyncService.retryConnections] 凭缓存地址主动重连（用户反馈：
  ///   切回前台/解锁回来不重连，因原逻辑 `!isEnabled` 条件整段跳过）。
  /// 失败静默：不阻塞 App，同步页可手动开启。
  Future<void> _resumeSync() async {
    try {
      final identity = ref.read(deviceIdentityProvider);
      await identity.ensureLoaded(); // 读取持久化配置（含 auto_sync）
      final service = ref.read(syncServiceProvider);
      if (!identity.autoSync || service.isUserDisabled) return;
      // 开关状态持久化（需求 10）：用户上次手动关闭同步 → 重启/回前台不自动开启。
      if (!identity.syncSwitchOn) return;
      if (!service.isEnabled) {
        await service.enable();
      } else if (!service.isConnected) {
        await service.retryConnections();
      }
    } catch (_) {
      // 自动恢复失败（如端口被占用）：不阻塞 App，同步页可手动开启。
    }
  }

  /// 读取持久化 UI 设置（主题模式 + 列表布局模式，task-26）并生效。
  ///
  /// [appSettingsProvider] 构造即触发异步加载；本方法等待加载完成后把
  /// 持久化值写入 [themeModeNotifier] 与 [layoutModeProvider]，保证跨启动
  /// 沿用用户选择。加载失败保持默认（跟随系统 / 平台默认布局）。
  Future<void> _loadUiSettings() async {
    try {
      final settings = ref.read(appSettingsProvider);
      await settings.ensureLoaded();
      themeModeNotifier.value = settings.themeMode;
      ref.read(layoutModeProvider.notifier).state = settings.layoutMode;
    } catch (_) {
      // 加载失败不阻塞 App，保持默认值。
    }
  }

  @override
  Widget build(BuildContext context) {
    // watch 保持全局配对弹窗控制器存活（订阅 pairingEvents / 冲突事件流）。
    ref.watch(pairingDialogControllerProvider);
    // 主题模式（亮/暗/跟随系统）：themeModeNotifier 由 theme.dart 提供，
    // 参考 EE app.dart 的 themeMode 处理（task-25）。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp.router(
        title: 'EasyNote',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: mode,
        // flutter_quill 工具栏/编辑器本地化（task-29 富文本）：不带这些
        // delegate 时 QuillSimpleToolbar 会抛 MissingFlutterQuillLocalization。
        localizationsDelegates:
            FlutterQuillLocalizations.localizationsDelegates,
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
        // 主题切换全局过渡：默认 200ms 偏生硬，350ms + easeInOutCubic
        // 让背景/卡片/文字整体平滑渐变（丝滑主题切换）。
        themeAnimationDuration: const Duration(milliseconds: 350),
        themeAnimationCurve: Curves.easeInOutCubic,
        routerConfig: appRouter,
      ),
    );
  }
}
