import '../data/note.dart';

/// 协议版本（v4 图片跨设备同步，task-30）：通告（UDP JSON `v` 字段）与
/// hello 均携带。
///
/// 版本沿革：v1（mDNS 时代）→ v2（task-27 配对协议 v4：请求-同意 + HMAC
/// 挑战认证）→ v3（task-29 富文本：Note.content 格式由纯文本改为 delta
/// JSON 字符串）→ **v4（task-30 图片跨设备同步：新增 file_request /
/// file_chunk / file_complete 文件传输消息）**。
///
/// 版本不兼容（对端协议版本 < 本值，含 v3 无图片同步对端）时不互连：通告
/// 版本不符被接收端忽略；hello 携带的版本低于本值时，接收方回
/// [PairingFailMessage]（原因「协议版本不兼容，请升级应用」）后断开
/// （见 docs/技术架构.md 7.3 节）。
const int kProtocolVersion = 4;

/// 同步协议消息（docs/技术架构.md 7.2 节消息协议表）。
///
/// 所有消息均为 JSON 对象，统一携带 `type` 字段判别类型；
/// 经 [SyncMessage.fromJson] 按 type 分发反序列化。未知类型或载荷
/// 非法的消息返回 null，接收方忽略该消息（对端畸形数据不导致崩溃）。
sealed class SyncMessage {
  const SyncMessage();

  /// 消息类型（与协议表 `type` 字段一致）。
  String get type;

  /// 序列化为 JSON Map（传输层 jsonEncode 后写入 WebSocket）。
  Map<String, dynamic> toJson();

  /// 反序列化：按 `type` 分发；未知类型或载荷非法返回 null。
  static SyncMessage? fromJson(Map<String, dynamic> json) {
    try {
      return switch (json['type']) {
        'hello' => HelloMessage.fromJson(json),
        'welcome' => WelcomeMessage.fromJson(json),
        'pairing_request' => PairingRequestMessage.fromJson(json),
        'pairing_accept' => PairingAcceptMessage.fromJson(json),
        'pairing_fail' => PairingFailMessage.fromJson(json),
        'unpair' => UnpairMessage.fromJson(json),
        'disconnect' => const DisconnectMessage(),
        'challenge' => ChallengeMessage.fromJson(json),
        'challenge_response' => ChallengeResponseMessage.fromJson(json),
        'sync_request' => const SyncRequestMessage(),
        'sync_data' => SyncDataMessage.fromJson(json),
        'note_upsert' => NoteUpsertMessage.fromJson(json),
        'note_delete' => NoteDeleteMessage.fromJson(json),
        'devices_update' => DevicesUpdateMessage.fromJson(json),
        'auto_connect_rejected' => AutoConnectRejectedMessage.fromJson(json),
        'file_request' => FileRequestMessage.fromJson(json),
        'file_chunk' => FileChunkMessage.fromJson(json),
        'file_complete' => FileCompleteMessage.fromJson(json),
        'ping' => const PingMessage(),
        'pong' => const PongMessage(),
        _ => null,
      };
    } catch (_) {
      // 载荷字段缺失/类型不符：忽略该消息。
      return null;
    }
  }
}

/// 客户端握手消息（C→H）：向主机登记设备。
///
/// [trusted] 为发送方对接收方的信任判断（信息性字段，兼容 P2P 对称握手
/// 双方互发 hello 的语义）；接收方是否放行以**自己的**信任列表为准。
/// [protocolVersion] 为协议版本（v4 起为 [kProtocolVersion]；旧对端缺省 1）。
class HelloMessage extends SyncMessage {
  const HelloMessage({
    required this.deviceId,
    required this.deviceName,
    this.trusted = false,
    this.protocolVersion = kProtocolVersion,
    this.port,
  });

  /// 客户端设备 ID。
  final String deviceId;

  /// 客户端设备名（展示用）。
  final String deviceName;

  /// 发送方是否信任接收方（缺省 false，兼容旧对端）。
  final bool trusted;

