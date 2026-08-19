import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repository/providers.dart';
import '../sync/discovery_service.dart';
import '../sync/sync_protocol.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import 'widgets/glass_style.dart';
import 'widgets/section_label.dart';

/// 同步管理页：开启/关闭同步（P2P 总开关）、设备发现与对端连接管理、
/// 状态显示、手动同步、设备设置（含重置设备 ID）。
///
/// 布局（flat 风格，Material 3，见 docs/技术架构.md 第 4 节组件树）：
/// - 顶部同步总开关：开启后本机同时担任服务端（固定端口 WebSocket 监听 +
///   UDP 广播发布）与客户端（v4 智能扫描：直连优先 + 按需扫描），见
///   [SyncService.enable]；状态说明展示本机设备名与固定端口；
/// - **已配对设备列表**（task-14）：信任列表 + 连接状态（已连接/连接中/
///   自动连接中），已连接设备可断开（断开后已配对设备进入退避扫描自动
///   重连，符合 v4 连接策略）；
/// - **发现的设备列表**（v4）：**常态不自动扫描**——列表仅在手动
///   「重新扫描」（3s 收集窗口后定格）与已配对断线退避扫描时更新；
///   未配对设备标「未配对」，点击连接发起配对请求（同意/拒绝弹窗由全局
///   [PairingDialogController] 弹出，任意页面可见）；
/// - 设备 ID 冲突横幅：握手/发现/手动连接检测到同 ID 设备时置顶展示，
///   提示在设置中重置设备 ID；
/// - SyncStatusBar：同步开关状态、已连接设备数、最近同步时间、同步中指示；
/// - 「立即同步」按钮：向所有已连接对端发送 sync_request 触发全量对齐；
/// - 设置入口：本机设备名修改（v4 已移除连接密码）+ **重置设备 ID**
///   （重新生成 deviceId，旧配对关系失效需重新配对）。
///
/// 数据流（docs/技术架构.md 第 6 节）：本页只消费 SyncService 暴露的流
/// （syncCompleted / devicesUpdates / peerDevices / discoveredDevices /
/// deviceIdConflictEvents），变更一律调 SyncService 方法，不在 Widget 内
/// 直接操作数据库。
///
/// 配对弹窗（被动 pairing_request）已移至全局控制器（[PairingDialogController]），
/// 本页不再维护本地弹窗状态；多对端同时请求由全局队列依次展示。
///
/// 生命周期：同步开关状态由 SyncService 统一管理（enable/disable），
/// 页面打开/退出不再单独启停发现（task-13 P2P）。
class SyncPage extends ConsumerStatefulWidget {
  const SyncPage({super.key});

