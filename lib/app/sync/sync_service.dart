import 'dart:async';
import 'dart:convert';
// 只取 SocketException（端口占用判定）：避免整包导入与 web_socket_channel
// 的 WebSocket 等符号冲突。
import 'dart:io' show SocketException;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/database.dart' show TrustedDevice;
import '../data/folder.dart';
import '../data/note.dart';
import '../repository/attachments.dart';
import '../repository/device_identity.dart';
import '../repository/folder_repository.dart';
import '../repository/note_repository.dart';
import 'discovery_service.dart';
import 'sync_connection.dart';
import 'sync_protocol.dart';

/// 默认同步端口：每台设备 WebSocket 服务端固定监听端口（可配置，task-13）。
const int kDefaultSyncPort = 58888;

/// 端口冲突自动顺延的候选端口数（目标端口起连试 N 个，全部占用才无法开启）。
const int kPortFallbackAttempts = 10;

/// 配对事件（全局配对弹窗数据源，见 docs/技术架构.md 7.3 节认证与配对流程）。
///
/// 本类通过 [SyncService.pairingEvents] 暴露；UI（全局 [PairingDialogController]，
/// task-14 起任意页面可见）监听后弹出「同意/拒绝」确认框，经
/// [SyncService.acceptPairing] / [SyncService.rejectPairing] 响应；多对端
/// 同时请求按 FIFO 队列依次展示。
sealed class PairingEvent {
  const PairingEvent();
}

/// 收到对端 `pairing_request`：请求连接本机，弹窗「xx 请求连接」（同意/拒绝）。
class PairingRequestedEvent extends PairingEvent {
  const PairingRequestedEvent({
    required this.deviceId,
    required this.deviceName,
    this.connectionId,
  });

  /// 请求方设备 ID。
  final String deviceId;

  /// 请求方设备名（展示用）。
  final String deviceName;

  /// 对应会话 ID（task-13 P2P：入站/出站会话统一为 session id）。
  final String? connectionId;
}

/// 配对失败（请求被拒绝 / 协议版本不兼容）：请求方提示原因。
class PairingFailedEvent extends PairingEvent {
  const PairingFailedEvent({
    required this.deviceId,
    this.connectionId,
    this.reason = '配对被拒绝',
  });

  /// 拒绝方设备 ID。
  final String deviceId;

  /// 对应会话 ID（task-13 P2P：入站/出站会话统一为 session id）。
  final String? connectionId;

  /// 失败原因（如「对方拒绝了配对请求」/「协议版本不兼容，请升级应用」）。
  final String reason;
}

/// 配对成功（本地确认密码正确）：UI 关闭弹窗。
class PairingSucceededEvent extends PairingEvent {
  const PairingSucceededEvent({
    required this.deviceId,
    required this.deviceName,
  });

  /// 配对成功的对端设备 ID。
  final String deviceId;

  /// 配对成功的对端设备名。
  final String deviceName;
}

/// 配对取消（连接断开 / 用户取消 / 重试耗尽，task-14）：
/// UI 从待处理队列移除对应请求并切换到下一个（多对端排队展示）。
class PairingCancelledEvent extends PairingEvent {
  const PairingCancelledEvent({
    required this.deviceId,
    this.connectionId,
    this.reason = '连接已断开',
  });

  /// 原请求方设备 ID。
  final String deviceId;

  /// 对应会话 ID（与 [PairingRequestedEvent.connectionId] 一致）。
  final String? connectionId;

  /// 取消原因（展示用）。
  final String reason;
}

/// 设备 ID 冲突事件（用户需求，task-14，docs/技术架构.md 7.3 节）。
///
/// 对端 deviceId 与本机相同时发出：
/// - **握手/会话登记**（[source] = `hello`）：拒绝该连接并断开；
/// - **发现列表**（[source] = `discovery`）：发现与本机相同 deviceId 的设备
///   （可能恢复了备份数据），不自动连接；同一设备持续在列表只报一次；
/// - **手动连接**（[source] = `connect`）：用户点击同 ID 设备时被拒。
///
/// 注意：发现与本地信任列表相同 deviceId 但不同 IP 的设备属正常
/// （IP 变化），不在此报警——仅对与本机相同的 ID 报警。
class DeviceIdConflictEvent {
  const DeviceIdConflictEvent({
    required this.peerDeviceId,
    this.peerDeviceName,
    required this.source,
  });

  /// 冲突对端的 deviceId（等于本机 deviceId）。
  final String peerDeviceId;

  /// 冲突对端的设备名（发现/手动连接场景有值，握手场景可能为空）。
  final String? peerDeviceName;

  /// 冲突来源：`hello`（握手）/ `discovery`（发现列表）/ `connect`（手动连接）。
  final String source;
}

/// 对端连接状态（同步页设备列表展示，task-14）。
enum PeerStatus {
  /// 已连接：会话就绪（双方互信），数据互通。
  connected,

  /// 连接中：会话存在但尚未就绪（握手/配对/自动重连中）。
  connecting,

  /// 未连接：无会话（已配对设备等待下一轮发现自动重连）。
  disconnected,
}

/// 同步页设备列表条目：本机连接表 / 信任列表中的对端设备。
class PeerDevice {
  const PeerDevice({
    required this.deviceId,
    required this.deviceName,
    required this.isTrusted,
    required this.status,
    this.autoConnect = true,
    this.manuallyDisconnected = false,
    this.syncToPeer = true,
    this.syncFromPeer = true,
    this.address,
  });

  /// 对端设备 ID。
  final String deviceId;

  /// 对端设备名。
  final String deviceName;

  /// 是否已配对（在本地信任列表中）。
  final bool isTrusted;

  /// 当前连接状态。
  final PeerStatus status;

  /// 已配对设备的「自动连接」开关（task-16，WiFi 式；未配对恒 true）。
  final bool autoConnect;

  /// 会话级手动断开标记（task-16）：手动断开后当下不自动重连。
  final bool manuallyDisconnected;

  /// 向对端同步（task-32）：本机是否把变更推送给该设备。
  final bool syncToPeer;

  /// 从对端同步（task-32）：本机是否接收该设备推送的变更。
  final bool syncFromPeer;

  /// 对端最近已知地址（IP:端口，取自地址缓存；无缓存为 null，UI 小字展示）。
  final String? address;
}

/// 同步编排服务（P2P 对等，task-13，docs/技术架构.md 7.1/7.3 节）。
///
/// 每台设备同时承担双角色：
/// - **服务端**：[enable] 时在固定端口（默认 58888，可配置）启动 WebSocket
///   服务端并发布 UDP 广播通告（JSON 携带 deviceId + 设备名 + 端口）；
/// - **客户端（v4 智能扫描，task-27）**：**常态不主动扫描**——enable 后
///   先对已配对设备凭**地址缓存直连**（[directConnectAttempts]×2 组，组间
///   [directConnectAttemptTimeout]），失败/无缓存才进入**退避扫描**（断开后
///   [backoffScanBase] 起每轮 +[backoffScanIncrement] 直到 [backoffScanCap]
///   封顶，持续低频扫描）；未配对设备不自动扫描，仅用户手动「重新扫描」
///   （[scanOnce]，3s 收集窗口后列表定格）；广播（30s 周期通告）保留。
///
/// 对端连接管理：本机维护会话表（按对端 deviceId，见 [_sessionByPeerId]），
/// 可同时连接多台设备；任一连接的消息独立走统一协议状态机（[_PeerSession]）。
///
/// 认证与配对（v4 请求-同意 + HMAC 挑战认证，docs/技术架构.md 7.3 节）：
/// - 连接建立后发起方发 hello（携带协议版本 v2）；接受方查本地信任列表：
///   - 命中且**持有密钥** → challenge{nonce} → 对端用本地存的该设备密钥算
///     HMAC-SHA256 → challenge_response → 验证匹配才 welcome{trusted:true}
///     （防伪装 deviceId；不匹配/无密钥视为未配对）；
///   - 未命中/验证失败 → welcome{trusted:false} → 发起方发 pairing_request
///     （请求同意）→ 接受方弹窗「xx 请求连接」→ 同意 → pairing_accept
///     （携带本机生成的 32 字节密钥）→ 请求方存入信任列表并确认回发 →
///     双方写信任列表（含密钥）进入同步；拒绝 → pairing_fail → 断开；
/// - 反向（发起方不信任接受方）：发起方收到 welcome{trusted:false} 后自行
///   发 pairing_request（接受方弹窗同意/拒绝），流程同上；
/// - 未配对完成的会话不响应 sync_request / 不合并 note_upsert / note_delete
///   （F14 未配对设备无法连接）。
///
/// 取消配对（双边解除，task-27）：任一方 [unpairPeer] → 发 unpair{deviceId}
/// → 对端移除信任 + 断开，本机同步移除——双边不残留。
///
/// 同步集成：每对会话就绪后双向全量对齐（发起方发 sync_request → 接受方
/// 回 sync_data → 合并后回推本机全部笔记）；任一会话收到增量 → 本地 LWW
/// 合并 + 向其他所有已就绪会话转发（多向广播）；devices_update 多向发送。
///
/// 增量推送：订阅 [NoteRepository.changes]（本地变更事件），向所有已就绪
/// 对端推送 note_upsert / note_delete；订阅 [FolderRepository.changes]
/// 推送 folder_upsert（task-32 文件夹归类）。
///
/// 防回声：远端数据写库一律走 [NoteRepository.mergeRemoteNote] /
/// [NoteRepository.mergeRemoteDelete] / [FolderRepository.mergeRemoteFolder]，
/// 这些入口不经过 changes 通道（见 note_repository.dart 类注释约定），
/// 因此远端合并不会再次触发推送。
class SyncService {
  SyncService({
    required NoteRepository repository,
    required DeviceIdentityStore identity,
    FolderRepository? folderRepository,
    DiscoveryService? discovery,
    AttachmentsStore? attachments,
    this.fileRequestTimeout = const Duration(seconds: 30),
    this.fileChunkSendDelay = Duration.zero,
    this.directConnectAttempts = 3,
    this.directConnectGroups = 2,
    this.directConnectAttemptTimeout = const Duration(seconds: 4),
    this.heartbeatInterval = const Duration(seconds: 2),
    this.heartbeatTimeout = const Duration(seconds: 5),
  }) : _repository = repository,
       _identity = identity,
       _folderRepository = folderRepository,
       _discovery = discovery ?? DiscoveryService(),
       _attachments = attachments ?? AttachmentsStore() {
    // 本地变更 → 推送：订阅贯穿服务生命周期，无对端时推送为空操作。
    _changesSub = repository.changes.listen(_onLocalChange);
    // 文件夹变更 → 推送（task-32 文件夹归类）：folder_upsert 消息。
    _folderChangesSub = folderRepository?.changes.listen(_onLocalFolderChange);
    // 发现 → 自动连接：扫描结果到达时，已配对且本机 deviceId 较小者自动
    // 发起连接（扫描按需触发：手动 [scanOnce] / 已配对断线退避扫描）。
    _discoverySub = _discovery.devices.listen((devices) {
      unawaited(_onDiscoveredDevices(devices));
    });
  }

  // ===== 直连优先与退避扫描参数（可注入，验证脚本用短间隔确定性驱动） =====

  /// 直连阶段每组尝试次数（默认 3 次）。
  final int directConnectAttempts;

  /// 直连阶段组数（默认 2 组：先试 3 次
  /// 再试 3 次；仍失败进入退避扫描）。
  final int directConnectGroups;

  /// 直连组间等待时长（默认 5s）。

  /// 单次直连尝试的等待上限（默认 5s；超时视为该次失败，避免对端不可达时
  /// 单次尝试被 SyncClient 内部指数退避拖满 31s）。
  final Duration directConnectAttemptTimeout;

  /// 心跳探活间隔（默认 2s）：连接内周期发 ping，超时判离线（v4 恢复）。
  final Duration heartbeatInterval;

  /// 心跳判离线超时（默认 5s）：超过该时长未收到对端任何消息（ping/pong
  /// 或业务消息）视为对端失联（强杀/断网无 close 帧），关闭会话触发重连。
  final Duration heartbeatTimeout;

  /// 附件请求超时（task-30）：发出 file_request 后对端 [fileRequestTimeout]
  /// 无响应（无此文件 / 大小不符 / 被忽略）→ 移除请求，后续合并可重试
  /// （默认 30s）。
  final Duration fileRequestTimeout;

  /// 分片发送间隔（task-30）：发送方逐片发 file_chunk 之间的等待时长。
  /// 生产默认零延迟（局域网全速传输）；联调脚本注入短间隔确定性驱动
  /// 「断线中断传输」场景。
  final Duration fileChunkSendDelay;

  final NoteRepository _repository;

  /// 文件夹仓库（task-32 文件夹归类）：订阅本地文件夹变更推送
  /// folder_upsert；远端合并走 [FolderRepository.mergeRemoteFolder]。
  /// 可空——不注入时文件夹不参与同步（验证脚本/无文件夹场景）。
  final FolderRepository? _folderRepository;

  /// 本机设备身份与信任列表（deviceId/设备名/信任列表统一入口）。
  final DeviceIdentityStore _identity;

  /// UDP 广播发布/扫描（可注入假实现供联调脚本确定性驱动，见 verify_sync.dart）。
  final DiscoveryService _discovery;

  /// 附件存储（task-30 图片跨设备同步）：存在性检查 / 分片写入 / 校验落盘。
  final AttachmentsStore _attachments;

  /// 本机设备 ID（持久化身份，重启不变；hello/pairing/UDP 通告携带）。
  String get deviceId => _identity.deviceId;

  /// 本机设备名（设置页可修改；hello/UDP 广播发布使用）。
  String get deviceName => _identity.deviceName;

  /// 本机设备名（对外发送兜底）：空/全空白时回退 'lan-notes'。
  ///
  /// Android 上 Platform.localHostname 可能返回空串/`localhost`，设备名
  /// 取不到主机名时（_defaultDeviceName 已回退），或持久化值异常为空时，
  /// 所有对外发送路径（hello/welcome/pairing_*/UDP 通告）统一用本 getter，
  /// 确保对端收到的名称永不为空。
  String get _safeDeviceName {
    final name = _identity.deviceName.trim();
    return name.isEmpty ? 'lan-notes' : name;
  }

  /// 对端设备名登记兜底：空/全空白时回退 fallback（默认对端 deviceId）。
  ///
  /// 对端上报的 deviceName 可能为空（Android 取主机名失败 / 传输字段缺失，
  /// 协议反序列化后为 ''），会话登记与展示一律经此兜底，保证后续使用
  /// 对端名称的地方非空。
  String _safePeerName(String? name, {required String fallback}) {
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }

  final SyncServer _server = SyncServer();

  StreamSubscription<NoteChangeEvent>? _changesSub;
  StreamSubscription<FolderChangeEvent>? _folderChangesSub;
  StreamSubscription<List<DiscoveredDevice>>? _discoverySub;
  StreamSubscription<SyncServerConnection>? _serverConnectedSub;
  StreamSubscription<SyncServerConnection>? _serverDisconnectedSub;
  bool _serverListenersAttached = false;
  int _outgoingSeq = 0;

  /// 全部对端会话（会话 id → 会话；入站用连接 id，出站用 out-N）。
  final Map<String, _PeerSession> _sessions = {};

  /// 对端连接表：对端 deviceId → 会话 id（连接去重/自动连接/多对端管理）。
  final Map<String, String> _sessionByPeerId = {};

  /// 配对请求队列（FIFO，task-14）：等待本机**同意/拒绝**（接受方）的会话。
  ///
  /// 解决 task-13 单槽位覆盖问题：多对端同时请求配对时按到达顺序排队，
  /// 当前请求完成/取消后自动处理下一个；UI（全局配对弹窗）收到
  /// [PairingRequestedEvent] 后与本队列保持同序（队首即当前弹窗目标）。
  /// v4（task-27）：接受方生成密钥经 pairing_accept 发送，请求方确认回发。
  final List<_PeerSession> _pairingQueue = [];

  /// 信任列表缓存（deviceId → 设备）：供 [peerList] 合并展示与
  /// 发现列表「已配对/未配对」标记；配对成功/重置身份后刷新。
  List<TrustedDevice> _trustedCache = const [];
  Set<String> _trustedIds = const {};

  /// 已配对设备的「自动连接」开关缓存（deviceId → autoConnect，task-16）。
  ///
  /// 与 [_trustedCache] 同步刷新；autoConnect=false 的已配对设备保持配对
  /// 但不自动连接（WiFi 式，手动点击仍可连）。
  Map<String, bool> _autoConnectByPeerId = const {};

  /// 同步方向缓存（deviceId → 开关，task-32）：向对端同步 / 从对端同步。
  /// 与 [_trustedCache] 同步刷新；控制推送/接收，不影响连接（永远自动连）。
  Map<String, bool> _syncToByPeerId = const {};
  Map<String, bool> _syncFromByPeerId = const {};