  /// 协议版本（缺省 [kProtocolVersion]；旧对端不带该字段 → 1）。
  final int protocolVersion;

  /// 发送方 WebSocket 监听端口（task-32：入站方收到 hello 后缓存对端
  /// ip:port，重新上线时凭缓存直连；旧对端不带该字段 → null）。
  final int? port;

  @override
  String get type => 'hello';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'trusted': trusted,
    'protocolVersion': protocolVersion,
    if (port != null) 'port': port,
  };

  factory HelloMessage.fromJson(Map<String, dynamic> json) => HelloMessage(
    deviceId: json['deviceId'] as String,
    deviceName: (json['deviceName'] as String?) ?? '',
    trusted: (json['trusted'] as bool?) ?? false,
    protocolVersion: (json['protocolVersion'] as int?) ?? 1,
    port: (json['port'] as num?)?.toInt(),
  );
}

/// 主机确认握手消息（H→C）：告知主机身份与信任状态，随后客户端发起全量同步。
///
/// [trusted] = 对端（主机）是否在**本机**信任列表中：true 时客户端直接进入
/// 同步流程；false 时按 docs/技术架构.md 7.3 节进入配对流程。
class WelcomeMessage extends SyncMessage {
  const WelcomeMessage({
    required this.hostName,
    required this.deviceId,
    this.trusted = false,
  });

  /// 主机设备名。
  final String hostName;

  /// 主机设备 ID。
  final String deviceId;

  /// 对端是否在本地信任列表（缺省 false，兼容旧对端）。
  final bool trusted;

  @override
  String get type => 'welcome';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'hostName': hostName,
    'deviceId': deviceId,
    'trusted': trusted,
  };

  factory WelcomeMessage.fromJson(Map<String, dynamic> json) => WelcomeMessage(
    hostName: (json['hostName'] as String?) ?? '',
    deviceId: json['deviceId'] as String,
    trusted: (json['trusted'] as bool?) ?? false,
  );
}

/// 配对请求（双向）：请求方主动向对端请求**同意连接**（v4 去密码，
/// 用户确认方案，见 docs/技术架构.md 7.3 节）。
///
/// 载荷为发送方（请求方）自身身份；接收方弹窗「xx 请求连接」，用户点
/// 「同意」→ 回 [PairingAcceptMessage]（携带本机生成的认证密钥）；点
/// 「拒绝」→ 回 [PairingFailMessage]。
class PairingRequestMessage extends SyncMessage {
  const PairingRequestMessage({
    required this.deviceId,
    required this.deviceName,
  });

  /// 请求方设备 ID。
  final String deviceId;

  /// 请求方设备名（展示用）。
  final String deviceName;

  @override
  String get type => 'pairing_request';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'deviceId': deviceId,
    'deviceName': deviceName,
  };

  factory PairingRequestMessage.fromJson(Map<String, dynamic> json) =>
      PairingRequestMessage(
        deviceId: json['deviceId'] as String,
        deviceName: (json['deviceName'] as String?) ?? '',
      );
}

/// 配对同意（双向）：对端同意配对请求，携带**本机生成的认证密钥**。
///
/// 流程（docs/技术架构.md 7.3 节 v4）：接受方生成随机 32 字节密钥 K 并
/// 随本消息发送；请求方将 K 存入信任列表（接受方条目）后**确认回发同一
/// 密钥**（另一条 pairing_accept，载荷不变），接受方幂等刷新——双方以
/// 同一密钥完成 HMAC 挑战认证（每对设备共享一个密钥；实现要点见 7.3）。
class PairingAcceptMessage extends SyncMessage {
  const PairingAcceptMessage({
    required this.deviceId,
    required this.deviceName,
    required this.secret,
  });

  /// 发送方设备 ID。
  final String deviceId;

  /// 发送方设备名（展示用）。
  final String deviceName;

  /// HMAC 认证密钥（32 字节随机，hex 编码，每对设备共享一个）。
  final String secret;

