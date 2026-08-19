import '../../data/note.dart';

/// 正文摘要：先按 delta JSON / 纯文本提取纯文本（task-29 富文本适配，
/// [Note.plainTextOf]），再折叠空白为单空格；空内容显示占位文案。
///
/// 列表页与回收站页共用（避免两处各自维护相同逻辑）。
String excerptOf(String content) {
  final text = Note.plainTextOf(content).trim().replaceAll(RegExp(r'\s+'), ' ');
  return text.isEmpty ? '空白笔记' : text;
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前，超过 7 天显示日期。
///
/// 列表页（updatedAt）与回收站页（deletedAt）共用。
String relativeTime(int epochMs) {
  final now = DateTime.now();
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = now.difference(time);
  if (diff.inMinutes < 1) {
    return '刚刚';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes} 分钟前';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours} 小时前';
  }
  if (diff.inDays < 7) {
    return '${diff.inDays} 天前';
  }
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  return '${time.year}-$month-$day';
}