  @override
  ConsumerState<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends ConsumerState<SyncPage> {
  /// 「同步中」指示的最长展示时长：全量同步超时兜底，防止一直转圈。
  static const Duration _syncIndicatorTimeout = Duration(seconds: 8);

  late final SyncService _service;

  StreamSubscription<DateTime>? _syncSub;
  StreamSubscription<List<DeviceInfo>>? _devicesSub;
  StreamSubscription<List<PeerDevice>>? _peersSub;
  StreamSubscription<List<DiscoveredDevice>>? _discoverySub;
  StreamSubscription<DeviceIdConflictEvent>? _conflictSub;
  Timer? _syncTimeout;

  /// 顶部同步总开关状态（与 [SyncService.isEnabled] 保持一致）。
  bool _syncEnabled = false;

  /// 开关切换进行中（防止快速连点重复触发启停）。
  bool _busy = false;

  /// 发现的设备列表（UDP 广播发现，见 [SyncService.discoveredDevices]）。
  List<DiscoveredDevice> _discoveredDevices = const [];

  /// 手动「重新扫描」进行中（v4：3s 收集窗口内显示「正在搜索设备…」）。
  bool _scanning = false;

  /// 设备 ID 冲突提示（非空时置顶展示横幅，可手动关闭）。
  String? _conflictMessage;

  /// 最近一次同步完成时间（来自 [SyncService.syncCompleted]）。
  DateTime? _lastSyncTime;

  /// 同步进行中（连接握手全量同步 / 手动「立即同步」期间为 true）。
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(syncServiceProvider);
    _syncEnabled = _service.isEnabled;
    _lastSyncTime = _service.lastSyncTime;

    _syncSub = _service.syncCompleted.listen((time) {
      _setSyncing(false);
      if (mounted) setState(() => _lastSyncTime = time);
    });
    // 本机连接表变化（连接/断开/登记）：触发重建，列表读 service.connectedDevices。
    _devicesSub = _service.devicesUpdates.listen((_) {
      if (mounted) setState(() {});
    });
    // 对端设备列表（连接表 + 信任列表合并）：已配对设备卡数据源。
    _peersSub = _service.peerDevices.listen((_) {
      if (mounted) setState(() {});
    });
    _discoverySub = _service.discoveredDevices.listen((devices) {
      if (mounted) setState(() => _discoveredDevices = devices);
    });
    // 设备 ID 冲突（握手/发现/手动连接）：置顶横幅提示重置设备 ID。
    _conflictSub = _service.deviceIdConflictEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        _conflictMessage =
            '设备 ID 冲突：检测到与本机相同的设备 ID（可能恢复了备份数据），'
            '请在设置中重置设备 ID';
      });
    });
  }

  @override
  void dispose() {
    _syncTimeout?.cancel();
    _syncSub?.cancel();
    _devicesSub?.cancel();
    _peersSub?.cancel();
    _discoverySub?.cancel();
    _conflictSub?.cancel();
    super.dispose();
  }

  // ---------- 事件处理 ----------

  /// 顶部同步总开关：开启→[SyncService.enable]（服务端 + UDP 广播发布/发现 +
  /// 自动连接已配对设备）；关闭→[SyncService.disable]。
  Future<void> _onSyncSwitchChanged(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (enabled) {
        await _service.enable();
        if (mounted) {
          setState(() => _syncEnabled = _service.isEnabled);
        }
      } else {
        // 用户手动关闭：走 disableByUser（task-17）——记录「用户手动关闭」
        // 标记，回前台不自动重新开启（尊重用户操作；重启后按 auto_sync 配置恢复）。
        await _service.disableByUser();
        _syncTimeout?.cancel();
        if (mounted) {
          setState(() {
            _syncEnabled = false;
            _discoveredDevices = const [];
            _syncing = false;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _syncEnabled = _service.isEnabled);
        _showSnack('操作失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 点击发现的设备：手动建立对端连接（已配对直接同步；
  /// 未配对发起配对请求——v4 起请求-同意，对端弹窗「xx 请求连接」
  /// 由全局 [PairingDialogController] 展示同意/拒绝）。
  Future<void> _connectToPeer(DiscoveredDevice device) async {
    if (device.deviceId == _service.deviceId) return; // 同 ID：不连接（冲突）
    try {
      await _service.connectToPeer(device);
    } catch (_) {
      if (mounted) _showSnack('无法连接 ${device.deviceName}');
    }
  }

  /// 断开指定对端连接（task-16，WiFi 式断开）：断开 + 会话级手动断开
  /// 标记——当下发现轮询不自动重连；重新开启同步/重启 App 后自动重连
  /// 恢复；手动连接该设备时清除标记。
  Future<void> _disconnectPeer(PeerDevice peer) async {
    await _service.disconnectPeer(peer.deviceId);
    if (mounted) {
      _showSnack('已断开 ${peer.deviceName}（手动断开后不自动重连，可重新开启同步恢复）');
    }
  }

  /// 切换某已配对设备的「自动连接」开关（task-16，WiFi 式）。
  ///
  /// 关闭后保持配对（信任列表不删除）但不自动连接；手动点击仍可连
  /// （不改变配置）。已建立的连接不受影响。
  Future<void> _setAutoConnect(PeerDevice peer, bool value) async {
    await _service.setAutoConnect(peer.deviceId, value);
    if (mounted) {
      _showSnack(value
          ? '已开启「${peer.deviceName}」的自动连接'
          : '已关闭「${peer.deviceName}」的自动连接（保持配对，手动可连）');
    }
  }

  /// 取消配对（task-27 v4 双边解除）：二次确认后断开连接 + 移除信任列表
  /// + 通知对端移除（unpair）。
  ///
  /// 取消后该设备在「已配对设备」列表中消失，重新连接本机需再次请求配对
  /// （对端信任列表中的本机条目同步移除，双边不残留）。
  Future<void> _confirmUnpairPeer(PeerDevice peer) async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      title: const Text('取消配对？'),
      content: Text(
        '将断开与「${peer.deviceName}」的连接并移除信任关系。\n\n'
        '对方也会同步移除对本机的信任并断开连接。确定继续？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('取消配对'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    await _service.unpairPeer(peer.deviceId);
    if (mounted) _showSnack('已取消与「${peer.deviceName}」的配对');
  }

  /// 「立即同步」：向所有已连接对端发送 sync_request 触发全量对齐。
  void _syncNow() {
    if (!_service.isConnected) return;
    _setSyncing(true);
    _service.syncNow();
  }

  /// 设置「同步中」标记；超时兜底（防止对端无响应时一直转圈）。
  void _setSyncing(bool value) {
    _syncTimeout?.cancel();
    if (value) {
      _syncTimeout = Timer(_syncIndicatorTimeout, () {
        if (mounted) setState(() => _syncing = false);
      });
    }
    if (mounted) setState(() => _syncing = value);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 打开设备设置弹窗（设备名 + 本机连接密码 + 重置设备 ID）；关闭后
  /// 刷新本页（设备名可能已修改）。
  Future<void> _showSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const DeviceSettingsDialog(),
    );
    if (mounted) setState(() {});
  }

  // ---------- 状态文案 ----------

  /// 状态栏主文案：同步开关状态 + 已连接设备数。
  String get _statusLabel {
    if (!_syncEnabled) return '未开启同步';
    return '已开启 · ${_service.connectedPeerCount} 台设备已连接';
  }

  /// 状态栏详情文案。
  String get _statusDetail {
    if (!_syncEnabled) {
      return '开启后本机发布 UDP 广播通告并监听固定端口，自动发现并连接局域网内已配对设备';
    }
    if (_syncing) return '正在与对端同步数据…';
    final portLabel = '本机监听端口 ${_service.port ?? '-'}';
    if (_service.connectedPeerCount == 0) {
      return '正在等待其他设备…（$portLabel）';
    }
    return '已连接 ${_service.connectedPeerCount} 台设备（$portLabel）';
  }

  /// 已配对设备行文案由顶层函数 [_peerStatusLabel] 提供（_PeerTile 复用），
  /// 语义见该函数注释。

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步'),
        actions: [
          IconButton(
            tooltip: '设备设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_conflictMessage != null) ...[
            _buildConflictBanner(context),
            const SizedBox(height: 12),
          ],
          _buildSwitchCard(context),
          const SizedBox(height: 12),
          _buildStatusCard(context),
          if (_syncEnabled) ...[
            const SizedBox(height: 12),
            _buildTrustedDevicesCard(context),
            const SizedBox(height: 12),
            _buildDiscoveryCard(context),
          ],
          const SizedBox(height: 20),
          _buildSyncNowButton(context),
        ],
      ),
    );
  }

  /// 设备 ID 冲突横幅：检测到与本机相同 deviceId 的设备时置顶展示，
  /// 引导用户在设置中重置设备 ID（可手动关闭）。
  Widget _buildConflictBanner(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          Icons.report_gmailerrorred,
          color: colorScheme.onErrorContainer,
        ),
        title: Text(
          '设备 ID 冲突',
          style: TextStyle(
            color: colorScheme.onErrorContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          _conflictMessage ?? '',
          style: TextStyle(color: colorScheme.onErrorContainer),
        ),
        trailing: IconButton(
          tooltip: '关闭',
          icon: Icon(Icons.close, color: colorScheme.onErrorContainer),
          onPressed: () => setState(() => _conflictMessage = null),
        ),
      ),
    );
  }

  /// 顶部同步总开关 + 状态说明（本机设备名、固定端口）。
  Widget _buildSwitchCard(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: EdgeInsets.zero,
      child: SwitchListTile(
        secondary: Icon(
          _syncEnabled ? Icons.sync : Icons.sync_disabled,
          color: _syncEnabled
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: const Text('同步'),
        subtitle: Text(
          _syncEnabled
              ? '本机「${_service.deviceName}」正在发布服务（端口 ${_service.port ?? '-'}）并自动连接已配对设备'
              : '开启后本机「${_service.deviceName}」发布 UDP 广播通告并监听固定端口 '
                    '$kDefaultSyncPort，自动发现并连接局域网内已配对设备',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        value: _syncEnabled,
        onChanged: _busy ? null : _onSyncSwitchChanged,
      ),
    );
  }

  /// SyncStatusBar：同步状态、最近同步时间、同步进行中指示。
  ///
  /// 动效（task-25）：同步中图标旋转（_SyncStatusIcon 内 RotationTransition）；
  /// 连接成功图标轻微弹跳（easeOutBack scale，仅状态翻转时一次）。
  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final connected = _service.isConnected;
    final Color iconColor = !_syncEnabled || !connected
        ? colorScheme.onSurfaceVariant
        : colorScheme.primary;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SyncStatusIcon(
                syncing: _syncing,
                connected: _syncEnabled && connected,
                color: iconColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_statusLabel, style: theme.textTheme.titleMedium),
              ),
              if (_syncing) ...[
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _statusDetail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最近同步：${_formatSyncTime(_lastSyncTime)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 已配对设备列表（信任列表 + 连接状态，task-14；task-16 加每设备
  /// 「自动连接」开关与「取消配对」）：
  /// - 已连接：会话就绪，数据互通，可断开（手动断开后当下不自动重连）；
  /// - 连接中：会话存在但握手/配对/自动重连未完成；
  /// - 自动连接中：当前无会话，已配对设备将在下一次发现轮询自动重连；
  /// - 「自动连接」开关（WiFi 式）：关闭后保持配对但不自动连，手动可连；
  /// - 「取消配对」：断开 + 移除信任列表，重新连接需再输密码。
  ///
  /// task-25 卡片化：整卡玻璃装饰（[GlassCard]），设备行带彩色状态点
  /// （已连接绿 / 连接中橙（呼吸）/ 未连接灰）。
  Widget _buildTrustedDevicesCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final peers = _service.peerList.where((p) => p.isTrusted).toList();
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.devices, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('已配对设备', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${peers.length} 台',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '自动连接开关类似 WiFi「自动加入」：关闭后保持配对但不自动连，手动可连',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '暂无已配对设备 — 在下方「发现的设备」点击设备，对方同意后完成首次配对',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < peers.length; i++) ...[
              _PeerTile(
                peer: peers[i],
                statusColor: _peerStatusColor(peers[i]),
                onDisconnect: peers[i].status == PeerStatus.connected
                    ? () => _disconnectPeer(peers[i])
                    : null,
                onAutoConnectChanged: (value) =>
                    _setAutoConnect(peers[i], value),
                onUnpair: () => _confirmUnpairPeer(peers[i]),
              ),
              if (i < peers.length - 1)
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: colorScheme.outlineVariant,
                ),
            ],
        ],
      ),
    );
  }

  /// 连接状态颜色：已连接=绿；连接中/自动连接中=橙；未连接=灰
  /// （task-25 状态彩色圆点规范）。
  Color _peerStatusColor(PeerDevice peer) {
    return switch (peer.status) {
      PeerStatus.connected => kStatusConnected,
      PeerStatus.connecting => kStatusConnecting,
      PeerStatus.disconnected => kStatusDisconnected,
    };
  }

  /// 发现的设备列表：未配对标「未配对」（点击连接并请求配对）；已配对标
  /// 「已配对」（点击强制连接/更新目标）；与本机 deviceId 相同标
  /// 「设备 ID 冲突」（点击无效，提示重置）。
  ///
  /// v4（task-27）：**常态不自动扫描**——列表仅在手动「重新扫描」（3s
  /// 收集窗口）与已配对断线退避扫描时更新，两次扫描之间列表定格。
  /// task-25：整卡玻璃装饰（[GlassCard]），与已配对设备卡风格一致。
  Widget _buildDiscoveryCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final devices = _discoveredDevices.where((d) => !d.isSelf).toList();

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.wifi_find, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('发现的设备', style: theme.textTheme.titleMedium),
                const Spacer(),
                // v4 手动扫描：「重新扫描」触发一次 3s 收集窗口，列表定格。
                IconButton(
                  tooltip: '重新扫描',
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: _scanning || !_syncEnabled ? null : _rescan,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '常态不自动扫描：点「重新扫描」搜索局域网设备（约 3 秒）；'
              '已配对设备断线后自动低频扫描重连',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!_syncEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                '开启同步后手动扫描局域网内的设备',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '正在搜索设备…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                '未发现设备 — 点击右上角「重新扫描」搜索同一局域网内的设备',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final device in devices)
              _DeviceTile(
                device: device,
                isPaired: device.deviceId != null &&
                    _service.trustedDeviceIds.contains(device.deviceId),
                isConflict: device.deviceId == _service.deviceId,
                onTap: device.deviceId == _service.deviceId
                    ? null // 同 ID 冲突：不连接
                    : () => _connectToPeer(device),
              ),
        ],
      ),
    );
  }

  /// 手动「重新扫描」：触发一次扫描（3s 收集窗口），完成后列表定格。
  Future<void> _rescan() async {
    setState(() => _scanning = true);
    try {
      await _service.scanOnce();
    } catch (_) {
      if (mounted) _showSnack('扫描失败，请重试');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 「立即同步」按钮：有已连接对端时可触发全量对齐。
  Widget _buildSyncNowButton(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = _service.isConnected && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: enabled ? _syncNow : null,
          icon: _syncing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          label: Text(_syncing ? '同步中…' : '立即同步'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '对所有已连接设备触发一次全量同步',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 设备设置弹窗：设备名 + 启动时自动同步 + **重置设备 ID**（task-14）。
///
/// - 设备名：默认取系统主机名，修改后持久化；同步开启时刷新 UDP 广播发布
///   （[SyncService.refreshPublishedIdentity]），已配对设备不受影响；
/// - v4（task-27）：**已移除连接密码设置**——配对改为请求-同意 + HMAC
///   认证（见 docs/技术架构.md 7.3 节），无密码可设；
/// - **重置设备 ID**：重新生成 deviceId 并清空信任列表——旧配对关系
///   全部失效，其他设备需重新请求配对（设备 ID 冲突修复入口）。
class DeviceSettingsDialog extends ConsumerStatefulWidget {
  const DeviceSettingsDialog({super.key});

  @override
  ConsumerState<DeviceSettingsDialog> createState() =>
      _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends ConsumerState<DeviceSettingsDialog> {
  late final TextEditingController _nameController;
  late String _deviceId;
  late bool _autoSync;
  bool _nameError = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final identity = ref.read(deviceIdentityProvider);
    _nameController = TextEditingController(text: identity.deviceName);
    _deviceId = identity.deviceId;
    _autoSync = identity.autoSync;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = true);
      return;
    }
    setState(() => _saving = true);
    final identity = ref.read(deviceIdentityProvider);
    await identity.setDeviceName(name);
    // 同步开启时刷新 UDP 广播发布：设备名变更立即对局域网生效。
    await ref.read(syncServiceProvider).refreshPublishedIdentity();
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设备设置已保存')),
    );
  }

  /// 重置设备 ID：二次确认后重新生成 deviceId 并清空信任列表
  /// （旧配对关系失效需重新配对），断开全部会话并以新身份重新发布 UDP 广播通告。
  Future<void> _resetDeviceId() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      title: const Text('重置设备 ID？'),
      content: const Text(
        '将重新生成设备 ID 并清空全部配对关系（旧配对失效）。\n\n'
        '其他设备将视本机为新设备，需重新请求配对。\n'
        '此操作用于修复「设备 ID 冲突」（两台设备 deviceId 相同，'
        '常见于从备份恢复数据）。确定继续？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('重置'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    await ref.read(syncServiceProvider).resetDeviceIdentity();
    final identity = ref.read(deviceIdentityProvider);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _deviceId = identity.deviceId;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设备 ID 已重置，旧配对关系已失效，请重新配对')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return GlassDialog(
      title: const Text('设备设置'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 设备组 ----
          const SectionLabel('设备'),
          // 设备名：图标 + 标题 + 副标题（TextField 内嵌）
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.badge_outlined),
            title: const Text('设备名'),
            subtitle: TextField(
              controller: _nameController,
              decoration: InputDecoration(
                hintText: '设备名',
                errorText: _nameError ? '设备名不能为空' : null,
                helperText: '其他设备发现/连接时显示的名称',
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const Divider(height: 20),
          // ---- 同步组 ----
          const SectionLabel('同步'),
          // 启动时自动同步（task-17）：独立于顶部同步总开关，修改后立即
          // 持久化；下次启动/回前台恢复时按新配置生效（重启后生效语义）。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.bolt),
            title: const Text('启动时自动同步'),
            subtitle: const Text(
              '打开 App 时自动开启同步；从后台回到前台时若同步被系统关闭自动恢复',
            ),
            value: _autoSync,
            onChanged: (value) async {
              setState(() => _autoSync = value);
              await ref.read(deviceIdentityProvider).setAutoSync(value);
            },
          ),
          const Divider(height: 20),
          // ---- 高级组 ----
          const SectionLabel('高级'),
          // 设备 ID（只读展示）
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fingerprint),
            title: const Text('设备 ID'),
            subtitle: Text(
              _shortId(_deviceId),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // 重置设备 ID（task-14：设备 ID 冲突修复入口）。
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh, color: colorScheme.error),
            title: Text('重置设备 ID', style: TextStyle(color: colorScheme.error)),
            subtitle: const Text('重新生成身份并清空配对关系（旧配对失效需重新配对）'),
            enabled: !_saving,
            onTap: _resetDeviceId,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

/// 单个发现设备的列表项：设备名 + IP:端口（+ 设备 ID 前缀）+ 配对状态标记。
///
/// - 未配对：橙色「未配对」标记，点击连接进入配对流程（密码弹窗全局展示）；
/// - 已配对：蓝色「已配对」标记，点击强制连接/更新目标；
/// - 设备 ID 冲突：红色「设备 ID 冲突」标记，点击无效（同 ID 拒绝连接）。
/// task-25：行内加彩色状态点（已配对蓝 / 未配对橙），与已配对设备卡风格对齐。
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.isPaired,
    required this.isConflict,
    required this.onTap,
  });

  final DiscoveredDevice device;
  final bool isPaired;
  final bool isConflict;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = device.deviceName.trim().isEmpty
        ? device.instanceName
        : device.deviceName.trim();
    final dotColor = isConflict
        ? colorScheme.error
        : (isPaired ? kStatusConnected : kStatusConnecting);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: _StatusDot(color: dotColor),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${device.address.address}:${device.port}'
          '${device.deviceId != null ? ' · ID ${_shortId(device.deviceId!)}' : ''}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: _StatusBadge(isConflict: isConflict, isPaired: isPaired),
        onTap: onTap,
      ),
    );
  }
}

