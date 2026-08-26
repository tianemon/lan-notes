import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/note.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/ui/home_page.dart';

void main() {
  testWidgets('主页可渲染：文件夹按钮、搜索框、设置、新建按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 注入空笔记流，避免测试触碰真实数据库
          notesStreamProvider.overrideWith(
            (ref) => Stream.value(const <Note>[]),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );

    // task-32 布局重构：第一行文件夹按钮 + 三按钮，第二行搜索框。
    expect(find.text('搜索笔记'), findsOneWidget);
    expect(find.byTooltip('文件夹'), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    // add 图标出现在 FAB 与抽屉「新建文件夹」按钮（抽屉收起时仍在树中）。
    expect(find.byIcon(Icons.add), findsWidgets);
    // 消化入场动画，避免遗留 Timer 导致测试失败。
    await tester.pumpAndSettle();
  });
}
