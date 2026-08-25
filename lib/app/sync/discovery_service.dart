import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// UDP 广播发现端口。
///
/// 与 WebSocket TCP 端口（[kDefaultSyncPort]，见 sync_service.dart）同号
/// 58888——UDP 与 TCP 是独立协议栈，同端口号不冲突；统一端口便于记忆、
/// 防火墙放行与文档描述。
const int kDiscoveryPort = 58888;

/// 通告协议版本（v4，task-30）。载荷结构变更时升级版本号，接收端忽略不兼容版本。
/// 与 [kProtocolVersion]（hello 携带）保持一致；v3 及以下旧设备（UDP v3
/// 无图片同步协议）与新版本不互连（版本不兼容 → 提示升级，见 docs/技术架构.md
/// 7.3 节）。
const int kAnnounceVersion = 4;

/// 默认扫描窗口：一次 [DiscoveryService.scanOnce] 的收集时长（3s）。
/// 窗口结束后停止监听，设备列表定格（不再自动更新，等待下一次扫描）。
const Duration kDefaultScanWindow = Duration(seconds: 3);

/// 发现的可用主机（UDP 广播解析结果）。
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.instanceName,
    required this.deviceName,
    this.deviceId,
    required this.address,
    required this.port,
    this.isSelf = false,
  });

  /// 实例标识（UDP 通告无 mDNS 实例名概念，以 deviceId 占位）。
  ///
  /// 保留该字段仅为与旧 API 兼容：UI 在设备名为空时用它兜底展示
  /// （见 sync_page.dart），去重键一律用 [deviceId]。
  final String instanceName;

  /// 设备名（通告 JSON `name` 字段）。
  final String deviceName;

  /// 设备 ID（通告 JSON `deviceId` 字段；UDP 协议必填，恒非空）。
  final String? deviceId;

  /// 主机 IP（通告数据报的源地址）。
  final InternetAddress address;

  /// 服务端口（通告 JSON `port` 字段，对端 WebSocket 监听端口）。
  final int port;

  /// 是否为广播域内本机发布的设备。
  ///
  /// UDP 广播会回环到本机监听 socket：通过通告 deviceId 与本机
  /// deviceId 比对过滤，本机通告不会进入设备表，故恒为 false。
  final bool isSelf;

  /// 可直接用于建立 WebSocket 连接的地址。
  String get wsUrl => 'ws://${address.address}:$port';

  @override
  String toString() =>
      'DiscoveredDevice($deviceName@${address.address}:$port, deviceId: $deviceId, isSelf: $isSelf)';
}

