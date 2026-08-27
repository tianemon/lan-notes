import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repository/providers.dart';
import '../sync/sync_service.dart';
import '../navigation.dart';
import 'widgets/glass_style.dart';
import '../theme.dart';

/// 全局配对弹窗控制器（Provider 单例）：App 根组件 watch 保持存活。
///
/// 解决 task-13 遗留问题：
/// - **仅同步页生效** → 通过全局 [rootNavigatorKey] 弹窗，用户在任意页面
///   都能看到配对请求；
/// - **单槽位覆盖** → 多对端同时请求按 FIFO 队列依次展示，当前请求
///   完成/取消后自动切换到下一个。
///
/// v4（task-27）：配对去密码改**请求-同意**——弹窗为「xx 请求连接」，
/// 用户点「同意」（[accept] → [SyncService.acceptPairing]）或「拒绝」
/// （[reject] → [SyncService.rejectPairing]），不再输入密码。
final pairingDialogControllerProvider = Provider<PairingDialogController>((ref) {
  final controller = PairingDialogController(
    service: ref.watch(syncServiceProvider),
    navigatorKey: rootNavigatorKey,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 配对弹窗 UI 状态（全局控制器驱动）。
class _PairingDialogState {
  const _PairingDialogState({
    this.request,
    this.queued = 0,
  });

  /// 当前展示的配对请求（配对队列队首）。
  final PairingRequestedEvent? request;

  /// 排队中的配对请求数（含当前；>1 时展示排队提示）。
  final int queued;
}

/// 全局配对弹窗控制器（task-14，docs/技术架构.md 7.3 节 v4）。
///
/// - 订阅 [SyncService.pairingEvents]：收到 `pairing_request` 时通过全局
///   [rootNavigatorKey] 弹窗「xx 请求连接」（与 SyncService 内部配对队列
///   同序，队首即当前弹窗目标）；成功/拒绝/取消移除当前请求并自动切换
///   到下一个；
/// - 订阅 [SyncService.deviceIdConflictEvents]：检测到与本机相同 deviceId
///   的设备（握手/发现/手动连接）时全局 SnackBar 提示用户重置设备 ID。
class PairingDialogController {
  PairingDialogController({
    required SyncService service,
    required GlobalKey<NavigatorState> navigatorKey,
  }) : _service = service,
       _navigatorKey = navigatorKey {
    _sub = service.pairingEvents.listen(_onPairingEvent);
    _conflictSub = service.deviceIdConflictEvents.listen(_onConflictEvent);
  }

  final SyncService _service;
  final GlobalKey<NavigatorState> _navigatorKey;

  /// 待处理配对请求队列（FIFO，与 SyncService 内部 [_pairingQueue] 同序）。
  final List<PairingRequestedEvent> _pending = [];

  /// 弹窗内容状态（ValueListenableBuilder 驱动，实时更新排队数）。
  final ValueNotifier<_PairingDialogState> _state =
      ValueNotifier(const _PairingDialogState());

  StreamSubscription<PairingEvent>? _sub;
  StreamSubscription<DeviceIdConflictEvent>? _conflictSub;
  bool _dialogOpen = false;

  /// 对端设备名展示回退：空/全空白时依次回退 deviceId、'未知设备'。
  ///
  /// 对端上报的 deviceName 可能为空（Android 取主机名失败 / 传输字段缺失），
  /// 配对成功提示、弹窗标题统一经此回退，避免展示「『』」空名。
  String _displayName(String? name, {String? deviceId}) {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    final id = deviceId?.trim() ?? '';
    return id.isNotEmpty ? id : '未知设备';
  }

  void _onPairingEvent(PairingEvent event) {
    switch (event) {
      case PairingRequestedEvent(): // 新请求入队（可能排在已有请求之后）
        _pending.removeWhere((e) => e.connectionId == event.connectionId);
        _pending.add(event);
        _refresh();
        _ensureDialog();
      case PairingFailedEvent(): // 本机请求被拒绝：SnackBar 提示
        _showSnack(
          '「${_displayName(null, deviceId: event.deviceId)}」拒绝了配对请求'
          '${event.reason.isNotEmpty && event.reason != '配对被拒绝' ? '：${event.reason}' : ''}',
        );
      case PairingSucceededEvent(): // 配对成功：移除当前请求，展示下一个
        _pending.removeWhere((e) => e.deviceId == event.deviceId);
        _refresh();
        _maybeCloseDialog();
        _showSnack('与「${_displayName(event.deviceName, deviceId: event.deviceId)}」配对成功');
      case PairingCancelledEvent(): // 请求失效（断开/取消/拒绝）：移除
        _pending.removeWhere((e) => e.connectionId == event.connectionId);
        _refresh();
        _maybeCloseDialog();
    }
  }

  void _onConflictEvent(DeviceIdConflictEvent event) {
    _showSnack(
      '设备 ID 冲突：检测到与本机相同的设备 ID（可能恢复了备份数据），'
      '请在设置中重置设备 ID',
    );
  }

  /// 以配对队列队首刷新弹窗状态。
  void _refresh() {
    final next = _pending.isEmpty
        ? const _PairingDialogState()
        : _PairingDialogState(
            request: _pending.first,
            queued: _pending.length,
          );
    _state.value = next;
  }

  /// 有排队请求且弹窗未打开时，通过全局导航弹出「同意/拒绝」确认框。
  void _ensureDialog() {
    if (_dialogOpen || _pending.isEmpty) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) return; // 导航未就绪：下一次事件再试。
    _dialogOpen = true;
    showDialog<void>(
      context: nav.context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<_PairingDialogState>(
        valueListenable: _state,
        builder: (context, ui, _) {
          final request = ui.request;
          if (request == null) {
            // 弹窗打开期间队列被清空（如全部请求失效）：关闭弹窗。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_dialogOpen) _maybeCloseDialog();
            });
            return const SizedBox.shrink();
          }
          final name = _displayName(request.deviceName, deviceId: request.deviceId);
          return GlassDialog(
            title: Text('「$name」请求连接'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ui.queued > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '还有 ${ui.queued - 1} 个配对请求排队等待处理',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Text('是否同意「$name」连接本机并同步笔记？'),
                const SizedBox(height: 8),
                Text(
                  '同意后双方建立信任关系（配对），之后将自动连接并同步数据。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: reject,
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: accept,
                child: const Text('同意'),
              ),
            ],
          );
        },
      ),
    ).then((_) => _dialogOpen = false);
  }

  /// 队列已空时关闭弹窗（幂等）。
  void _maybeCloseDialog() {
    if (!_dialogOpen || _pending.isNotEmpty) return;
    _dialogOpen = false;
    final nav = _navigatorKey.currentState;
    if (nav != null) {
      nav.pop();
    }
  }

  /// 用户点「同意」：SyncService 生成密钥并发送 pairing_accept。
  void accept() {
    unawaited(_service.acceptPairing());
  }

  /// 用户点「拒绝」：SyncService 发送 pairing_fail 并断开
  /// （[PairingCancelledEvent] 触发本控制器移除请求并切换到下一个）。
  void reject() {
    unawaited(_service.rejectPairing());
  }

  void _showSnack(String message) {
    showAppSnackBar(message);
  }

  void dispose() {
    _sub?.cancel();
    _conflictSub?.cancel();
    _state.dispose();
  }
}
