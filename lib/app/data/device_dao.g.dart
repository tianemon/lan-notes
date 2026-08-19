// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_dao.dart';

// ignore_for_file: type=lint
mixin _$DeviceDaoMixin on DatabaseAccessor<AppDatabase> {
  $DeviceSettingsTable get deviceSettings => attachedDatabase.deviceSettings;
  $TrustedDevicesTable get trustedDevices => attachedDatabase.trustedDevices;
  DeviceDaoManager get managers => DeviceDaoManager(this);
}

class DeviceDaoManager {
  final _$DeviceDaoMixin _db;
  DeviceDaoManager(this._db);
  $$DeviceSettingsTableTableManager get deviceSettings =>
      $$DeviceSettingsTableTableManager(
        _db.attachedDatabase,
        _db.deviceSettings,
      );
  $$TrustedDevicesTableTableManager get trustedDevices =>
      $$TrustedDevicesTableTableManager(
        _db.attachedDatabase,
        _db.trustedDevices,
      );
}
