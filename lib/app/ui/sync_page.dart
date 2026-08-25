import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repository/providers.dart';
import '../sync/discovery_service.dart';
import '../sync/sync_protocol.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import 'widgets/glass_style.dart';

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

  /// 临时广播进行中（task-31「可被发现」按钮：30s 内显示「广播中…」）。
  bool _announcing = false;

  /// 「可被发现」广播倒计时（30s 后复位 [_announcing]）。
  Timer? _announceTimer;

  /// 端口输入框控制器（task-32：改端口后重启同步服务）。
  late final TextEditingController _portController;

  /// 设备名输入框控制器（task-32：顶部设备名直接编辑、输入自动保存）。
  late final TextEditingController _nameController;

  /// 设备名自动保存防抖定时器（500ms 无输入后落盘）。
  Timer? _nameSaveTimer;

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

  /// 同步进行中（连接握手全量同步 / 手动「立即同步」期间为 true）。
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(syncServiceProvider);
    _syncEnabled = _service.isEnabled;
    _portController = TextEditingController(
      text: '${_service.port ?? kDefaultSyncPort}',
    );
    _nameController = TextEditingController(text: _service.deviceName);

    _syncSub = _service.syncCompleted.listen((time) {
      _setSyncing(false);
      if (mounted) setState(() {});
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
    _announceTimer?.cancel();
    _nameSaveTimer?.cancel();
    _portController.dispose();
    _nameController.dispose();
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
    } on SocketException {
      if (mounted) {
        setState(() => _syncEnabled = _service.isEnabled);
        _showSnack('端口被占用，请在「端口」处修改后点重启');
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



  /// 切换某已配对设备的同步方向（task-32）：向对端同步 / 从对端同步。
  ///
  /// 只控制数据推送/接收，不影响连接（配对成功永远自动连接）。
  Future<void> _setSyncDirections(
    PeerDevice peer, {
    bool? syncToPeer,
    bool? syncFromPeer,
  }) async {
    await _service.setSyncDirections(
      peer.deviceId,
      syncToPeer: syncToPeer ?? peer.syncToPeer,
      syncFromPeer: syncFromPeer ?? peer.syncFromPeer,
    );
    if (mounted) {
      _showSnack('已更新「${peer.deviceName}」的同步方向');
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

  // ---------- 状态文案 ----------

  /// 已配对设备行：设备名 + 手动连接开关（状态即连接状态）+ 自动连接开关。

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_conflictMessage != null) ...[
            _buildConflictBanner(context),
            const SizedBox(height: 12),
          ],
          // 本机设备名（task-32：卡片风格，左侧「设备名」标签 + 右侧输入框
          // 直接编辑、输入自动保存——与端口行样式一致）。
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Text(
                  '设备名',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    // 参考端口输入框：描边 + 内边距，不贴边。
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onChanged: (_) => _scheduleSaveDeviceName(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildSwitchCard(context),
          if (_syncEnabled) ...[
            const SizedBox(height: 12),
            _buildTrustedDevicesCard(context),
            const SizedBox(height: 12),
            _buildDiscoveryCard(context),
          ],
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
  /// 顶部同步总开关（task-31/32 去文案）+ 端口行（task-32）：
  /// 单行「同步」标题 + 精致开关；下方端口输入框 + 重启按钮。
  Widget _buildSwitchCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _syncEnabled ? Icons.sync : Icons.sync_disabled,
                size: 22,
                color: _syncEnabled
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '同步',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
              SlimSwitch(
                value: _syncEnabled,
                onChanged: _busy ? null : _onSyncSwitchChanged,
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 端口行：修改端口后点「重启」重新开启同步服务。
          Row(
            children: [
              Text(
                '端口',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  enabled: !_busy,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _busy ? null : _restartSyncWithPort,
                child: const Text('重启'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 设备名修改防抖自动保存：500ms 无输入后写入持久化 + 刷新 UDP 广播
  /// 发布（对端立即看到新名字）；空名不保存。
  void _scheduleSaveDeviceName() {
    _nameSaveTimer?.cancel();
    _nameSaveTimer = Timer(const Duration(milliseconds: 500), () async {
      final name = _nameController.text.trim();
      if (name.isEmpty) return;
      await ref.read(deviceIdentityProvider).setDeviceName(name);
      await _service.refreshPublishedIdentity();
    });
  }

  /// 改端口后重启同步服务：校验端口 → 关闭 → 以新端口开启 → 临时广播
  /// 新端口（对端凭旧端口直连失败后，扫描/广播可发现新地址）。
  Future<void> _restartSyncWithPort() async {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _showSnack('端口无效（1-65535）');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.disable();
      await _service.enable(port: port);
      // 广播新端口 30s（互联手动化：对端凭旧缓存直连失败后靠扫描发现）。
      unawaited(_service.announceTemporarily());
      if (mounted) {
        setState(() => _syncEnabled = _service.isEnabled);
        _showSnack('已重启同步（端口 $port）');
      }
    } on SocketException {
      if (mounted) {
        setState(() => _syncEnabled = _service.isEnabled);
        _showSnack('端口 $port 被占用，请换一个端口');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _syncEnabled = _service.isEnabled);
        _showSnack('重启失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                '暂无已配对设备',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (var i = 0; i < peers.length; i++) ...[
              _PeerTile(
                peer: peers[i],
                statusColor: _peerStatusColor(peers[i]),
                onSyncToChanged: (value) =>
                    _setSyncDirections(peers[i], syncToPeer: value),
                onSyncFromChanged: (value) =>
                    _setSyncDirections(peers[i], syncFromPeer: value),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.wifi_find,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text('发现的设备', style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 10),
                // task-31 互联手动化：两个手动按钮（可被发现 / 扫描设备）
                Row(
                  children: [
                    _buildActionButton(
                      context: context,
                      label: _announcing ? '广播中…' : '可被发现',
                      icon: _announcing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering, size: 18),
                      onPressed: _announcing || !_syncEnabled
                          ? null
                          : _announceNow,
                    ),
                    const SizedBox(width: 8),
                    _buildActionButton(
                      context: context,
                      label: _scanning ? '扫描中…' : '扫描设备',
                      icon: _scanning
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search, size: 18),
                      onPressed: _scanning || !_syncEnabled
                          ? null
                          : _rescan,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!_syncEnabled)
            const SizedBox(height: 8)
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
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            )
          else if (devices.isEmpty)
            const SizedBox(height: 8)
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

  /// 「扫描设备」（task-31）：触发一次 30s 扫描窗口，期间收集设备列表。
  /// （常态不自动扫描，互联手动化。）
  Future<void> _rescan() async {
    setState(() => _scanning = true);
    try {
      await _service.scanOnce(window: const Duration(seconds: 30));
    } catch (_) {
      if (mounted) _showSnack('扫描失败，请重试');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 「可被发现」（task-31）：向外广播 30s（每 5s 一次），UI 同步倒计时。
  Future<void> _announceNow() async {
    setState(() => _announcing = true);
    try {
      await _service.announceTemporarily();
      _announceTimer?.cancel();
      _announceTimer = Timer(const Duration(seconds: 30), () {
        if (mounted) setState(() => _announcing = false);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _announcing = false);
        _showSnack('广播失败，请重试');
      }
    }
  }

  /// 发现区操作按钮（可被发现 / 扫描设备）：紧凑小按钮。
  Widget _buildActionButton({
    required BuildContext context,
    required String label,
    required Widget icon,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(label),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: Theme.of(context).textTheme.labelMedium,
      ),
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
          '${device.address.address}:${device.port}',
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

/// 已配对设备行（task-32）：状态彩色圆点 + 设备名 + 两个同步方向开关
/// （向 B 同步 / 从 B 同步，上下排列）+ 更多菜单（取消配对）。
///
/// 连接策略已简化为「配对成功永远自动连接」——设备行不再有连接开关，
/// 只控制同步方向：向对端同步（本机推送）/ 从对端同步（本机接收），
/// 两端各自独立、不同步。连接状态由状态圆点显示。
class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.statusColor,
    required this.onSyncToChanged,
    required this.onSyncFromChanged,
    required this.onUnpair,
  });

  final PeerDevice peer;
  final Color statusColor;

  /// 是否连接中（状态点呼吸动画）。
  bool get _isConnecting => peer.status == PeerStatus.connecting;

  /// 向对端同步开关回调。
  final ValueChanged<bool> onSyncToChanged;

  /// 从对端同步开关回调。
  final ValueChanged<bool> onSyncFromChanged;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          // 状态彩色圆点：已连接绿 / 连接中橙（呼吸）/ 未连接灰
          _StatusDot(color: statusColor, pulse: _isConnecting),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              peer.deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 右侧：两个同步方向开关（上下排列）——
          // 向此设备同步 = 本机是否推送变更给它；
          // 从此设备同步 = 本机是否接收它的变更。
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSwitchRow(
                context: context,
                label: '向此设备同步',
                value: peer.syncToPeer,
                onChanged: onSyncToChanged,
                colorScheme: colorScheme,
              ),
              const SizedBox(height: 6),
              _buildSwitchRow(
                context: context,
                label: '从此设备同步',
                value: peer.syncFromPeer,
                onChanged: onSyncFromChanged,
                colorScheme: colorScheme,
              ),
            ],
          ),
          // 更多菜单（取消配对）：单选项时 hover 覆盖整个下拉容器——
          // 容器 padding 归零（容器=按钮大小），圆角与按钮一致（task-32）。
          MenuAnchor(
            style: MenuStyle(
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              backgroundColor: WidgetStatePropertyAll(colorScheme.surface),
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            builder: (context, controller, _) => IconButton(
              tooltip: '更多操作',
              icon: const Icon(Icons.more_vert),
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => controller.open(),
            ),
            menuChildren: [
              MenuItemButton(
                onPressed: onUnpair,
                style: MenuItemButton.styleFrom(
                  // 宽度适配文字：padding 决定按钮大小；圆角与容器一致，
                  // 单选项时 hover 高亮正好覆盖整个下拉容器。
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('取消配对'),
              ),
            ],
          ),
        ],
      ),
    );
  }

/// 开关行：左侧小标签 + 右侧 [SlimSwitch]（紧凑行）。
  Widget _buildSwitchRow({
    required BuildContext context,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    required ColorScheme colorScheme,
  }) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        SlimSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 设备设置弹窗分组标题由共享组件 [SectionLabel] 提供
/// （lib/app/ui/widgets/section_label.dart，task-26 设置页复用）。