  /// 对端「向各设备同步」配置缓存（task-32 v5）：peerId → (targetId → bool)。
  /// hello/sync_config 交换；fan-out 转发/接收时按 origin 的配置过滤。
  Map<String, Map<String, bool>> _peerSyncToConfigs = const {};

  /// 会话级手动断开标记（task-16，WiFi 式断开）：按对端 deviceId 记录。
  ///
  /// 手动断开（[disconnectPeer]）后当下不自动重连（发现轮询跳过）；
  /// 重新开启同步（[enable]）/关闭再开启（[disable]+[enable]）/重启 App
  /// 时清除（会话级，不持久化）；手动连接该设备（[connectToPeer]）时清除。
  final Set<String> _manuallyDisconnected = {};

  /// 用户是否手动关闭了同步开关（task-17，会话级内存态）。
  ///
  /// 区分「用户手动关闭」与「后台被系统回收/挂起」：
  /// - [disableByUser]（UI 关闭同步开关）置位 → 回前台（resumed）不自动
  ///   重新开启（尊重用户操作）；
  /// - [enable]（用户重新开启 / 启动自动同步 / 回前台恢复）清除；
  /// - App 重启后内存态丢失 → 按 auto_sync 配置恢复（见 main.dart）。
  bool _userDisabled = false;

  /// 已上报的发现列表冲突（同一冲突设备持续在列表只报一次；消失后可再报）。
  final Set<String> _reportedDiscoveryConflicts = {};

  /// 对端地址缓存（deviceId → 最近地址/端口，内存态 + 持久化，task-19/27）。
  ///
  /// 连接建立/发现时刷新并写入 [DeviceIdentityStore]（跨重启有效，v4 直连
  /// 优先——打开软件/enable 先凭缓存直连，失败再扫描）；重连时优先用缓存
  /// 地址直接连接（失败/超时再走 UDP 广播重新发现），使对端短暂掉线/通告
  /// 未达时无需等下一轮发现即可恢复连接（Syncthing 式：UDP 广播仅作兜底）。
  final Map<String, _PeerAddress> _addressCache = {};

  /// 附件传输状态表（fileId → 状态，task-30）：接收方发出的文件请求
  /// （含分片接收进度）。同 hash 去重（一次只请求一个来源会话）；请求
  /// 超时（[fileRequestTimeout]）无响应 / 校验失败 / 会话断开时移除，
  /// 后续笔记合并重新检测缺失再请求。
  final Map<String, _FileTransferState> _fileTransfers = {};

  /// 附件分片写入串行链（fileId → 链尾 Future，task-30）：_onMessage 对每条
  /// 消息 unawaited 并发分发，分片按 WebSocket 保序到达但处理可能交错；
  /// 按 fileId 串行化 createTemp/appendChunk/finalize，保证追加顺序与到达
  /// 顺序一致（内容正确性再由 sha256 校验兜底）。
  final Map<String, Future<void>> _fileWriteChains = {};

  /// 发送中文件去重（`会话id:fileId`，task-30）：防止同一会话对同一文件
  /// 并发重复传输（重复 file_request）。
  final Set<String> _fileSendsInFlight = {};

  /// 超限拒绝的附件（fileId，task-30）：单文件超过
  /// [AttachmentsStore.maxFileSizeBytes] 时拒绝并不再重试（disable/enable
  /// 时清空）。
  final Set<String> _fileSizeRejected = {};

  final StreamController<List<DeviceInfo>> _devicesController =
      StreamController<List<DeviceInfo>>.broadcast();
  final StreamController<DateTime> _syncCompletedController =
      StreamController<DateTime>.broadcast();
  final StreamController<PairingEvent> _pairingController =
      StreamController<PairingEvent>.broadcast();
  final StreamController<DeviceIdConflictEvent> _conflictController =
      StreamController<DeviceIdConflictEvent>.broadcast();
  final StreamController<List<PeerDevice>> _peersController =
      StreamController<List<PeerDevice>>.broadcast();
  DateTime? _lastSyncTime;

  /// 最近一次 [peerList] 快照（同步页 build 直接读取；流事件驱动重建）。
  List<PeerDevice> _lastPeers = const [];

  // ===== 状态与事件暴露（供同步页 UI 消费）=====

  /// 同步总开关是否已开启（服务端监听 + UDP 广播发布/发现均随 [enable] 启动）。
  bool get isEnabled => _server.isRunning;

  /// 用户是否手动关闭了同步开关（task-17）。
  ///
  /// 回前台恢复逻辑（main.dart）据此跳过自动重新开启：手动关闭后不自动
  /// 恢复；App 重启后标记丢失，按 auto_sync 配置恢复。
  bool get isUserDisabled => _userDisabled;

  /// 本机 WebSocket 服务端监听端口（未开启为 null）。
  int? get port => _server.port;

  /// 已登记对端设备列表（按对端 deviceId 去重；含未配对会话）。
  List<DeviceInfo> get connectedDevices {
    final result = <DeviceInfo>[];
    final seen = <String>{};
    for (final session in _sessions.values) {
      final peerId = session.peerDeviceId;
      if (peerId == null || peerId.isEmpty || peerId == deviceId) continue;
      if (seen.contains(peerId)) continue;
      seen.add(peerId);
      result.add(
        DeviceInfo(deviceId: peerId, deviceName: session.peerName ?? peerId),
      );
    }
    return result;
  }

  /// 设备列表变化流（本机连接表变化时发出；P2P 各端以本机连接表为准）。
  Stream<List<DeviceInfo>> get devicesUpdates => _devicesController.stream;

  /// 配对事件流（请求弹窗 / 失败提示 / 成功关闭弹窗 / 取消移除队列）。
  Stream<PairingEvent> get pairingEvents => _pairingController.stream;

  /// 设备 ID 冲突事件流（握手/发现/手动连接检测到同 ID 设备，task-14）。
  Stream<DeviceIdConflictEvent> get deviceIdConflictEvents =>
      _conflictController.stream;

  /// 对端设备列表流（连接表/信任列表合并，task-14 同步页设备列表数据源）。
  Stream<List<PeerDevice>> get peerDevices => _peersController.stream;

  /// 对端设备列表快照（同步页 build 直接读取；变更由 [peerDevices] 驱动重建）。
  List<PeerDevice> get peerList => _lastPeers;

  /// 已配对设备 ID 集合（发现列表标记「已配对/未配对」，task-14）。
  Set<String> get trustedDeviceIds => _trustedIds;

  /// 是否已有至少一条就绪（双方互信）的对端连接。
  bool get isConnected => _sessions.values.any((session) => session.ready);

  /// 已就绪（双方互信）的对端连接数。
  int get connectedPeerCount =>
      _sessions.values.where((session) => session.ready).length;

  /// 在途附件请求数（task-30，联调脚本观测用）。
  int get pendingFileRequests => _fileTransfers.length;

  /// 正在接收分片的附件数（task-30，联调脚本观测用；已收到首个分片）。
  int get activeFileReceives =>
      _fileTransfers.values.where((state) => state.started).length;

  /// 当前会话总数（含未完成登记的入站连接；供联调脚本断言连接去重）。
  int get sessionCount => _sessions.length;

  /// 最近一次同步完成时间（全量/增量合并完成时刷新）。
  DateTime? get lastSyncTime => _lastSyncTime;

  /// 同步完成流（供 UI 展示「最近同步时间」）。
  Stream<DateTime> get syncCompleted => _syncCompletedController.stream;

  /// UDP 广播是否正在发布（[enable] 后为 true）。
  bool get isPublishing => _discovery.isPublishing;

  /// UDP 广播是否正在扫描（手动「重新扫描」/退避扫描窗口内为 true，v4）。
  bool get isScanning => _discovery.isScanning;

  /// 发现的设备流（见 DiscoveryService；仅扫描窗口内更新，列表定格）。
  Stream<List<DiscoveredDevice>> get discoveredDevices => _discovery.devices;

  // ===== 生命周期：enable / disable =====

  /// 开启同步（P2P 总开关，task-27 v4 智能扫描）：启动 WebSocket 服务端
  /// （固定 [port]，默认 [kDefaultSyncPort]）+ 发布 UDP 广播通告（JSON 携带
  /// deviceId+设备名+端口，见 7.1）。**常态不主动扫描**：enable 后先对已配对
  /// 设备凭地址缓存直连（[directConnectAttempts]×[directConnectGroups] 次），
  /// 失败静默结束（task-31：不自动退避扫描，等对方上线连本机或手动扫描）；
  /// 未配对设备仅手动「扫描设备」可见。
  ///
  /// 幂等：已开启时无操作；并发调用去重（[_enableInFlight]——启动自动
  /// 同步与回前台恢复可能重叠，避免重复启动服务端）。
  ///
  /// task-16（WiFi 式）：开启时清除会话级手动断开标记——重新开启同步
  /// 后已配对设备恢复自动重连（与重启 App 同理，标记不持久化）。
  /// task-17：开启时清除「用户手动关闭」标记（重新开启后回前台可自动
  /// 恢复）。
  /// task-31（互联手动化）：enable 不再持续广播——只开 WebSocket 服务端
  /// 等待已配对设备凭缓存直连；向外广播由「可被发现」（[announceTemporarily]）
  /// 手动触发。
  ///
  /// [port] 为 null 时使用持久化端口（persistedSyncPort），无持久化记录则
  /// 回退 [kDefaultSyncPort]。端口被占用时自动顺延尝试（最多
  /// [kPortFallbackAttempts] 个），成功后把实际端口持久化（重启沿用），
  /// 并通过 [lastPortFallbackBase] 告知 UI「默认端口被占用，已自动调整」。
  /// 全部端口均被占用时抛出最后一次 [SocketException]，同步无法开启。
  Future<void> enable({int? port}) {
    if (isEnabled) return Future.value();
    return _enableInFlight ??= _doEnable(port: port).whenComplete(() {
      _enableInFlight = null;
    });
  }

  /// 临时广播本机通告（task-31「可被发现」）：向外广播 [_announceTemporaryDuration]
  /// （30s），每 [_announceTemporaryInterval]（5s）一次，到点自动停止（unpublish）。
  ///
  /// 用于让正在「扫描设备」的对端发现本机（新设备配对/身份重置后重新被发现）。
  /// 幂等：同步未开启时不动作；已在广播时不重复启动（刷新剩余时长）。
  Future<void> announceTemporarily() async {
    if (!isEnabled) return;
    await _identity.ensureLoaded();
    _announceTemporaryTimer?.cancel();
    await _discovery.publish(
      deviceName: _safeDeviceName,
      deviceId: deviceId,
      port: _server.port!,
      announceInterval: _announceTemporaryInterval,
      // 可被发现不走上线三连发（用户确认）：只靠 5s 周期广播。
      initialAnnouncements: false,
    );
    _announceTemporaryTimer = Timer(_announceTemporaryDuration, () {
      _announceTemporaryTimer = null;
      unawaited(_discovery.unpublish());
    });
  }

  /// 立即停止临时广播（task-31；disable/身份重置时清理）。
  Future<void> stopAnnouncing() async {
    _announceTemporaryTimer?.cancel();
    _announceTemporaryTimer = null;
    if (_discovery.isPublishing) {
      await _discovery.unpublish();
    }
  }

  /// 正在进行的 enable 操作（并发去重；无论成功/失败均复位，允许重试）。
  Future<void>? _enableInFlight;

  /// 临时广播定时器（task-31「可被发现」：广播 30s 后自动停止）。
  Timer? _announceTemporaryTimer;

  /// 临时广播时长（「可被发现」向外广播的持续时间；与 kDiscoveryWindow 统一）。
  static const Duration _announceTemporaryDuration = kDiscoveryWindow;

  /// 临时广播通告间隔（「可被发现」每 5s 广播一次）。
  static const Duration _announceTemporaryInterval = Duration(seconds: 5);

  /// 是否正在临时广播（「可被发现」进行中）。
  bool get isAnnouncing => _discovery.isPublishing;

  Future<void> _doEnable({required int? port}) async {
    _userDisabled = false; // 重新开启同步 → 清除用户手动关闭标记（task-17）
    _manuallyDisconnected.clear(); // 重新开启同步 → 自动重连（会话级标记重置）
    await _identity.ensureLoaded(); // 身份就绪后再对外发布（持久化 deviceId/设备名）
    _repository.localDeviceId = deviceId; // task-32 v5：本地笔记 origin 标记用
    _folderRepository?.localDeviceId = deviceId; // task-32：本地文件夹 origin 标记用
    await _refreshTrustedCache(); // 信任列表缓存（同步页已配对设备列表/发现标记）
    await _loadAddressCache(); // 地址缓存（v4 直连优先，跨重启有效）
    // 端口冲突自动顺延：从目标端口起最多尝试 kPortFallbackAttempts 个，
    // 全部占用才认定无法开启（SocketException 抛给 UI 提示）。
    final basePort = port ?? _identity.persistedSyncPort ?? kDefaultSyncPort;
    Object? lastError;
    var startedPort = -1;
    for (var attempt = 0; attempt < kPortFallbackAttempts; attempt++) {
      final candidate = basePort + attempt;
      try {
        await _server.start(port: candidate);
        startedPort = candidate;
        break;
      } on SocketException catch (e) {
        lastError = e; // 端口被占用 → 顺延下一个端口重试
      }
    }
    if (startedPort < 0) {
      // 全部候选端口均被占用：同步无法开启（保留 userDisabled=false，
      // UI 提示后用户可排查端口再重试）。
      throw lastError!;
    }
    // 实际端口持久化（需求 9：重启沿用调整后的端口），并记录是否发生顺延，
    // 供同步页展示「默认端口被占用，已自动调整」提示。
    _lastPortFallbackBase = startedPort != basePort ? basePort : null;
    await _identity.setSyncPort(startedPort);
    unawaited(_identity.setSyncSwitchOn(true)); // 开启成功 → 持久化开关状态
    _attachServerListeners();
    // task-31（互联手动化）：enable 不再持续广播——本机只开 WebSocket 服务端
    // 等待已配对设备凭缓存直连；向外广播（「可被发现」）与扫描（「扫描设备」）
    // 由用户在同步页手动触发（场景少，基本自己的设备，手动最稳妥）。
    _emitPeers();
    // 开启后自动连接已配对的设备（凭缓存直连，用户确认）：本机刚上线时
    // 主动连回已配对对端；对方未上线则直连失败静默结束（等对方上线连本机）。
    unawaited(_runDirectConnectPhase());
  }

  /// 最近一次 enable 发生端口顺延时记录的原目标端口（null = 未顺延，
  /// UI 据此展示/清除「默认端口被占用，已自动调整」提示）。
  int? _lastPortFallbackBase;

  /// 最近一次 enable 是否发生了端口顺延（UI 提示用）。
  bool get lastPortFallback => _lastPortFallbackBase != null;

  /// 最近一次 enable 的原目标端口（发生顺延时非 null）。
  int? get lastPortFallbackBase => _lastPortFallbackBase;

  /// 当前持久化的同步端口（未持久化时为 [kDefaultSyncPort]，UI 输入框初始值）。
  int get configuredPort => _identity.persistedSyncPort ?? kDefaultSyncPort;

  /// 用户手动关闭同步（task-17）：与 [disable] 相同，但记录「用户手动
  /// 关闭」标记——回前台（resumed）时不自动重新开启（尊重用户操作）。
  ///
  /// 开关状态持久化（需求 10）：重启后保持关闭（main.dart 恢复时检查
  /// syncSwitchOn）。
  Future<void> disableByUser() async {
    _userDisabled = true;
    unawaited(_identity.setSyncSwitchOn(false)); // 持久化：重启保持关闭
    await disable();
  }

  /// 关闭同步（总开关）：停止 UDP 广播发布/扫描、停止退避扫描、断开全部
  /// 对端会话（幂等）。
  ///
  /// task-16（WiFi 式）：关闭时一并清除会话级手动断开标记——重新开启
  /// 同步后自动重连。
  Future<void> disable() async {
    _manuallyDisconnected.clear(); // 重新开启同步 → 自动重连（会话级标记重置）
    _directFailAt.clear(); // 直连失败冷却重置（用户主动开关同步后重新尝试）
    _autoConnectBlocked.clear(); // 被拒内存标记重置（重新开启同步重新尝试）
    _announceTemporaryTimer?.cancel();
    _announceTemporaryTimer = null;
    await _discovery.unpublish();
    _discovery.stopScan();
    await _server.stop();
    final sessions = _sessions.values.toList();
    for (final session in sessions) {
      await _closeSession(session);
    }
    _sessions.clear();
    _sessionByPeerId.clear();
    _pairingQueue.clear();
    // 附件传输状态随开关重置（会话已全部关闭）：请求/接收/超限拒绝清空，
    // 重新开启后全量对齐重新检测缺失（task-30）。
    for (final state in _fileTransfers.values) {
      state.timer?.cancel();
    }
    _fileTransfers.clear();
    _fileWriteChains.clear();
    _fileSizeRejected.clear();
    _fileSendsInFlight.clear();
    // 发现列表冲突去重状态随开关重置：重新开启后同一冲突设备可再上报。
    _reportedDiscoveryConflicts.clear();
    _emitDevices();
  }

