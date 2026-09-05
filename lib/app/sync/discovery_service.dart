import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart';

import 'sync_protocol.dart' show kProtocolVersion;

/// UDP 广播发现端口。
///
/// 与 WebSocket TCP 端口（[kDefaultSyncPort]，见 sync_service.dart）同号
/// 58888——UDP 与 TCP 是独立协议栈，同端口号不冲突；统一端口便于记忆、
/// 防火墙放行与文档描述。
const int kDiscoveryPort = 58888;

/// 通告协议版本：与 hello 携带的 [kProtocolVersion] 同源（单一事实来源，
/// 协议升级自动同步到发现层，杜绝两处版本号漂移——task-32 升 v6 时此处
/// 漏改停在 4，v5 旧设备此前要等 hello 握手才被拒）。版本不符的通告直接
/// 忽略（发现层拦截旧版本，握手层 hello 版本门兜底）。
///
/// ⚠️ 2026-09-06 起 4 → 6：需**全员升级**——旧版构建（通告 v:4）与新版
/// 在发现层互不可见，混用期间无法发现/配对（见 docs/技术架构.md 7.3 节）。
const int kAnnounceVersion = kProtocolVersion;

/// 默认扫描窗口：一次 [DiscoveryService.scanOnce] 的收集时长
/// （task-32：30s；手动扫描与临时广播窗口统一，见 [kDiscoveryWindow]）。
/// 窗口结束关闭扫描监听并清空列表（常驻监听随后的通告实时补充）。
const Duration kDefaultScanWindow = Duration(seconds: 30);

