import 'dart:io';

import 'package:uuid/uuid.dart';

import '../data/device_dao.dart';
import '../data/database.dart' show TrustedDevice;

/// 设备设置键：deviceId（持久化身份，UUID）。
const String kDeviceSettingDeviceId = 'device_id';

/// 设备设置键：设备名（默认取主机名，可在设置中修改）。
const String kDeviceSettingDeviceName = 'device_name';

/// 设备设置键：启动时自动同步（默认开，task-17）。
///
/// 开启时 App 启动自动调用 [SyncService.enable]（无需手动点开关）；
/// 从后台回前台时若同步被系统关闭自动恢复。存储 '1'/'0'。
const String kDeviceSettingAutoSync = 'auto_sync';

/// 对端地址缓存键前缀（task-27 v4 直连优先，持久化）：
/// `addr_<deviceId>` → `ip:port`。打开软件/enable 时先凭缓存地址直连
/// 已配对设备（3 次×2 组），失败再进入退避扫描；连接/发现时刷新。
const String kPeerAddressKeyPrefix = 'peer_addr_';

/// 本机设备身份与信任列表的统一入口。
///
/// - **设备身份**：首次启动生成 deviceId（UUID）并持久化（重启不变，
///   跨设备识别凭据，IP 变化不影响）；设备名默认取系统主机名，可修改。
/// - **信任列表**：已配对设备（凭 deviceId，IP 变化不影响识别），
///   每条含 HMAC 认证密钥（v4，配对时交换）。
/// - **对端地址缓存**：已配对设备的最近地址/端口，持久化到设置表
///   （v4 直连优先，跨重启有效）。
///
/// 内存缓存提供同步读取（[deviceId]/[deviceName]），
/// [ensureLoaded] 从数据库加载持久化值并写入首次默认值（幂等）。
/// SyncService 在握手/配对等身份敏感路径前 await [ensureLoaded]，
/// 保证对外使用的始终是持久化身份（而非启动时的临时值）。
class DeviceIdentityStore {
  DeviceIdentityStore(
    this._dao, {
    String? deviceId,
    String? deviceName,
  })  : // 先给内存临时值（构造后即可同步读取）；ensureLoaded 后为持久化权威值。
        // 注入参数用于验证脚本构造确定性身份（见 temp/drafts/verify_sync.dart）。
        _deviceId = deviceId ?? const Uuid().v4(),
        _deviceName = deviceName ?? _defaultDeviceName();

  final DeviceDao _dao;

  String _deviceId;
  String _deviceName;
  bool _autoSync = true;
  Future<void>? _loading;

  /// 本机设备 ID（持久化身份，重启不变；首次启动生成并落库）。
  String get deviceId => _deviceId;

  /// 本机设备名（默认取主机名，可在设置中修改）。
  String get deviceName => _deviceName;

  /// 是否「启动时自动同步」（默认 true，task-17）。
  ///
  /// 开启时 App 启动/回前台自动恢复同步（见 main.dart 生命周期逻辑）；
  /// 关闭后仅手动开启同步，重启 App 也不自动开启。
  bool get autoSync => _autoSync;