  // ===== v4 连接策略：直连优先 + 手动扫描（task-27；task-31 互联手动化） =====

  /// 手动扫描一次：UDP 收集窗口（[window] 参数优先，缺省 3s）后停止，
  /// 设备列表定格（同步页「扫描设备」按钮调用，30s 持续监听）。
  Future<void> scanOnce({Duration? window, bool restart = false}) =>
      _discovery.scanOnce(window: window, restart: restart);

  /// 前台/解锁恢复重连（已启用但断开时调用）：凭缓存地址直连已配对设备。
  /// 幂等：已启用且有就绪连接时不动作（避免锁屏/切回反复触发无谓重连）。
  ///
  /// 解决：锁屏/切后台时 sync 服务仍 isEnabled=true（只是网络被系统挂起/
  /// 连接断开），原有的「仅未启用才 enable」逻辑整段跳过，导致回前台也
  /// 不重连（用户反馈）。本方法在已启用但未连接时主动恢复。
  Future<void> retryConnections() async {
    if (!isEnabled || isConnected) return;
    await _refreshTrustedCache();
    await _loadAddressCache();
    await _runDirectConnectPhase();
  }

  /// 从持久化设置加载对端地址缓存到内存（enable 时调用，v4 直连优先）。
  Future<void> _loadAddressCache() async {
    final cached = await _identity.getAllCachedPeerAddresses();
    _addressCache.clear();
    for (final entry in cached.entries) {
      final parts = entry.value.split(':');
      final port = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (parts.isNotEmpty && port != null && port > 0) {
        _addressCache[entry.key] = _PeerAddress(parts[0], port);
      }
    }
  }

  /// 直连阶段（enable 后）：对全部「应主动连接」的已配对设备（autoConnect
  /// && 非手动断开 && 本机 deviceId 较小）凭缓存地址尝试连接
  /// [directConnectAttempts]×[directConnectGroups] 次（组间等待
  /// 仍失败进入退避扫描。
  ///
  /// 每台对端独立异步推进（不阻塞 enable 返回）。
  Future<void> _runDirectConnectPhase() async {
    final peers = await _identity.getTrustedDevices();
    for (final peer in peers) {
      if (peer.deviceId == deviceId) continue;
      // task-32：配对成功永远自动连接（不再检查 autoConnect——连接策略
      // 简化为「永远自动连 + 离线判定」，同步方向由 syncTo/syncFrom 控制）。
      if (_manuallyDisconnected.contains(peer.deviceId)) continue;
      // 被对端拒绝过（对方对本机关了自动连接）：本次运行不再自动尝试。
      if (_autoConnectBlocked.contains(peer.deviceId)) continue;
      // 直连失败冷却（task-32）：离线对端 60s 内不反复自动重试——
      // 回前台/解锁触发 retryConnections 时避免「频繁刷新转圈」。
      final failAt = _directFailAt[peer.deviceId];
      if (failAt != null &&
          DateTime.now().difference(failAt) < _directRetryCooldown) {
        continue;
      }
      // 抢占式连接（迭代优化）：不再按 deviceId 大小分配发起权——刚
      // 活跃的一端对全部已配对对端凭地址缓存抢连（单人多设备场景时间差
      // 足够，基本不会撞车）；万一双方同时抢连，[_registerPeerId]/
      // [_shouldReplace] 的会话去重保证每对设备仅保留一条连接（安全网）。
      unawaited(_directConnectPeer(peer.deviceId));
    }
  }

