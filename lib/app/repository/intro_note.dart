import 'dart:convert';

import '../data/database.dart';
import 'note_repository.dart';

/// 「首次安装介绍笔记已创建」标记键（存在 DeviceSettings 表）。
const String kIntroNoteCreatedKey = 'intro_note_created';

/// 介绍笔记标题。
const String _introTitle = '欢迎使用 lan-notes';

/// 介绍笔记正文（逐行 = 一段，存 delta JSON 与富文本正文格式一致）。
const List<String> _introLines = <String>[
  'lan-notes 是一款局域网多设备同步的笔记应用：数据只在你自己的设备之间流转，不经过任何服务器。',
  '新建：点右下角 + 按钮即可新建笔记，输入的内容会自动保存。',
  '仅本机保存：勾选「仅本机保存」（笔记页右上角 / 卡片右键菜单）后，这篇笔记不再同步到其他设备，其他设备上已有的副本会被删除。',
  '文件夹：点左上角文件夹按钮打开抽屉，把笔记拖到文件夹即可归类；抽屉最下方的「未分类」是还没归类的笔记。',
  '多设备同步：在「同步」页让两台设备互相搜索并配对，配对成功后笔记会自动同步。',
  '删除的笔记先进回收站，可在回收站恢复，也可彻底清空。',
  '这篇介绍笔记仅保存在本机（不会同步到其他设备），你可以随时删掉它。',
];

/// 首次安装时创建介绍笔记（**幂等**：标记已写入则直接返回）。
///
/// 语义（用户确认）：
/// - **仅本机保存**：介绍笔记创建为 localOnly=true，每台设备各自生成
///   一篇，不会同步给已配对的设备；
/// - **删掉不复活**：标记在成功创建后写入，用户删除笔记后不会再次生成。
///
/// 失败不抛给调用方之外的处理：调用方（main）已 try/catch，最坏情况是
/// 下次启动再试一次。
Future<void> ensureIntroNote(AppDatabase db, NoteRepository repository) async {
  final created = await db.deviceDao.getSetting(kIntroNoteCreatedKey);
  if (created != null) return;
  await repository.createNote(
    title: _introTitle,
    content: jsonEncode([
      for (final line in _introLines) {'insert': '$line\n'},
    ]),
    localOnly: true,
  );
  await db.deviceDao.setSetting(kIntroNoteCreatedKey, '1');
}
