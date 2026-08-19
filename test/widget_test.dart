import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/note.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/ui/home_page.dart';

void main() {
  testWidgets('主页可渲染：搜索框、同步入口、新建按钮', (WidgetTester tester) async {
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

    expect(find.text('搜索笔记'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
