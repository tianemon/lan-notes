import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

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
  }) : _stream = stream,
       _send = send,
       _close = close;

  /// 包装服务端升级后的 WebSocket。
  factory _SyncChannel.server(WebSocket socket) =>
      _SyncChannel._(stream: socket, send: socket.add, close: socket.close);

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
  }) : _channel = channel,
       _onClosed = onClosed {
    _subscription = channel.stream.listen(
      _onData,
      onError: (Object _) => _handleClosed(),
      onDone: _handleClosed,
      cancelOnError: true,
    );
    // 保活判定统一收编到会话层（SyncService 5s）：传输层不再自行判超时。
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
    if (data is! String) return;
    final message = _tryDecodeJson(data);
    if (message == null) return;
    // 心跳消息不再在传输层消化：统一进入业务流，由会话层
    // （SyncService._onMessage）刷新 _lastInbound 并回 pong——
    // 「任何入站即保活证据」成立（含 ping/pong）。
    _messages.add(message);
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;
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
  SyncClient();

  _SyncChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  SyncConnectionState _state = SyncConnectionState.disconnected;
  String? _host;
  int? _port;
  bool _manualDisconnect = false;

  final StreamController<SyncConnectionState> _stateController =
      StreamController<SyncConnectionState>.broadcast();
  final StreamController<Map<String, dynamic>> _messagesController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 当前连接状态。
  SyncConnectionState get state => _state;

  /// 连接状态变化流（disconnected/connecting/connected）。
  Stream<SyncConnectionState> get stateChanges => _stateController.stream;

  /// 服务端发来的业务消息流（含心跳 ping/pong，由会话层统一刷新计时）。
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
  /// 连接失败或连接中断后**不再自动重连**（架构决策：在线方不主动重连，
  /// 断线只报 [SyncConnectionState.disconnected]，由上层决定——上线方/
  /// 手动连接/前台恢复时才重新 [connect]）。
  Future<void> connect(String host, int port) async {
    _host = host;
    _port = port;
    _manualDisconnect = false;
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
  /// 仅更新目标地址。若当前处于空闲（[SyncConnectionState.disconnected]）
  /// 状态，则立即按新目标重新发起连接（mDNS 重新发现解析到的新地址）。
  void updateTarget(String host, int port) {
    _host = host;
    _port = port;
    if (_state == SyncConnectionState.disconnected && !_manualDisconnect) {
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
      _setState(SyncConnectionState.connected);
      _listen();
    } catch (_) {
      // 连接失败（拒绝/超时/网络不可达）：不再自动重连，直接报断开。
      _handleDisconnected();
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
    if (data is! String) return;
    final message = _tryDecodeJson(data);
    if (message == null) return;
    // 心跳消息不再在传输层消化：统一进入业务流，由会话层
    // （SyncService._onMessage）刷新 _lastInbound 并回 pong。
    _messagesController.add(message);
  }

  void _handleDisconnected() {
    if (_manualDisconnect) return;
    _cleanupChannel();
    _setState(SyncConnectionState.disconnected);
  }

  void _cleanupChannel() {
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
