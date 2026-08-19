import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

/// 心跳发送间隔：每 15s 发送 `{type: 'ping'}`。
const Duration kHeartbeatInterval = Duration(seconds: 15);

/// 心跳超时：45s 内未收到任何消息（含 pong 与业务消息）判定断连。
const Duration kHeartbeatTimeout = Duration(seconds: 45);

/// 自动重连最大次数：指数退避 1s/2s/4s/8s/16s，最多重试 5 次。
const int kMaxReconnectAttempts = 5;

/// WebSocket 连接状态。
enum SyncConnectionState { disconnected, connecting, connected }

/// 统一底层 WebSocket 通道。
///
/// 服务端（dart:io [WebSocket]）与客户端（web_socket_channel 的
/// [IOWebSocketChannel]）的收发接口一致化，屏蔽底层差异。
class _SyncChannel {
  _SyncChannel._({
    required Stream<dynamic> stream,
    required void Function(Object?) send,
    required Future<void> Function() close,
  })  : _stream = stream,
        _send = send,
        _close = close;

  /// 包装服务端升级后的 WebSocket。
  factory _SyncChannel.server(WebSocket socket) => _SyncChannel._(
        stream: socket,
        send: socket.add,
        close: socket.close,
      );

  /// 包装客户端连接得到的 IOWebSocketChannel。
  factory _SyncChannel.client(IOWebSocketChannel channel) => _SyncChannel._(
        stream: channel.stream,
        send: channel.sink.add,
        close: channel.sink.close,
      );

  final Stream<dynamic> _stream;
  final void Function(Object?) _send;
  final Future<void> Function() _close;

  Stream<dynamic> get stream => _stream;

  void send(Object? data) => _send(data);

  Future<void> close() => _close();
}

/// 服务端视角的一条客户端连接（一台已连接的设备）。
class SyncServerConnection {
  SyncServerConnection._({
    required this.id,
    required this.remoteAddress,
    required _SyncChannel channel,
    required void Function(SyncServerConnection) onClosed,
  })  : _channel = channel,
        _onClosed = onClosed {
    _subscription = channel.stream.listen(
      _onData,
      onError: (Object _) => _handleClosed(),
      onDone: _handleClosed,
      cancelOnError: true,
    );
    // 服务端心跳监控：客户端每 15s 发 ping，45s 无任何消息判定失活断开。
    _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) {
      if (DateTime.now().difference(_lastMessageAt) > kHeartbeatTimeout) {
        _handleClosed();
      }
    });
  }

  /// 连接唯一标识（服务端分配，如 client-1）。
  final String id;

  /// 客户端来源地址（可能为 null）。
  final InternetAddress? remoteAddress;

  final _SyncChannel _channel;
  final void Function(SyncServerConnection) _onClosed;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  DateTime _lastMessageAt = DateTime.now();
  bool _closed = false;

  /// 该客户端发来的业务消息流（心跳 ping/pong 已由传输层内部消化，
  /// 不进入此流；task-7 协议层在此消费 hello/sync_request 等）。
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// 该连接是否已关闭。
  bool get isClosed => _closed;

  /// 向该客户端定向发送一条业务消息（task-7 用于 welcome/sync_data 等）。
  void send(Map<String, dynamic> message) {
    if (_closed) return;
    try {
      _channel.send(jsonEncode(message));
    } catch (_) {
      // socket 写入失败：由 onDone/onError 触发清理与上层通知。
    }
  }

  void _onData(dynamic data) {
    _lastMessageAt = DateTime.now();
    if (data is! String) return;
    final message = _tryDecodeJson(data);
    if (message == null) return;
    if (message['type'] == 'ping') {
      // 心跳请求：立即回 pong，不进入业务消息流。
      try {
        _channel.send(jsonEncode({'type': 'pong'}));
      } catch (_) {}
      return;
    }
    if (message['type'] == 'pong') {
      return; // 心跳响应内部消化（对称保活时对端回应的 pong）
    }
    _messages.add(message);
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    if (!_messages.isClosed) {
      unawaited(_messages.close());
    }
    _onClosed(this);
  }

  /// 主动关闭该连接（幂等）。
  Future<void> close() async {
    if (_closed) return;
    _handleClosed();
    try {
      await _channel.close();
    } catch (_) {}
  }
}

/// WebSocket 服务端：监听 `ws://0.0.0.0:<随机端口>`，可同时服务多台设备。
class SyncServer {
  HttpServer? _server;
  final Map<String, SyncServerConnection> _connections =
      <String, SyncServerConnection>{};
  final StreamController<SyncServerConnection> _onConnected =
      StreamController<SyncServerConnection>.broadcast();
  final StreamController<SyncServerConnection> _onDisconnected =
      StreamController<SyncServerConnection>.broadcast();
  int _nextId = 0;

  /// 新客户端连接事件（task-7 在此登记设备并广播 devices_update）。
  Stream<SyncServerConnection> get onClientConnected => _onConnected.stream;

