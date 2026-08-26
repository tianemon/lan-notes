import 'database.dart';

/// 文件夹数据类：字段与 folders 表一致，同时承担同步协议传输载荷。
///
/// 字段体系与 [Note] 完全同构（LWW 合并框架复用，见 docs/技术架构.md 3.3 节）：
/// - [id]：UUID，跨设备全局唯一主键
/// - [name]：文件夹名称（允许重名，不做唯一性约束）
/// - [createdAt] / [updatedAt]：epoch ms
/// - [version]：LWW 冲突合并用的单调递增版本号（默认 0）
/// - [deletedAt]：软删除标记（null=正常，非 null=已删除；删除不可恢复，
///   无文件夹回收站，软删除条目仅从抽屉隐藏，仍随同步——LWW 语义与
///   笔记软删除一致）
/// - [isPinned]：置顶（抽屉置顶区，isPinned DESC → sortOrder ASC）
/// - [sortOrder]：手动排序键（拖拽排序后归一化为 0..n-1）
/// - [origin]：最后修改者 deviceId（同 [Note.origin]）
class Folder {
  final String id;
  final String name;
  final int createdAt;
  final int updatedAt;
  final int version;
  final int? deletedAt;
  final bool isPinned;
  final int sortOrder;
  final String? origin;

  const Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
    this.isPinned = false,
    this.sortOrder = 0,
    this.origin,
  });

  Folder copyWith({String? origin}) => Folder(
        id: id,
        name: name,
        createdAt: createdAt,
        updatedAt: updatedAt,
        version: version,
        deletedAt: deletedAt,
        isPinned: isPinned,
        sortOrder: sortOrder,
        origin: origin ?? this.origin,
      );

  /// 从 drift 行数据转换（数据库读取 → 领域对象）。
  factory Folder.fromRow(FolderRow row) {
    return Folder(
      id: row.id,
      name: row.name,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      version: row.version,
      deletedAt: row.deletedAt,
      isPinned: row.isPinned,
      sortOrder: row.sortOrder,
      origin: row.origin,
    );
  }

  /// 转换为 drift 行数据（领域对象 → 数据库写入）。
  FolderRow toRow() {
    return FolderRow(
      id: id,
      name: name,
      createdAt: createdAt,
      updatedAt: updatedAt,
      version: version,
      deletedAt: deletedAt,
      isPinned: isPinned,
      sortOrder: sortOrder,
      origin: origin,
    );
  }

  /// 序列化为同步协议 JSON（字段与表一致，供 WebSocket 传输）。
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'version': version,
      'deletedAt': deletedAt,
      'isPinned': isPinned,
      'sortOrder': sortOrder,
      if (origin != null) 'origin': origin,
    };
  }

  /// 从同步协议 JSON 反序列化（WebSocket 消息 → 领域对象）。
  ///
  /// `deletedAt` 缺失或为 null 均视为正常；`isPinned` 缺失视为未置顶；
  /// `sortOrder` 缺失视为 0（兼容旧对端——旧对端无文件夹消息，此路径
  /// 仅防畸形载荷）。
  factory Folder.fromJson(Map<String, dynamic> json) {
    return Folder(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      createdAt: json['createdAt'] as int,
      updatedAt: json['updatedAt'] as int,
      version: (json['version'] as int?) ?? 0,
      deletedAt: json['deletedAt'] as int?,
      isPinned: (json['isPinned'] as bool?) ?? false,
      sortOrder: (json['sortOrder'] as int?) ?? 0,
      origin: (json['origin'] as String?) ?? '',
    );
  }
}