  /// 对单个对端执行直连尝试循环；全部失败后静默结束（不自动扫描）。
  ///
  /// task-31（互联手动化）：直连失败不再自动退避扫描——对方未上线时
  /// 等待其凭缓存地址主动连本机（本机 WebSocket 服务端在跑）；用户也可
  /// 手动点「扫描设备」发现新地址后由 [_onDiscoveredDevices] 自动连接。
  ///
  /// task-32：直连只尝试一次，失败立即清理未就绪的出站会话——不再
  /// 多轮重试（2 组×3 次×5s 超时≈55s，离线对端会一直显示「连接中」转圈）；
  /// 重连责任在重新上线方，离线方上线后会凭缓存直连本机，无需本机重试。
  /// 返回是否连接成功（手动连接开关/UI 提示用）。
  Future<bool> _directConnectPeer(String peerId, {bool manual = false}) async {
    // 无缓存地址：无从直连，静默结束（等对方连本机或手动扫描）。
    if (_addressCache[peerId] == null) return false;
    if (!isEnabled) return false; // 同步已关闭：中止直连
    final sessionId = _sessionByPeerId[peerId];
    final session = sessionId == null ? null : _sessions[sessionId];
    if (session != null && session.ready) return true; // 已连接：完成
    // task-32：短间隔重试（最多 3 次，间隔 3s）——上线瞬间对端可能
    // 瞬时不可达（服务端启动中/竞态），一次失败就放弃会导致双方死锁
    // （在线方不主动重连）。仍失败才冷却，防离线设备反复尝试。
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_directRetryDelay);
        if (!isEnabled) return false;
      }
      final connected = await _connectFromCacheOnce(peerId, manual: manual);
      if (connected) {
        final ok = await _waitReady(peerId);
        if (ok) return true;
      }
    }
    // 全部失败：清理未就绪的出站会话——client 连接挂起时状态停在
    // connecting，不清理会让 UI 一直显示「连接中」转圈（task-32）。
    final cleanupId = _sessionByPeerId[peerId];
    final cleanup = cleanupId == null ? null : _sessions[cleanupId];
    if (cleanup != null && !cleanup.ready && cleanup.isInitiator) {
      await _closeSession(cleanup);
    }
    // 记录失败时间（冷却期内不再自动重试，防回前台频繁刷新）。
    _directFailAt[peerId] = DateTime.now();
    return false;
  }

  /// 等会话握手就绪（ready）：TCP 已连上后握手可能被拒/卡住，超时失败。
  Future<bool> _waitReady(String peerId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final sid = _sessionByPeerId[peerId];
      final s = sid == null ? null : _sessions[sid];
      if (s == null) return false; // 会话被关闭（对端拒绝/异常）
      if (s.ready) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false; // 握手超时未就绪
  }

  /// 凭缓存地址发起一次出站连接尝试（无会话则创建；已有出站会话则重新
  /// 发起）。等待终端状态（connected/disconnected，超时 [directConnectAttemptTimeout]）。
  ///
  /// 返回是否已连接；无缓存/参数非法返回 false（调用方转入退避扫描）。
  Future<bool> _connectFromCacheOnce(
    String peerId, {
    bool manual = false,
  }) async {
    final cached = _addressCache[peerId];
    if (cached == null) return false;
    var sessionId = _sessionByPeerId[peerId];
    var session = sessionId == null ? null : _sessions[sessionId];
    if (session != null && !session.isInitiator) return false; // 入站会话：不主动连
    if (session == null) {
      // 从信任列表取对端名（直连阶段对端不在发现列表）。
      final name = _trustedCache
          .where((t) => t.deviceId == peerId)
          .map((t) => t.deviceName)
          .firstOrNull;
      final client = SyncClient();
      final newSession =
          _PeerSession(
              id: 'out-${++_outgoingSeq}',
              isInitiator: true,
              link: _OutgoingLink(client),
              service: this,
            )
            ..peerDeviceId = peerId
            ..peerName = _safePeerName(name, fallback: peerId)
            ..manualConnect = manual;
      _sessions[newSession.id] = newSession;
      _sessionByPeerId[peerId] = newSession.id;
      newSession.attach();
      session = newSession;
    }
    final link = session.link;
    if (link is! _OutgoingLink) return false;
    final client = link.client;
    await client.connect(cached.address, cached.port);
    return client.waitForTerminal(timeout: directConnectAttemptTimeout);
  }

  /// 被自动连接拒绝的内存标记（task-32）：对端因本机 autoConnect=false
  /// 拒绝自动连接后记录，本次运行不再自动尝试连该设备；手动连接清除。
  /// 不持久化（重启后跟随 autoConnect 重新尝试）。
  final Set<String> _autoConnectBlocked = {};

  /// 直连失败时间戳（task-32 冷却）：离线对端短时间不反复自动重试——
  /// App 回前台/解锁触发 retryConnections 时避免「频繁刷新转圈」。
  final Map<String, DateTime> _directFailAt = {};

  /// 直连失败冷却期：冷却期内 [_runDirectConnectPhase] 跳过该设备。
  static const Duration _directRetryCooldown = Duration(seconds: 60);

  /// 直连重试间隔（task-32：瞬时不可达场景短间隔重试）。
  static const Duration _directRetryDelay = Duration(seconds: 3);

  /// 手动扫描后未连接的对端由 [_onDiscoveredDevices] 自动连接（扫描结果
  /// 流驱动）；无其他动作。

  void _attachServerListeners() {
    if (_serverListenersAttached) return;
    _serverListenersAttached = true;
    _serverConnectedSub = _server.onClientConnected.listen(_onClientConnected);
    _serverDisconnectedSub = _server.onClientDisconnected.listen(
      _onClientDisconnected,
    );
  }

  /// 服务端接受新连接：登记为入站会话（身份待 hello 登记）。
  void _onClientConnected(SyncServerConnection connection) {
    final session = _PeerSession(
      id: connection.id,
      isInitiator: false,
      link: _IncomingLink(connection),
      service: this,
    );
    _sessions[session.id] = session;
    session.attach();
    _emitDevices();
  }

  /// 服务端连接断开：移除对应入站会话（幂等）。
  /// 在线方不主动重连：断开只标记移除，等待对端重新上线后主动连接。
  void _onClientDisconnected(SyncServerConnection connection) {
    final session = _sessions.remove(connection.id);
    if (session == null) return;
    session.markClosed();
    _clearFileTransfersForSession(session.id); // 附件传输随会话断开丢弃（task-30）
    _unregisterPeerId(session.peerDeviceId, session);
    _clearActivePairingSession(session);
    _emitDevices();
  }

  // ===== 对端连接管理 =====

  /// 用户主动连接对端（未配对设备的配对入口，等待用户操作）。
  ///
  /// 与自动连接共用同一出站会话路径；连接去重由 [_registerPeerId] 保证
  /// 同一对端仅保留一条会话（规范会话优先）。
  ///
  /// task-16（WiFi 式）：手动连接某设备时清除该设备的会话级手动断开
  /// 标记（用户主动恢复连接，后续自动重连恢复）。
  Future<void> connectToPeer(DiscoveredDevice device) async {
    final peerId = device.deviceId;
    if (peerId != null && peerId.isNotEmpty) {
      _manuallyDisconnected.remove(peerId);
    }
    await _connectOutgoing(device);
  }

  /// 手动连接已配对设备（task-31「手动连接」开关开启时触发）：清除手动
  /// 断开标记后凭地址缓存直连对端（无缓存则静默，可先「扫描设备」发现）。
  ///
  /// 与 [connectToPeer]（发现列表点击，未配对可发起配对）不同：本方法
  /// 仅用于已配对设备的手动重连（设备行「手动连接」开关）。
  ///
  /// 返回是否连接成功（task-32：UI 据此提示「正在连接/无法连接」）。
  Future<bool> connectTrustedPeer(String peerId) async {
    if (peerId.isEmpty || peerId == deviceId) return false;
    _manuallyDisconnected.remove(peerId);
    if (!_trustedIds.contains(peerId)) return false;
    // 手动连接：无条件（对方不因 autoConnect 拒绝）+ 清除被拒内存标记。
    _autoConnectBlocked.remove(peerId);
    return _directConnectPeer(peerId, manual: true);
  }

  /// 断开指定对端的连接（幂等）。
  ///
  /// task-16（WiFi 式断开）：断开 + 标记为「手动断开」——发现轮询自动
  /// 连接逻辑跳过已标记对端，当下不自动重连；重新开启同步（[enable]/
  /// [disable]）/重启 App 时标记清除（自动重连恢复）；手动连接
  /// （[connectToPeer]）时清除。
  ///
  /// task-32：断开前发送 [DisconnectMessage] 通知对端——对端收到后同样
  /// 标记本机为「手动断开」，不再自动重连（避免「手机主动断开后，mac 切
  /// 前台又凭缓存自动连回」的误判）。
  Future<void> disconnectPeer(String peerId) async {
    _manuallyDisconnected.add(peerId);
    final sessionId = _sessionByPeerId[peerId];
    if (sessionId == null) {
      _emitPeers(); // 无会话也刷新状态文案（已断开（手动））
      return;
    }
    final session = _sessions[sessionId];
    if (session != null) {
      // 先通知对端「主动断开」再关闭连接（close 帧语义区分主动/意外）。
      if (session.ready) {
        session.sendMessage(const DisconnectMessage().toJson());
      }
      await _closeSession(session);
    }
  }

  /// 该对端是否处于会话级手动断开状态（task-16，同步页状态文案用）。
  bool isManuallyDisconnected(String peerId) =>
      _manuallyDisconnected.contains(peerId);

  /// 设置某已配对设备的「自动连接」开关（task-16，WiFi 式）。
  ///
  /// 关闭后保持配对（信任列表不删除）但不自动连接；手动点击仍可连
  /// （不改变配置）。已建立的连接不受影响。
  /// task-32 起 autoConnect 不再控制连接（永远自动连接），保留兼容。
  Future<void> setAutoConnect(String deviceId, bool value) async {
    await _identity.setAutoConnect(deviceId, value);
    await _refreshTrustedCache();
    _emitPeers();
  }

  /// 设置某已配对设备的同步方向（task-32）：向对端同步 / 从对端同步。
  ///
  /// 只控制数据推送/接收，不影响连接（配对成功永远自动连接）；两端开关
  /// 独立、不同步——关闭最多导致对方收不到/本机不收，无冲突。
  Future<void> setSyncDirections(
    String deviceId, {
    required bool syncToPeer,
    required bool syncFromPeer,
  }) async {
    final prevTo = _syncToByPeerId[deviceId] ?? true;
    final prevFrom = _syncFromByPeerId[deviceId] ?? true;
    await _identity.setSyncDirections(
      deviceId,
      syncToPeer: syncToPeer,
      syncFromPeer: syncFromPeer,
    );
    await _refreshTrustedCache();
    _emitPeers();
    // task-32 v5：向配置变更 → 广播给所有已配对对端（转发/接收过滤依据）。
    if (syncToPeer != prevTo) {
      _broadcastSyncConfig();
    }
    // task-32：开关打开时主动触发一次对应动作（已连接会话上）——
    // 向此设备同步打开 → 主动推一次全量；从此设备同步打开 → 主动拉一次。
    if (syncToPeer && !prevTo) {
      unawaited(_pushFullToPeer(deviceId));
    }
    if (syncFromPeer && !prevFrom) {
      unawaited(_pullFromPeer(deviceId));
    }
  }

  /// 广播本机「向」配置给所有已就绪对端（task-32 v5）。
  void _broadcastSyncConfig() {
    final message = SyncConfigMessage(syncTo: _syncToByPeerId).toJson();
    for (final session in _sessions.values) {
      if (session.ready) {
        session.sendMessage(message);
      }
    }
  }

  /// 主动推送全量给对端（打开「向此设备同步」时）。
  Future<void> _pushFullToPeer(String peerId) async {
    final sessionId = _sessionByPeerId[peerId];
    final session = sessionId == null ? null : _sessions[sessionId];
    if (session == null || !session.ready) return;
    await session._sendFullSnapshot();
  }

  /// 主动从对端拉取全量（打开「从此设备同步」时）。
  Future<void> _pullFromPeer(String peerId) async {
    final sessionId = _sessionByPeerId[peerId];
    final session = sessionId == null ? null : _sessions[sessionId];
    if (session == null || !session.ready) return;
    session.sendMessage(const SyncRequestMessage().toJson());
  }

  /// 取消配对（task-27 v4 双边解除）：发 unpair{deviceId} → 对端移除信任
  /// + 断开；本机同步移除信任/地址缓存/手动断开标记——双边不残留。
  ///
  /// 取消后本机不再信任对端：重新发现不自动连接，对端再连本机需重新
  /// 走请求-同意配对。
  Future<void> unpairPeer(String peerId) async {
    _manuallyDisconnected.remove(peerId);
    final sessionId = _sessionByPeerId[peerId];
    if (sessionId != null) {
      final session = _sessions[sessionId];
      if (session != null) {
        // 先通知对端（unpair 帧先于 close 帧，TCP 保序），再断开本机侧。
        session.sendMessage(UnpairMessage(deviceId: deviceId).toJson());
        await _closeSession(session);
      }
    }
    await _identity.removeTrusted(peerId);
    await _identity.removeCachedPeerAddress(peerId);
    _addressCache.remove(peerId);
    await _refreshTrustedCache();
    _emitPeers();
    _emitDevices();
  }

  /// 收到对端 `unpair`（双边解除）：移除对该对端的信任 + 地址缓存并断开。
  ///
  /// 以会话登记的 peerDeviceId 为准（消息载荷可伪造，防未配对设备冒充
  /// 他人触发删除）。
  Future<void> _onUnpairReceived(
    _PeerSession session,
    String claimedPeerId,
  ) async {
    final targetId = session.peerDeviceId ?? claimedPeerId;
    if (targetId.isEmpty || targetId == deviceId) return;
    await _identity.removeTrusted(targetId);
    await _identity.removeCachedPeerAddress(targetId);
    _addressCache.remove(targetId);
    await _refreshTrustedCache();
    unawaited(_closeSession(session));
    _emitPeers();
    _emitDevices();
  }

  /// 收到「自动连接被拒」通知（task-31 Q4）：对端（拒绝方）关闭了对本机
  /// 的自动连接开关，拒绝本机发起的连接。
  ///
  /// 本机自动关闭对该拒绝方的自动连接开关（持久化到 TrustedDevices），
  /// 刷新 UI——之后本机不再自动连对方，直到用户手动重新打开。
  Future<void> _onAutoConnectRejected(String rejectingPeerId) async {
    if (rejectingPeerId.isEmpty || rejectingPeerId == deviceId) return;
    if (!_trustedIds.contains(rejectingPeerId)) return;
    // task-32：不持久化关闭对方视角的自动连接开关（两端状态独立、不同步），
    // 仅记内存标记——本次运行不再自动尝试连该设备；手动连接不受限
    // （connectTrustedPeer 清除标记）；重启后跟随 autoConnect 重新尝试。
    _autoConnectBlocked.add(rejectingPeerId);
    _emitPeers();
  }

  /// 手动触发全量同步：向所有已就绪会话发送 sync_request（双向对齐）。
  void syncNow() {
    for (final session in _sessions.values) {
      if (session.ready) {
        session.sendMessage(const SyncRequestMessage().toJson());
      }
    }
  }

  /// 设备名等身份信息变更后刷新 UDP 广播发布（已建立的连接不受影响）。
  ///
  /// task-31（互联手动化）：enable 不持续广播，仅「可被发现」临时广播期间
  /// 需要刷新（身份变更对正在扫描的对端即时生效）；未在发布时为空操作。
  Future<void> refreshPublishedIdentity() async {
    await _identity.ensureLoaded();
    if (_discovery.isPublishing) {
      await _discovery.publish(
        deviceName: _safeDeviceName,
        deviceId: deviceId,
        port: _server.port!,
      );
    }
  }

  /// 刷新对端地址缓存（task-19 + v4 持久化）：发现/连接建立时调用，
  /// 同时写入 [DeviceIdentityStore]（跨重启有效，直连优先）。
  void _cachePeerAddress(String peerId, String address, int port) {
    if (peerId.isEmpty || address.isEmpty || port <= 0) return;
    _addressCache[peerId] = _PeerAddress(address, port);
    unawaited(_identity.cachePeerAddress(peerId, address, port));
  }

  /// 创建出站会话（自动连接 / 用户主动连接共用）。
  ///
  /// 出站会话创建时即已知对端身份（来自 UDP 广播发现的 deviceId），提前登记
  /// 到 [_sessionByPeerId] 用于连接去重（避免重复发起）。已存在会话时仅
  /// 更新连接目标（IP 变化通过重新发现解析新地址，见 [SyncClient.updateTarget]）。
  ///
  /// 设备 ID 冲突：对端 deviceId 与本机相同时拒绝连接并上报冲突事件
  /// （不建立连接；发现/握手路径同理，见 [_onDiscoveredDevices]/[_onPeerHello]）。
  Future<void> _connectOutgoing(DiscoveredDevice device) async {
    final peerId = device.deviceId;
    if (peerId == null || peerId.isEmpty) return;
    if (peerId == deviceId) {
      _reportConflict(
        peerId: peerId,
        peerName: device.deviceName,
        source: 'connect',
      );
      return;
    }
    // task-19：连接发起时刷新地址缓存（连接建立/发现时缓存对端地址）。
    _cachePeerAddress(peerId, device.address.address, device.port);
    final existingId = _sessionByPeerId[peerId];
    if (existingId != null) {
      final existing = _sessions[existingId];
      if (existing != null && existing.isInitiator) {
        // 从缓存读取地址更新连接目标（缓存为权威来源，刚刷新）。
        final cached = _addressCache[peerId];
        if (cached != null) {
          existing.updateTarget(cached.address, cached.port);
        }
      }
      return;
    }
    final client = SyncClient();
    final session =
        _PeerSession(
            id: 'out-${++_outgoingSeq}',
            isInitiator: true,
            link: _OutgoingLink(client),
            service: this,
          )
          ..peerDeviceId = peerId
          ..peerName = _safePeerName(device.deviceName, fallback: peerId);
    _sessions[session.id] = session;
    _sessionByPeerId[peerId] = session.id;
    session.attach();
    await client.connect(device.address.address, device.port);
  }

  /// UDP 广播发现结果 → 自动连接（task-13 核心，task-14 加同 ID 冲突防护，
  /// task-16 加 WiFi 式断开 + 每设备自动连接配置）。
  ///
  /// 规则：
  /// - 过滤本机（isSelf / deviceId 等于本机）；
  /// - **设备 ID 冲突**：发现与本机相同 deviceId 的设备（可能恢复了备份
  ///   数据）→ 不自动连接 + 上报冲突事件（同一设备持续在列表只报一次）；
  /// - 连接去重：仅当本机 deviceId 字典序**小于**对端时才主动连接
  ///   （大者只接受对端连接），保证每对设备仅一条连接；
  /// - 未配对设备不自动连（等待用户 [connectToPeer] 操作，配合 task-12
  ///   配对流程，不自动发配对请求）；
  /// - **每设备自动连接配置（task-16）**：autoConnect=false 的已配对设备
  ///   保持配对但不自动连（手动点击仍可连，不改变配置）；
  /// - **手动断开标记（task-16）**：手动断开后的对端跳过自动连接——当下
  ///   不自动重连（重新开启同步/重启 App/手动连接时恢复）；
  /// - 已存在会话：出站会话更新目标地址（IP 变化重连）；入站会话不动。
  Future<void> _onDiscoveredDevices(List<DiscoveredDevice> devices) async {
    final discoveredIds = <String>{};
    for (final device in devices) {
      if (device.isSelf) continue;
      final peerId = device.deviceId;
      if (peerId == null || peerId.isEmpty) continue;
      discoveredIds.add(peerId);
      // 设备 ID 冲突：仅对与本机相同的 ID 报警（发现与信任列表相同
      // deviceId 但不同 IP 的设备属正常 IP 变化，不误报）。
      if (peerId == deviceId) {
        _reportConflict(
          peerId: peerId,
          peerName: device.deviceName,
          source: 'discovery',
        );
        continue;
      }
      // 抢占式连接（迭代优化，与 _runDirectConnectPhase 一致）：不再按
      // deviceId 大小分配发起权——本端刚活跃时主动连已配对对端（不管大小，
      // 保证无地址缓存的场景也能靠扫描发现后抢连）；双向同时抢连由
      // _registerPeerId/_shouldReplace 会话去重兜底（每对仅保留一条）。
      // 未配对设备不自动连（等待用户操作）。
      if (!await _identity.isTrusted(peerId)) continue;
      // task-32：配对成功永远自动连接（扫描发现即连，不再检查 autoConnect）。
      // 会话级手动断开标记（task-16）：手动断开后当下不自动重连。
      if (_manuallyDisconnected.contains(peerId)) continue;
      // task-19：发现即刷新地址缓存（重连时优先用缓存地址，见
      // [_maybeReconnectFromCache]；updateTarget 路径同样先刷新缓存再取地址）。
      _cachePeerAddress(peerId, device.address.address, device.port);
      final existingId = _sessionByPeerId[peerId];
      if (existingId != null) {
        final existing = _sessions[existingId];
        if (existing != null && existing.isInitiator) {
          // 从缓存读取地址更新连接目标（刚刷新，与发现一致；缓存为
          // 权威来源，保证与 _maybeReconnectFromCache 同源）。
          final cached = _addressCache[peerId];
          if (cached != null) {
            existing.updateTarget(cached.address, cached.port);
          }
        }
        continue;
      }
      unawaited(_connectOutgoing(device));
    }
    // 清理已消失的冲突设备（下次再出现可重新上报）。
    _reportedDiscoveryConflicts.removeWhere(
      (id) => !discoveredIds.contains(id),
    );
  }

  /// 登记会话的对端身份（连接去重：每对设备仅保留一条会话）。
  ///
  /// 返回 false 表示本会话被判定为重复连接并已关闭，调用方应停止后续处理。
  bool _registerPeerId(_PeerSession session) {
    final peerId = session.peerDeviceId;
    if (peerId == null || peerId == deviceId) return true;
    final existingId = _sessionByPeerId[peerId];
    if (existingId != null && existingId != session.id) {
      final existing = _sessions[existingId];
      if (existing != null && _shouldReplace(existing, session)) {
        unawaited(_closeSession(existing));
      } else {
        unawaited(_closeSession(session));
        return false;
      }
    }
    _sessionByPeerId[peerId] = session.id;
    return true;
  }

  /// 连接去重规则（docs/技术架构.md 7.1 节）：deviceId 字典序小者主动连接、
  /// 大者只接受。规范会话 = 发起方是两者中 deviceId 较小者；规范会话优先
  /// 保留；否则保留存活的新会话（重连残留/身份漂移）。
  bool _shouldReplace(_PeerSession existing, _PeerSession incoming) {
    final peerId = incoming.peerDeviceId!;
    final meSmaller = deviceId.compareTo(peerId) < 0;
    bool isCanonical(_PeerSession s) => s.isInitiator ? meSmaller : !meSmaller;
    final existingCanonical = isCanonical(existing);
    final incomingCanonical = isCanonical(incoming);
    if (existingCanonical && !incomingCanonical && existing.isAlive) {
      // 旧会话为规范且存活：保留旧会话，关闭非规范的新会话。
      return false;
    }
    return true; // 其余情况保留新会话（规范优先 / 重连残留 / 旧会话失活）。
  }

  void _unregisterPeerId(String? peerId, _PeerSession session) {
    if (peerId == null) return;
    if (_sessionByPeerId[peerId] == session.id) {
      _sessionByPeerId.remove(peerId);
    }
  }

  /// 关闭会话并从连接表移除（幂等）。
  Future<void> _closeSession(_PeerSession session) async {
    await session.close();
    if (_sessions.remove(session.id) == null) return;
    _clearFileTransfersForSession(session.id); // 附件传输随会话关闭丢弃（task-30）
    _unregisterPeerId(session.peerDeviceId, session);
    _clearActivePairingSession(session);
    _emitDevices();
  }

  /// 会话底层连接关闭（对端断开/消息流结束）：移除会话（幂等）；
  /// 心跳超时：对端强杀/断网（无 close 帧）判定失联——关闭会话并标记离线。
  /// 在线方不主动重连（架构决策），等待对端重新上线后主动连接。
  void _onHeartbeatTimeout(_PeerSession session) {
    // ignore: avoid_print
    print(
      '[心跳监控] onHeartbeatTimeout 关闭会话 peer=${session.peerDeviceId ?? 'null'}',
    );
    // 直接 close()（勿先 markClosed——那会让 close() 因 _closed 直接 return，
    // link 不关闭、消息流不 onDone，会话卡在连接表）。
    unawaited(session.close());
    // 主动走一次会话清理（幂等：_onSessionLinkClosed 有 _sessions.remove 守卫，
    // 即使随后消息流 onDone 再触发也无副作用）：确保 isConnected 立即翻转、
    // 状态灯随即变灰，不完全依赖 onDone 时序。
    _onSessionLinkClosed(session);
  }

  void _onSessionLinkClosed(_PeerSession session) {
    if (_sessions.remove(session.id) == null) return;
    // ignore: avoid_print
    print(
      '[心跳监控] 会话移除 peer=${session.peerDeviceId ?? 'null'} isConnected=$isConnected 剩余会话=${_sessions.length}',
    );
    _clearFileTransfersForSession(session.id); // 附件传输随会话断开丢弃（task-30）
    _unregisterPeerId(session.peerDeviceId, session);
    _clearActivePairingSession(session);
    _emitDevices();
  }

  // ===== 配对（UI 钩子，task-14 队列化，v4 请求-同意） =====

  /// 用户同意配对请求：向配对队列队首（当前弹窗目标）发送 pairing_accept
  /// （携带本机生成的 32 字节密钥），并写入信任列表。
  ///
  /// 无待配对流程时为空操作。
  Future<void> acceptPairing() async {
    final session = _activePairingSession;
    if (session == null) return;
    await session.acceptConsent();
  }

  /// 用户拒绝配对请求：向队首发送 pairing_fail 并断开（请求方提示被拒绝）。
  Future<void> rejectPairing() async {
    final session = _activePairingSession;
    if (session == null) return;
    session.rejectConsent();
  }

  /// 用户取消当前配对请求（关闭弹窗/连接断开）：关闭对应待配对会话（幂等）。
  ///
  /// 关闭会触发 [PairingCancelledEvent]，UI 据此从队列移除该请求并
  /// 切换到下一个（若有）。
  Future<void> cancelPairing() async {
    final session = _activePairingSession;
    if (session == null) return;
    _clearActivePairingSession(session);
    await _closeSession(session);
  }

  /// 当前等待用户同意/拒绝的会话（配对队列队首；FIFO 依次处理）。
  _PeerSession? get _activePairingSession =>
      _pairingQueue.isEmpty ? null : _pairingQueue.first;

  /// 从配对队列移除会话（连接断开/关闭时调用）。若该会话正在等待用户
  /// 同意（接受方），通知 UI 取消对应弹窗请求并切换到下一个。
  void _clearActivePairingSession(_PeerSession? session) {
    if (session == null || session._pairingRole != _PairingRole.consenter) {
      return;
    }
    session._leaveQueueCancelled('连接已断开');
  }

  /// 重置设备身份（设备 ID 冲突修复入口，task-14）：
  /// 重新生成 deviceId + 清空信任列表（旧配对失效需重新配对），
  /// 断开全部会话，以新身份重新发布 UDP 广播通告（同步开启时）。
  ///
  /// 见 [DeviceIdentityStore.resetDeviceId] 与 docs/技术架构.md 7.3 节。
  /// task-16：一并清除会话级手动断开标记（新身份下旧标记无意义）。
  /// task-27：清空地址缓存（旧身份的地址缓存随信任列表清空）。
  /// task-31：重置身份后不主动广播——互联手动化，「可被发现」临时广播期间
  /// 刷新新身份通告，否则等用户手动触发。
  Future<void> resetDeviceIdentity() async {
    await _identity.resetDeviceId();
    _manuallyDisconnected.clear();
    _addressCache.clear();
    final sessions = _sessions.values.toList();
    for (final session in sessions) {
      await _closeSession(session);
    }
    _sessions.clear();
    _sessionByPeerId.clear();
    _pairingQueue.clear();
    _reportedDiscoveryConflicts.clear();
    await _refreshTrustedCache();
    if (_discovery.isPublishing) {
      // 以新身份重新发布 UDP 广播通告（JSON 携带新 deviceId）。
      await _discovery.publish(
        deviceName: _safeDeviceName,
        deviceId: deviceId,
        port: _server.port!,
      );
    }
    _emitDevices();
  }

  // ===== 设备列表与信任缓存 =====

  /// 刷新信任列表缓存（enable/配对成功/取消配对/重置身份/开关变更后调用）。
  ///
  /// task-16：同步构建每设备「自动连接」开关缓存（[_autoConnectByPeerId]），
  /// 供自动连接条件判断与同步页开关展示。
  Future<void> _refreshTrustedCache() async {
    final trusted = await _identity.getTrustedDevices();
    _trustedCache = trusted;
    _trustedIds = trusted.map((t) => t.deviceId).toSet();
    _autoConnectByPeerId = {for (final t in trusted) t.deviceId: t.autoConnect};
    _syncToByPeerId = {for (final t in trusted) t.deviceId: t.syncToPeer};
    _syncFromByPeerId = {for (final t in trusted) t.deviceId: t.syncFromPeer};
  }

  /// 上报设备 ID 冲突（握手/手动连接每次上报；发现列表按 deviceId 去重）。
  void _reportConflict({
    required String peerId,
    String? peerName,
    required String source,
  }) {
    if (source == 'discovery' && !_reportedDiscoveryConflicts.add(peerId)) {
      return; // 同一冲突设备持续在列表：只报一次。
    }
    if (!_conflictController.isClosed) {
      _conflictController.add(
        DeviceIdConflictEvent(
          peerDeviceId: peerId,
          peerDeviceName: peerName,
          source: source,
        ),
      );
    }
  }

  /// 对端设备列表（连接表 + 信任列表合并）：同步页「已配对设备」数据源。
  ///
  /// - 当前连接表中的会话（含未配对，状态按传输层/就绪度计算）；
  /// - 已配对但当前无会话的设备（状态 disconnected——自动连接中）；
  /// - 按对端 deviceId 去重；本机自身永不出现。
  ///
  /// task-16：条目携带「自动连接」开关（[_autoConnectByPeerId]）与会话级
  /// 手动断开标记（[_manuallyDisconnected]），供同步页状态文案/开关展示。
  void _emitPeers() {
    final peers = <PeerDevice>[];
    final seen = <String>{};
    for (final session in _sessions.values) {
      final peerId = session.peerDeviceId;
      if (peerId == null || peerId.isEmpty || peerId == deviceId) continue;
      if (seen.contains(peerId)) continue;
      seen.add(peerId);
      // 设备名多来源兜底（task-32）：信任列表名 → 会话名 → UDP 通告名，
      // 避免对端上报空名（旧版/取主机名失败）导致显示 ID。
      final trustedName = _trustedCache
          .where((t) => t.deviceId == peerId)
          .map((t) => t.deviceName)
          .firstOrNull;
      peers.add(
        PeerDevice(
          deviceId: peerId,
          deviceName: _peerDisplayName(
            peerId,
            trustedName: trustedName,
            sessionName: session.peerName,
          ),
          isTrusted: _trustedIds.contains(peerId),
          status: _sessionStatus(session),
          autoConnect: _autoConnectByPeerId[peerId] ?? true,
          manuallyDisconnected: _manuallyDisconnected.contains(peerId),
          syncToPeer: _syncToByPeerId[peerId] ?? true,
          syncFromPeer: _syncFromByPeerId[peerId] ?? true,
          // 最近已知地址（UI 小字展示 IP:端口）。
          address: _addressCache[peerId]?.displayName,
        ),
      );
    }
    for (final trusted in _trustedCache) {
      if (trusted.deviceId == deviceId) continue; // 自身永不出现
      if (seen.contains(trusted.deviceId)) continue;
      seen.add(trusted.deviceId);
      peers.add(
        PeerDevice(
          deviceId: trusted.deviceId,
          deviceName: _peerDisplayName(
            trusted.deviceId,
            trustedName: trusted.deviceName,
          ),
          isTrusted: true,
          status: PeerStatus.disconnected,
          autoConnect: trusted.autoConnect,
          manuallyDisconnected: _manuallyDisconnected.contains(
            trusted.deviceId,
          ),
          syncToPeer: trusted.syncToPeer,
          syncFromPeer: trusted.syncFromPeer,
          // 最近已知地址（UI 小字展示 IP:端口）。
          address: _addressCache[trusted.deviceId]?.displayName,
        ),
      );
    }
    // 稳定排序：已配对设备按配对时间倒序（最新配对的在最上面）。
    //
    // 起因：上面的构建顺序取决于 _sessions（Map，插入顺序随连接建立/断开
    // 变化）与分段拼接，设备会在断开重连、连接去重、启动竞争时无故跳位。
    // 这里统一按配对时间定序；未配对设备无 pairedAt，排在最后并用 deviceId
    // 兜底，保证 List.sort（非稳定排序）下顺序仍然确定。
    final pairedAtById = <String, int>{
      for (final t in _trustedCache) t.deviceId: t.pairedAt,
    };
    peers.sort((a, b) {
      final ta = pairedAtById[a.deviceId] ?? 0;
      final tb = pairedAtById[b.deviceId] ?? 0;
      final byPairedAt = tb.compareTo(ta); // 降序：时间戳大的（新配对的）在前
      return byPairedAt != 0 ? byPairedAt : a.deviceId.compareTo(b.deviceId);
    });
    _lastPeers = peers;
    if (!_peersController.isClosed) {
      _peersController.add(peers);
    }
  }

  /// 对端展示名（task-32）：优先信任列表名 → 会话名 → UDP 通告名 → ID。
  ///
  /// 信任列表/会话名可能存的是 ID（对端上报 deviceName 为空时 fallback，
  /// 如旧版/Android 取主机名失败），此时从 UDP 通告（name 通常可靠）恢复
  /// 真实设备名，避免已配对/已连接设备显示 ID。
  String _peerDisplayName(
    String peerId, {
    String? trustedName,
    String? sessionName,
  }) {
    String? pick(String? name) {
      final t = name?.trim() ?? '';
      return (t.isEmpty || t == peerId) ? null : t;
    }

    final fromTrusted = pick(trustedName);
    if (fromTrusted != null) return fromTrusted;
    final fromSession = pick(sessionName);
    if (fromSession != null) return fromSession;
    for (final d in _discovery.knownDevices) {
      if (d.deviceId == peerId) {
        final n = pick(d.deviceName);
        if (n != null) return n;
      }
    }
    // 最终兜底：显示 ID 前 8 位（task-32，避免展示完整长 ID）。
    return peerId.length <= 8 ? peerId : peerId.substring(0, 8);
  }

  /// 会话的连接状态（同步页展示）：就绪=已连接；出站传输层连接中/入站未就绪
  /// =连接中（握手/配对/自动重连）；其余=未连接。
  PeerStatus _sessionStatus(_PeerSession session) {
    if (session.ready) return PeerStatus.connected;
    final link = session.link;
    if (link is _OutgoingLink) {
      return switch (link.client.state) {
        SyncConnectionState.connecting ||
        SyncConnectionState.connected => PeerStatus.connecting,
        SyncConnectionState.disconnected => PeerStatus.disconnected,
      };
    }
    // 入站：传输层连接存活但未就绪 → 握手/配对进行中。
    return PeerStatus.connecting;
  }

  // ===== 同步集成 =====

  /// 把消息转发给除 [except] 外的所有**已就绪**会话（多向广播 fan-out）。
  void _fanOutToOthers(Map<String, dynamic> message, _PeerSession except) {
    // task-32 v5：转发时按 origin 的「向目标」配置过滤——A 关「向 B」后，
    // 即使 C 向 B 开放，origin=A 的数据也不转发给 B。
    final origin = _originOf(message);
    for (final session in _sessions.values) {
      if (session != except && session.ready && _canPushTo(session)) {
        if (origin != null && !_originAllowsTo(origin, session.peerDeviceId)) {
          continue; // origin 设备对该目标关「向」：不转发
        }
        session.sendMessage(message);
      }
    }
  }

  /// 从消息提取 origin（note_upsert/note_delete 的原始作者）。
  String? _originOf(Map<String, dynamic> message) {
    final origin = message['origin'];
    return origin is String && origin.isNotEmpty ? origin : null;
  }

  /// origin 设备是否允许数据到达目标（查对端缓存配置，缺省放行）。
  bool _originAllowsTo(String origin, String? targetId) {
    if (targetId == null || targetId.isEmpty) return true;
    if (origin == deviceId) return true; // 本机数据：由本机「向」开关控制（_canPushTo）
    final config = _peerSyncToConfigs[origin];
    if (config == null) return true; // 无缓存（未交换过配置）：放行
    return config[targetId] ?? true;
  }

  /// 向所有已就绪对端推送（本地变更 → note_upsert / note_delete）。
  void _pushToAllPeers(Map<String, dynamic> message) {
    // ignore: avoid_print
    print(
      '[增量推送] type=${message['type']} origin=${message['origin']} 本机会话数=${_sessions.length}',
    );
    for (final session in _sessions.values) {
      // ignore: avoid_print
      print(
        '[增量推送]   对端=${session.peerDeviceId} ready=${session.ready} 可推=${_canPushTo(session)}',
      );
      if (session.ready && _canPushTo(session)) {
        session.sendMessage(message);
      }
    }
  }

  /// 是否允许向该对端推送（task-32）：本机「向对端同步」开关开启才推。
  bool _canPushTo(_PeerSession session) {
    final peerId = session.peerDeviceId;
    if (peerId == null) return false;
    return _syncToByPeerId[peerId] ?? true;
  }

  /// 本地变更 → 推送：软删除/恢复与新增/修改同走 note_upsert（deletedAt
  /// 非空即删除语义，见 docs/技术架构.md 7.2 节），清空/删除走 note_delete。
  void _onLocalChange(NoteChangeEvent event) {
    switch (event) {
      case NoteUpsertedEvent(note: final note):
      case NoteTrashedEvent(note: final note):
      case NoteRestoredEvent(note: final note):
        _pushToAllPeers(
          NoteUpsertMessage(
            // 仅本机保存：只传标记（空标题/正文），对端收到后删除自己的
            // 副本——内容不外传是该标记的语义核心。
            note: note.syncPayload,
            origin: note.origin ?? deviceId,
          ).toJson(),
        );
      case NoteDeletedEvent(
        id: final id,
        version: final version,
        deletedAt: final deletedAt,
      ):
      case NotePurgedEvent(
        id: final id,
        version: final version,
        deletedAt: final deletedAt,
      ):
        _pushToAllPeers(
          NoteDeleteMessage(
            id: id,
            version: version,
            deletedAt: deletedAt,
            origin: deviceId,
          ).toJson(),
        );
    }
  }

  /// 本地文件夹变更 → 推送（task-32 文件夹归类）：新增/修改/置顶/排序/
  /// 软删除均走 folder_upsert（deletedAt 非空即删除语义，与笔记同构）。
  void _onLocalFolderChange(FolderChangeEvent event) {
    switch (event) {
      case FolderUpsertedEvent(folder: final folder):
      case FolderTrashedEvent(folder: final folder):
        _pushToAllPeers(
          FolderUpsertMessage(
            folder: folder,
            origin: folder.origin ?? deviceId,
          ).toJson(),
        );
    }
  }

  /// 连接表变化 → 本地流 + 向所有已登记会话多向发送 devices_update；
  /// 同时刷新对端设备列表（[peerDevices]，同步页已配对设备卡数据源）。
  void _emitDevices() {
    final devices = connectedDevices;
    _devicesController.add(devices);
    final message = DevicesUpdateMessage(devices: devices).toJson();
    for (final session in _sessions.values) {
      if (session.peerDeviceId != null) {
        session.sendMessage(message);
      }
    }
    _emitPeers();
  }

  void _markSyncCompleted() {
    _lastSyncTime = DateTime.now();
    _syncCompletedController.add(_lastSyncTime!);
  }

  // ===== 图片跨设备同步（task-30，协议 v4） =====

  /// 从 delta content 提取图片引用 hash（`attachments/<16位hex>.jpg`）。
  ///
  /// 正则直接匹配 delta JSON 字符串中的 quill image embed 值
  /// （`{"image":"attachments/<hash>.jpg"}`）与纯文本引用；同 hash 去重。
  static final RegExp _attachmentRef = RegExp(
    r'attachments/([a-f0-9]{16})\.([a-z0-9]+)',
  );

  /// 提取 delta content 中的附件引用 (hash, ext) 列表（按 hash 去重，保持出现顺序）。
  static List<(String, String)> extractAttachmentRefs(String content) {
    final result = <(String, String)>[];
    for (final match in _attachmentRef.allMatches(content)) {
      final hash = match.group(1);
      final ext = match.group(2);
      if (hash != null && ext != null && !result.any((e) => e.$1 == hash)) {
        result.add((hash, ext));
      }
    }
    return result;
  }

  /// 笔记合并后缺失检测（task-30）：解析 delta content 中的图片引用，本地
  /// 不存在且不在请求队列 → 入队并向来源会话发 file_request。
  Future<void> _requestMissingAttachmentsForContent(
    String content,
    _PeerSession source,
  ) async {
    for (final (hash, ext) in extractAttachmentRefs(content)) {
      await _ensureAttachmentRequested(hash, ext, source);
    }
  }

  /// 确保附件已被请求（同 hash 去重）：本地已存在 / 已在请求队列 / 已被
  /// 超限拒绝 → 跳过；否则入队并发 file_request{fileId, expectedSize:null}
  /// （接收方请求时不知道文件大小，发送方以本地实际大小为准校验）。
  Future<void> _ensureAttachmentRequested(
    String hash,
    String ext,
    _PeerSession source,
  ) async {
    if (!AttachmentsStore.isValidHash(hash)) return;
    if (_fileTransfers.containsKey(hash)) return; // 已在请求/传输中：去重
    if (_fileSizeRejected.contains(hash)) return; // 超限已拒绝：不重试
    if (await _attachments.exists(hash)) return; // 本地已有：无需请求
    final state = _FileTransferState(
      fileId: hash,
      sourceSessionId: source.id,
      ext: ext,
    );
    _fileTransfers[hash] = state;
    // 请求超时兜底：对端无此文件 / 大小不符 / 被忽略 → 移除，可重试。
    state.timer = Timer(fileRequestTimeout, () {
      _fileTransfers.remove(hash);
    });
    source.sendMessage(FileRequestMessage(fileId: hash, ext: ext).toJson());
  }

  /// 发送侧：收到 file_request → 本地存在该文件 → 分片（64KB → base64）
  /// 逐片发 file_chunk → 最后 file_complete。
  ///
  /// 文件不存在 / expectedSize 与本地大小不符 / expectedSize 超限（>
  /// [AttachmentsStore.maxFileSizeBytes]）→ 忽略（接收方超时放弃，可重试）。
  Future<void> _onFileRequest(
    _PeerSession source,
    String fileId,
    int? expectedSize,
    String? ext,
  ) async {
    if (!source.ready) return;
    if (!AttachmentsStore.isValidHash(fileId)) return;
    if (expectedSize != null &&
        expectedSize > AttachmentsStore.maxFileSizeBytes) {
      return; // 单文件大小上限：超限拒绝
    }
    final file = ext != null && ext.isNotEmpty
        ? await _attachments.resolveFile(
            '${AttachmentsStore.dirName}/$fileId.$ext',
          )
        : await _attachments.resolveByHash(fileId); // 旧对端不带 ext：扫描目录
    if (file == null) return; // 本地无此文件：忽略（接收方超时放弃）
    if (expectedSize != null && expectedSize != await file.length()) {
      return; // 期望大小与本地文件不符：忽略
    }
    final sendKey = '${source.id}:$fileId';
    if (!_fileSendsInFlight.add(sendKey)) return; // 同会话同文件去重
    try {
      final bytes = await file.readAsBytes();
      const chunkSize = 64 * 1024;
      final totalChunks = bytes.isEmpty ? 1 : (bytes.length / chunkSize).ceil();
      for (var i = 0; i < totalChunks; i++) {
        if (!source.isAlive) return; // 会话已断开：中止传输
        final start = i * chunkSize;
        final end = math.min(start + chunkSize, bytes.length);
        source.sendMessage(
          FileChunkMessage(
            fileId: fileId,
            chunkIndex: i,
            totalChunks: totalChunks,
            data: base64Encode(bytes.sublist(start, end)),
          ).toJson(),
        );
        if (fileChunkSendDelay > Duration.zero) {
          await Future<void>.delayed(fileChunkSendDelay);
        }
      }
      source.sendMessage(FileCompleteMessage(fileId: fileId).toJson());
    } finally {
      _fileSendsInFlight.remove(sendKey);
    }
  }

  /// 接收侧：收到 file_chunk → 写入临时文件（首个分片 createTemp，后续
  /// appendChunk）；按 fileId 串行化处理（见 [_fileWriteChains]）。
  Future<void> _onFileChunk(
    _PeerSession source,
    String fileId,
    int chunkIndex,
    int totalChunks,
    String data,
  ) {
    return _runFileWrite(
      fileId,
      () => _appendFileChunk(source, fileId, chunkIndex, totalChunks, data),
    );
  }

  Future<void> _appendFileChunk(
    _PeerSession source,
    String fileId,
    int chunkIndex,
    int totalChunks,
    String data,
  ) async {
    if (!source.ready) return;
    final state = _fileTransfers[fileId];
    if (state == null || state.sourceSessionId != source.id) {
      return;
    }
    if (chunkIndex != state.nextChunkIndex) {
      // 乱序/重复分片（WebSocket 保序下不应发生）：协议违规，中止本次传输。
      await _abortFileTransfer(fileId);
      return;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      await _abortFileTransfer(fileId); // 非法 base64：中止
      return;
    }
    state.nextChunkIndex = chunkIndex + 1;
    state.totalChunks = totalChunks;
    state.receivedBytes += bytes.length;
    if (state.receivedBytes > AttachmentsStore.maxFileSizeBytes) {
      // 单文件大小上限：超限拒绝（不再重试）。
      _fileSizeRejected.add(fileId);
      await _abortFileTransfer(fileId);
      return;
    }
    if (!state.started) {
      state.started = true;
      state.timer?.cancel(); // 已开始接收：请求超时兜底不再适用
      state.timer = null;
      await _attachments.createTemp(fileId);
    }
    await _attachments.appendChunk(fileId, bytes);
  }

  /// 接收侧：收到 file_complete → finalize 校验 sha256 → 成功落盘并通知 UI
  /// （[AttachmentsStore.attachmentReady]）；失败丢弃临时文件（请求已移除，
  /// 后续合并可重新请求）。
  Future<void> _onFileComplete(_PeerSession source, String fileId) {
    return _runFileWrite(fileId, () => _finalizeFile(source, fileId));
  }

  Future<void> _finalizeFile(_PeerSession source, String fileId) async {
    if (!source.ready) return;
    final state = _fileTransfers[fileId];
    if (state == null || state.sourceSessionId != source.id) return;
    state.timer?.cancel();
    _fileTransfers.remove(fileId);
    _fileWriteChains.remove(fileId); // 传输结束：清理串行链
    // finalize 成功：附件就绪事件已由 AttachmentsStore 静态流发出（UI 刷新）；
    // 失败（数据被篡改/不完整）：临时文件已删除，请求已移除——可重新请求。
    await _attachments.finalize(fileId, ext: state.ext);
  }

  /// 中止一次附件传输（乱序/非法载荷/超限）：丢弃临时文件并移除请求状态。
  Future<void> _abortFileTransfer(String fileId) async {
    final state = _fileTransfers.remove(fileId);
    state?.timer?.cancel();
    _fileWriteChains.remove(fileId);
    await _attachments.discardTemp(fileId);
  }

  /// 按 fileId 串行化附件写入（分片顺序追加，见 [_fileWriteChains]）。
  /// 返回的错误已被吞掉的 Future（链上后续 op 照常执行，调用方 await 不抛）。
  Future<void> _runFileWrite(String fileId, Future<void> Function() op) {
    final previous = _fileWriteChains[fileId] ?? Future<void>.value();
    final next = previous.then((_) => op()).catchError((_) {});
    _fileWriteChains[fileId] = next;
    return next;
  }

  /// 会话断开清理（task-30）：移除该会话的附件请求/接收状态并丢弃未完成
  /// 临时文件——重连后全量对齐重新检测缺失再请求。
  void _clearFileTransfersForSession(String sessionId) {
    final aborted = <String>[];
    _fileTransfers.removeWhere((fileId, state) {
      if (state.sourceSessionId != sessionId) return false;
      state.timer?.cancel();
      aborted.add(fileId);
      return true;
    });
    for (final fileId in aborted) {
      _fileWriteChains.remove(fileId);
      unawaited(_attachments.discardTemp(fileId));
    }
  }

  // ===== HMAC 挑战认证工具（v4，task-27） =====

  /// 生成随机 32 字节密钥（hex 编码 64 字符）：配对时接受方生成，经
  /// pairing_accept 交换（每对设备共享一个）。
  String generateSecret() => _randomHex(32);

  /// 生成随机挑战数（32 字节 hex）：每次握手重新生成（防重放）。
  String generateNonce() => _randomHex(32);

  /// 计算 `HMAC-SHA256(secret, message)` 的 hex 编码（64 字符）。
  ///
  /// 密钥以 hex 字符串存储（[generateSecret] 产出），直接以其 UTF-8 字节
  /// 作为 HMAC 密钥（32 字节随机数编码为 64 个 ASCII 字符，任何字节序列
  /// 均可作密钥，等效熵不变）。
  String hmacHex(String secret, String message) {
    final hmac = Hmac(
      sha256,
      utf8.encode(secret),
    ).convert(utf8.encode(message));
    return hmac.toString(); // Digest.toString() 即 hex
  }

  /// 生成 [bytes] 个随机字节的 hex 编码（crypto 安全随机源）。
  String _randomHex(int bytes) {
    final rnd = math.Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// 释放资源（停止服务/连接/发现并关闭事件流）。
  Future<void> dispose() async {
    await _changesSub?.cancel();
    await _folderChangesSub?.cancel();
    await _discoverySub?.cancel();
    await _serverConnectedSub?.cancel();
    await _serverDisconnectedSub?.cancel();
    await disable();
    await _server.dispose();
    await _discovery.dispose();
    await _devicesController.close();
    await _syncCompletedController.close();
    await _pairingController.close();
    await _conflictController.close();
    await _peersController.close();
  }
}