  @override
  String get type => 'pairing_accept';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'secret': secret,
  };

  factory PairingAcceptMessage.fromJson(Map<String, dynamic> json) =>
      PairingAcceptMessage(
        deviceId: json['deviceId'] as String,
        deviceName: (json['deviceName'] as String?) ?? '',
        secret: (json['secret'] as String?) ?? '',
      );
}

/// 配对失败（双向）：对方拒绝配对请求 / 协议版本不兼容等。
class PairingFailMessage extends SyncMessage {
  const PairingFailMessage({required this.reason});

  /// 失败原因（如「对方拒绝了配对请求」/「协议版本不兼容，请升级应用」）。
  final String reason;

  @override
  String get type => 'pairing_fail';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'reason': reason};

  factory PairingFailMessage.fromJson(Map<String, dynamic> json) =>
      PairingFailMessage(reason: (json['reason'] as String?) ?? '配对被拒绝');
}

/// 取消配对通知（双向，task-27 v4 双边解除）：任一方取消配对时发送。
///
/// 载荷为发送方（取消方）自身 deviceId；接收方据此移除对该发送方的信任
/// 并断开连接——双边不残留（见 docs/技术架构.md 7.3 节）。
class UnpairMessage extends SyncMessage {
  const UnpairMessage({required this.deviceId});

  /// 取消方设备 ID。
  final String deviceId;

  @override
  String get type => 'unpair';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'deviceId': deviceId};

  factory UnpairMessage.fromJson(Map<String, dynamic> json) =>
      UnpairMessage(deviceId: (json['deviceId'] as String?) ?? '');
}

/// HMAC 挑战（握手认证，v4）：验证方（hello 接收方）在对端位于信任列表
/// 且持有密钥时发出，对端须用本地存储的该设备密钥计算 HMAC-SHA256 响应。
class ChallengeMessage extends SyncMessage {
  const ChallengeMessage({required this.nonce});

  /// 随机挑战数（32 字节随机 hex；防重放，每次握手重新生成）。
  final String nonce;

  @override
  String get type => 'challenge';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'nonce': nonce};

  factory ChallengeMessage.fromJson(Map<String, dynamic> json) =>
      ChallengeMessage(nonce: (json['nonce'] as String?) ?? '');
}

/// HMAC 挑战响应（握手认证，v4）：对端计算 `HMAC-SHA256(secret, nonce)`
/// 返回；验证方比对一致才 welcome{trusted:true}（防伪装 deviceId）。
class ChallengeResponseMessage extends SyncMessage {
  const ChallengeResponseMessage({required this.nonce, required this.hmac});

  /// 回显挑战的 nonce（防错配）。
  final String nonce;

  /// HMAC-SHA256 计算结果（hex 编码，64 字符）。
  final String hmac;

  @override
  String get type => 'challenge_response';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'nonce': nonce,
    'hmac': hmac,
  };

  factory ChallengeResponseMessage.fromJson(Map<String, dynamic> json) =>
      ChallengeResponseMessage(
        nonce: (json['nonce'] as String?) ?? '',
        hmac: (json['hmac'] as String?) ?? '',
      );
}

/// 全量同步请求（C→H）：握手完成后 / 用户手动「立即同步」时发送。
class SyncRequestMessage extends SyncMessage {
  const SyncRequestMessage();

  @override
  String get type => 'sync_request';

  @override
  Map<String, dynamic> toJson() => {'type': type};
}

/// 墓碑（协议载荷，docs/技术架构.md 3.3 节）：物理删除（清空）后留下的
/// 删除标记，随全量同步快照（sync_data）交换，对端据此拦截过期数据防复活。
///
/// 与数据层 drift 生成的 `Tombstone`（database.g.dart）字段同构
/// （id/version/deletedAt）；协议层独立定义以保持消息模型自洽，
/// SyncService 在组装/解析 sync_data 时与仓库层互相转换。
class Tombstone {
  const Tombstone({
    required this.id,
    required this.version,
    required this.deletedAt,
  });

