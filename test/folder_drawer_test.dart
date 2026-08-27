import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/database.dart';
import 'package:lan_notes/app/repository/folder_repository.dart';
import 'package:lan_notes/app/repository/note_repository.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/ui/home_page.dart';

/// 问题 1 回归：新建文件夹按钮可点击（弹命名框）+ 抽屉可展开。
void main() {
  late AppDatabase db;
  late NoteRepository noteRepo;
  late FolderRepository folderRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    noteRepo = NoteRepository(db.noteDao);
    folderRepo = FolderRepository(db.folderDao, noteRepo);
  });

  tearDown(() async {
    await db.close();
  });

  /// 卸载 widget 树释放 provider 对 db 的引用，并 pump 足够时长让
  /// drift stream 取消时创建的 0 延迟 Timer 执行完（否则测试结束会
  /// 报 "A Timer is still pending even after the widget tree was
  /// disposed"）。
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<ProviderScope> pumpApp(WidgetTester tester) async {
    final scope = ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteRepositoryProvider.overrideWithValue(noteRepo),
        folderRepositoryProvider.overrideWithValue(folderRepo),
      ],
      child: const MaterialApp(home: HomePage()),
    );
    await tester.pumpWidget(scope);
    // 消化入场/抽屉动画（不 pumpAndSettle——抽屉 AnimatedPositioned
    // 常驻，settle 可能等不到稳定）。
    await tester.pump(const Duration(milliseconds: 400));
    return scope;
  }

  testWidgets('新建文件夹按钮可点击并弹出命名框', (tester) async {
    await pumpApp(tester);

    // 打开抽屉（点击左上角文件夹按钮）。
    await tester.tap(find.byTooltip('文件夹'));
    await tester.pumpAndSettle();

    // 抽屉中应有「新建文件夹」按钮。
    expect(find.text('新建文件夹'), findsOneWidget);

    // 点击 → 弹出命名框。
    await tester.tap(find.text('新建文件夹'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 命名框出现（dialog 内 TextField；页面搜索框也是 TextField）。
    expect(find.byType(Dialog), findsOneWidget);
    final dialogTextField = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    expect(dialogTextField, findsOneWidget);
    expect(find.text('创建'), findsOneWidget);

    // 输入名称并确认 → 创建成功（仓库层真实写入）。
    await tester.enterText(dialogTextField, '测试文件夹');
    await tester.tap(find.text('创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final folders = await folderRepo.getActive();
    expect(folders.length, 1);
    expect(folders.first.name, '测试文件夹');

    // 卸载 widget 树（teardown 前释放 provider 对 db 的引用）。
    await disposeTree(tester);
  });

  testWidgets('多选模式隐藏文件夹按钮（不重叠）', (tester) async {
    // 注入一条笔记（多选需要长按卡片）。
    await noteRepo.createNote(title: '笔记一', content: '内容');
    await pumpApp(tester);

    // 长按卡片进入多选。
    await tester.longPress(find.text('笔记一'));
    await tester.pumpAndSettle();

    // 多选时文件夹按钮应隐藏。
    expect(find.byTooltip('文件夹'), findsNothing);
    // 多选工具栏出现。
    expect(find.text('已选 1 项'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('拖放注册表：抽屉展开后各落点矩形有效', (tester) async {
    await folderRepo.createFolder('工作');
    await noteRepo.createNote(title: '笔记一', content: '内容');
    await pumpApp(tester);

    // 打开抽屉。
    await tester.tap(find.byTooltip('文件夹'));
    await tester.pumpAndSettle();

    // 注册表应包含 __new__ / __all__ / 文件夹 id，且 rect 非空且有效。
    final registry = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    ).read(dropZoneRegistryProvider);
    final ids = registry.keys;
    expect(ids, contains('__new__'));
    expect(ids, contains('__all__'));
    for (final id in ids) {
      final rect = registry.rectOf(id);
      expect(rect, isNotNull, reason: '落点 $id 应有矩形');
      if (rect != null) {
        expect(rect.width, greaterThan(0));
        expect(rect.height, greaterThan(0));
      }
    }

    await disposeTree(tester);
  });
}
