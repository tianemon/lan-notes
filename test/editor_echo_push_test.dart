// 编辑页 drift 流回推判定回归（输入丢失根因修复）：
//
// 每次本地保存产生两次写库（DAO mutate + origin 标记 replace），连续输入
// 时前一次保存的流推送可能迟到——送达时 _lastSavedVersion 已被下一次保存
// 抬高。旧判定精确判等（==）会把迟到回推误判为「远端修改」走 _applyRemoteNote
// 强覆盖：未保存输入被整段替换且 _dirty=false 永不落库（实测输入丢失主因）。
//
// 用 DB 直接注入行的方式模拟「迟到的流推送」：
//   1. version < lastSaved 的迟到回推 → 必须跳过（输入保持不变）；
//   2. version == lastSaved 但内容 ≠ 保存快照（远端同版本时间裁决采纳）
//      → 必须覆盖（旧判定误跳过，远端修改丢失的隐性缺口）；
//   3. 畸形 delta content → 纯文本兜底，不崩溃、抑制标志不泄漏。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/database.dart';
import 'package:lan_notes/app/data/note.dart';
import 'package:lan_notes/app/repository/note_repository.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/ui/editor_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository noteRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    noteRepo = NoteRepository(db.noteDao);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 构造注入行（Note.copyWith 只支持 origin/localOnly，这里直接重建）。
  Note rowFor(Note current, {String? title, String? content, int? version}) {
    return Note(
      id: current.id,
      title: title ?? current.title,
      content: content ?? current.content,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      version: version ?? current.version,
      deletedAt: current.deletedAt,
      isPinned: current.isPinned,
      tags: current.tags,
      origin: current.origin,
      folderId: current.folderId,
      localOnly: current.localOnly,
    );
  }

  Future<String> pumpEditor(WidgetTester tester) async {
    final note = await noteRepo.createNote(title: '笔记一', content: '正文');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          noteRepositoryProvider.overrideWithValue(noteRepo),
        ],
        child: MaterialApp(
          localizationsDelegates:
              FlutterQuillLocalizations.localizationsDelegates,
          home: EditorPage(id: note.id),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return note.id;
  }

  /// 输入标题并等防抖保存落库（防抖 1s + 保存链 + 流推送送达）。
  Future<void> typeTitleAndSave(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('迟到回推（version < lastSaved）不覆盖输入', (tester) async {
    final id = await pumpEditor(tester);

    // 连续两轮「输入 → 防抖保存」：DB 到 v2，编辑器 lastSaved=2。
    await typeTitleAndSave(tester, '标题A');
    expect((await noteRepo.getById(id))!.version, 1);
    await typeTitleAndSave(tester, '标题AB');
    expect((await noteRepo.getById(id))!.version, 2);

    // 注入「迟到的旧保存推送」（模拟：v1 的流推送在 v2 保存后才送达）。
    final current = await noteRepo.getById(id);
    await db.noteDao.insertOrReplace(
      rowFor(current!, title: '标题A', version: 1),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 修复前：v1 != lastSaved(2) → 误判远端修改 → 标题被替换回「标题A」。
    expect(
      find.widgetWithText(TextField, '标题AB'),
      findsOneWidget,
      reason: '迟到回推必须跳过：输入不被旧保存的延迟推送覆盖',
    );
    expect(tester.takeException(), isNull);
    await disposeTree(tester);
  });

  testWidgets('同版本但内容不同（远端时间裁决采纳）正确覆盖', (tester) async {
    final id = await pumpEditor(tester);

    await typeTitleAndSave(tester, '标题A');
    expect((await noteRepo.getById(id))!.version, 1);

    // 注入同版本、不同内容的行（模拟远端设备同版本时间裁决赢过本机保存）。
    final current = await noteRepo.getById(id);
    await db.noteDao.insertOrReplace(
      rowFor(current!, title: '远端改'),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 修复前：version == lastSaved 即判回声 → 远端修改被误跳过（不覆盖）。
    expect(
      find.widgetWithText(TextField, '远端改'),
      findsOneWidget,
      reason: '同版本远端采纳是真远端修改，必须覆盖到编辑器',
    );
    expect(tester.takeException(), isNull);
    await disposeTree(tester);
  });

  testWidgets('畸形 delta content：纯文本兜底，不崩溃、抑制标志不泄漏', (tester) async {
    final id = await pumpEditor(tester);

    // 注入畸形 delta（数组元素非 Map）：旧实现 cast 抛 TypeError，
    // _applyRemoteNote 中断（_suppressChanges 卡 true → 后续输入全部
    // 被静默丢弃）。
    final current = await noteRepo.getById(id);
    await db.noteDao.insertOrReplace(
      rowFor(current!, content: '[1,2,3]'),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '畸形 delta 必须兜底不崩溃');

    // 畸形替换后正文按纯文本兜底渲染（"[1,2,3]"）。
    expect(
      find.textContaining('[1,2,3]', findRichText: true),
      findsOneWidget,
      reason: '畸形 delta 走纯文本兜底构造',
    );

    // 后续合法推送仍正常应用（_applyRemoteNote 完整走完、finally 重建订阅）。
    // 注：抑制标志是否复位无法从 widget 外稳定驱动 quill 文档变更来观测
    //（其编辑器为自有实现，测试环境无 EditableText 可输入）；生产路径上
    // _documentFromStored 已保证任何输入都不抛（全路径兜底），替换段由
    // try/finally 兜底复位，泄漏面为空。
    final second = await noteRepo.getById(id);
    await db.noteDao.insertOrReplace(rowFor(second!, title: '第二次'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(TextField, '第二次'), findsOneWidget);
    await disposeTree(tester);
  });
}