/// 发现设备的配对状态标记：未配对 / 已配对 / 设备 ID 冲突。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.isConflict, required this.isPaired});

  final bool isConflict;
  final bool isPaired;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (isConflict) {
      return _badge('设备 ID 冲突', colorScheme.error);
    }
    if (isPaired) {
      return _badge('已配对', colorScheme.primary);
    }
    return _badge('未配对', colorScheme.tertiary);
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}

/// 设备 ID 缩写（展示用：前 8 位 + …）。
String _shortId(String id) =>
    id.length <= 8 ? id : '${id.substring(0, 8)}…';

/// 已配对设备的连接状态文案（task-16，WiFi 式断开 + 每设备自动连接配置）：
/// - 未配对 →「未配对」；
/// - 已配对 + 手动断开 →「已断开（手动）」（会话级，不自动重连）；
/// - 已配对 + autoConnect=false 且未连接 →「已保存（不自动连接）」；
/// - 已配对 + 正常 →「自动连接中 / 连接中 / 已连接」。
///
/// 顶层函数（供 [_PeerTile] 与状态栏复用，_PeerTile 在 _SyncPageState 外）。
String _peerStatusLabel(PeerDevice peer) {
  if (!peer.isTrusted) return '未配对';
  if (peer.manuallyDisconnected) return '已断开（手动）';
  return switch (peer.status) {
    PeerStatus.connected => '已连接',
    PeerStatus.connecting => '连接中',
    PeerStatus.disconnected =>
      peer.autoConnect ? '自动连接中' : '已保存（不自动连接）',
  };
}

