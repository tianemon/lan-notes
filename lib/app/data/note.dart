import 'dart:convert';

import 'database.dart';

/// 笔记数据类：字段与 notes 表一致，同时承担同步协议传输载荷。
///
/// - [id]：UUID，跨设备全局唯一主键
/// - [createdAt] / [updatedAt]：epoch ms
/// - [version]：LWW 冲突合并用的单调递增版本号（默认 0）
/// - [deletedAt]：软删除标记（null=正常，非 null=回收站，epoch ms；
///   JSON 序列化中可缺失/null，兼容旧版数据与旧对端）
/// - [isPinned]：是否置顶（task-28，列表置顶优先；JSON 可缺失 → false，
///   兼容旧版数据与旧对端）
/// - [tags]：标签列表（task-28，列表页标签筛选；JSON 可缺失 → 空列表，
///   兼容旧版数据与旧对端）
/// - [content]：**task-29 富文本起存 delta JSON 字符串**（Quill Document 的
///   toJson 序列化，如 `[{"insert":"你好\n"}]`）；列类型不变（TEXT）。
///   存量纯文本在 schemaVersion 7→8 迁移时逐行转为 delta；首次读取兜底
///   （[plainTextOf]）也兼容纯文本。同步协议 v3 起 content 格式为 delta JSON，
///   LWW 合并仍把 content 当不透明字符串处理（格式由协议版本保证）。
class Note {
  final String id;
  final String title;
  final String content;
  final int createdAt;
  final int updatedAt;
  final int version;
  final int? deletedAt;
  final bool isPinned;
  final List<String> tags;

  const Note({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
    this.isPinned = false,
    this.tags = const [],
  });

  /// 从 drift 行数据转换（数据库读取 → 领域对象）。
  factory Note.fromRow(NoteRow row) {
    return Note(
      id: row.id,
      title: row.title,
      content: row.content,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      version: row.version,
      deletedAt: row.deletedAt,
      isPinned: row.isPinned,
      tags: _decodeTags(row.tags),
    );
  }

  /// 转换为 drift 行数据（领域对象 → 数据库写入）。
  NoteRow toRow() {
    return NoteRow(
      id: id,
      title: title,
      content: content,
      createdAt: createdAt,
      updatedAt: updatedAt,
      version: version,
      deletedAt: deletedAt,
      isPinned: isPinned,
      tags: jsonEncode(tags),
    );
  }

  /// 序列化为同步协议 JSON（字段与表一致，供 WebSocket 传输）。
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'version': version,
      'deletedAt': deletedAt,
      'isPinned': isPinned,
      'tags': tags,
    };
  }

  /// 从同步协议 JSON 反序列化（WebSocket 消息 → 领域对象）。
  ///
  /// `deletedAt` 缺失或为 null 均视为正常笔记；`isPinned` 缺失视为未置顶；
  /// `tags` 缺失视为无标签（兼容旧版对端/旧数据）。
  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] as String,
      title: (json['title'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
      createdAt: json['createdAt'] as int,
      updatedAt: json['updatedAt'] as int,
      version: (json['version'] as int?) ?? 0,
      deletedAt: json['deletedAt'] as int?,
      isPinned: (json['isPinned'] as bool?) ?? false,
      tags: _decodeTagsJson(json['tags']),
    );
  }

  /// 提取笔记正文纯文本（列表摘要 / 字数统计用，task-29 富文本适配）。
  ///
  /// 兼容两种存量格式：
  /// - **delta JSON**（新格式，可解析为 List）：逐个 op 拼接 `insert` 字符串，
  ///   embed 节点（如本地插图 `{"image":"attachments/x.jpg"}`）不计入文本；
  /// - **纯文本**（v8 迁移前的存量，或解析失败）：按原文返回（容错）。
  static String plainTextOf(String content) {
    if (content.isEmpty) return '';
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return content; // 非 JSON：存量纯文本
    }
    if (decoded is! List) {
      return content; // JSON 但非 delta 数组（异常数据）：按原样返回
    }
    final buffer = StringBuffer();
    for (final op in decoded) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is String) buffer.write(insert);
    }
    return buffer.toString();
  }

  /// 实例便捷方法：等价于 [Note.plainTextOf]（供列表摘要/字数直接调用）。
  String toPlainText() => Note.plainTextOf(content);

  /// 解析数据库 tags 列（JSON 数组字符串），非法/非数组 → 空列表。
  static List<String> _decodeTags(String raw) {
    try {
      return _decodeTagsJson(jsonDecode(raw));
    } catch (_) {
      return const [];
    }
  }

  /// 解析 JSON 载荷中的 tags 字段（`List<dynamic>`），非列表 → 空列表。
  static List<String> _decodeTagsJson(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    return const [];
  }
}
