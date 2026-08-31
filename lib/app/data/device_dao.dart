import 'package:drift/drift.dart';

import 'database.dart';

part 'device_dao.g.dart';

/// 设备 DAO：本机身份设置（deviceId/设备名）与信任列表的持久化访问。
///
/// - 身份设置：键值对（[DeviceSettings] 表），键见 device_identity.dart
///   的 `kDeviceSetting*` 常量；
/// - 地址缓存：同样存于 [DeviceSettings]（键前缀 [kPeerAddressKeyPrefix]），
///   值格式 `ip:port`（task-27 v4 直连优先，跨重启记住已配对设备地址）；
/// - 信任列表：[TrustedDevices] 表，行数据类为 drift 生成的 [TrustedDevice]
///   （字段 deviceId/deviceName/pairedAt/autoConnect/secret，与同步协议
///   无关，仅供本地使用）。
@DriftAccessor(tables: [DeviceSettings, TrustedDevices])
class DeviceDao extends DatabaseAccessor<AppDatabase> with _$DeviceDaoMixin {
  DeviceDao(super.db);

  /// 读取一条设置（不存在返回 null）。
  Future<String?> getSetting(String key) async {
    final row = await (select(
      deviceSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// 按前缀读取全部设置（task-27：地址缓存遍历）。
  Future<Map<String, String>> getSettingsByPrefix(String prefix) async {
    final rows = await (select(
      deviceSettings,
    )..where((t) => t.key.like('$prefix%'))).get();
    return {for (final row in rows) row.key: row.value};
  }

  /// 写入一条设置（UPSERT，以 key 为主键）。
  Future<void> setSetting(String key, String value) {
    return into(deviceSettings).insertOnConflictUpdate(
      DeviceSettingsCompanion.insert(key: key, value: value),
    );
  }

  /// 删除一条设置（不存在时无操作）。
  Future<void> removeSetting(String key) async {
    await (delete(deviceSettings)..where((t) => t.key.equals(key))).go();
  }

  /// 设备是否在信任列表中（已配对）。
  Future<bool> isTrusted(String deviceId) async {
    final row = await (select(
      trustedDevices,
    )..where((t) => t.deviceId.equals(deviceId))).getSingleOrNull();
    return row != null;
  }

  /// 读取某已配对设备的认证密钥（未配对/无密钥返回 null）。
  Future<String?> getSecret(String deviceId) async {
    final row = await (select(
      trustedDevices,
    )..where((t) => t.deviceId.equals(deviceId))).getSingleOrNull();
    return row?.secret;
  }

  /// 写入/更新信任列表条目（UPSERT：重复配对幂等刷新设备名/密钥）。
  Future<void> addTrusted(TrustedDevice device) {
    return into(trustedDevices).insertOnConflictUpdate(
      TrustedDevicesCompanion.insert(
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        pairedAt: device.pairedAt,
        secret: Value(device.secret),
      ),
    );
  }

  /// 更新某已配对设备的设备名（task-32：存量条目存了 ID 时握手刷新）。
  Future<void> updateTrustedName(String deviceId, String deviceName) async {
    await (update(trustedDevices)..where((t) => t.deviceId.equals(deviceId)))
        .write(TrustedDevicesCompanion(deviceName: Value(deviceName)));
  }

  /// 更新某已配对设备的认证密钥（重新配对/确认回发时刷新）。
  Future<void> setSecret(String deviceId, String secret) async {
    await (update(trustedDevices)..where((t) => t.deviceId.equals(deviceId)))
        .write(TrustedDevicesCompanion(secret: Value(secret)));
  }

  /// 从信任列表移除（取消配对）。
  Future<void> removeTrusted(String deviceId) async {
    await (delete(
      trustedDevices,
    )..where((t) => t.deviceId.equals(deviceId))).go();
  }

  /// 设置某已配对设备的「自动连接」开关（task-16，WiFi 式）。
  ///
  /// 关闭后保持配对（信任列表不删除）但不自动连接；手动点击仍可连。
  /// task-32 起 autoConnect 不再控制连接（永远自动连接），该方法保留兼容。
  Future<void> setAutoConnect(String deviceId, bool value) async {
    await (update(trustedDevices)..where((t) => t.deviceId.equals(deviceId)))
        .write(TrustedDevicesCompanion(autoConnect: Value(value)));
  }

  /// 设置某已配对设备的同步方向（task-32）：向对端同步 / 从对端同步。
  Future<void> setSyncDirections(
    String deviceId, {
    required bool syncToPeer,
    required bool syncFromPeer,
  }) async {
    await (update(
      trustedDevices,
    )..where((t) => t.deviceId.equals(deviceId))).write(
      TrustedDevicesCompanion(
        syncToPeer: Value(syncToPeer),
        syncFromPeer: Value(syncFromPeer),
      ),
    );
  }

  /// 全部已配对设备（按配对时间倒序）。
  Future<List<TrustedDevice>> getAllTrusted() async {
    return (select(
      trustedDevices,
    )..orderBy([(t) => OrderingTerm.desc(t.pairedAt)])).get();
  }
}
