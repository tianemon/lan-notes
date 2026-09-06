// 连接层安全回归（评估 C1-C4 + 正常流程回归）：
// 驱动真实网络栈（WebSocket over 127.0.0.1 + 真实 SyncService），攻击面用
// 裸 WebSocket 客户端注入伪造协议帧（hello 声明任意 deviceId）。
//
// 覆盖：
//   C1  挑战反射预言机：反射挑战不得获得 HMAC 答案；未认证会话拿不到数据
//   C2  unpair / disconnect 信任门控：未认证会话不得解除配对 / 标记手动断开
//   C3  已配对 ID 的伪造配对请求：先挑战验证；验证失败后才进队列且带强提示
//   C4  地址缓存投毒：hello 未认证不得改写已配对设备的缓存地址
//   回归  正常握手/同步/地址缓存/双边 unpair 不受门控影响
//   回归  未配对设备 sync_request 拿不到数据（F14）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notes/app/data/database.dart' show AppDatabase;
import 'package:lan_notes/app/repository/attachments.dart';
import 'package:lan_notes/app/repository/device_identity.dart';
import 'package:lan_notes/app/repository/note_repository.dart';
import 'package:lan_notes/app/sync/discovery_service.dart';
import 'package:lan_notes/app/sync/sync_protocol.dart';
import 'package:lan_notes/app/sync/sync_service.dart';

/// 轮询等待条件成立（网络断言统一入口，避免时序抖动）。
Future<bool> waitFor(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return await condition();
}

/// 确定性假发现：不碰真实 UDP，由测试驱动「扫描到设备」。
class _FakeDiscovery extends DiscoveryService {
  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();
  final List<DiscoveredDevice> _known = [];
  bool _publishing = false;
  bool _scanning = false;

  @override
  Stream<List<DiscoveredDevice>> get devices => _controller.stream;
  @override
  bool get isPublishing => _publishing;
  @override
  bool get isScanning => _scanning;

  @override
  Future<void> publish({
    required String deviceName,
    required int port,
    String? deviceId,
    Duration? announceInterval,
    bool initialAnnouncements = true,
  }) async {
    _publishing = true;
  }

  @override
  Future<void> unpublish() async {
    _publishing = false;
  }

  @override
  void updateIdentity({
    required String deviceName,
    required String deviceId,
    required int port,
  }) {}

  @override
  Future<void> startResidentListen() async {}

  @override
  void stopResidentListen() {}

  @override
  Future<Set<String>?> localIpv4Addresses() async => {'198.51.100.1'};

  @override
  Future<void> scanOnce({Duration? window, bool restart = false}) async {
    _scanning = true;
    _controller.add(List.of(_known));
    _scanning = false;
  }

  @override
  void stopScan() {
    _scanning = false;
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  void discover(DiscoveredDevice device) {
    _known.removeWhere((d) => d.deviceId == device.deviceId);
    _known.add(device);
    _controller.add(List.of(_known));
  }
}

/// 测试设备：内存库 + 注入式身份/发现 + 真实 SyncService（真实 WebSocket）。
class _TestDevice {
  _TestDevice({required this.id, required this.name});

  final String id;
  final String name;

  late final AppDatabase db;
  late final NoteRepository repo;
  late final DeviceIdentityStore identity;
  late final DiscoveryService discovery;
  late final SyncService service;
  late final Directory attachmentsDir;

  static String pairSecret(String a, String b) {
    final sorted = [a, b]..sort();
    return 'pair:${sorted[0]}:${sorted[1]}';
  }

  Future<void> start({List<String> trustedPeers = const []}) async {
    db = AppDatabase(NativeDatabase.memory());
    repo = NoteRepository(db.noteDao);
    identity = DeviceIdentityStore(db.deviceDao, deviceId: id, deviceName: name);
    await identity.ensureLoaded();
    for (final peerId in trustedPeers) {
      await identity.addTrusted(peerId, peerId, secret: pairSecret(id, peerId));
    }
    attachmentsDir = await Directory.systemTemp.createTemp('sec_att_$id');
    discovery = _FakeDiscovery();
    service = SyncService(
      repository: repo,
      identity: identity,
      discovery: discovery,
      attachments: AttachmentsStore(
        directoryProvider: () async => attachmentsDir,
      ),
    );
    await service.enable(port: 0);
  }

  DiscoveredDevice device() => DiscoveredDevice(
    instanceName: '$name._lan_notes._tcp.local',
    deviceName: name,
    deviceId: id,
    address: InternetAddress('127.0.0.1'),
    port: service.port!,
  );

  void fakeDiscover(DiscoveredDevice device) {
    (discovery as _FakeDiscovery).discover(device);
  }

  Future<void> dispose() async {
    await service.dispose();
    await repo.dispose();
    await db.close();
    try {
      await attachmentsDir.delete(recursive: true);
    } catch (_) {}
  }
}

/// 裸 WebSocket 攻击客户端：收帧缓冲 + 超时取帧（无帧返回 null）。
class _AttackerSocket {
  _AttackerSocket(this.ws) {
    ws.listen(
      (data) {
        if (data is String) {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) _inbox.add(decoded);
        }
      },
      onError: (Object _) {},
      onDone: () => _closed = true,
      cancelOnError: true,
    );
  }