  /// 被物理删除的笔记 id。
  final String id;

  /// 删除时刻的笔记 version：拦截判断——远端笔记 version > 该值才允许
  /// 复活（合并规则：version 大者胜 → 相等比操作时间 → 平局删除优先）。
  final int version;

  /// 物理删除时刻（epoch ms）：version 相等时与笔记操作时间比较裁决。
  final int deletedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'version': version,
    'deletedAt': deletedAt,
  };

  factory Tombstone.fromJson(Map<String, dynamic> json) => Tombstone(
    id: json['id'] as String,
    version: json['version'] as int,
    deletedAt: json['deletedAt'] as int,
  );
}

/// 全量快照（双向，响应 sync_request）：携带本端全部笔记（含回收站条目）
/// 与全部墓碑，对端按 v3 合并规则处理（docs/技术架构.md 7.2 节）。
///
/// 墓碑先行：对端先处理 tombstones（写本地墓碑/拦截被覆盖的本地旧数据），
/// 再合并 notes（含 deletedAt 非空的回收站条目），保证清空过的笔记不会
/// 被快照中的旧数据复活。
class SyncDataMessage extends SyncMessage {
  const SyncDataMessage({required this.notes, this.tombstones = const []});

  /// 全量笔记列表（含回收站条目，deletedAt 非空即软删除）。
  final List<Note> notes;

  /// 全量墓碑列表（缺省空列表，兼容旧对端——旧对端不携带该字段）。
  final List<Tombstone> tombstones;

  @override
  String get type => 'sync_data';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'notes': notes.map((note) => note.toJson()).toList(),
    'tombstones': tombstones.map((t) => t.toJson()).toList(),
  };

  factory SyncDataMessage.fromJson(Map<String, dynamic> json) {
    final notes = <Note>[];
    final rawNotes = json['notes'];
    if (rawNotes is List) {
      for (final raw in rawNotes) {
        if (raw is Map<String, dynamic>) {
          notes.add(Note.fromJson(raw));
        }
      }
    }
    // 旧对端的 sync_data 无 tombstones 字段：缺省空列表，正常解析。
    final tombstones = <Tombstone>[];
    final rawTombstones = json['tombstones'];
    if (rawTombstones is List) {
      for (final raw in rawTombstones) {
        if (raw is Map<String, dynamic>) {
          tombstones.add(Tombstone.fromJson(raw));
        }
      }
    }
    return SyncDataMessage(notes: notes, tombstones: tombstones);
  }
}

/// 笔记增/改推送（双向）：携带完整笔记（含递增后的 version）。
class NoteUpsertMessage extends SyncMessage {
  const NoteUpsertMessage({required this.note});

  /// 变更后的完整笔记。
  final Note note;

  @override
  String get type => 'note_upsert';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'note': note.toJson()};

  factory NoteUpsertMessage.fromJson(Map<String, dynamic> json) =>
      NoteUpsertMessage(
        note: Note.fromJson(json['note'] as Map<String, dynamic>),
      );
}

/// 删除推送（双向）：携带删除时刻的 version，对端校验后删除
/// （防乱序，见 docs/技术架构.md 3.3 节）。
///
/// v3 修订（task-21）：新增可选 [deletedAt]（删除/清空时刻）——全量同步
/// 反向回推墓碑与增量清空推送携带它，使对端在同 version 时按统一比较器
/// 做时间裁决（本地操作时间更新则保留复活，否则删除）；旧对端不携带该
/// 字段（null）时退化为「同 version 删除优先」旧语义。
class NoteDeleteMessage extends SyncMessage {
  const NoteDeleteMessage({
    required this.id,
    required this.version,
    this.deletedAt,
  });

  /// 被删除笔记的 ID。
  final String id;

  /// 删除时刻的本地 version。
  final int version;

  /// 删除/清空时刻（epoch ms，可选）：时间裁决用（见类注释）。
  final int? deletedAt;