  /// 从数据库加载持久化身份并缓存（幂等）；首次运行把内存默认值落库。
  ///
  /// 返回的 Future 缓存复用：多次调用只触发一次数据库加载。
  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final storedId = await _dao.getSetting(kDeviceSettingDeviceId);
    if (storedId != null && storedId.isNotEmpty) {
      _deviceId = storedId;
    } else {
      await _dao.setSetting(kDeviceSettingDeviceId, _deviceId);
    }
    final storedName = await _dao.getSetting(kDeviceSettingDeviceName);
    if (storedName != null && storedName.isNotEmpty) {
      _deviceName = storedName;
    } else {
      await _dao.setSetting(kDeviceSettingDeviceName, _deviceName);
    }
    // auto_sync：不存在（旧库）时默认 true 并落库，与全新库默认一致。
    final storedAutoSync = await _dao.getSetting(kDeviceSettingAutoSync);
    _autoSync = storedAutoSync == null || storedAutoSync == '1';
    if (storedAutoSync == null) {
      await _dao.setSetting(kDeviceSettingAutoSync, '1');
    }
  }

  /// 修改设备名（持久化；同步开关开启时由 SyncService 刷新 UDP 广播发布）。
  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _deviceName = trimmed;
    await _dao.setSetting(kDeviceSettingDeviceName, trimmed);
  }

  /// 设置「启动时自动同步」开关（持久化，task-17）。
  ///
  /// 开关独立于同步总开关：修改后不影响当前会话的同步状态，下次启动/
  /// 回前台恢复时按新配置生效（重启后生效语义）。
  Future<void> setAutoSync(bool value) async {
    _autoSync = value;
    await _dao.setSetting(kDeviceSettingAutoSync, value ? '1' : '0');
  }

  /// 设备是否已配对（在信任列表中）。
  Future<bool> isTrusted(String deviceId) => _dao.isTrusted(deviceId);

  /// 读取某已配对设备的 HMAC 认证密钥（未配对/无密钥返回 null）。
  Future<String?> getTrustedSecret(String deviceId) => _dao.getSecret(deviceId);

  /// 配对成功后写入信任列表（UPSERT，幂等：重复配对刷新设备名与密钥）。
  ///
  /// [secret]：HMAC 挑战认证密钥（v4，接受方生成经 pairing_accept 交换、
  /// 请求方确认回发；每对设备共享一个）。task-16：新配对设备「自动连接」
  /// 开关默认开（WiFi 式，可在同步页关闭）。
  Future<void> addTrusted(
    String deviceId,
    String deviceName, {
    String? secret,
  }) {
    return _dao.addTrusted(
      TrustedDevice(
        deviceId: deviceId,
        deviceName: deviceName,
        pairedAt: DateTime.now().millisecondsSinceEpoch,
        autoConnect: true,
        secret: secret,
      ),
    );
  }

  /// 刷新某已配对设备的认证密钥（确认回发/重新配对时）。
  Future<void> setTrustedSecret(String deviceId, String secret) =>
      _dao.setSecret(deviceId, secret);

  /// 从信任列表移除（取消配对）。
  Future<void> removeTrusted(String deviceId) => _dao.removeTrusted(deviceId);

  /// 设置某已配对设备的「自动连接」开关（task-16，WiFi 式）。
  ///
  /// 关闭后保持配对（信任列表不删除）但不自动连接；手动点击仍可连。
  Future<void> setAutoConnect(String deviceId, bool value) =>
      _dao.setAutoConnect(deviceId, value);

  /// 全部已配对设备（按配对时间倒序）。
  Future<List<TrustedDevice>> getTrustedDevices() => _dao.getAllTrusted();

  // ===== 对端地址缓存（task-27 v4 直连优先，持久化） =====

  /// 缓存某对端设备的最近地址/端口（`ip:port`，跨重启有效）。
  Future<void> cachePeerAddress(String deviceId, String address, int port) {
    if (deviceId.isEmpty || address.isEmpty || port <= 0) {
      return Future.value();
    }
    return _dao.setSetting(
      '$kPeerAddressKeyPrefix$deviceId',
      '$address:$port',
    );
  }

  /// 读取某对端设备的缓存地址（`ip:port`；无缓存返回 null）。
  Future<String?> getCachedPeerAddress(String deviceId) =>
      _dao.getSetting('$kPeerAddressKeyPrefix$deviceId');

  /// 读取全部对端地址缓存（deviceId → `ip:port`）。
  Future<Map<String, String>> getAllCachedPeerAddresses() async {
    final raw = await _dao.getSettingsByPrefix(kPeerAddressKeyPrefix);
    return {
      for (final entry in raw.entries)
        entry.key.substring(kPeerAddressKeyPrefix.length): entry.value,
    };
  }

  /// 移除某对端设备的地址缓存（取消配对/地址失效时）。
  Future<void> removeCachedPeerAddress(String deviceId) =>
      _dao.removeSetting('$kPeerAddressKeyPrefix$deviceId');

  /// 重置设备 ID：重新生成持久化 deviceId 并清空全部信任列表（task-14）。
  ///
  /// 用于**设备 ID 冲突**修复（如从备份恢复导致两台设备 deviceId 相同，
  /// 见 docs/技术架构.md 7.3 节）：重置后本机以全新身份参与局域网，
  /// 旧配对关系全部失效——本机信任列表清空，对端仍信任旧 deviceId，
  /// 发现新身份后会走配对流程，需重新请求-同意配对。
  ///
  /// 调用方（SyncService.resetDeviceIdentity）应随后刷新 UDP 广播发布
  /// （TXT 携带新 deviceId）并断开全部会话。
  Future<String> resetDeviceId() async {
    final newId = const Uuid().v4();
    _deviceId = newId;
    await _dao.setSetting(kDeviceSettingDeviceId, newId);
    // 旧身份全部失效：清空信任列表（对方也需重新配对）。
    final trusted = await _dao.getAllTrusted();
    for (final device in trusted) {
      await _dao.removeTrusted(device.deviceId);
    }
    return newId;
  }
}

/// 默认设备名：取系统主机名，取不到时回退默认名。
String _defaultDeviceName() {
  try {
    final name = Platform.localHostname.trim();
    // Android 上 gethostname 常返回空或 'localhost'（无实际设备名），
    // 直接回退平台默认名，避免对方看到空名/localhost（真机反馈修复）。
    if (name.isNotEmpty &&
        name != 'localhost' &&
        name != 'localhost.local') {
      return name;
    }
  } catch (_) {
    // 个别平台取主机名失败：回退默认名。
  }
  if (Platform.isAndroid) return 'Android 设备';
  return 'lan-notes';
}
