import '../../data/note.dart';

/// 正文摘要：先按 delta JSON / 纯文本提取纯文本（task-29 富文本适配，
/// [Note.plainTextOf]），再折叠空白为单空格；空内容显示占位文案。
///
/// 列表页与回收站页共用（避免两处各自维护相同逻辑）。
String excerptOf(String content) {
  final text = Note.plainTextOf(content).trim().replaceAll(RegExp(r'\s+'), ' ');
  return text.isEmpty ? '空白笔记' : text;
}

/// 标题展示兜底：标题为空时取正文第一句（第一个空白符或标点符号之前的
/// 内容，含中英文标点；全空白/首个字符即标点时回退「无标题」）。
///
/// 仅展示层使用（列表页/回收站页），不写库——用户之后补填标题不受影响。
String displayTitleOf(String title, String content) {
  final trimmed = title.trim();
  if (trimmed.isNotEmpty) return trimmed;
  final text = Note.plainTextOf(content).trim();
  if (text.isEmpty) return '无标题';
  // \p{P} 标点 + \p{S} 符号 + 空白：首个命中前即「第一句」（unicode 开关
  // 才支持 \p{} 属性类，中英文标点通用）。
  final match = RegExp(r'[\s\p{P}\p{S}]', unicode: true).firstMatch(text);
  final first = (match == null ? text : text.substring(0, match.start)).trim();
  return first.isEmpty ? '无标题' : first;
}

/// 相对时间：当天显示 刚刚 / N 分钟前 / N 小时前；非当天显示具体日期时间
/// （同年省略年份：MM-dd HH:mm；跨年带年份：yyyy-MM-dd HH:mm）。
///
/// 列表页（updatedAt）与回收站页（deletedAt）共用。
String relativeTime(int epochMs) {
  final now = DateTime.now();
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs);
  // 按「自然日」判断当天（而非 24h 差值）：昨天 23:00 的笔记在今天 01:00
  // 看也属于非当天，直接显示具体日期时间（用户需求）。
  final isToday =
      time.year == now.year && time.month == now.month && time.day == now.day;
  if (isToday) {
    final diff = now.difference(time);
    if (diff.inMinutes < 1) {
      return '刚刚';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes} 分钟前';
    }
    return '${diff.inHours} 小时前';
  }
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  if (time.year == now.year) {
    return '$month-$day $hour:$minute';
  }
  return '${time.year}-$month-$day $hour:$minute';
}
