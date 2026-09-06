// M1 回归：多选拖拽进行中被外部退出（PopScope 系统返回/抽屉点击等任何
// 来源——清理逻辑只依赖「多选集合变空 + 拖拽态残留」这一事实），拖拽态
// 必须被完整兜底清理：ghost 移除、落点高亮/拖拽标记复位、抽卡恢复。
// 清理挂 post-frame 执行（build 阶段同步写共享 ValueNotifier 会触发其他
// 组件 setState，框架禁止）——本测试同时守护「不再抛 setState during
// build」与「清理确实发生」两个断言面。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/database.dart';
import 'package:lan_notes/app/repository/folder_repository.dart';
import 'package:lan_notes/app/repository/note_repository.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/ui/home_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository noteRepo;
  late FolderRepository folderRepo;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    noteRepo = NoteRepository(db.noteDao);
    folderRepo = FolderRepository(db.folderDao, noteRepo);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        noteRepositoryProvider.overrideWithValue(noteRepo),
        folderRepositoryProvider.overrideWithValue(folderRepo),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await noteRepo.createNote(title: '拖拽清理测试', content: '');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 卸载 widget 树并 pump 足够时长（drift stream 取消产生的 0 延迟
  /// Timer 执行完，避免「Timer is still pending」误报）。
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('多选拖拽中退出多选：拖拽态被兜底清理，无 build 阶段异常',
      (tester) async {
    await pumpApp(tester);

    // 长按卡片进入多选（延迟拿起窗口 500ms 到期后自动拿起 = 拖拽开始）。
    final cardCenter = tester.getCenter(find.text('拖拽清理测试'));
    final gesture = await tester.startGesture(cardCenter);
    await tester.pump(const Duration(milliseconds: 600)); // 长按触发
    await tester.pump(const Duration(milliseconds: 600)); // 延迟拿起到期
    expect(container.read(multiSelectProvider), isNotEmpty,
        reason: '前置：长按已进入多选');

    final registry = container.read(dropZoneRegistryProvider);
    expect(registry.dragging.value, isTrue, reason: '前置：拖拽已开始');
    // 拖拽中卡片被抽走（hiddenIds），列表不渲染；ghost 浮层仍显示文本
    //（恰好 1 个可命中实例——ghost 自身）。

    // 外部退出多选（等价 PopScope 返回/抽屉点击的收敛点：集合清空）。
    container.read(multiSelectProvider.notifier).exit();
    await tester.pump(); // build：登记 post-frame 兜底清理
    await tester.pump(); // 执行 post-frame 清理 + 其触发的重建

    expect(tester.takeException(), isNull,
        reason: '清理必须发生在 post-frame（build 阶段同步清理会抛 '
            'setState during build）');
    expect(registry.dragging.value, isFalse, reason: '拖拽标记复位');
    expect(registry.highlighted.value, isNull, reason: '落点高亮复位');
    expect(container.read(multiSelectProvider), isEmpty);
    // 抽卡集合清空：卡片回到列表（ghost 已移除，文本唯一）。
    expect(find.text('拖拽清理测试'), findsOneWidget);

    await gesture.up();
    await disposeTree(tester);
  });
}