/// 最近同步时间文案：今天显示「今天 HH:mm」，更早显示「MM-dd HH:mm」。
String _formatSyncTime(DateTime? time) {
  if (time == null) return '从未同步';
  final local = time.toLocal();
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(local.hour)}:${two(local.minute)}';
  final isToday =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  return isToday ? '今天 $hm' : '${two(local.month)}-${two(local.day)} $hm';
}

// ============================================================
// task-25 新增组件（同步页动效 / 卡片化 / 分组设置）
// ============================================================

/// 同步状态图标：同步中旋转（RotationTransition 循环）；
/// 连接成功轻微弹跳（easeOutBack scale，仅断开→连接翻转时一次）。
class _SyncStatusIcon extends StatefulWidget {
  const _SyncStatusIcon({
    required this.syncing,
    required this.connected,
    required this.color,
  });

  final bool syncing;
  final bool connected;
  final Color color;

  @override
  State<_SyncStatusIcon> createState() => _SyncStatusIconState();
}

class _SyncStatusIconState extends State<_SyncStatusIcon>
    with TickerProviderStateMixin {
  /// 同步中旋转动画（循环）。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  /// 连接成功弹跳动画（一次）。
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  @override
  void initState() {
    super.initState();
    if (widget.syncing) _spin.repeat();
  }

  @override
  void didUpdateWidget(_SyncStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.syncing && !oldWidget.syncing) _spin.repeat();
    if (!widget.syncing && oldWidget.syncing) _spin.stop();
    if (widget.connected && !oldWidget.connected) {
      _bounce.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final IconData icon = widget.syncing
        ? Icons.sync
        : (widget.connected ? Icons.cloud_done : Icons.cloud_queue);

    Widget child = Icon(icon, size: 22, color: widget.color);
    // 连接成功弹跳：scale 1 → 1.12 → 1（easeOutBack，轻微回弹）
    child = AnimatedBuilder(
      animation: _bounce,
      builder: (context, c) => Transform.scale(
        scale: 1 + 0.12 * Curves.easeOutBack.transform(_bounce.value),
        child: c,
      ),
      child: child,
    );
    // 同步中旋转
    if (widget.syncing) {
      child = RotationTransition(turns: _spin, child: child);
    }
    return child;
  }
}