  @override
  String get type => 'note_delete';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'version': version,
    if (deletedAt != null) 'deletedAt': deletedAt,
  };

  factory NoteDeleteMessage.fromJson(Map<String, dynamic> json) =>
      NoteDeleteMessage(
        id: json['id'] as String,
        version: json['version'] as int,
        deletedAt: json['deletedAt'] as int?,
      );
}

/// 设备信息：hello 登记内容，也是 devices_update 的载荷元素。
class DeviceInfo {
  const DeviceInfo({required this.deviceId, required this.deviceName});

  /// 设备 ID（hello 登记）。
  final String deviceId;

  /// 设备名（hello 登记）。
  final String deviceName;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    deviceId: json['deviceId'] as String,
    deviceName: (json['deviceName'] as String?) ?? '',
  );
}

/// 文件请求（图片跨设备同步，v4，task-30）：接收方在笔记合并后解析出
/// delta content 中的图片引用（`attachments/<hash>.jpg`），本地不存在该
/// 附件时向**来源会话**发送本消息请求传输。
///
/// [fileId] 为附件内容寻址 hash（sha256 前 16 位，即附件文件名主体）；
/// [expectedSize] 为期望的文件字节数（**接收方请求时通常未知**，发 null
/// = 不限）。发送方收到后校验：本地存在该文件 && （expectedSize 为 null 或
/// 与本地文件大小一致）才分片响应；文件不存在 / 大小不符 / 超限（>
/// [AttachmentsStore.maxFileSizeBytes]）→ 忽略（接收方请求超时放弃，可重试）。
class FileRequestMessage extends SyncMessage {
  const FileRequestMessage({required this.fileId, this.expectedSize, this.ext});

  /// 附件 hash（16 位十六进制，对应 `attachments/<fileId>.<ext>`）。
  final String fileId;

  /// 期望的文件大小（字节；null = 未知）。
  final int? expectedSize;

  /// 附件扩展名（如 `jpg`/`png`/`heic`；null = 旧对端不带，发送方扫描目录查找）。
  final String? ext;

  @override
  String get type => 'file_request';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'fileId': fileId,
    'expectedSize': expectedSize,
    'ext': ext,
  };

  factory FileRequestMessage.fromJson(Map<String, dynamic> json) =>
      FileRequestMessage(
        fileId: (json['fileId'] as String?) ?? '',
        expectedSize: json['expectedSize'] as int?,
        ext: json['ext'] as String?,
      );
}

/// 文件分片（图片跨设备同步，v4，task-30）：发送方收到 [FileRequestMessage]
/// 后按 64KB 分片逐片发送，最后发 [FileCompleteMessage]。
///
/// [data] 为分片字节的 base64 编码（64KB → ~87KB 文本）；[totalChunks] 供
/// 接收方预知分片总数（WebSocket 保序，简单按序追加即可，hash 校验兜底）。
class FileChunkMessage extends SyncMessage {
  const FileChunkMessage({
    required this.fileId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
  });

  /// 附件 hash（与 [FileRequestMessage.fileId] 一致）。
  final String fileId;

  /// 分片序号（从 0 开始）。
  final int chunkIndex;

  /// 分片总数（最后一片可能不足 64KB）。
  final int totalChunks;

  /// 分片字节的 base64 编码。
  final String data;

  @override
  String get type => 'file_chunk';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'fileId': fileId,
    'chunkIndex': chunkIndex,
    'totalChunks': totalChunks,
    'data': data,
  };

  factory FileChunkMessage.fromJson(Map<String, dynamic> json) =>
      FileChunkMessage(
        fileId: (json['fileId'] as String?) ?? '',
        chunkIndex: (json['chunkIndex'] as int?) ?? 0,
        totalChunks: (json['totalChunks'] as int?) ?? 0,
        data: (json['data'] as String?) ?? '',
      );
}