  /// 客户端断开事件（task-7 在此移除设备并广播 devices_update）。
  Stream<SyncServerConnection> get onClientDisconnected =>
      _onDisconnected.stream;

  /// 当前已连接的客户端列表（可同时服务多台设备）。
  List<SyncServerConnection> get clients => _connections.values.toList();

  /// 实际监听端口（未启动时为 null）。
  int? get port => _server?.port;

  /// 服务端是否正在运行。
  bool get isRunning => _server != null;

  /// 启动服务端并监听指定端口（默认 0 = 随机端口），返回实际端口号。
  ///
  /// 传入固定端口可让主机重启后端口保持稳定，客户端自动重连（指数退避）
  /// 才能在主机恢复后重新命中并全量对齐（task-9 场景四断线重连验证）。
  Future<int> start({int port = 0}) async {
    await stop();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(_handleRequest);
    return server.port;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path != '/') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      final id = 'client-${++_nextId}';
      final connection = SyncServerConnection._(
        id: id,
        remoteAddress: request.connectionInfo?.remoteAddress,
        channel: _SyncChannel.server(socket),
        onClosed: _removeConnection,
      );
      _connections[id] = connection;
      _onConnected.add(connection);
    } catch (_) {
      // WebSocket 升级失败（如非 WebSocket 请求）：关闭响应避免挂起。
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _removeConnection(SyncServerConnection connection) {
    if (_connections.remove(connection.id) != null) {
      _onDisconnected.add(connection);
    }
  }

  /// 广播一条业务消息给所有已连接客户端（task-7 用于 devices_update）。
  void broadcast(Map<String, dynamic> message) {
    for (final connection in _connections.values.toList()) {
      connection.send(message);
    }
  }

  /// 断开指定客户端连接（按连接 ID，幂等）。
  ///
  /// 关闭连接会触发 [onClientDisconnected]，由上层（SyncService）移除设备
  /// 并广播 devices_update（同步页「断开设备」按钮走此路径）。
  Future<void> disconnectClient(String connectionId) async {
    final connection = _connections[connectionId];
    if (connection != null) {
      await connection.close();
    }
  }

  /// 停止服务端并断开所有客户端（幂等）。
  Future<void> stop() async {
    final connections = _connections.values.toList();
    for (final connection in connections) {
      await connection.close();
    }
    _connections.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  /// 释放资源（停止服务并关闭事件流）。
  Future<void> dispose() async {
    await stop();
    await _onConnected.close();
    await _onDisconnected.close();
  }
}

/// WebSocket 客户端：连接、心跳保活、指数退避自动重连（最多 5 次）。
class SyncClient {
  SyncClient({
    this.maxReconnectAttempts = kMaxReconnectAttempts,
    this.reconnectBaseDelay = const Duration(seconds: 1),
  });

  /// 自动重连最大次数（可注入，测试用短链快速失败；生产默认 5 次）。
  final int maxReconnectAttempts;

  /// 重连退避基数（第 n 次等待 `base × 2^(n-1)`；可注入，测试用短间隔）。
  final Duration reconnectBaseDelay;

  _SyncChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime _lastMessageAt = DateTime.now();
  SyncConnectionState _state = SyncConnectionState.disconnected;
  String? _host;
  int? _port;
  int _reconnectAttempt = 0;
  bool _manualDisconnect = false;

  final StreamController<SyncConnectionState> _stateController =
      StreamController<SyncConnectionState>.broadcast();
  final StreamController<Map<String, dynamic>> _messagesController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 当前连接状态。
  SyncConnectionState get state => _state;

  /// 连接状态变化流（disconnected/connecting/connected）。
  Stream<SyncConnectionState> get stateChanges => _stateController.stream;

  /// 服务端发来的业务消息流（心跳 ping/pong 已由传输层内部消化）。
  Stream<Map<String, dynamic>> get messages => _messagesController.stream;

  /// 是否已连接。
  bool get isConnected => _state == SyncConnectionState.connected;

  /// 当前连接目标主机。
  String? get host => _host;

  /// 当前连接目标端口。
  int? get port => _port;

  /// 等待连接进入终端状态（connected 或 disconnected，重试耗尽）。
  ///
  /// 用于直连阶段（task-27 v4）：每次尝试等待结果，超时（[timeout]，
  /// 可空=不限）后返回当前是否已连接。
  Future<bool> waitForTerminal({Duration? timeout}) async {
    final completer = Completer<bool>();
    late final StreamSubscription<SyncConnectionState> sub;
    void settle() {
      if (completer.isCompleted) return;
      completer.complete(_state == SyncConnectionState.connected);
      sub.cancel();
    }
    sub = stateChanges.listen((state) {
      if (state == SyncConnectionState.connected ||
          state == SyncConnectionState.disconnected) {
        settle();
      }
    });
    if (_state == SyncConnectionState.connected ||
        _state == SyncConnectionState.disconnected) {
      settle();
    }
    if (timeout != null) {
      Timer(timeout, settle);
    }
    return completer.future;
  }

  /// 连接指定主机。
  ///
  /// 连接失败或连接中断后自动按指数退避重连（1s/2s/4s/8s/16s，
  /// 最多 5 次，见 [kMaxReconnectAttempts]）；重连耗尽后状态回到
  /// [SyncConnectionState.disconnected]，需再次调用 [connect] 重新发起。
  Future<void> connect(String host, int port) async {
    _host = host;
    _port = port;
    _manualDisconnect = false;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cleanupChannel();
    await _connectOnce();
  }

  /// 手动断开：停止自动重连并释放连接（幂等）。
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cleanupChannel();
    _setState(SyncConnectionState.disconnected);
  }

  /// 更新连接目标（对端 IP/端口变化时由发现层调用，task-13 P2P）。
  ///
  /// 仅更新目标地址；正在进行的重连退避会在下一次尝试时使用新地址。
  /// 若当前处于空闲/重试耗尽（[SyncConnectionState.disconnected]）状态，
  /// 则立即按新目标重新发起连接（mDNS 重新发现解析到的新地址）。
  void updateTarget(String host, int port) {
    _host = host;
    _port = port;
    if (_state == SyncConnectionState.disconnected && !_manualDisconnect) {
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      unawaited(_connectOnce());
    }
  }

  /// 发送一条业务消息（JSON 编码）。未连接时抛出 [StateError]。
  void send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || _state != SyncConnectionState.connected) {
      throw StateError('SyncClient 未连接，无法发送消息');
    }
    try {
      channel.send(jsonEncode(message));
    } catch (_) {
      // socket 已损坏：触发断开与自动重连。
      _handleDisconnected();
    }
  }

  /// 释放资源（断开连接并关闭事件流）。
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
    await _messagesController.close();
  }

  Future<void> _connectOnce() async {
    if (_manualDisconnect) return;
    _setState(SyncConnectionState.connecting);
    final host = _host;
    final port = _port;
    if (host == null || port == null) return;

    try {
      final channel = IOWebSocketChannel.connect(
        'ws://$host:$port',
        connectTimeout: const Duration(seconds: 10),
      );
      await channel.ready;
      if (_manualDisconnect) {
        await channel.sink.close();
        return;
      }
      _channel = _SyncChannel.client(channel);
      _reconnectAttempt = 0; // 连接成功：重置重连计数
      _lastMessageAt = DateTime.now();
      _setState(SyncConnectionState.connected);
      _startHeartbeat();
      _listen();
    } catch (_) {
      // 连接失败（拒绝/超时/网络不可达）：进入自动重连。
      _scheduleReconnect();
    }
  }

  void _listen() {
    _subscription = _channel!.stream.listen(
      _onData,
      onError: (Object _) => _handleDisconnected(),
      onDone: _handleDisconnected,
      cancelOnError: true,
    );
  }

  void _onData(dynamic data) {
    _lastMessageAt = DateTime.now();
    if (data is! String) return;
    final message = _tryDecodeJson(data);
    if (message == null) return;
    final type = message['type'];
    if (type == 'pong') {
      return; // 心跳响应内部消化
    }
    if (type == 'ping') {
      // 对端主动心跳（对称保活）：回 pong。
      try {
        _channel?.send(jsonEncode({'type': 'pong'}));
      } catch (_) {}
      return;
    }
    _messagesController.add(message);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) {
      try {
        _channel?.send(jsonEncode({'type': 'ping'}));
      } catch (_) {}
      // 45s 无任何消息（含 pong 与业务消息）→ 判定断连并触发自动重连。
      if (DateTime.now().difference(_lastMessageAt) > kHeartbeatTimeout) {
        _handleDisconnected();
      }
    });
  }

  void _handleDisconnected() {
    if (_manualDisconnect) return;
    _cleanupChannel();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect) return;
    if (_reconnectAttempt >= kMaxReconnectAttempts) {
      _setState(SyncConnectionState.disconnected);
      return;
    }
    _reconnectAttempt++;
    _setState(SyncConnectionState.connecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      _reconnectDelay(_reconnectAttempt, reconnectBaseDelay),
      () {
        _reconnectTimer = null;
        _connectOnce();
      },
    );
  }

  void _cleanupChannel() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        unawaited(channel.close());
      } catch (_) {}
    }
  }

  void _setState(SyncConnectionState next) {
    if (_state == next) return;
    _state = next;
    _stateController.add(next);
  }
}

/// 指数退避延迟：第 [attempt] 次重试等待 `base × 2^(attempt-1)`（默认 1/2/4/8/16）。
Duration _reconnectDelay(int attempt, Duration base) =>
    base * (1 << (attempt - 1));

/// 解析 WebSocket 文本帧为 JSON 对象；非法 JSON 返回 null。
Map<String, dynamic>? _tryDecodeJson(String data) {
  try {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // 非 JSON 文本帧忽略。
  }
  return null;
}