/// 彩色状态圆点：已连接绿 / 连接中橙（呼吸动画）/ 未连接灰。
///
/// [pulse] 为 true 时透明度循环呼吸（连接中/自动连接中状态），
/// 动画轻量（单个 FadeTransition，不叠加 GPU 开销）。
class _StatusDot extends StatefulWidget {
  const _StatusDot({
    required this.color,
    this.pulse = false,
  });

  final Color color;
  final bool pulse;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !oldWidget.pulse) {
      _pulse.repeat(reverse: true);
    } else if (!widget.pulse && oldWidget.pulse) {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = widget.pulse
        ? Tween<double>(begin: 0.4, end: 1).animate(
            CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
          )
        : const AlwaysStoppedAnimation(1.0);
    return FadeTransition(
      opacity: opacity,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.5),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// 已配对设备行：彩色状态点 + 设备名/状态 + 操作（断开/自动连接开关/更多）。
///
/// 卡片化布局对齐列表卡片风格（圆角 16 卡内分隔行，见
/// _buildTrustedDevicesCard）。
class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.statusColor,
    required this.onAutoConnectChanged,
    required this.onUnpair,
    this.onDisconnect,
  });

  final PeerDevice peer;
  final Color statusColor;
  final VoidCallback? onDisconnect;
  final ValueChanged<bool> onAutoConnectChanged;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final connecting =
        peer.status == PeerStatus.connecting ||
        (peer.status == PeerStatus.disconnected && peer.autoConnect);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          // 状态彩色圆点：已连接绿 / 连接中橙（呼吸）/ 未连接灰
          _StatusDot(color: statusColor, pulse: connecting),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_peerStatusLabel(peer)} · ID ${_shortId(peer.deviceId)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (onDisconnect != null)
            IconButton(
              tooltip: '断开（手动断开后不自动重连）',
              icon: const Icon(Icons.link_off),
              color: colorScheme.error,
              onPressed: onDisconnect,
            ),
          Tooltip(
            message: peer.autoConnect
                ? '自动连接已开启'
                : '自动连接已关闭（保持配对，手动可连）',
            child: Switch(
              value: peer.autoConnect,
              onChanged: onAutoConnectChanged,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'unpair') onUnpair();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'unpair',
                child: Text('取消配对'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 设备设置弹窗分组标题由共享组件 [SectionLabel] 提供
/// （lib/app/ui/widgets/section_label.dart，task-26 设置页复用）。
