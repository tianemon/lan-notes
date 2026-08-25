import 'dart:convert';

import 'package:drift/drift.dart';

import 'device_dao.dart';
import 'notes_dao.dart';

part 'database.g.dart';

/// notes 表：跨设备同步的主数据表。
///
/// - [Notes.id]：UUID 文本主键，跨设备全局唯一
/// - [Notes.createdAt] / [Notes.updatedAt]：epoch ms
/// - [Notes.version]：LWW 冲突合并的单调递增版本号（默认 0）
/// - [Notes.deletedAt]：软删除标记（null=正常，非 null=回收站，epoch ms）
/// - [Notes.isPinned]：是否置顶（task-28，置顶优先排序，随同步）
/// - [Notes.tags]：标签 JSON 数组字符串（task-28，随同步）
/// - `updatedAt` 建索引：列表按更新时间倒序查询
@DataClassName('NoteRow')
@TableIndex(name: 'idx_notes_updated_at', columns: {#updatedAt})
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get content => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get version => integer().withDefault(const Constant(0))();

  /// 软删除时间（epoch ms）：null=正常，非 null=回收站
  ///（删除机制 v3 修订，见 docs/技术架构.md 3.3 节）。
  IntColumn get deletedAt => integer().nullable()();

  /// 是否置顶（task-28）：列表置顶优先排序（isPinned DESC → updatedAt DESC）；
  /// 置顶/取消经 [NoteRepository.setPinned] 变更，version+1 随同步。
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();

  /// 标签 JSON 数组字符串（task-28）：存 `["标签1","标签2"]`，列表页顶部
  /// 标签栏聚合筛选；经 [NoteRepository.setTags] 变更，version+1 随同步。
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 墓碑表：物理删除（清空回收站）后留下的删除标记，**永不清除**。
///
/// 防复活（docs/技术架构.md 3.3 节 v3 修订）：全量同步携带墓碑列表，
/// 离线设备带回的旧数据按 version/时间比较被墓碑拦截；个人笔记量级下
/// 墓碑累积可忽略，因此不做清理。
class Tombstones extends Table {
  /// 被物理删除的笔记 id。
  TextColumn get id => text()();

  /// 删除时刻的笔记 version：对端仅当本地 version ≤ 该值时执行删除
  /// （删除防乱序）；墓碑拦截时远端笔记 version 更大才放行。
  IntColumn get version => integer()();

  /// 物理删除时刻（epoch ms）：与 version 共同参与防复活比较。
  IntColumn get deletedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 设备设置表：本机持久化身份（键值对，单行语义）。
///
/// 键为 [kDeviceSettingDeviceId] / [kDeviceSettingDeviceName] /
/// [kDeviceSettingAutoSync] / `peer_addr_*`（对端地址缓存，v4）之一
/// （见 device_identity.dart）：
/// - `device_id`：首次启动生成的 UUID（重启不变，跨设备识别凭据）
/// - `device_name`：默认取系统主机名，可在设置中修改
/// - `auto_sync`：启动时自动同步开关（task-17）
/// - `peer_addr_<deviceId>`：对端最近地址/端口（v4 直连优先，task-27）
class DeviceSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 信任列表：已配对设备（凭据是 deviceId，IP 变化不影响识别）。
///
/// 配对成功后双方各自写入对方设备；后续连接凭本表直接放行
/// （v4 起无需密码，请求-同意配对，见 docs/技术架构.md 7.3 节）。
///
/// [autoConnect]：每设备「自动连接」开关（task-16，WiFi 式，默认开）——
/// 关闭后保持配对但不自动连接，手动点击仍可连（不改变配置）。
///
/// [secret]：HMAC 挑战认证密钥（task-27 v4，32 字节随机密钥的 hex 编码，
/// 每对设备共享一个——接受方生成经 pairing_accept 交换，请求方确认回发）。
/// 连接握手时对端用它计算 HMAC-SHA256 响应证明真身（防伪装 deviceId）；
/// v3 旧配对升级后为 null——升级后首次连接按未配对处理需重新配对获得密钥。
class TrustedDevices extends Table {
  TextColumn get deviceId => text()();
  TextColumn get deviceName => text()();
  IntColumn get pairedAt => integer()(); // epoch ms

  /// 是否自动连接该已配对设备（默认开；关闭 = 仅保存配对，不自动连）。
  BoolColumn get autoConnect => boolean().withDefault(const Constant(true))();

  /// 向对端同步（task-32）：本机是否把变更/全量推送给该设备（默认开）。
  BoolColumn get syncToPeer => boolean().withDefault(const Constant(true))();

  /// 从对端同步（task-32）：本机是否接收该设备推送的变更/全量（默认开）。
  BoolColumn get syncFromPeer => boolean().withDefault(const Constant(true))();

  /// HMAC 挑战认证密钥（32 字节随机 hex，nullable——旧配对升级后为 null）。
  TextColumn get secret => text().nullable()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// 本地数据库：drift 代码生成入口。
///
/// 使用 drift_flutter 的 [driftDatabase] 跨平台统一初始化
/// （桌面/移动端走系统 SQLite，见 docs/开发进度.md 风险记录）。
@DriftDatabase(
  tables: [Notes, Tombstones, DeviceSettings, TrustedDevices],
  daos: [NoteDao, DeviceDao],
)
class AppDatabase extends _$AppDatabase {
  /// 注入执行器：默认文件库由 providers.dart 传入（drift_flutter），
  /// 验证/调试可注入内存库（NativeDatabase.memory()）。
  ///
  /// 数据层保持纯 Dart（不依赖 drift_flutter / dart:ui），使
  /// `dart run temp/drafts/verify_sync.dart` 端到端验证脚本可以直接
  /// 实例化本类驱动真实数据层（见 task-9 联调记录）。
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 9;

  /// 迁移策略：v1（仅 Notes）→ v2（新增 DeviceSettings/TrustedDevices）
  /// → v3（TrustedDevices 加 autoConnect 列，task-16）→ v4（Notes 加
  /// deletedAt 列 + 新建 Tombstones 表，task-20 回收站+墓碑）→ v5
  /// （TrustedDevices 加 secret 列，task-27 v4 HMAC 挑战认证密钥）→ v6
  /// （Notes 加 isPinned 列，task-28 置顶）→ v7（Notes 加 tags 列，task-28
  /// 标签）→ v8（task-29 富文本：notes.content 纯文本 → delta JSON，
  /// 逐行转换，列类型不变）。
  ///
  /// task-12 新增两张表：旧库（schemaVersion=1）升级时仅建新表，
  /// 不触碰笔记数据；task-16 给信任列表加「自动连接」开关列（带默认值
  /// true，存量已配对设备升级后自动连接保持开启）；task-20 给 notes 加
  /// 软删除列（deletedAt 可空，存量笔记升级后默认 null=正常）+ 新建墓碑
  /// 表（空表即可，物理删除时按需写入）；task-27 给信任列表加认证密钥列
  /// （可空，存量已配对设备升级后 secret=null——首次连接按未配对处理，
  /// 需重新走请求-同意配对获得密钥，见 docs/技术架构.md 7.3 节）；
  /// task-28 给 notes 加置顶列（BOOL 默认 false，存量笔记升级后均不置顶）
  /// 与标签列（TEXT 默认 '[]'，存量笔记升级后无标签）；
  /// task-29（v8）不新增列：content 存储格式从纯文本改为 delta JSON，
  /// 逐行转换存量数据（已是 delta 的跳过，见 [_contentToDeltaV8]）；
  /// task-32（v9）：TrustedDevices 加 syncToPeer/syncFromPeer 列（默认 true，
  /// 存量已配对设备升级后双向同步保持开启）；连接策略简化为「永远自动
  /// 连接」+ 同步方向开关（autoConnect 列保留但不再控制连接）；
  /// 全新库走 onCreate 建全部表。
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(deviceSettings);
            await m.createTable(trustedDevices);
          }
          if (from < 3) {
            await m.addColumn(trustedDevices, trustedDevices.autoConnect);
          }
          if (from < 4) {
            await m.addColumn(notes, notes.deletedAt);
            await m.createTable(tombstones);
          }
          if (from < 5) {
            await m.addColumn(trustedDevices, trustedDevices.secret);
          }
          if (from < 6) {
            await m.addColumn(notes, notes.isPinned);
          }
          if (from < 7) {
            await m.addColumn(notes, notes.tags);
          }
          if (from < 8) {
            await _migrateContentToDeltaV8();
          }
          if (from < 9) {
            await m.addColumn(trustedDevices, trustedDevices.syncToPeer);
            await m.addColumn(trustedDevices, trustedDevices.syncFromPeer);
          }
        },
      );

  /// 单条 content 转 delta JSON（v8 迁移与纯 Dart 验证脚本共用）。
  ///
  /// 已是 delta（可解析为 List）原样保留；纯文本补尾换行后包一层 insert；
  /// 空内容 → `[]`（与 QuillEditor 空文档序列化一致）。
  static String contentToDeltaJson(String content) {
    if (content.isEmpty) return '[]';
    try {
      final decoded = jsonDecode(content);
      if (decoded is List) {
        return content; // 已是 delta JSON：原样保留
      }
    } catch (_) {
      // 非 JSON：纯文本，走转换
    }
    final text = content.endsWith('\n') ? content : '$content\n';
    return jsonEncode([{'insert': text}]);
  }

  /// v8 迁移（task-29 富文本）：存量 notes.content 逐行转换为 delta JSON。
  ///
  /// 存量可能是纯文本（旧数据）也可能是 delta（升级后又被旧版本写过等
  /// 异常场景）：先尝试解析 JSON——能解析为 List 视为 delta，原样保留；
  /// 解析失败视为纯文本，转换为 `[{"insert":"原文本\n"}]`（补尾换行，
  /// 空内容 → `[]`，与 QuillEditor 空文档序列化一致）。
  Future<void> _migrateContentToDeltaV8() async {
    final rows = await select(notes).get();
    for (final row in rows) {
      final converted = contentToDeltaJson(row.content);
      if (converted != row.content) {
        await (update(notes)..where((t) => t.id.equals(row.id)))
            .write(NotesCompanion(content: Value(converted)));
      }
    }
  }
}