/// UDP 广播设备发现服务（task-24：mDNS → UDP 广播，参考 Syncthing
/// lib/discover/local.go 周期广播 + LocalSend multicast_discovery.dart
/// 上线三连发与回播机制；task-27 v4：发现侧改为**按需扫描**）。
///
/// 协议：JSON 通告 `{v:4, deviceId, name, port, ts}`，UTF-8 编码，
/// 发往 UDP 广播端口 [kDiscoveryPort]（58888）。
///
/// **发送（周期广播，保留）**：逐网卡计算子网广播地址（IP+掩码推导，过滤
/// 虚拟/断开网卡，排除 loopback/链路本地）+ `255.255.255.255` 兜底；
/// 发送失败容忍（try-catch + 日志），不影响后续通告。
/// - **上线三连发**：[publish] 时按可注入延迟（默认 100ms/500ms/2s）连发
///   三次（LocalSend 式上线宣告，广播丢包容忍）；随后按 [announceInterval]
///   （默认 30s，可配置）周期通告。
/// - **新设备回播**：扫描窗口内收到**新 deviceId** 的通告后立即回播一次
///   自己的通告（LocalSend 式互相知晓）；防已收到风暴：记录最近回播的
///   deviceId+时间，[replyCooldown] 限频。
///
/// **接收（发现侧，v4 按需扫描）**：常态不监听（不消耗 socket/电耗）；
/// 仅 [scanOnce] 时绑定 UDP [kDiscoveryPort]（reuseAddress，macOS/Linux 加
/// reusePort 支持同机多实例/多进程共存）收集 [scanWindow]（默认 3s）内的
/// 通告，窗口结束关闭监听，设备列表**定格**（保留扫描结果，不再自动更新）。
/// 手动「重新扫描」与已配对断线退避扫描均走 [scanOnce]（SyncService 编排）。
/// 离线清理：每次扫描结束按 [deviceExpiry]（默认 90s）清理超时无通告的设备
/// （跨扫描窗口按 lastSeen 计算，列表定格期间不清除）。
///
/// 本机身份（deviceId/deviceName）来自 [publish] 参数（SyncService 从
/// DeviceIdentityStore 读取后传入）；未注入时可用构造参数 [deviceId]/
/// [deviceName]（供验证脚本注入确定性身份，见 temp/drafts/verify_sync.dart）。
///
/// 平台适配：
/// - Windows 不支持 SO_REUSEPORT（绑定 reusePort:true 抛 errno 10042），
///   降级为仅 reuseAddress（Windows 下 SO_REUSEADDR 允许多 socket 同端口
///   绑定且广播投递给全部 socket）；
/// - Android 的 WiFi 省电只过滤**多播**包，**广播**不受 MulticastLock
///   限制，无需持锁（task-24 删除 mDNS 多播锁）；
/// - 发送 socket 显式开启 broadcast（SO_BROADCAST，[RawDatagramSocket.broadcastEnabled]）。
class DiscoveryService {
  DiscoveryService({
    Duration announceInterval = const Duration(seconds: 30),
    Duration deviceExpiry = const Duration(seconds: 90),
    Duration scanWindow = kDefaultScanWindow,
    String? deviceId,
    String? deviceName,
    List<Duration> initialAnnounceDelays = const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 500),
      Duration(seconds: 2),
    ],
    Duration replyCooldown = const Duration(seconds: 30),
    List<InternetAddress>? broadcastAddresses,
  })  : _announceInterval = announceInterval,
        _deviceExpiry = deviceExpiry,
        _scanWindow = scanWindow,
        _localDeviceId = deviceId,
        _localDeviceName = deviceName ?? '',
        _initialAnnounceDelays = initialAnnounceDelays,
        _replyCooldown = replyCooldown,
        _broadcastAddresses = broadcastAddresses;

  /// 周期通告间隔（默认 30s；可配置，测试用短间隔验证周期通告维持在线）。
  final Duration _announceInterval;

  /// 设备离线判定窗口：超过该时长无通告即判定离线移除（默认 90s）。
  final Duration _deviceExpiry;

  /// 一次 [scanOnce] 的收集窗口（默认 3s；可配置，测试用短窗口）。
  final Duration _scanWindow;

  /// 上线三连发延迟序列（可注入，便于测试）。
  final List<Duration> _initialAnnounceDelays;

  /// 新设备回播限频窗口（默认 30s）：同一设备回播后 [replyCooldown]
  /// 内不再回播（防已收到风暴）。
  final Duration _replyCooldown;

  /// 覆盖广播目标（测试注入）：非空时跳过网卡枚举直接使用该列表
  /// （verify_sync.dart 用本机回环/真实网卡广播确定性驱动）。
  final List<InternetAddress>? _broadcastAddresses;

  /// 本机设备 ID（publish 参数优先，未注入时用构造参数）。
  String? _localDeviceId;

  /// 本机设备名（publish 参数优先，未注入时用构造参数）。
  String _localDeviceName;

  /// 本机 WebSocket 服务端口（publish 设置；非空即处于发布状态）。
  int? _localPort;

  /// 是否正在发布（publish 置位 / unpublish 复位）。
  bool _publishing = false;

  /// 是否正在扫描（scanOnce 窗口内）。
  bool _scanning = false;

  /// 发送通告的 socket（anyIPv4:0 + SO_BROADCAST；publish/回播共用）。
  RawDatagramSocket? _sendSocket;

  /// 接收通告的 socket（绑定 [kDiscoveryPort]，scanOnce 创建）。
  RawDatagramSocket? _receiveSocket;

  /// 周期通告定时器（publish 启动，unpublish 停止）。
  Timer? _announceTimer;

  /// 上线三连发定时器（publish 调度，可被重复调用替换）。
  final List<Timer> _initialAnnounceTimers = [];

  /// 扫描窗口结束定时器（scanOnce 调度）。
  Timer? _scanTimer;

  /// 当前扫描的完成信号：窗口结束（或 [stopScan] 提前定格）时完成，
  /// 使 [scanOnce] 的调用方可 `await` 整个收集窗口。
  Completer<void>? _scanCompleter;

  /// 设备表（按 deviceId 去重），含最后可见时间（离线判定依据）。
  /// 跨扫描保留（列表定格）；扫描结束按 [_deviceExpiry] 清理过期条目。
  final Map<String, _DeviceEntry> _devices = {};

  /// 最近回播时间（deviceId → 时间）：收到新设备通告回播后记录，
  /// [replyCooldown] 内不再对同一设备回播（防已收到风暴）。
  final Map<String, DateTime> _lastReplyByDeviceId = {};

  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  /// 发现的设备列表流（扫描窗口内收到设备/扫描结束清理时推送完整列表；
  /// 列表定格期间不推送）。
  Stream<List<DiscoveredDevice>> get devices => _devicesController.stream;

  /// 当前已知设备快照（task-32：对端展示名恢复用，从 UDP 通告取真实名）。
  List<DiscoveredDevice> get knownDevices =>
      _devices.values.map((entry) => entry.device).toList();

  /// 当前是否正在发布（[publish] 后为 true，[unpublish] 后为 false）。
  bool get isPublishing => _publishing;

  /// 当前是否正在扫描（scanOnce 窗口内为 true）。
  bool get isScanning => _scanning;

  // ===== 主机模式：发布（周期广播通告） =====

  /// 发布本机通告（幂等：先停止旧发布再发布新的）。
  ///
  /// [deviceName]/[deviceId] 为本机身份（SyncService 从 DeviceIdentityStore
  /// 读取传入；[deviceId] 为空时回退构造参数注入的身份）；[port] 为
  /// WebSocket 服务端监听端口（写入通告 JSON `port` 字段）。
  ///
  /// 发布后立即按 [_initialAnnounceDelays] 三连发（上线宣告，LocalSend 式），
  /// 随后按周期通告（[announceInterval] 参数优先，缺省 [_announceInterval]）；
  /// unpublish 后停止通告（对端凭 [_deviceExpiry] 离线判定移除，无显式 goodbye）。
  ///
  /// [announceInterval]：可选覆盖周期通告间隔（task-31「可被发现」临时广播
  /// 用 5s 快速宣告；未传则用构造参数默认 30s）。
  Future<void> publish({
    required String deviceName,
    required int port,
    String? deviceId,
    Duration? announceInterval,
  }) async {
    await unpublish();
    _publishing = true;
    if (deviceId != null && deviceId.isNotEmpty) {
      _localDeviceId = deviceId;
    }
    final name = deviceName.trim();
    if (name.isNotEmpty) _localDeviceName = name;
    _localPort = port;
    await _ensureSendSocket();
    _scheduleInitialAnnouncements();
    final interval = announceInterval ?? _announceInterval;
    _announceTimer = Timer.periodic(
      interval,
      (_) => unawaited(_announceOnce()),
    );
  }

  /// 停止发布（幂等）：取消通告定时器并关闭发送 socket（若扫描也停止）。
  Future<void> unpublish() async {
    if (!_publishing) return;
    _publishing = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    for (final timer in _initialAnnounceTimers) {
      timer.cancel();
    }
    _initialAnnounceTimers.clear();
    _localPort = null;
    _maybeCloseSendSocket();
  }

  // ===== 发现侧：按需扫描（task-27 v4） =====

  /// 手动扫描一次：绑定 UDP [kDiscoveryPort]（reuseAddress + macOS/Linux
  /// reusePort 同机共存）接收广播通告，收集窗口（[window] 参数优先，缺省
  /// [_scanWindow]，默认 3s）后停止——设备列表**定格**（保留本次扫描结果，
  /// 不再自动更新，等待下一次扫描）。
  ///
  /// 返回的 Future 在**收集窗口结束后**完成：调用方 `await scanOnce()` 即
  /// 表示一次完整扫描已结束（SyncService 手动扫描/同步页「扫描设备」用）。
  ///
  /// - 扫描窗口内收到通告 → 更新设备表 + 推送列表（新设备立即回播自己的
  ///   通告，LocalSend 式互相知晓）；
  /// - 扫描开始时若正在发布，立即补发一次通告（帮助正在扫描的对端发现本机）；
  /// - 窗口结束 → 关闭接收 socket + 按 [_deviceExpiry] 清理过期设备 + 推送
  ///   最终列表；
  /// - 设备表跨扫描保留（列表定格语义：两次扫描之间的列表不变化）。
  ///
  /// 幂等：已有扫描进行中时立即返回（不重复扫描）。
  ///
  /// [window]：可选覆盖收集窗口（task-31「扫描设备」用 30s 持续监听）。
  Future<void> scanOnce({Duration? window, bool restart = false}) {
    if (_scanning) {
      if (!restart) return Future.value();
      // task-32：可重复点击——结束当前窗口，重新开始（重置定时器/重绑 socket）。
      _finishScan();
    }
    _scanning = true;
    _scanCompleter = Completer<void>();
    unawaited(_bindScanSocket());
    // 扫描开始补发一次通告：让正在扫描的对端及时收到本机（配合回播机制）。
    if (_publishing) {
      unawaited(_announceOnce());
    }
    final effectiveWindow = window ?? _scanWindow;
    _scanTimer?.cancel();
    _scanTimer = Timer(effectiveWindow, _finishScan);
    return _scanCompleter!.future;
  }

  /// 绑定扫描接收 socket（scanOnce 内部；绑定失败则结束扫描并释放信号）。
  Future<void> _bindScanSocket() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows, // Windows 不支持 SO_REUSEPORT
      );
      socket.broadcastEnabled = true;
      _receiveSocket = socket;
      socket.listen(_onDatagram);
      // ignore: avoid_print
      print('[discovery] 扫描监听已绑定 UDP $kDiscoveryPort');
    } catch (e) {
      // ignore: avoid_print
      print('[discovery] 扫描监听绑定失败: $e');
      _scanning = false;
      _finishScan();
    }
  }

  /// 立即停止当前扫描（幂等）：窗口未结束时调用则提前定格并清理。
  void stopScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (_scanning) _finishScan();
  }

  /// 结束一次扫描：关闭接收 socket、按过期窗口清理设备表、推送最终列表、
  /// 完成 [scanOnce] 的返回 Future。
  ///
  /// 注意：必须在置 [_scanning] 为 false **之前**推送最终列表（[_pushMerged]
  /// 仅在扫描中时推送——扫描结束的定格列表也要下发）。
  void _finishScan() {
    _receiveSocket?.close();
    _receiveSocket = null;
    _pruneExpired();
    _pushMerged();
    _scanning = false;
    final completer = _scanCompleter;
    _scanCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// 释放资源（停止发布与扫描并关闭事件流）。
  Future<void> dispose() async {
    await unpublish();
    stopScan();
    _maybeCloseSendSocket(); // 兜底：从未 publish/scanOnce 时的残留 socket
    await _devicesController.close();
  }

  // ===== 通告发送 =====

  /// 广播一次本机通告（周期通告 / 上线三连发 / 新设备回播共用）。
  ///
  /// 目标地址：逐网卡计算的子网广播地址（[publish] 时缓存）+
  /// `255.255.255.255` 兜底；测试注入 [_broadcastAddresses] 时仅用注入列表。
  /// 单个目标发送失败容忍（try-catch），不影响其他目标与后续通告。
  Future<void> _announceOnce() async {
    final socket = _sendSocket;
    final deviceId = _localDeviceId;
    final port = _localPort;
    if (socket == null || deviceId == null || port == null) return;
    final payload = utf8.encode(json.encode({
      'v': kAnnounceVersion,
      'deviceId': deviceId,
      'name': _localDeviceName,
      'port': port,
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    final targets = await _broadcastTargets();
    // ignore: avoid_print
    print('[discovery] 广播发送 targets=${targets.map((t) => t.address).toList()}');
    for (final target in targets) {
      try {
        socket.send(payload, target, kDiscoveryPort);
      } catch (e) {
        // 发送失败（网络抖动/网卡变化/路由不可达）容忍：不影响后续通告。
        stderr.writeln(
          '[discovery] 通告发送失败 -> $target: $e',
        );
      }
    }
  }

  /// 计算广播目标地址列表：逐网卡子网广播（IP+掩码推导）+ 255.255.255.255
  /// 兜底；过滤虚拟/断开网卡，排除 loopback/链路本地。
  Future<List<InternetAddress>> _broadcastTargets() async {
    final injected = _broadcastAddresses;
    if (injected != null && injected.isNotEmpty) return injected;

    final targets = <InternetAddress>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (_looksLikeVirtualInterface(iface.name)) continue; // 虚拟/断开网卡
        for (final address in iface.addresses) {
          if (address.isLoopback || address.isLinkLocal) continue;
          final broadcast = _broadcastAddressFor(address);
          if (broadcast != null) targets.add(broadcast);
        }
      }
    } catch (_) {
      // 网卡枚举失败：仅剩 255.255.255.255 兜底。
    }
    targets.add(InternetAddress('255.255.255.255')); // 兜底（limited broadcast）
    return targets.toList();
  }

  /// 由接口 IP 推导子网广播地址（IP | ~掩码）。
  ///
  /// dart:io 的 [NetworkInterface] 不暴露 netmask，按私有网段惯例推导：
  /// `10/8` → `10.255.255.255`；`172.16/12` → `172.x.255.255`；
  /// `192.168/24` → `192.168.x.255`；其余（公网等）按 `/24` 默认。
  /// 推导失败返回 null（由 255.255.255.255 兜底）。
  InternetAddress? _broadcastAddressFor(InternetAddress address) {
    final parts = address.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return null;
    final a = parts[0]!, b = parts[1]!, c = parts[2]!;
    if (a == 10) return InternetAddress('10.255.255.255'); // 10/8
    if (a == 172 && b >= 16 && b <= 31) {
      return InternetAddress('172.$b.255.255'); // 172.16.0.0/12
    }
    if (a == 192 && b == 168) {
      return InternetAddress('192.168.$c.255'); // 192.168.0.0/16
    }
    return InternetAddress('$a.$b.$c.255'); // 其他：/24 默认
  }

  /// 调度上线三连发（publish 触发；重复调用先取消
  /// 上次的未发定时器再重排，保证一次上线恰好三连发）。
  void _scheduleInitialAnnouncements() {
    for (final timer in _initialAnnounceTimers) {
      timer.cancel();
    }
    _initialAnnounceTimers.clear();
    if (!_publishing) return; // 未发布（无身份/端口）不宣告
    for (final delay in _initialAnnounceDelays) {
      _initialAnnounceTimers.add(
        Timer(delay, () => unawaited(_announceOnce())),
      );
    }
  }

  /// 获取发送 socket（懒创建：anyIPv4:0 + SO_BROADCAST；多网卡广播共用）。
  Future<RawDatagramSocket> _ensureSendSocket() async {
    final existing = _sendSocket;
    if (existing != null) return existing;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
      reusePort: !Platform.isWindows,
    );
    socket.broadcastEnabled = true; // SO_BROADCAST：允许发往广播地址
    _sendSocket = socket;
    return socket;
  }

  /// 发布与扫描都停止时关闭发送 socket（避免 enable/disable 循环泄漏 fd）。
  void _maybeCloseSendSocket() {
    if (!_publishing && !_scanning) {
      _sendSocket?.close();
      _sendSocket = null;
    }
  }

  // ===== 通告接收 =====

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _receiveSocket;
    final datagram = socket?.receive();
    if (socket == null || datagram == null) return;
    // ignore: avoid_print
    print('[discovery] 收到 UDP 包 ${datagram.address.address}:${datagram.port} len=${datagram.data.length}');
    final announcement = _parseAnnouncement(datagram.data);
    if (announcement == null) return; // 坏包/非本协议：忽略
    _handleAnnouncement(announcement, datagram.address);
  }

  /// 处理一条通告：按 deviceId 去重更新设备表；新设备立即回播一次
  /// 自己的通告（限频）；设备信息变化（地址/端口/名称）推送列表。
  void _handleAnnouncement(_Announcement announcement, InternetAddress source) {
    // isSelf：通告 deviceId == 本机 deviceId（过滤自己；本机广播会回环）。
    if (announcement.deviceId == _localDeviceId) return;
    final now = DateTime.now();
    final device = DiscoveredDevice(
      instanceName: announcement.deviceId,
      deviceName: announcement.name,
      deviceId: announcement.deviceId,
      address: source,
      port: announcement.port,
    );
    final existing = _devices[announcement.deviceId];
    if (existing == null) {
      // 新设备：登记 + 立即回播自己的通告（LocalSend 式握手）。
      _devices[announcement.deviceId] = _DeviceEntry(device, now);
      _maybeReplyAnnouncement(announcement.deviceId, now);
    } else {
      existing.lastSeen = now; // 刷新最后可见时间（离线判定依据）
      if (existing.device.address.address != source.address ||
          existing.device.port != announcement.port ||
          existing.device.deviceName != announcement.name) {
        // 地址/端口/名称变化（IP 变更等）：更新条目并推送。
        existing.device = device;
      }
    }
    if (_scanning) {
      // 收到有效通告即推送列表——设备表跨扫描保留、UI 可能在 disable 时
      // 被清空（sync_page _discoveredDevices = []）后重新扫描：此时条目
      // 即使无变化（changed=false）也必须刷新 UI，否则「扫描不到」（task-32）。
      _pushMerged();
    }
  }

  /// 新设备回播：收到新 deviceId 通告后立即广播一次自己的通告。
  ///
  /// 限频（防已收到风暴）：记录最近回播的 deviceId+时间，[_replyCooldown]
  /// 内不再对同一设备回播——周期性通告已由对端 lastSeen 维护，回播只在
  /// 设备首次出现/离线重来时触发一次。
  void _maybeReplyAnnouncement(String deviceId, DateTime now) {
    if (!_publishing) return; // 未发布（无身份/端口）：无通告可回播
    final last = _lastReplyByDeviceId[deviceId];
    if (last != null && now.difference(last) < _replyCooldown) return;
    _lastReplyByDeviceId[deviceId] = now;
    unawaited(_announceOnce());
  }

  /// 解析通告数据报：JSON 容错（坏包/版本不符/字段缺失 → null）。
  _Announcement? _parseAnnouncement(Uint8List data) {
    try {
      final decoded = json.decode(utf8.decode(data, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != kAnnounceVersion) return null; // 版本不符：忽略
      final deviceId = decoded['deviceId'];
      final name = decoded['name'];
      final port = decoded['port'];
      final ts = decoded['ts'];
      if (deviceId is! String || deviceId.isEmpty) return null;
      if (name is! String) return null;
      if (port is! int || port <= 0 || port > 65535) return null;
      return _Announcement(
        deviceId: deviceId,
        name: name,
        port: port,
        ts: ts is int ? ts : 0,
      );
    } catch (_) {
      return null; // 坏包忽略（非 JSON / 截断等）
    }
  }

  /// 推送完整设备列表（扫描中且流未关闭时）。
  void _pushMerged() {
    if (!_scanning || _devicesController.isClosed) return;
    _devicesController.add(
      _devices.values.map((entry) => entry.device).toList(),
    );
  }

  /// 离线清理：移除超过 [_deviceExpiry] 无通告的设备（按 deviceId lastSeen）。
  void _pruneExpired() {
    if (_devices.isEmpty) return;
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere(
      (_, entry) => now.difference(entry.lastSeen) > _deviceExpiry,
    );
    if (_devices.length != before) {
      _pushMerged();
    }
  }
}