/// 对端地址缓存条目（task-19：deviceId → 最近地址/端口，内存态）。
class _PeerAddress {
  const _PeerAddress(this.address, this.port);

  /// 对端主机地址（如 `192.168.1.5`）。
  final String address;

  /// 对端 WebSocket 服务端口（固定端口，如 [kDefaultSyncPort]）。
  final int port;

  /// 展示用地址（`IP:端口`，同步页设备小字）。
  String get displayName => '$address:$port';
}

/// 附件传输状态（task-30）：一次 file_request → 分片接收 → file_complete
/// 校验落盘的生命周期状态（接收方视角）。
class _FileTransferState {
  _FileTransferState({
    required this.fileId,
    required this.sourceSessionId,
    this.ext,
  });

  /// 附件 hash（sha256 前 16 位，即 `attachments/<fileId>.<ext>` 文件名主体）。
  final String fileId;

  /// 附件扩展名（来自 delta 引用；null = 旧对端不带，落盘回退 .jpg）。
  final String? ext;

  /// 请求来源会话（仅接受该会话的分片/完成消息，防其他会话注入）。
  final String sourceSessionId;

  /// 请求超时定时器（发出 file_request 后 [SyncService.fileRequestTimeout]
  /// 无响应 → 移除请求可重试；收到首个分片后取消）。
  Timer? timer;