/// 文件传输完成（图片跨设备同步，v4，task-30）：发送方全部 [FileChunkMessage]
/// 发送完毕后发送；接收方据此触发 [AttachmentsStore.finalize]——读临时文件
/// 校验 sha256 前 16 位 == [fileId] 后重命名落盘，校验失败丢弃临时文件
/// （可重新请求）。
class FileCompleteMessage extends SyncMessage {
  const FileCompleteMessage({required this.fileId});

  /// 附件 hash（与 [FileRequestMessage.fileId] 一致）。
  final String fileId;

  @override
  String get type => 'file_complete';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'fileId': fileId};

  factory FileCompleteMessage.fromJson(Map<String, dynamic> json) =>
      FileCompleteMessage(fileId: (json['fileId'] as String?) ?? '');
}

/// 主机广播已连接设备列表（H→C）：客户端连接 / 断开 / 新设备登记时发送。
class DevicesUpdateMessage extends SyncMessage {
  const DevicesUpdateMessage({required this.devices});

  /// 当前已连接设备列表。
  final List<DeviceInfo> devices;

  @override
  String get type => 'devices_update';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'devices': devices.map((device) => device.toJson()).toList(),
  };

  factory DevicesUpdateMessage.fromJson(Map<String, dynamic> json) {
    final devices = <DeviceInfo>[];
    final rawDevices = json['devices'];
    if (rawDevices is List) {
      for (final raw in rawDevices) {
        if (raw is Map<String, dynamic>) {
          devices.add(DeviceInfo.fromJson(raw));
        }
      }
    }
    return DevicesUpdateMessage(devices: devices);
  }
}

/// 自动连接被拒通知（v5，task-31）：在线方对某设备 autoConnect=false 时，
/// 拒绝该设备发起的连接并发送本消息——对端收到后自动关闭对本机的
/// 自动连接开关（持久化），避免反复尝试自动连被拒（Q4）。
///
/// 载荷为发送方（拒绝方/在线方）自身 deviceId；接收方将其作为「被拒方」
/// 对本机执行 setAutoConnect(发送方, false) + 刷新 UI。
///
/// 与 [PairingFailMessage] 区分：pairing_fail 表示配对被拒（未配对场景）；
/// 本消息表示已配对但自动连接被关闭（连接被拒）。
class AutoConnectRejectedMessage extends SyncMessage {
  const AutoConnectRejectedMessage({required this.deviceId});

  /// 拒绝方（在线方）设备 ID。
  final String deviceId;

  @override
  String get type => 'auto_connect_rejected';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'deviceId': deviceId};

  factory AutoConnectRejectedMessage.fromJson(Map<String, dynamic> json) =>
      AutoConnectRejectedMessage(deviceId: (json['deviceId'] as String?) ?? '');
}

/// 主动断开通知（task-32）：本机手动断开某设备（手动连接开关关闭/
/// [SyncService.disconnectPeer]）时发送——对端收到后标记该设备为「手动
/// 断开」，不再自动重连（避免「手机主动断开后，mac 切前台又自动连回」）。
///
/// 载荷为空；发送方为本机，接收方以会话登记的 peerDeviceId 识别发送方。
class DisconnectMessage extends SyncMessage {
  const DisconnectMessage();

  @override
  String get type => 'disconnect';

  @override
  Map<String, dynamic> toJson() => {'type': type};
}

/// 心跳探活 ping（离线检测，v4 恢复）：连接内周期发送，对端回 pong。
///
/// 解决「对端被强杀/断网时本端感知不到下线」：优雅关闭会发 WebSocket close，
/// 强杀/断网没有 close 帧，只能靠 ping 超时判定断连。
class PingMessage extends SyncMessage {
  const PingMessage();

  @override
  String get type => 'ping';

  @override
  Map<String, dynamic> toJson() => {'type': 'ping'};
}

/// 心跳 pong（对端收到 ping 后回执）。
class PongMessage extends SyncMessage {
  const PongMessage();

  @override
  String get type => 'pong';

  @override
  Map<String, dynamic> toJson() => {'type': 'pong'};
}