/// 一条 UDP 通告（解析后的结构化表示）。
class _Announcement {
  const _Announcement({
    required this.deviceId,
    required this.name,
    required this.port,
    required this.ts,
  });

  final String deviceId;
  final String name;
  final int port;
  final int ts;
}

/// 设备表条目：设备 + 最后可见时间（通告刷新，离线判定依据）。
class _DeviceEntry {
  _DeviceEntry(this.device, this.lastSeen);

  DiscoveredDevice device;
  DateTime lastSeen;
}

/// 网卡名是否像虚拟/断开网卡（Hyper-V vEthernet、蓝牙、WSL/ISATAP、
/// macOS 的 utun/awdl/bridge/anpi 等虚拟接口）。
bool _looksLikeVirtualInterface(String name) {
  final n = name.toLowerCase();
  return n.contains('vethernet') ||
      n.contains('virtual') ||
      n.contains('bluetooth') ||
      n.contains('蓝牙') ||
      n.contains('loopback') ||
      n.contains('isatap') ||
      n.contains('teredo') ||
      n.contains('utun') ||
      n.contains('awdl') ||
      n.contains('llw') ||
      n.contains('bridge') ||
      n.contains('anpi') ||
      n.contains('ap1') ||
      n.startsWith('本地连接*');
}