  /// 是否已收到首个分片（临时文件已创建；[SyncService.activeFileReceives]）。
  bool started = false;

  /// 下一个期望的分片序号（WebSocket 保序，按序追加）。
  int nextChunkIndex = 0;

  /// 分片总数（最后一片可能不足 64KB）。
  int totalChunks = 0;

  /// 已接收字节数（20MB 上限累计检查）。
  int receivedBytes = 0;
}

/// 对端连接统一句柄：入站（[SyncServerConnection]）或出站（[SyncClient]）。
abstract class _PeerLink {
  /// 会话是否仍存活（连接未彻底关闭/重试未耗尽）。
  bool get isAlive;

  /// 发送一条业务消息。
  void send(Map<String, dynamic> message);

  /// 关闭连接（幂等）。
  Future<void> close();
}

/// 入站连接句柄：对端主动连接本机（本机服务端接受，task-13 大者只接受）。
class _IncomingLink implements _PeerLink {
  _IncomingLink(this.connection);

  final SyncServerConnection connection;

  @override
  bool get isAlive => !connection.isClosed;

  @override
  void send(Map<String, dynamic> message) => connection.send(message);

  @override
  Future<void> close() => connection.close();
}

/// 出站连接句柄：本机主动连接对端（SyncClient 自带心跳与指数退避重连）。
class _OutgoingLink implements _PeerLink {
  _OutgoingLink(this.client);

  final SyncClient client;

  @override
  bool get isAlive => client.state != SyncConnectionState.disconnected;

  @override
  void send(Map<String, dynamic> message) {
    try {
      client.send(message);
    } catch (_) {
      // 发送时连接恰好中断：由传输层重连/握手兜底。
    }
  }

  @override
  Future<void> close() => client.dispose();
}

/// 对端会话配对角色（v4 请求-同意配对，task-27）。
///
/// - [none]：未在配对流程中；
/// - [requester]：本机为请求方——已发 pairing_request，等待对端同意
///   （收到 pairing_accept 后存密钥并确认回发）；
/// - [consenter]：本机为接受方——收到 pairing_request，等待用户同意/拒绝
///   （在配对队列中，UI 弹窗「xx 请求连接」）。
enum _PairingRole { none, requester, consenter }

/// 对端会话：一条与对端设备的连接（入站或出站）及其协议状态机。
///
/// 统一处理 P2P 对称协议（docs/技术架构.md 7.2/7.3 节 v4）：
/// - 出站会话（[isInitiator]）：连接成功后发 hello（携带协议版本 v2）；
///   收到 welcome 后按信任列表决定直接同步（发 sync_request）或反向配对；
/// - 入站会话：收到 hello 后按信任列表回 welcome 或配对流程；
/// - **HMAC 挑战认证（v4）**：对端在信任列表且持有密钥时，验证方发
///   challenge{nonce} → 对端用本地存储的该设备密钥算 HMAC-SHA256 →
///   challenge_response → 验证匹配才 welcome{trusted:true}（防伪装
///   deviceId）；不匹配/无密钥视为未配对；
/// - **配对（v4 请求-同意）**：请求方发 pairing_request → 接受方弹窗
///   「xx 请求连接」→ 同意 → pairing_accept（携带本机生成的 32 字节密钥）
///   → 请求方存入信任列表并确认回发同一密钥 → 双方就绪；拒绝 →
///   pairing_fail → 断开；
/// - 取消配对：收到 unpair → 移除信任 + 断开（双边解除）；
/// - 两类会话统一处理 sync_request / sync_data / note_upsert / note_delete
///   / devices_update。
///
/// 未配对完成的会话不响应 sync_request / 不合并增量（F14）；已就绪
/// （双方互信）才收发笔记数据（F15）。
class _PeerSession {
  _PeerSession({
    required this.id,
    required this.isInitiator,
    required this.link,
    required this.service,
  });

  /// 会话唯一标识（入站 = 服务端连接 id；出站 = out-N）。
  final String id;

  /// 是否为本机主动发起的出站会话（连接去重规范判断依据）。
  final bool isInitiator;

  /// 是否手动发起的连接（task-32：手动连接无条件，hello 携带 manual 标志，
  /// 对端不因 autoConnect 关闭而拒绝）。
  bool manualConnect = false;

  final _PeerLink link;
  final SyncService service;

  // 身份（出站会话创建时已知；入站会话 hello 登记后确认）。
  String? peerDeviceId;
  String? peerName;

  // 信任状态。
  bool _peerTrusted = false; // 本机信任对端（HMAC 验证通过/配对成功）
  bool _peerTrustsMe = false; // 对端信任本机（welcome.trusted / pairing_accept）

  /// 会话是否已就绪（双方互信）：就绪后才同步数据。
  bool get ready =>
      peerDeviceId != null &&
      peerDeviceId != service.deviceId &&
      _peerTrusted &&
      _peerTrustsMe;

  /// 会话是否存活（供连接去重判断）。
  bool get isAlive => link.isAlive;

  /// 配对角色（v4 请求-同意）：none=未在配对；requester=已发请求等待同意；
  /// consenter=收到请求等待用户同意/拒绝（在配对队列中）。
  _PairingRole _pairingRole = _PairingRole.none;

  // HMAC 挑战认证状态（v4）：
  bool _challengeSent = false; // 本机已发 challenge，等待 challenge_response
  String? _challengeNonce; // 本机已发挑战的 nonce（验证响应回显是否匹配）
  Timer? _challengeTimer; // 挑战超时（对端不应答按未配对处理，防会话卡死）

  /// 是否已触发过全量对齐（sync_request）。
  ///
  /// pairing_accept 与 welcome 双路径都会调用 [_onReady]，该标志保证一次
  /// 会话就绪只发起一次全量同步（task-15 去重）；重连/断开时由 [_resetAuth]
  /// 复位，使重新握手后就绪时可再次全量对齐。
  bool _fullSyncTriggered = false;

  bool _closed = false;
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<SyncConnectionState>? _stateSub;

  /// 订阅消息流与（出站）连接状态流。
  void attach() {
    _msgSub = link is _IncomingLink
        ? (link as _IncomingLink).connection.messages.listen(
            (raw) => unawaited(_onMessage(raw)),
            onDone: () => service._onSessionLinkClosed(this),
            cancelOnError: true,
          )
        : (link as _OutgoingLink).client.messages.listen(
            (raw) => unawaited(_onMessage(raw)),
            onDone: () {
              // ignore: avoid_print
              print('[连接监控] 出站消息流 onDone peer=${peerDeviceId ?? 'null'}');
              service._onSessionLinkClosed(this);
            },
            cancelOnError: true,
          );
    if (link is _OutgoingLink) {
      _stateSub = (link as _OutgoingLink).client.stateChanges.listen(
        _onOutgoingState,
      );
    }
  }

  void _onOutgoingState(SyncConnectionState state) {
    // ignore: avoid_print
    print('[连接监控] 出站状态变化 peer=${peerDeviceId ?? 'null'} -> $state');
    if (state == SyncConnectionState.connected) {
      // 连接成功：重新握手（发送 hello、重置认证状态）。
      _resetAuth();
      unawaited(_sendHello());
    } else if (state == SyncConnectionState.disconnected) {
      // 断线：重置认证状态 + 立即清理会话并刷新 UI（task-32）。
      // 架构决策：在线方不主动重连，重连责任在「重新上线的一方」。
      // 此前只 _resetAuth()：心跳被 _stopHeartbeat 停掉、会话残留在
      // _sessions（出站消息流不 close，onDone 不触发）、UI 不刷新——
      // 导致「手机杀后台后 mac 一直显示已连接」。socket 断开即感知。
      _resetAuth();
      service._onSessionLinkClosed(this);
    }
  }

  /// 关闭会话（幂等）：取消订阅并关闭底层连接。
  /// 最后收到对端任何消息的时刻（心跳判离线；任何 inbound 都刷新）。
  DateTime _lastInbound = DateTime.now();

  /// 心跳定时器（ready 后启动；关闭时取消）。
  Timer? _heartbeat;

  /// 启动心跳探活：周期发 ping + 超时判对端失联（强杀/断网无 close 帧）。
  void _startHeartbeat() {
    if (_heartbeat != null) return;
    // ignore: avoid_print
    print(
      '[心跳监控] 心跳启动 peer=${peerDeviceId ?? 'null'} 间隔=${service.heartbeatInterval.inSeconds}s 超时=${service.heartbeatTimeout.inSeconds}s',
    );
    _heartbeat = Timer.periodic(service.heartbeatInterval, (_) {
      try {
        if (_closed) {
          _heartbeat?.cancel();
          return;
        }
        final idle = DateTime.now().difference(_lastInbound);
        // 周期 tick 不打日志（每秒多条刷屏）；仅在失联判定时输出。
        // 超时判定：超过 heartbeatTimeout 未收到对端任何消息 → 失联。
        if (idle > service.heartbeatTimeout) {
          // ignore: avoid_print
          print('[心跳监控] **** 判定对端失联 peer=${peerDeviceId ?? 'null'} ****');
          _heartbeat?.cancel();
          service._onHeartbeatTimeout(this);
          return;
        }
        // 发送 ping 失败（对端已死/连接半开）**必须吞掉**：否则异常会
        // 终止 periodic timer，超时判定随之停止——对端离线就永远检测不到
        //（曾导致：手机离线一夜，mac 仍显示在线）。
        try {
          sendMessage(const PingMessage().toJson());
        } catch (_) {}
      } catch (_) {
        // 任何异常都不允许终止心跳——超时判定必须持续进行。
      }
    });
  }

  /// ready 成立即启动心跳（幂等：_startHeartbeat 有 _heartbeat!=null 守卫）。
  ///
  /// 修复握手时序竞态：_onReady 在 ready 未成立时提前 return，之后对端
  /// sync_request 才补齐信任（_peerTrustsMe=true）——此时若不补调本方法，
  /// 心跳永远不会启动（手机离线 mac 检测不到）。
  void _maybeStartHeartbeatIfReady() {
    // ready 检查是周期路径（每次 sync_request 兜底触发）：静默，
    // 状态变化由 _startHeartbeat 的「心跳启动」日志体现。
    if (ready) {
      _startHeartbeat();
    }
  }