  final WebSocket ws;
  final List<Map<String, dynamic>> _inbox = [];
  bool _closed = false;

  /// 与断言无关的噪声帧（受害者会话登记/连接表变化的周期广播）。
  static const Set<String> noiseTypes = {'devices_update', 'ping', 'pong'};

  bool get isClosed => _closed;

  void send(Map<String, dynamic> message) {
    ws.add(jsonEncode(message));
  }

  /// 取一帧；[timeout] 内无帧返回 null（「对端不应答」断言用）。
  /// 默认跳过 [noiseTypes]（受害者对会话登记的周期性广播，与断言无关）。
  Future<Map<String, dynamic>?> recv({
    Duration timeout = const Duration(milliseconds: 800),
    bool skipNoise = true,
  }) async {
    Map<String, dynamic>? match;
    Future<void> pump() async {
      final deadline = DateTime.now().add(timeout);
      while (_inbox.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    while (match == null) {
      await pump();
      if (_inbox.isEmpty) return null;
      final frame = _inbox.removeAt(0);
      if (skipNoise && noiseTypes.contains(frame['type'])) continue;
      match = frame;
    }
    return match;
  }

  /// 发送伪造 hello（声明任意 deviceId/监听端口）。
  void sendHello(String deviceId, {int? port, String name = 'attacker'}) {
    send({
      'type': 'hello',
      'deviceId': deviceId,
      'deviceName': name,
      'trusted': false,
      'protocolVersion': kProtocolVersion,
      // port 为 null 时显式携带 null：对端解析 (json['port'] as num?) 为
      // null，与「不带 port 字段」的旧行为一致。
      'port': port,
    });
  }

  Future<void> close() async {
    await ws.close();
  }
}

Future<_AttackerSocket> _connect(int port) async {
  return _AttackerSocket(await WebSocket.connect('ws://127.0.0.1:$port'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('C1 挑战反射预言机：反射挑战拿不到 HMAC 答案，未认证拿不到数据', () async {
    final victim = _TestDevice(id: 'victim', name: 'Victim');
    await victim.start();
    // 受害者已与真实设备 X 配对（X 当前不在线，攻击者冒充 X）。
    await victim.identity.addTrusted('X', 'X', secret: 'secret-of-X');
    await victim.repo.createNote(title: 'top secret', content: '');

    final atk = await _connect(victim.service.port!);
    atk.sendHello('X');
    final challenge = await atk.recv();
    expect(challenge?['type'], 'challenge', reason: '受害者按握手流程发挑战');
    final nonce = challenge?['nonce'] as String?;

    // 攻击核心：把受害者的挑战原样反射回去（修复前受害者会算出 HMAC）。
    atk.send({'type': 'challenge', 'nonce': nonce});
    final reflected = await atk.recv();
    expect(
      reflected?['type'] == 'challenge_response',
      isFalse,
      reason: 'C1 门控：未验证的入站会话发来的挑战一律不应答',
    );

    // 退而求其次给错答案 → welcome{trusted:false}；随后 sync_request 也
    // 拿不到全量数据（_peerTrusted 为 false，F14 门控）。
    atk.send({'type': 'challenge_response', 'nonce': nonce, 'hmac': '00'});
    final welcome = await atk.recv();
    expect(welcome?['type'], 'welcome');
    expect(welcome?['trusted'], isFalse);
    atk.send({'type': 'sync_request'});
    final data = await atk.recv();
    expect(
      data?['type'] == 'sync_data',
      isFalse,
      reason: '未通过 HMAC 验证的会话不响应 sync_request',
    );
    expect(victim.service.isConnected, isFalse);

    await atk.close();
    await victim.dispose();
  });

  test('C2 unpair 门控：未认证会话无法静默解除配对', () async {
    final victim = _TestDevice(id: 'victim', name: 'Victim');
    await victim.start();
    await victim.identity.addTrusted('X', 'X', secret: 'secret-of-X');

    final atk = await _connect(victim.service.port!);
    atk.sendHello('X');
    await atk.recv(); // challenge（忽略）
    atk.send({'type': 'unpair', 'deviceId': victim.id});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(
      await victim.identity.getTrustedSecret('X'),
      isNotNull,
      reason: 'C2 门控：未通过 HMAC 验证的 unpair 不得移除信任',
    );

    // disconnect 同理：不得把真设备标记为「手动断开」。
    atk.send({'type': 'disconnect'});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(
      victim.service.isManuallyDisconnected('X'),
      isFalse,
      reason: 'C2 门控：未认证 disconnect 不得设置手动断开标记',
    );

    await atk.close();
    await victim.dispose();
  });

  test('C3 已配对 ID 的配对请求：先挑战验证；验证失败后进队列并带强提示', () async {
    final victim = _TestDevice(id: 'victim', name: 'Victim');
    await victim.start();
    await victim.identity.addTrusted('X', 'X', secret: 'secret-of-X');

    final events = <PairingEvent>[];
    final sub = victim.service.pairingEvents.listen(events.add);

    final atk = await _connect(victim.service.port!);
    atk.sendHello('X');
    final challenge1 = await atk.recv();
    expect(challenge1?['type'], 'challenge');

    // 攻击者发伪造 pairing_request（冒充已配对设备 X）：不得立即弹窗
    //（先挑战验证——受害方重发一个新挑战 n2）。
    atk.send({'type': 'pairing_request', 'deviceId': 'X', 'deviceName': 'X'});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(
      events.whereType<PairingRequestedEvent>(),
      isEmpty,
      reason: 'C3 门控：持密钥 ID 的配对请求先经挑战验证，不得直接弹窗',
    );
    final challenge2 = await atk.recv();
    expect(challenge2?['type'], 'challenge', reason: 'C3 门控路径：重新挑战验证');

    // 给错 HMAC → 验证失败（welcome{trusted:false}）；此后重发的
    // pairing_request 允许进队列，但必须携带 alreadyPaired 强提示
    //（同意会覆盖原密钥，用户需明确裁决）。
    atk.send({
      'type': 'challenge_response',
      'nonce': challenge2?['nonce'],
      'hmac': 'deadbeef',
    });
    final welcome = await atk.recv();
    expect(welcome?['type'], 'welcome');
    expect(welcome?['trusted'], isFalse);

    atk.send({'type': 'pairing_request', 'deviceId': 'X', 'deviceName': 'X'});
    final requested = await waitFor(
      () async => events.whereType<PairingRequestedEvent>().isNotEmpty,
    );
    expect(requested, isTrue, reason: '验证失败后进入人工裁决队列');
    final event = events.whereType<PairingRequestedEvent>().first;
    expect(event.alreadyPaired, isTrue, reason: '弹窗须带「已配对设备重新配对」强提示');

    // 原密钥未被覆盖（用户尚未同意）。
    expect(await victim.identity.getTrustedSecret('X'), 'secret-of-X');

    await sub.cancel();
    await atk.close();
    await victim.dispose();
  });

  test('C4 地址缓存投毒：hello 未认证不得改写已配对设备的缓存地址', () async {
    final victim = _TestDevice(id: 'victim', name: 'Victim');
    await victim.start();
    await victim.identity.addTrusted('X', 'X', secret: 'secret-of-X');
    // X 的真实地址缓存（攻击者想把它改写到自己这里）。
    await victim.identity.cachePeerAddress('X', '10.0.0.9', 58888);

    final atk = await _connect(victim.service.port!);
    atk.sendHello('X', port: 4711);
    await atk.recv(); // challenge
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final cached = await victim.identity.getAllCachedPeerAddresses();
    expect(
      cached['X'],
      '10.0.0.9:58888',
      reason: 'C4 门控：地址缓存写入推迟到会话就绪（HMAC 通过）后',
    );

    await atk.close();
    await victim.dispose();
  });

  test('回归：正常握手/全量同步/地址缓存/双边 unpair 不受门控影响', () async {
    final a = _TestDevice(id: 'dev-a', name: 'A');
    final b = _TestDevice(id: 'dev-b', name: 'B');
    await a.start(trustedPeers: ['dev-b']);
    await b.start(trustedPeers: ['dev-a']);

    a.fakeDiscover(b.device());
    expect(
      await waitFor(
        () => a.service.isConnected && b.service.isConnected,
      ),
      isTrue,
      reason: 'C1 门控不得阻断合法 HMAC 握手（发起方须应答首个挑战）',
    );

    await a.repo.createNote(title: 'hello', content: '');
    expect(
      await waitFor(
        () async => (await b.repo.getAll()).any((n) => n.title == 'hello'),
      ),
      isTrue,
    );

    // 会话就绪后地址缓存才写入（C4 新时序：合法设备不受影响）。
    expect(
      await waitFor(() async =>
          (await b.identity.getAllCachedPeerAddresses())['dev-a'] != null),
      isTrue,
    );

    // 合法 unpair（已验证会话）双边解除（C2 门控放行）。
    await a.service.unpairPeer('dev-b');
    expect(
      await waitFor(() async => await b.identity.getTrustedSecret('dev-a') == null),
      isTrue,
      reason: '已通过 HMAC 验证的会话的 unpair 正常执行',
    );
    expect(
      await a.identity.getTrustedSecret('dev-b'),
      isNull,
    );

    await a.dispose();
    await b.dispose();
  });

  test('回归：未配对设备 sync_request 拿不到数据（F14）', () async {
    final victim = _TestDevice(id: 'victim', name: 'Victim');
    await victim.start();
    await victim.repo.createNote(title: 'private', content: '');

    final atk = await _connect(victim.service.port!);
    atk.sendHello('ghost');
    final welcome = await atk.recv();
    expect(welcome?['type'], 'welcome');
    expect(welcome?['trusted'], isFalse, reason: '未知设备无密钥：直接按未配对处理');

    atk.send({'type': 'sync_request'});
    final data = await atk.recv();
    expect(data?['type'] == 'sync_data', isFalse);

    await atk.close();
    await victim.dispose();
  });
}