/// 互联窗口统一时长（task-32）：临时广播/扫描/UI 状态计时共用。
const Duration kDiscoveryWindow = Duration(seconds: 30);

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
  /// 当前所有构造点都不传 true（本机通告在 [_handleAnnouncement] 按
  /// deviceId 比对提前过滤，不会进入设备表），因此恒为 false；使用方
  /// （sync_page / sync_service）的判断是防御性冗余——若将来某处构造
  /// 显式标记本机设备，此处能兜底过滤。
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
/// **发送**：逐网卡计算子网广播地址（IP+掩码推导，过滤虚拟/断开网卡，
/// 排除 loopback/链路本地）+ `255.255.255.255` 兜底；发送失败容忍
/// （try-catch + 日志），不影响后续通告。触发点（互联手动化：常态不广播）：
/// - **「可被发现」临时广播**：[publish]（5s 周期）持续 30s，到点由
///   SyncService unpublish；不带三连发（5s 周期已足够）；
/// - **扫描期间周期广播**：[scanOnce] 窗口内每 5s 广播一次本机通告——
///   修复「哑巴扫描」（双方同时扫描时都在听、都不发，互相看不见）；
///   不要求正在发布，凭 [updateIdentity] 登记的身份即可通告；
/// - **新设备回播**：监听期间收到**新 deviceId** 的通告后立即广播一次
///   自己的通告（LocalSend 式互相知晓，全平台）；防已收到风暴：记录
///   最近回播的 deviceId+时间，[replyCooldown] 限频；
/// - **身份变更三连发**：发布期间身份刷新（改名/重置 deviceId）时按
///   可注入延迟（默认 100ms/500ms/2s）连发三次，让对端尽快看到新身份。
///
/// **接收（常驻监听 + 按需扫描）**：
/// - **常驻监听**：enable 期间绑定 UDP [kDiscoveryPort]
///   （[startResidentListen]，与发布/扫描解耦——收听需求不依赖是否在
///   广播）；收到通告即更新并推送设备列表（「未扫描」时也能实时看到
///   正在广播的设备）；
/// - **扫描监听**：[scanOnce] 绑定（reuseAddress，macOS/Linux/iOS 加
///   reusePort 支持同机多 socket 共存；Windows 降级 reuseAddress）收集
///   [scanWindow]（默认 30s）内的通告，窗口结束关闭扫描 socket 并**清空**
///   设备列表（task-32：不再定格旧设备），常驻监听随后的通告实时补充；
/// - **离线清理**：监听期间（扫描或常驻）每 1s 周期清理超过
///   [_scanInactiveThreshold]（6s）无通告的设备（task-32：下线设备从
///   列表及时移除）。
///
/// 本机身份（deviceId/deviceName/port）：enable 时经 [updateIdentity] 登记
/// （供扫描期间广播与回播）；[publish] 参数同样会刷新；未走这两个入口时
/// 可用构造参数 [deviceId]/[deviceName]（供验证脚本注入确定性身份，见
/// temp/drafts/verify_sync.dart）。
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
  }) : _announceInterval = announceInterval,
       _scanWindow = scanWindow,
       _localDeviceId = deviceId,
       _localDeviceName = deviceName ?? '',
       _initialAnnounceDelays = initialAnnounceDelays,
       _replyCooldown = replyCooldown,
       _broadcastAddresses = broadcastAddresses;

  /// 周期通告间隔（默认 30s；可配置，测试用短间隔验证周期通告维持在线）。
  final Duration _announceInterval;

  /// 一次 [scanOnce] 的收集窗口（默认 30s；可配置，测试用短窗口）。
  final Duration _scanWindow;

  /// 身份变更三连发延迟序列（可注入，便于测试）。
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

  /// 发送通告的 socket（anyIPv4:0 + SO_BROADCAST；publish/扫描期间广播/
  /// 回播共用，[_announceOnce] 懒创建。iOS 特例见 [_sendBindAddress]）。
  RawDatagramSocket? _sendSocket;

  /// 接收通告的 socket（绑定 [kDiscoveryPort]，scanOnce 创建）。
  RawDatagramSocket? _receiveSocket;

  /// 常驻监听 socket（enable 期间持续接收通告，全平台；独立于扫描
  /// socket——扫描的 _receiveSocket 会被 _finishScan 关闭，不能混用）。
  RawDatagramSocket? _residentListenSocket;

  /// 常驻监听期望标记：startResidentListen 置 true、stopResidentListen
  /// 置 false。_bindResidentListen 异步绑定完成后检查——若期间已停止
  /// （标记 false）则立即关闭新绑定的 socket，避免残留泄漏
  /// （开关竞态，用户实测偶发失联）。
  bool _wantResidentListen = false;

  /// 常驻监听绑定失败重试定时器（10s 后重试直到 stopResidentListen——
  /// 此前失败即静默失去常驻监听，要等下次 enable 才恢复）。
  Timer? _residentRetryTimer;

  /// 周期通告定时器（publish 启动，unpublish 停止）。
  Timer? _announceTimer;

  /// 身份变更三连发定时器（发布中身份刷新时调度，可被重复调用替换）。
  final List<Timer> _initialAnnounceTimers = [];

  /// 扫描窗口结束定时器（scanOnce 调度）。
  Timer? _scanTimer;

  /// 监听期间周期清理定时器（扫描窗口或常驻监听运行期间，见
  /// [_updatePruneTimer]）：下线设备从列表移除。
  Timer? _pruneTimer;

  /// 扫描期间周期广播定时器（见 scanOnce：修复「哑巴扫描」——双方同时
  /// 扫描时都在听、都不发，互相看不见）。
  Timer? _scanAnnounceTimer;

  /// 扫描期间周期广播间隔（5s：与「可被发现」广播周期一致）。
  static const Duration _scanAnnounceInterval = Duration(seconds: 5);

  /// 扫描期间清理周期（task-32：1s 检查一次，下线设备及时移除）。
  static const Duration _scanPruneInterval = Duration(seconds: 1);

  /// 设备停止广播视为下线的阈值（新版可被发现广播周期 5s，错过一次
  /// 广播 + 1s 余量即判下线；task-32 由 12s → 8s → 6s）。
  static const Duration _scanInactiveThreshold = Duration(seconds: 6);

  /// 当前扫描的完成信号：窗口结束（或 [stopScan] 提前结束）时完成，
  /// 使 [scanOnce] 的调用方可 `await` 整个收集窗口。
  Completer<void>? _scanCompleter;

  /// 设备表（按 deviceId 去重），含最后可见时间（离线判定依据）。
  /// 监听期间（扫描窗口或常驻监听）实时更新：扫描开始/结束清空、常驻
  /// 监听持续累积；每 1s 按 [_scanInactiveThreshold] 清理下线设备（task-32）。
  final Map<String, _DeviceEntry> _devices = {};

  /// 最近回播时间（deviceId → 时间）：收到新设备通告回播后记录，
  /// [replyCooldown] 内不再对同一设备回播（防已收到风暴）。
  final Map<String, DateTime> _lastReplyByDeviceId = {};

  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  /// 发现的设备列表流（监听期间——扫描窗口或常驻监听——收到设备/清理
  /// 下线设备时推送完整列表；未监听时不推送）。
  Stream<List<DiscoveredDevice>> get devices => _devicesController.stream;

  /// 当前已知设备快照（task-32：对端展示名恢复用，从 UDP 通告取真实名）。
  List<DiscoveredDevice> get knownDevices =>
      _devices.values.map((entry) => entry.device).toList();

  /// 当前是否正在发布（[publish] 后为 true，[unpublish] 后为 false）。
  bool get isPublishing => _publishing;

  /// 当前是否正在扫描（scanOnce 窗口内为 true）。
  bool get isScanning => _scanning;

  /// 是否处于监听状态（扫描窗口内或常驻监听开启）：监听期间收到通告即
  /// 更新并推送设备列表（常驻监听让「未扫描」时也能实时看到广播中的
  /// 设备）；离线清理定时器随该状态启停（[_updatePruneTimer]）。
  bool get _listening => _scanning || _wantResidentListen;

  // ===== 主机模式：发布（周期广播通告） =====

  /// 发布本机通告（幂等：先停止旧发布再发布新的）。
  ///
  /// [deviceName]/[deviceId] 为本机身份（SyncService 从 DeviceIdentityStore
  /// 读取传入；[deviceId] 为空时回退构造参数注入的身份）；[port] 为
  /// WebSocket 服务端监听端口（写入通告 JSON `port` 字段）。
  ///
  /// 发布后**立即宣告一次**（首包零延迟，见方法尾部说明），随后按周期
  /// 通告（[announceInterval] 参数优先，缺省 [_announceInterval]）持续
  /// 广播；unpublish 后停止通告（对端凭监听期间无通告 + 离线清理移除，
  /// 无显式 goodbye）。
  ///
  /// [initialAnnouncements]（默认 true）：发布瞬间按 [_initialAnnounceDelays]
  /// 三连发——**身份变更宣告**用（发布中改名/重置 deviceId 时让对端尽快
  /// 看到新身份）；「可被发现」（announceTemporarily）传 false——用户确认
  /// 只靠 5s 周期广播。注：enable 不再 publish（互联手动化，task-31），
  /// 本方法仅由「可被发现」与发布中身份刷新调用。
  ///
  /// [announceInterval]：可选覆盖周期通告间隔（task-31「可被发现」临时广播
  /// 用 5s 快速宣告；未传则用构造参数默认 30s）。
  Future<void> publish({
    required String deviceName,
    required int port,
    String? deviceId,
    Duration? announceInterval,
    bool initialAnnouncements = true,
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
    // 身份变更三连发（100ms/500ms/2s 各发一次）：发布中刷新身份（改名/
    // 重置 deviceId）时快速宣告新身份；「可被发现」传 false——用户确认：
    // 只靠 5s 周期广播，避免「开启瞬间三连发成功、之后周期广播失效」的
    // 错觉与干扰。
    if (initialAnnouncements) {
      _scheduleInitialAnnouncements();
    }
    final interval = announceInterval ?? _announceInterval;
    _announceTimer = Timer.periodic(
      interval,
      (_) => unawaited(_announceOnce()),
    );
    // 发布即宣告一次（首包零延迟）：周期定时器首个 tick 在 +interval
    // （可被发现 5s / 默认 30s），此前首包要白等一个周期——立即补一包
    // 把发现延迟砍掉一档（IP 变化自动广播、改端口、可被发现、身份刷新
    // 全部受益）。单包无副作用：无身份时 _announceOnce 自行跳过。
    unawaited(_announceOnce());
  }

  // ===== 常驻监听（enable 期间，与发布/扫描解耦） =====

  /// 登记本机身份（enable 时调用，与发布解耦）：扫描期间的周期广播与
  /// 新设备回播在「未发布」状态下也需要通告本机（否则哑巴扫描——双方
  /// 同时扫描时都在听、都不发，互相看不见）。[port] 为本机 WebSocket
  /// 服务端口（通告 JSON `port` 字段）。
  void updateIdentity({
    required String deviceName,
    required String deviceId,
    required int port,
  }) {
    _localDeviceId = deviceId;
    final name = deviceName.trim();
    if (name.isNotEmpty) _localDeviceName = name;
    _localPort = port;
  }

  /// 开启常驻监听（enable 时调用；幂等）：绑定 UDP [kDiscoveryPort] 持续
  /// 接收对端广播——收听需求与是否在广播无关；监听期间收到的通告实时
  /// 进入设备列表（「未扫描」时也能看到正在广播的设备并自动连接）。
  Future<void> startResidentListen() async {
    if (_wantResidentListen) return; // 已在监听/绑定中
    _wantResidentListen = true;
    _updatePruneTimer();
    await _bindResidentListen();
  }

  /// 停止常驻监听（disable 时调用；幂等）。不影响发布状态（unpublish
  /// 同理不反向影响监听——两者生命周期独立）。
  void stopResidentListen() {
    if (!_wantResidentListen) return;
    _wantResidentListen = false;
    _residentRetryTimer?.cancel();
    _residentRetryTimer = null;
    _residentListenSocket?.close();
    _residentListenSocket = null;
    _updatePruneTimer();
  }

  /// 常驻监听接收 socket（enable 期间持续接收对端广播，驱动设备列表
  /// 实时更新与「发现即连」）：绑定 UDP [kDiscoveryPort]，与扫描 socket
  /// 共存（reuseAddress/reusePort，广播投递给全部同端口 socket）。
  Future<void> _bindResidentListen() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows, // Windows 不支持 SO_REUSEPORT
      );
      socket.broadcastEnabled = true;
      // 绑定完成时若已不再需要监听（开关竞态）：立即关闭，不残留。
      if (!_wantResidentListen) {
        socket.close();
        return;
      }
      _residentListenSocket = socket;
      socket.listen((e) => _onDatagram(e, socket));
      if (kDebugMode) debugPrint('[discovery] 常驻监听已绑定 UDP $kDiscoveryPort');
    } catch (e) {
      if (kDebugMode) debugPrint('[discovery] 常驻监听绑定失败: $e');
      // 加固：绑定失败（端口被占/瞬时错误）定时重试，直到 stopResidentListen
      // 复位期望标记——避免本次运行静默失去常驻监听。
      _residentRetryTimer?.cancel();
      _residentRetryTimer = Timer(const Duration(seconds: 10), () {
        if (_wantResidentListen && _residentListenSocket == null) {
          unawaited(_bindResidentListen());
        }
      });
    }
  }

  /// 停止发布（幂等）：取消通告定时器并关闭发送 socket（若扫描也停止）。
  ///
  /// 不影响常驻监听（随 enable/disable 生命周期，见 [stopResidentListen]）
  /// 与本机身份登记（[updateIdentity]，enable 期间始终有效——供扫描期间
  /// 广播与回播使用），因此不清 [_localPort]。
  Future<void> unpublish() async {
    if (!_publishing) return;
    _publishing = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    for (final timer in _initialAnnounceTimers) {
      timer.cancel();
    }
    _initialAnnounceTimers.clear();
    _maybeCloseSendSocket();
  }

  // ===== 发现侧：按需扫描（task-27 v4） =====

  /// 手动扫描一次：绑定 UDP [kDiscoveryPort]（reuseAddress + macOS/Linux/iOS
  /// reusePort 同机共存）接收广播通告，收集窗口（[window] 参数优先，缺省
  /// [_scanWindow]，默认 30s）后停止——关闭扫描 socket 并**清空**设备列表
  /// （task-32：不再定格旧设备；常驻监听随后的通告会实时补充）。
  ///
  /// 返回的 Future 在**收集窗口结束后**完成：调用方 `await scanOnce()` 即
  /// 表示一次完整扫描已结束（SyncService 手动扫描/同步页「扫描设备」用）。
  ///
  /// - 扫描窗口内收到通告 → 更新设备表 + 推送列表（新设备立即回播自己的
  ///   通告，LocalSend 式互相知晓）；
  /// - 扫描期间每 5s 周期广播本机（不要求正在发布——凭 [updateIdentity]
  ///   登记的身份即可）：修复「哑巴扫描」（双方同时扫描时都在听、都不发，
  ///   互相看不见），也让正在扫描的本机随时可被对端发现；
  /// - 幂等：已有扫描进行中时立即返回（不重复扫描）；
  /// - [restart]：扫描进行中时结束当前窗口重新开始（task-32 可重复点击）。
  ///
  /// [window]：可选覆盖收集窗口（task-31「扫描设备」用 30s 持续监听）。
  Future<void> scanOnce({Duration? window, bool restart = false}) {
    if (_scanning) {
      if (!restart) return Future.value();
      // task-32：可重复点击——结束当前窗口，重新开始（重置定时器/重绑 socket）。
      _finishScan();
    }
    _scanning = true;
    _updatePruneTimer();
    // task-32：点击扫描清空旧列表并立即推送（UI 立即清空，不等新广播）。
    _devices.clear();
    _pushMerged();
    _scanCompleter = Completer<void>();
    unawaited(_bindScanSocket());
    // 扫描期间周期广播本机（每 5s 一次）：不要求正在发布（_publishing）——
    // 凭 updateIdentity 登记的身份即可通告（_announceOnce 内部对无身份
    // 静默跳过），否则双方同时扫描时都在听、都不发，互相看不见。
    _scanAnnounceTimer?.cancel();
    unawaited(_announceOnce());
    _scanAnnounceTimer = Timer.periodic(_scanAnnounceInterval, (_) {
      if (!_scanning) return;
      unawaited(_announceOnce());
    });
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
      socket.listen((e) => _onDatagram(e, socket));
      if (kDebugMode) debugPrint('[discovery] 扫描监听已绑定 UDP $kDiscoveryPort');
    } catch (e) {
      if (kDebugMode) debugPrint('[discovery] 扫描监听绑定失败: $e');
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
    _scanAnnounceTimer?.cancel();
    _scanAnnounceTimer = null;
    _receiveSocket?.close();
    _receiveSocket = null;
    // task-32：扫描结束清空列表——不再定格旧设备（广播已停的设备
    // 不再显示；常驻监听随后的通告实时补充，下次扫描重新收集）。
    _devices.clear();
    _pushMerged();
    _scanning = false;
    _updatePruneTimer(); // 常驻监听仍在运行时保留清理定时器
    final completer = _scanCompleter;
    _scanCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// 同步离线清理定时器与监听状态：扫描窗口或常驻监听任一开启即运行
  /// （监听期间停止广播的设备及时从列表移除；都不监听时停止定时器）。
  void _updatePruneTimer() {
    if (_listening) {
      _pruneTimer ??= Timer.periodic(_scanPruneInterval, (_) {
        if (!_listening) return;
        final now = DateTime.now();
        final before = _devices.length;
        _devices.removeWhere(
          (_, entry) => now.difference(entry.lastSeen) > _scanInactiveThreshold,
        );
        if (_devices.length != before) _pushMerged();
      });
    } else {
      _pruneTimer?.cancel();
      _pruneTimer = null;
    }
  }

  /// 释放资源（停止发布、常驻监听与扫描并关闭事件流）。
  Future<void> dispose() async {
    await unpublish();
    stopResidentListen();
    stopScan();
    _maybeCloseSendSocket(); // 兜底：从未 publish/scanOnce 时的残留 socket
    await _devicesController.close();
  }

  // ===== 通告发送 =====

  /// 广播一次本机通告（周期通告 / 身份变更三连发 / 扫描期间广播 /
  /// 新设备回播共用）。
  ///
  /// 无身份（未 enable 且未 publish/updateIdentity）时静默跳过；发送
  /// socket 懒创建（[publish] 与未发布的扫描/回播路径共用）。
  ///
  /// 目标地址：逐网卡计算的子网广播地址 + `255.255.255.255` 兜底；测试
  /// 注入 [_broadcastAddresses] 时仅用注入列表。单个目标发送失败容忍
  /// （try-catch），不影响其他目标与后续通告。
  Future<void> _announceOnce() async {
    final deviceId = _localDeviceId;
    final port = _localPort;
    if (deviceId == null || port == null) return; // 无身份：无可通告
    final socket = await _ensureSendSocket();
    final payload = utf8.encode(
      json.encode({
        'v': kAnnounceVersion,
        'deviceId': deviceId,
        'name': _localDeviceName,
        'port': port,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    // iOS 特例：发送 socket 每轮重建。iOS 上 dart socket 的 UDP 发送
    // 「仅 socket 新建后的首次/前几次成功，之后静默丢弃」（dart-lang/sdk
    // #45824/#55564）——每轮 close + rebind 使每次发送都是「新 socket
    // 首次发送」，用户实测广播稳定（2026-09-05 确认），与安卓/Mac 同
    // 路径（一次广播覆盖全网段）。绑定具体接口 IP 的原因见
    // [_sendBindAddress]；iOS 的历史遗留背景：原生 Network.framework
    // 发广播报 Permission denied（需 multicast entitlement），故始终走
    // dart socket。若重建失败则沿用手头 socket（[_ensureSendSocket] 兜底）。
    if (Platform.isIOS) {
      final stopwatch = Stopwatch()..start();
      await _maybeRecreateIOSSendSocket();
      final freshSocket = _sendSocket;
      if (freshSocket == null) return;
      final targets = await _broadcastTargets();
      if (kDebugMode) {
        debugPrint(
          '[discovery] iOS 广播重建后 targets=${targets.map((t) => t.address).toList()}',
        );
      }
      for (final target in targets) {
        try {
          freshSocket.send(payload, target, kDiscoveryPort);
        } catch (e) {
          if (kDebugMode) debugPrint('[discovery] iOS 广播发送失败 -> $target: $e');
        }
      }
      stopwatch.stop();
      if (kDebugMode) debugPrint('[discovery] iOS 广播完成，耗时 ${stopwatch.elapsedMilliseconds}ms');
      return;
    }
    final targets = await _broadcastTargets();
    if (kDebugMode) debugPrint('[discovery] 广播发送 targets=${targets.map((t) => t.address).toList()}');
    for (final target in targets) {
      try {
        socket.send(payload, target, kDiscoveryPort);
        if (kDebugMode) debugPrint('[discovery] 广播已发送 -> ${target.address}');
      } catch (e) {
        // 发送失败（网络抖动/网卡变化/路由不可达）容忍：不影响后续通告。
        if (kDebugMode) debugPrint('[discovery] 通告发送失败 -> $target: $e');
      }
    }
  }

  /// 本机当前非回环/非链路本地 IPv4 地址集合（与广播目标同一套网卡
  /// 过滤：跳过虚拟网卡）。供「本机 IP 变化检测」使用（SyncService 与
  /// 持久化基线比对，变化即临时广播——本机地址变了即对端缓存里的本机
  /// 地址已失效）。网卡枚举失败返回 null（调用方跳过检测，状态未知
  /// 不误报）。
  Future<Set<String>?> localIpv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return {
        for (final iface in interfaces)
          if (!_looksLikeVirtualInterface(iface.name))
            for (final address in iface.addresses)
              if (!address.isLoopback && !address.isLinkLocal) address.address,
      };
    } catch (_) {
      return null;
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

  /// 调度身份变更三连发（发布中身份刷新触发；重复调用先取消
  /// 上次的未发定时器再重排，保证一次刷新恰好三连发）。
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

  /// 获取发送 socket（懒创建：SO_BROADCAST；多网卡广播共用）。
  ///
  /// iOS 特例：绑定 anyIPv4 的 UDP socket 发送广播时，iOS 路由不把
  /// 广播包送到具体接口（用户实测：iPhone 能发现别人但别人发现不了
  /// iPhone——接收正常、发送丢包）。改为绑定本机第一个非回环 IPv4
  /// 地址（Wi-Fi 接口），iOS 即按该接口路由广播。其他平台保持
  /// anyIPv4（macOS/Android/Windows 无此问题）。
  Future<RawDatagramSocket> _ensureSendSocket() async {
    final existing = _sendSocket;
    if (existing != null) return existing;
    final bindAddr = await _sendBindAddress();
    final socket = await RawDatagramSocket.bind(
      bindAddr,
      0,
      reuseAddress: true,
      reusePort: !Platform.isWindows,
    );
    socket.broadcastEnabled = true; // SO_BROADCAST：允许发往广播地址
    _sendSocket = socket;
    return socket;
  }

  /// iOS 每轮重建发送 socket（见 _announceOnce iOS 分支说明）：
  /// 关闭现有并重新 bind，使每轮发送都是「新 socket 首次发送」。
  Future<void> _maybeRecreateIOSSendSocket() async {
    try {
      _sendSocket?.close();
      _sendSocket = null;
      final bindAddr = await _sendBindAddress();
      final socket = await RawDatagramSocket.bind(
        bindAddr,
        0,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;
      // 竞态防护：重建期间 unpublish 已执行（用户关闭可被发现）→
      // 新 socket 无人管理，立即关闭，避免残留泄漏（反复开关场景）。
      if (!_publishing) {
        socket.close();
        return;
      }
      _sendSocket = socket;
    } catch (e) {
      // 重建失败：保留旧 socket（可能仍可用）。
      if (kDebugMode) debugPrint('[discovery] iOS 发送 socket 重建失败: $e');
    }
  }

  /// 发送 socket 绑定地址：iOS 取本机第一个非回环 IPv4（Wi-Fi 接口），
  /// 其他平台 anyIPv4。取不到时回退 anyIPv4。
  Future<InternetAddress> _sendBindAddress() async {
    if (!Platform.isIOS) return InternetAddress.anyIPv4;
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (_looksLikeVirtualInterface(iface.name)) continue;
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          return addr; // 第一个可用 IPv4（通常 en0 Wi-Fi）
        }
      }
    } catch (_) {
      // 枚举失败：回退 anyIPv4。
    }
    return InternetAddress.anyIPv4;
  }

  /// 发布与扫描都停止时关闭发送 socket（避免 enable/disable 循环泄漏 fd）。
  void _maybeCloseSendSocket() {
    if (!_publishing && !_scanning) {
      _sendSocket?.close();
      _sendSocket = null;
    }
  }

  // ===== 通告接收 =====

  void _onDatagram(RawSocketEvent event, RawDatagramSocket socket) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    if (kDebugMode) {
      debugPrint(
        '[discovery] 收到 UDP 包 ${datagram.address.address}:${datagram.port} len=${datagram.data.length}',
      );
    }
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
      // 新设备：登记 + 立即回播自己的通告（LocalSend 式握手，全平台——
      // iOS 广播经每轮重建 socket 已实测稳定，无需再排除；凭已登记身份
      // 即可回播，不要求正在发布）。
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
    if (_listening) {
      // 收到有效通告即推送列表——常驻监听（enable 期间）让「未扫描」时
      // 也能实时更新；扫描窗口内同理。设备表跨扫描保留、UI 可能在
      // disable 时被清空（sync_page _discoveredDevices = []）后重新收到
      // 通告：此时条目即使无变化（changed=false）也必须刷新 UI，否则
      // 「扫描不到」（task-32）。
      _pushMerged();
    }
  }

  /// 新设备回播：收到新 deviceId 通告后立即广播一次自己的通告
  /// （LocalSend 式握手，全平台广播）。
  ///
  /// 不要求正在发布——凭 enable 登记的身份（[updateIdentity]）即可通告，
  /// [_announceOnce] 对无身份的情况静默跳过。限频（防已收到风暴）：记录
  /// 最近回播的 deviceId+时间，[_replyCooldown] 内不再对同一设备回播——
  /// 周期性通告已由对端 lastSeen 维护，回播只在设备首次出现/离线重来时
  /// 触发一次。
  void _maybeReplyAnnouncement(String deviceId, DateTime now) {
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
      if (deviceId is! String || deviceId.isEmpty) return null;
      if (name is! String) return null;
      if (port is! int || port <= 0 || port > 65535) return null;
      return _Announcement(
        deviceId: deviceId,
        name: name,
        port: port,
      );
    } catch (_) {
      return null; // 坏包忽略（非 JSON / 截断等）
    }
  }

  /// 推送完整设备列表（监听期间——扫描窗口或常驻监听——且流未关闭时）。
  void _pushMerged() {
    if (!_listening || _devicesController.isClosed) return;
    _devicesController.add(
      _devices.values.map((entry) => entry.device).toList(),
    );
  }
}

/// 一条 UDP 通告（解析后的结构化表示）。
class _Announcement {
  const _Announcement({
    required this.deviceId,
    required this.name,
    required this.port,
  });

  final String deviceId;
  final String name;
  final int port;
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