  /// 停止心跳（会话关闭/重连复位）。
  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _challengeTimer?.cancel();
    _heartbeat?.cancel();
    _heartbeat = null;
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    await link.close();
  }

  /// 标记已关闭（服务端断开路径调用；与 [close] 幂等配合）。
  void markClosed() {
    _closed = true;
  }

  /// 重置认证状态（重连/断开时调用；身份信息保留）。
  /// 若本机正作为接受方等待用户同意（在配对队列中），先离开队列并
  /// 通知 UI 取消（连接已断开），再重置认证标志。
  void _resetAuth() {
    if (_pairingRole == _PairingRole.consenter) {
      service._clearActivePairingSession(this);
    }
    _peerTrusted = false;
    _peerTrustsMe = false;
    _pairingRole = _PairingRole.none;
    _challengeSent = false;
    _challengeNonce = null;
    _challengeTimer?.cancel();
    _challengeTimer = null;
    _fullSyncTriggered = false; // 重连后需重新全量对齐（task-15）
    _stopHeartbeat(); // 会话断开：停止心跳（重连握手就绪后重新启动）
  }

  /// 发送一条业务消息（异常吞掉：由重连/握手兜底）。
  void sendMessage(Map<String, dynamic> message) {
    if (_closed) return;
    link.send(message);
  }

  void _send(Map<String, dynamic> message) {
    if (_closed) return;
    try {
      link.send(message);
    } catch (_) {
      // 发送时连接恰好中断：由重连/握手兜底。
    }
  }

  Future<void> _sendHello() async {
    await service._identity.ensureLoaded();
    // hello.trusted 按实际信任状态填充（对端是否在本机信任列表，task-15）：
    // 出站会话创建时即已知对端 deviceId（来自 UDP 广播发现），据此查询；
    // 未知时填 false（兼容旧对端，接收方仍以自己信任列表为准）。
    final peerId = peerDeviceId;
    final trusted = peerId != null && await service._identity.isTrusted(peerId);
    _send(
      HelloMessage(
        deviceId: service.deviceId,
        deviceName: service._safeDeviceName,
        trusted: trusted,
        protocolVersion: kProtocolVersion,
        port: service._server.port, // 对端入站缓存本机地址用（task-32）
        manual: manualConnect, // 手动连接标志（对端据此不拒绝，task-32）
        syncTo: service._syncToByPeerId, // 本机向配置（对端过滤转发/接收用）
      ).toJson(),
    );
  }

  void _sendWelcome({required bool trusted}) {
    _send(
      WelcomeMessage(
        hostName: service._safeDeviceName,
        deviceId: service.deviceId,
        trusted: trusted,
      ).toJson(),
    );
  }

  void _sendSyncRequest() {
    _send(const SyncRequestMessage().toJson());
  }

  /// 更新出站连接目标（IP/端口变化时由发现层调用，task-19 改为
  /// 从地址缓存读取地址后调用）。
  void updateTarget(String host, int port) {
    final outbound = link;
    if (outbound is _OutgoingLink) {
      outbound.client.updateTarget(host, port);
    }
  }

  /// 接受方用户点击「同意」：生成随机 32 字节密钥写入信任列表（本机验证
  /// 对端用），发送 pairing_accept 携带密钥；请求方确认回发同一密钥后双方
  /// 就绪（v4 请求-同意配对）。
  Future<void> acceptConsent() async {
    if (_pairingRole != _PairingRole.consenter || _closed) return;
    final peerId = peerDeviceId;
    if (peerId == null) return;
    final secret = service.generateSecret();
    // 展示名多来源兜底（task-32）：对端 hello 上报空名时从 UDP 通告恢复。
    final displayName = service._peerDisplayName(peerId, sessionName: peerName);
    await service._identity.addTrusted(peerId, displayName, secret: secret);
    await service._refreshTrustedCache();
    _peerTrusted = true; // 用户同意即本机信任对端
    _send(
      PairingAcceptMessage(
        deviceId: service.deviceId,
        deviceName: service._safeDeviceName,
        secret: secret,
      ).toJson(),
    );
    // 等待请求方确认回发 pairing_accept（同一密钥）后进入就绪。
  }

  /// 接受方用户点击「拒绝」：发送 pairing_fail 并断开（请求方提示被拒绝）。
  void rejectConsent() {
    if (_pairingRole != _PairingRole.consenter || _closed) return;
    _send(PairingFailMessage(reason: '对方拒绝了配对请求').toJson());
    _leaveQueueCancelled('配对被拒绝');
    unawaited(service._closeSession(this));
  }

  /// 本机作为**请求方**：向对端发送配对请求（等待同意）。
  void _enterRequester() {
    _pairingRole = _PairingRole.requester;
    _send(
      PairingRequestMessage(
        deviceId: service.deviceId,
        deviceName: service._safeDeviceName,
      ).toJson(),
    );
  }

  /// 本机作为**接受方**进入配对队列（FIFO）：UI 收到 pairing_request 弹窗
  /// 「xx 请求连接」。多对端同时请求时按到达顺序排队（task-14 解决单槽位
  /// 覆盖）。
  void _enterConsenter(String peerId, String peerName) {
    _pairingRole = _PairingRole.consenter;
    if (!service._pairingQueue.contains(this)) {
      service._pairingQueue.add(this);
      service._pairingController.add(
        PairingRequestedEvent(
          deviceId: peerId,
          deviceName: service._safePeerName(peerName, fallback: peerId),
          connectionId: id,
        ),
      );
    }
  }

  /// 配对成功离开队列（不通知 UI 取消；[PairingSucceededEvent] 由调用方发出）。
  void _leaveQueueOnSuccess() {
    _pairingRole = _PairingRole.none;
    service._pairingQueue.remove(this);
  }

  /// 离开队列并通知 UI 该请求已失效（连接断开/用户取消/拒绝）。
  void _leaveQueueCancelled(String reason) {
    _pairingRole = _PairingRole.none;
    service._pairingQueue.remove(this);
    service._pairingController.add(
      PairingCancelledEvent(
        deviceId: peerDeviceId ?? '',
        connectionId: id,
        reason: reason,
      ),
    );
  }

  // ===== 协议状态机（统一处理入站/出站消息）=====

  Future<void> _onMessage(Map<String, dynamic> raw) async {
    _lastInbound = DateTime.now(); // 任何对端消息都刷新（心跳判离线依据）
    final message = SyncMessage.fromJson(raw);
    if (message == null) return;
    // task-32：本机关闭「从对端同步」时，丢弃对端的同步数据
    // （note_upsert/note_delete/sync_data/sync_request）——连接/心跳/配对
    // 消息不受影响（连接永远维持，同步方向各自控制）。
    final peerId = peerDeviceId;
    if (peerId != null &&
        (service._syncFromByPeerId[peerId] ?? true) == false) {
      switch (message) {
        case NoteUpsertMessage() ||
            NoteDeleteMessage() ||
            SyncDataMessage() ||
            SyncRequestMessage():
          return; // 同步数据丢弃
        default:
          break;
      }
    }
    switch (message) {
      case HelloMessage(
        deviceId: final peerId,
        deviceName: final peerName,
        protocolVersion: final protocolVersion,
        port: final peerPort,
        manual: final manualHello,
        syncTo: final peerSyncTo,
      ):
        if (peerSyncTo.isNotEmpty) {
          service._peerSyncToConfigs = {
            ...service._peerSyncToConfigs,
            peerId: peerSyncTo,
          };
        }
        await _onPeerHello(
          peerId,
          peerName,
          protocolVersion,
          peerPort: peerPort,
          manualHello: manualHello,
        );
      case WelcomeMessage(
        deviceId: final peerId,
        hostName: final peerName,
        trusted: final trusted,
      ):
        await _onPeerWelcome(peerId, peerName, trusted);
      case PairingRequestMessage(
        deviceId: final peerId,
        deviceName: final peerName,
      ):
        await _onPairingRequest(peerId, peerName);
      case PairingAcceptMessage(
        deviceId: final id,
        deviceName: final name,
        secret: final secret,
      ):
        await _onPairingAccept(id, name, secret);
      case PairingFailMessage(reason: final reason):
        await _onPairingFail(reason);
      case UnpairMessage(deviceId: final claimedPeerId):
        await service._onUnpairReceived(this, claimedPeerId);
      case ChallengeMessage(nonce: final nonce):
        await _onChallenge(nonce);
      case ChallengeResponseMessage(nonce: final nonce, hmac: final hmac):
        await _onChallengeResponse(nonce, hmac);
      case SyncRequestMessage():
        await _onSyncRequest();
      case SyncDataMessage(
        notes: final notes,
        tombstones: final tombstones,
        folders: final folders,
      ):
        await _onSyncData(notes, tombstones, folders);
      case NoteUpsertMessage(note: final note, origin: final upsertOrigin):
        await _onNoteUpsert(note, upsertOrigin);
      case NoteDeleteMessage(
        id: final id,
        version: final version,
        deletedAt: final deletedAt,
        origin: final deleteOrigin,
      ):
        await _onNoteDelete(id, version, deletedAt, deleteOrigin);
      case FolderUpsertMessage(
        folder: final folder,
        origin: final folderOrigin,
      ):
        await _onFolderUpsert(folder, folderOrigin);
      case DevicesUpdateMessage():
        // P2P：各端设备列表以本机连接表为准（devicesUpdates 由本机
        // 连接表变化驱动），对端广播仅作信息参考，本地忽略。
        break;
      case AutoConnectRejectedMessage(deviceId: final rejectingPeerId):
        // 对端关闭了对本机的自动连接：本机收到被拒通知 → 自动关闭对
        // 该对端的自动连接开关（持久化），避免反复尝试自动连被拒（Q4）。
        await service._onAutoConnectRejected(rejectingPeerId);
        break;
      case SyncConfigMessage(syncTo: final peerConfig):
        // 对端同步方向配置变更：更新缓存（fan-out 转发/接收过滤依据）。
        final fromPeer = peerDeviceId;
        if (fromPeer != null && peerConfig.isNotEmpty) {
          service._peerSyncToConfigs = {
            ...service._peerSyncToConfigs,
            fromPeer: peerConfig,
          };
        }
        break;
      case DisconnectMessage():
        // 对端主动断开（手动断开/关同步）：标记该对端为「手动断开」——
        // 本机不再自动重连它（切前台凭缓存直连也跳过），直到用户手动
        // 恢复（手动连接开关 / connectTrustedPeer 清除标记）。
        final fromPeer = peerDeviceId;
        if (fromPeer != null && fromPeer.isNotEmpty) {
          service._manuallyDisconnected.add(fromPeer);
          service._emitPeers();
        }
        unawaited(service._closeSession(this));
        break;
      case PingMessage():
        // 收到 ping → 回 pong（对端心跳探活）。
        sendMessage(const PongMessage().toJson());
        break;
      case PongMessage():
        // 心跳回执：_lastInbound 已在 _onMessage 入口刷新，无需额外处理。
        break;
      case FileRequestMessage(
        fileId: final fileId,
        expectedSize: final expectedSize,
        ext: final ext,
      ):
        await service._onFileRequest(this, fileId, expectedSize, ext);
      case FileChunkMessage(
        fileId: final fileId,
        chunkIndex: final chunkIndex,
        totalChunks: final totalChunks,
        data: final data,
      ):
        await service._onFileChunk(this, fileId, chunkIndex, totalChunks, data);
      case FileCompleteMessage(fileId: final fileId):
        await service._onFileComplete(this, fileId);
    }
  }

  /// 登记/更新对端身份并做连接去重。返回 false 表示本会话被判定为重复
  /// 连接已关闭，调用方应停止后续处理。
  bool _setPeerIdentity(String peerId, String peerName) {
    if (peerDeviceId != null && peerDeviceId != peerId) {
      service._unregisterPeerId(peerDeviceId, this);
    }
    peerDeviceId = peerId;
    // 关键：参数与字段同名，必须显式 this. 赋字段——否则字段恒 null，
    // 导致已配对列表显示 ID（请求/弹窗用参数名正常，连接后字段空）。
    this.peerName = service._safePeerName(peerName, fallback: peerId);
    return service._registerPeerId(this);
  }

  Future<void> _onPeerHello(
    String peerId,
    String peerName,
    int protocolVersion, {
    int? peerPort,
    // manual 标志保留（协议兼容旧包）；task-32 起 autoConnect 只管本机
    // 是否自动发起连接，不控制是否接受对方——已配对连接无条件接受。
    bool manualHello = false,
  }) async {
    // 入站缓存对端地址（task-32）：从连接对端 IP + hello 携带的监听端口
    // 写入地址缓存——入站方（被连接方）重新上线时可凭缓存直连对方。
    // 旧对端不带 port 时跳过（无法得知对端监听端口）。
    final link = this.link;
    if (link is _IncomingLink && peerPort != null && peerPort > 0) {
      final address = link.connection.remoteAddress?.address;
      if (address != null && address.isNotEmpty) {
        service._cachePeerAddress(peerId, address, peerPort);
      }
    }
    // 设备 ID 冲突：对端 deviceId 与本机相同 → 拒绝该连接并断开（用户需求）。
    if (peerId == service.deviceId) {
      service._reportConflict(
        peerId: peerId,
        peerName: peerName,
        source: 'hello',
      );
      unawaited(service._closeSession(this));
      return;
    }
    if (!_setPeerIdentity(peerId, peerName)) return;
    // 协议版本：v1 旧协议不互连（提示升级后断开，见 docs/技术架构.md 7.3 节）。
    if (protocolVersion < kProtocolVersion) {
      _send(PairingFailMessage(reason: '协议版本不兼容，请升级应用').toJson());
      unawaited(service._closeSession(this));
      return;
    }
    service._emitDevices();
    final secret = await service._identity.getTrustedSecret(peerId);
    if (secret != null && secret.isNotEmpty) {
      // 已配对且持有密钥：HMAC 挑战认证（防伪装 deviceId）。
      _sendChallenge();
    } else {
      // 未命中信任列表 / 无密钥（v3 旧配对升级遗留）：按未配对处理。
      _sendWelcome(trusted: false);
    }
  }

  /// 发送 HMAC 挑战并启动超时兜底（对端 10s 不应答按未配对处理）。
  void _sendChallenge() {
    _challengeSent = true;
    _challengeNonce = service.generateNonce();
    _challengeTimer?.cancel();
    _challengeTimer = Timer(const Duration(seconds: 10), () {
      if (!_challengeSent || _closed) return;
      _challengeSent = false;
      _challengeNonce = null;
      _sendWelcome(trusted: false); // 对端未应答挑战：按未配对处理
    });
    _send(ChallengeMessage(nonce: _challengeNonce!).toJson());
  }

  Future<void> _onPeerWelcome(
    String peerId,
    String peerName,
    bool trusted,
  ) async {
    // 设备 ID 冲突（握手/会话登记）：拒绝并断开。
    if (peerId == service.deviceId) {
      service._reportConflict(
        peerId: peerId,
        peerName: peerName,
        source: 'hello',
      );
      unawaited(service._closeSession(this));
      return;
    }
    if (!_setPeerIdentity(peerId, peerName)) return;
    _peerTrustsMe = trusted;
    if (!trusted) {
      // 对端不信任本机（未配对）：本机作为请求方请求对端同意配对。
      _enterRequester();
      return;
    }
    final secret = await service._identity.getTrustedSecret(peerId);
    _maybeStartHeartbeatIfReady(); // welcome 后可能 ready 已成立（补调兜底）
    if (secret != null && secret.isNotEmpty) {
      // 对端已通过 HMAC 验证本机（welcome{trusted:true}）；本机反向挑战
      // 对端证明其真身（防伪装 welcome 骗取信任），验证通过后进入就绪。
      _sendChallenge();
    } else {
      // 本机不信任对端 / 无密钥：本机作为请求方请求对端同意配对（反向配对）。
      _enterRequester();
    }
  }

  Future<void> _onPairingRequest(String peerId, String peerName) async {
    // 设备 ID 冲突（握手/会话登记）：拒绝并断开。
    if (peerId == service.deviceId) {
      service._reportConflict(
        peerId: peerId,
        peerName: peerName,
        source: 'hello',
      );
      unawaited(service._closeSession(this));
      return;
    }
    // 对端请求连接本机：本机作为接受方进入同意/拒绝队列。
    if (!_setPeerIdentity(peerId, peerName)) return;
    // task-32：pairing_request 名称为空时回退会话已登记的 hello 名称
    // （请求方握手 hello 通常带名；避免弹窗显示 deviceId）。
    final displayName = peerName.trim().isNotEmpty
        ? peerName
        : (this.peerName ?? peerId);
    _enterConsenter(peerId, displayName);
  }

  /// 收到 challenge（对端验证本机）：用本地存储的该设备密钥计算 HMAC 响应。
  Future<void> _onChallenge(String nonce) async {
    if (nonce.isEmpty) return;
    final peerId = peerDeviceId;
    if (peerId == null) return;
    final secret = await service._identity.getTrustedSecret(peerId);
    if (secret == null || secret.isEmpty) return; // 无密钥：无法应答（对端将按未配对处理）
    _send(
      ChallengeResponseMessage(
        nonce: nonce,
        hmac: service.hmacHex(secret, nonce),
      ).toJson(),
    );
  }

  /// 收到 challenge_response（本机验证对端）：比对 HMAC，匹配才 welcome
  /// {trusted:true}；不匹配视为未配对（防伪装 deviceId）。
  Future<void> _onChallengeResponse(String nonce, String hmac) async {
    if (!_challengeSent || _challengeNonce != nonce) return; // 非预期响应：忽略
    _challengeSent = false;
    _challengeNonce = null;
    _challengeTimer?.cancel();
    _challengeTimer = null;
    final peerId = peerDeviceId;
    if (peerId == null) return;
    final secret = await service._identity.getTrustedSecret(peerId);
    if (secret == null || secret.isEmpty) {
      _sendWelcome(trusted: false);
      return;
    }
    final expected = service.hmacHex(secret, nonce);
    if (hmac == expected) {
      // 真身（持有配对时交换的密钥）：放行。
      _peerTrusted = true;
      _sendWelcome(trusted: true);
      // 若本机此前已收到 welcome{trusted:true}（反向挑战场景），在验证
      // 通过后直接进入就绪（_onPeerWelcome 已设置 _peerTrustsMe）。
      _onReady();
      service._emitDevices();
    } else {
      // 伪造密钥/伪装 deviceId：视为未配对。
      _peerTrusted = false;
      _sendWelcome(trusted: false);
    }
  }

  /// 收到 pairing_accept：请求方存密钥并确认回发；接受方幂等刷新密钥。
  ///
  /// 仅当本机处于配对流程（requester 或 consenter）时处理——防止对端
  /// 单方面伪造 accept 把自己写入本机信任列表（task-15 角色守卫语义）。
  Future<void> _onPairingAccept(
    String peerId,
    String peerName,
    String secret,
  ) async {
    // 设备 ID 冲突（握手/会话登记）：拒绝并断开。
    if (peerId == service.deviceId) {
      service._reportConflict(
        peerId: peerId,
        peerName: peerName,
        source: 'hello',
      );
      unawaited(service._closeSession(this));
      return;
    }
    if (!_setPeerIdentity(peerId, peerName)) return;
    if (secret.isEmpty) return;
    // 信任写入用会话登记的 peerDeviceId（消息载荷可伪造，会话身份由握手
    // hello 登记并经连接去重确认，是权威来源）。
    final trustedPeerId = peerDeviceId!;
    // 展示名多来源兜底（task-32）：pairing_accept 上报空名时回退会话名/通告名。
    final trustedPeerName = service._peerDisplayName(
      trustedPeerId,
      trustedName: peerName.isNotEmpty ? peerName : null,
      sessionName: this.peerName,
    );
    switch (_pairingRole) {
      case _PairingRole.requester:
        // 请求方收到接受方的 pairing_accept：存密钥 + 确认回发同一密钥
        // （每对设备共享一个密钥），进入就绪。
        await service._identity.addTrusted(
          trustedPeerId,
          trustedPeerName,
          secret: secret,
        );
        await service._refreshTrustedCache();
        _peerTrusted = true;
        _peerTrustsMe = true; // accept 即对端同意并信任本机
        service._pairingController.add(
          PairingSucceededEvent(
            deviceId: trustedPeerId,
            deviceName: trustedPeerName,
          ),
        );
        _send(
          PairingAcceptMessage(
            deviceId: service.deviceId,
            deviceName: service._safeDeviceName,
            secret: secret, // 确认回发同一密钥（共享密钥语义）
          ).toJson(),
        );
        _onReady();
        service._emitDevices();
      case _PairingRole.consenter:
        // 接受方收到请求方的确认回发：幂等刷新密钥，进入就绪。
        await service._identity.setTrustedSecret(trustedPeerId, secret);
        await service._refreshTrustedCache();
        _peerTrustsMe = true; // 确认回发 = 请求方已接受配对
        _leaveQueueOnSuccess();
        service._pairingController.add(
          PairingSucceededEvent(
            deviceId: trustedPeerId,
            deviceName: trustedPeerName,
          ),
        );
        _onReady();
        service._emitDevices();
      case _PairingRole.none:
        return; // 未请求配对的对端单方面 accept：忽略（防伪造）。
    }
  }

  Future<void> _onPairingFail(String reason) async {
    // 本机作为请求方被拒绝（对端为接受方）：提示原因并断开。
    service._pairingController.add(
      PairingFailedEvent(
        deviceId: peerDeviceId ?? '',
        connectionId: id,
        reason: reason,
      ),
    );
    _pairingRole = _PairingRole.none;
    unawaited(service._closeSession(this));
  }

  Future<void> _onSyncRequest() async {
    // 对端发来 sync_request 即视为对端已信任本机。
    _peerTrustsMe = true;
    _maybeStartHeartbeatIfReady(); // ready 可能在此成立：兜底启动心跳（幂等）
    // ready 可能在此翻转（接受方：信任来自 hello、对端信任来自 sync_request）：
    // 统一刷新 peerList，修复接受方同步页长期显示“连接中”的问题（task-15）。
    service._emitPeers();
    if (!ready) return; // 本机未信任对端（未配对）：不响应（F14）。
    // task-32：向对端同步开关关闭 → 不响应全量推送（方向由开关控制）。
    final peerId = peerDeviceId;
    if (peerId != null && (service._syncToByPeerId[peerId] ?? true) == false) {
      return;
    }
    await _sendFullSnapshot();
  }

  /// 发送本机全量快照（响应 sync_request / 打开「向此设备同步」主动推）。
  Future<void> _sendFullSnapshot() async {
    if (!ready) return;
    // 全量快照：笔记（含回收站条目，deletedAt 非空即软删除）+ 墓碑列表
    // + 文件夹（含软删除条目，task-32 v6）——对端先写墓碑再合并笔记/
    // 文件夹，防离线旧数据复活（docs/技术架构.md 7.2 节）。
    // 仅本机保存的笔记在快照里只带标记（空标题/正文）：对端据此删除
    // 自己的副本，内容不离开本机。
    final notes = (await service._repository.getAll())
        .map((n) => n.syncPayload)
        .toList();
    final tombstones = await service._repository.getAllTombstones();
    final folders = await service._folderRepository?.getAll() ?? const [];
    _send(
      SyncDataMessage(
        notes: notes,
        tombstones: tombstones
            .map(
              (t) => Tombstone(
                id: t.id,
                version: t.version,
                deletedAt: t.deletedAt,
              ),
            )
            .toList(),
        folders: folders,
      ).toJson(),
    );
  }

  Future<void> _onSyncData(
    List<Note> notes,
    List<Tombstone> tombstones,
    List<Folder> folders,
  ) async {
    if (!ready) return; // 未配对前忽略数据（F14）。
    // 合并顺序（docs/技术架构.md 7.4 节 v3 修订）：先处理墓碑（写本地墓碑
    // + 拦截被墓碑覆盖的本地旧数据），再合并笔记——保证快照中携带的
    // 清空记录先落地，回收站条目/旧数据不会把已清空的笔记复活。
    for (final tombstone in tombstones) {
      await service._repository.mergeRemoteTombstone(
        id: tombstone.id,
        version: tombstone.version,
        deletedAt: tombstone.deletedAt,
      );
    }
    // 文件夹全量合并（task-32 v6）：LWW 各自裁决（无墓碑，软删除语义），
    // 逐条按 origin 过滤「从该设备同步」（同笔记语义）。
    final folderRepo = service._folderRepository;
    if (folderRepo != null) {
      for (final folder in folders) {
        final authorId = (folder.origin != null && folder.origin!.isNotEmpty)
            ? folder.origin!
            : peerDeviceId;
        if (authorId != null &&
            (service._syncFromByPeerId[authorId] ?? true) == false) {
          continue;
        }
        if (authorId != null &&
            !service._originAllowsTo(authorId, service.deviceId)) {
          continue;
        }
        await folderRepo.mergeRemoteFolder(folder);
      }
    }
    for (final note in notes) {
      // task-32 v5：全量快照逐条按笔记 origin 过滤「从该设备同步」——
      // origin 空（旧数据/本机）时回退按来源会话检查。A 关「从 C」后，
      // B 全量里 origin=C 的笔记被 A 跳过。
      final authorId = (note.origin != null && note.origin!.isNotEmpty)
          ? note.origin!
          : peerDeviceId;
      // 仅本机保存的标记通知**不过滤**：它是让本机删掉副本的指令，与
      // 「从该设备同步」开关无关（关掉开关反而不该留着对方的私有内容）。
      if (!note.localOnly &&
          authorId != null &&
          (service._syncFromByPeerId[authorId] ?? true) == false) {
        continue;
      }
      if (!note.localOnly &&
          authorId != null &&
          !service._originAllowsTo(authorId, service.deviceId)) {
        continue;
      }
      await service._repository.mergeRemoteNote(note);
      // 图片缺失检测（task-30）：全量对齐后对快照中的每条笔记检查附件，
      // 本地缺失 → 自动 file_request（重连/超时后重试路径依赖此检测）。
      await service._requestMissingAttachmentsForContent(note.content, this);
    }
    // 双向对齐：合并对端全量后，把本机全部笔记回推对端（LWW 合并、
    // 幂等且不经 changes 通道，无回声），并同步本机墓碑（note_delete，
    // 对端按防乱序语义物理删除/补墓碑）。使本机离线期间新建/修改/清空
    // 的笔记也能到达对端（F8 双向数据一致）。
    final localNotes = await service._repository.getAll();
    for (final note in localNotes) {
      // task-32 v5：回推 origin = 数据作者（note.origin；转发来的数据
      // origin 不是本机，必须保留——否则对端按发送方过滤会漏）。
      // 仅本机保存：回推同样只带标记（对端据此删除自己的副本）。
      _send(
        NoteUpsertMessage(
          note: note.syncPayload,
          origin: note.origin ?? service.deviceId,
        ).toJson(),
      );
    }
    final localTombstones = await service._repository.getAllTombstones();
    for (final tombstone in localTombstones) {
      _send(
        NoteDeleteMessage(
          id: tombstone.id,
          version: tombstone.version,
          deletedAt: tombstone.deletedAt,
          origin: service.deviceId,
        ).toJson(),
      );
    }
    // 双向对齐（task-32 v6）：本机全部文件夹回推对端（含软删除条目，
    // 对端 LWW 合并维持各端文件夹状态一致）。
    if (folderRepo != null) {
      final localFolders = await folderRepo.getAll();
      for (final folder in localFolders) {
        _send(
          FolderUpsertMessage(
            folder: folder,
            origin: folder.origin ?? service.deviceId,
          ).toJson(),
        );
      }
    }
    service._markSyncCompleted();
  }

  /// 远端文件夹增/改推送处理（task-32 v6）：镜像 [NoteUpsertMessage] 链路
  /// ——origin 过滤 → [FolderRepository.mergeRemoteFolder]（LWW）→ 实际变更
  /// 才 fan-out 转发（未变更即回声丢弃，消息链收敛）。
  Future<void> _onFolderUpsert(Folder folder, String origin) async {
    if (!ready) return;
    final folderRepo = service._folderRepository;
    if (folderRepo == null) return;
    // task-32 v5 语义：按原始作者检查「从该设备同步」与「向」开关。
    final authorId = (folder.origin != null && folder.origin!.isNotEmpty)
        ? folder.origin!
        : (origin.isNotEmpty ? origin : peerDeviceId);
    if (authorId != null &&
        (service._syncFromByPeerId[authorId] ?? true) == false) {
      return;
    }
    if (authorId != null &&
        !service._originAllowsTo(authorId, service.deviceId)) {
      return;
    }
    final changed = await folderRepo.mergeRemoteFolder(folder);
    if (!changed) return; // 未实际变更本地（重复/过期消息）：丢弃
    service._fanOutToOthers(
      FolderUpsertMessage(folder: folder, origin: origin).toJson(),
      this,
    );
    service._markSyncCompleted();
  }

  Future<void> _onNoteUpsert(Note note, String origin) async {
    if (!ready) return;
    // task-32 v5：按原始作者检查「从该设备同步」——优先用笔记持久化的
    // origin（数据作者；全量回推时消息 origin 可能被发送方覆盖），回退
    // 消息 origin/来源会话。
    final authorId = (note.origin != null && note.origin!.isNotEmpty)
        ? note.origin!
        : (origin.isNotEmpty ? origin : peerDeviceId);
    // ignore: avoid_print
    print(
      '[增量接收] note=${note.id} origin=$authorId 来源会话=$peerDeviceId 从$authorId开关=${service._syncFromByPeerId[authorId] ?? true}',
    );
    // 仅本机保存的标记通知不过滤开关（同全量快照：它是删副本的指令）。
    if (!note.localOnly &&
        authorId != null &&
        (service._syncFromByPeerId[authorId] ?? true) == false) {
      return;
    }
    // v5：origin 设备对本机的「向」开关——关则丢弃（A 关「向本机」时，
    // 即使经 C 转发也不接收 A 的数据）。
    if (!note.localOnly &&
        authorId != null &&
        !service._originAllowsTo(authorId, service.deviceId)) {
      return;
    }
    final changed = await service._repository.mergeRemoteNote(note);
    // 图片缺失检测（task-30）：无论是否实际变更本地都执行——重复/回声消息
    // 也可能携带本地仍缺失的附件引用（上次请求超时/校验失败后的重试路径）。
    await service._requestMissingAttachmentsForContent(note.content, this);
    if (!changed) return; // 未实际变更本地（重复/过期消息）：丢弃，消息链收敛
    // 多向广播（task-15）：仅当合并实际变更本地时才转发给其他已就绪对端；
    // 未变更即回声（消息已在 mesh 中传播过），转发会形成无限中继循环。
    // v5：转发保留原始 origin（作者不变），接收方按 origin 过滤。
    service._fanOutToOthers(
      NoteUpsertMessage(note: note, origin: origin).toJson(),
      this,
    );
    service._markSyncCompleted();
  }

  Future<void> _onNoteDelete(
    String id,
    int version,
    int? deletedAt,
    String origin,
  ) async {
    if (!ready) return;
    // task-32 v5：按原始作者检查「从该设备同步」（fan-out 转发场景）。
    final authorId = origin.isNotEmpty ? origin : peerDeviceId;
    if (authorId != null &&
        (service._syncFromByPeerId[authorId] ?? true) == false) {
      return;
    }
    // v5：origin 设备对本机的「向」开关（同 upsert）。
    if (authorId != null &&
        !service._originAllowsTo(authorId, service.deviceId)) {
      return;
    }
    final changed = await service._repository.mergeRemoteDelete(
      id: id,
      version: version,
      deletedAt: deletedAt,
    );
    if (!changed) return; // 未实际变更本地（已删/乱序过期）：丢弃，消息链收敛
    // 删除同样多向广播（task-15）：仅实际删除时才转发（携带原始 version
    // 与删除时间，防乱序/时间裁决语义不变）；v5 转发保留 origin。
    service._fanOutToOthers(
      NoteDeleteMessage(
        id: id,
        version: version,
        deletedAt: deletedAt,
        origin: origin,
      ).toJson(),
      this,
    );
    service._markSyncCompleted();
  }

  /// 会话就绪（双方互信）：刷新设备列表并发起全量对齐。
  ///
  /// 去重（task-15）：pairing_ok 与 welcome 双路径都会触发本方法，
  /// [_fullSyncTriggered] 保证一次会话就绪只发起一次 sync_request；
  /// ready 翻转时统一刷新 peerList（含未就绪时的中间态刷新）。
  void _onReady() {
    service._emitPeers(); // ready 翻转/中间态：统一刷新设备列表状态
    // task-32：存量信任条目存了 ID（旧包配对/对端空名）时，用会话名刷新。
    unawaited(_refreshTrustedNameIfId());
    if (!ready || _fullSyncTriggered) return;
    _fullSyncTriggered = true;
    _startHeartbeat(); // 会话就绪：启动心跳探活（离线检测）
    service._emitDevices();
    // task-32：连接建立时按方向开关拉取——「从此设备同步」开才发
    // sync_request（对端是否响应受其「向本机同步」开关控制）。
    final peerId = peerDeviceId;
    if (peerId != null && (service._syncFromByPeerId[peerId] ?? true)) {
      _sendSyncRequest();
    }
  }

  /// 信任列表条目名是 ID（等于 deviceId 或空）时，用会话登记的 peerName
  /// 刷新——修复「已配对设备显示 ID」（task-32：存量数据 + 对端空名兜底）。
  Future<void> _refreshTrustedNameIfId() async {
    final peerId = peerDeviceId;
    if (peerId == null) return;
    final trusted = service._trustedCache
        .where((t) => t.deviceId == peerId)
        .firstOrNull;
    if (trusted == null) return;
    final stored = trusted.deviceName.trim();
    final sessionName = (peerName ?? '').trim();
    if ((stored.isEmpty || stored == peerId) &&
        sessionName.isNotEmpty &&
        sessionName != peerId) {
      await service._identity.updateTrustedName(peerId, sessionName);
      await service._refreshTrustedCache();
      service._emitPeers();
    }
  }
}
